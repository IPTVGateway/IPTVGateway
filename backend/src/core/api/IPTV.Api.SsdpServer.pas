unit IPTV.Api.SsdpServer;

{ Minimal SSDP (UPnP discovery) responder so Plex auto-detects the emulated
  HDHomeRun tuner. Listens on UDP 1900 (multicast 239.255.255.250) and answers
  M-SEARCH probes with a LOCATION pointing at our /discover.json. That's all Plex
  needs to then pull discover.json + lineup.json over HTTP (the httpPort, 7777).

  Runs only while Plex HDHomeRun emulation is enabled. Best-effort: if the socket
  can't bind (port in use), it logs and stays off rather than killing the host. }

interface

uses
  // Indy
  IdGlobal,
  IdUDPServer,
  IdSocketHandle;

type
  /// Log callback (one line per call).
  TLogProc = reference to procedure(const AMsg: string);

  /// SSDP responder that advertises our emulated HDHomeRun tuner to Plex.
  TSsdpServer = class
  private
    FServer: TIdUDPServer;
    FLocation: string;
    FLog: TLogProc;
    procedure DoRead(AThread: TIdUDPListenerThread; const AData: TIdBytes;
      ABinding: TIdSocketHandle);
  public
    /// Creates the responder (not yet listening).
    // ALocation = absolute URL of our discover.json (e.g. http://host:7777/discover.json)
    constructor Create(const ALocation: string; const ALog: TLogProc = nil);
    /// Stops the responder and frees it.
    destructor Destroy; override;
    /// Binds UDP 1900 and starts answering M-SEARCH probes; logs and stays off on failure.
    procedure Start;
    /// Stops listening (no-op when not running).
    procedure Stop;
    /// The advertised discover.json URL (fixed per instance: a new location = a new
    /// responder, so the listener thread never reads a string being replaced).
    property Location: string read FLocation;
  end;

/// <summary>The search targets (ST) to answer for one M-SEARCH datagram: the requested
/// one when we provide it (echoed as the client wrote it), both of ours for
/// ssdp:all, none for anything else or for a datagram that isn't a discovery probe.</summary>
function SsdpReplyTargets(const ARequest: string): TArray<string>;

/// <summary>The unicast M-SEARCH reply for one search target.</summary>
function BuildSsdpReply(const ALocation, ASearchTarget: string): string;

implementation

uses
  // RTL
  System.SysUtils,
  // own units
  IPTV.Api.Security;

const
  // SSDP / UPnP discovery
  cSsdpPort = 1900;
  cSsdpGroup = '239.255.255.250';
  cBindAnyIPv4 = '0.0.0.0';
  // tokens of a discovery probe (matched on the upper-cased datagram)
  cProbeMSearch = 'M-SEARCH';
  cProbeSsdpDiscover = 'SSDP:DISCOVER';
  // search targets we answer (UPnP: a reply's ST must equal the request's ST;
  // ssdp:all is answered once per target we provide)
  cStAll = 'ssdp:all';
  cStRootDevice = 'upnp:rootdevice';
  cStMediaServer = 'urn:schemas-upnp-org:device:MediaServer:1';
  cStHeader = 'ST:';
  cDeviceUuid = 'uuid:iptvplay-hdhomerun';

constructor TSsdpServer.Create(const ALocation: string; const ALog: TLogProc);
begin
  inherited Create;
  FLocation := ALocation;
  FLog := ALog;
end;

destructor TSsdpServer.Destroy;
begin
  Stop;
  inherited;
end;

function SsdpReplyTargets(const ARequest: string): TArray<string>;
var
  lUpper, lLine, lTarget: string;
begin
  Result := nil;
  lUpper := UpperCase(ARequest);
  // only discovery probes (M-SEARCH ... MAN: "ssdp:discover")
  if (Pos(cProbeMSearch, lUpper) = 0) or (Pos(cProbeSsdpDiscover, lUpper) = 0) then
    Exit;
  lTarget := '';
  for lLine in ARequest.Split([#13#10, #10]) do
    if lLine.Trim.StartsWith(cStHeader, True) then
    begin
      lTarget := lLine.Trim.Substring(Length(cStHeader)).Trim;
      Break;
    end;
  if SameText(lTarget, cStAll) then
    Result := [cStRootDevice, cStMediaServer]
  else if SameText(lTarget, cStRootDevice) or SameText(lTarget, cStMediaServer) then
    Result := [lTarget]; // echoed as written: some clients compare it exactly
end;

function BuildSsdpReply(const ALocation, ASearchTarget: string): string;
begin
  Result :=
    'HTTP/1.1 200 OK'#13#10 +
    'CACHE-CONTROL: max-age=1800'#13#10 +
    'EXT:'#13#10 +
    'LOCATION: ' + ALocation + #13#10 +
    'SERVER: IPTVPlay/1.0 UPnP/1.0 HDHomeRun/1.0'#13#10 +
    'ST: ' + ASearchTarget + #13#10 +
    'USN: ' + cDeviceUuid + '::' + ASearchTarget + #13#10 +
    #13#10;
end;

procedure TSsdpServer.DoRead(AThread: TIdUDPListenerThread; const AData: TIdBytes;
  ABinding: TIdSocketHandle);
var
  lTarget: string;
begin
  // SSDP is a LAN protocol: a probe from a public address (a spoofed source on an
  // exposed UDP 1900) would turn us into a reflection/amplification source - ignored
  if not IsPrivateAddress(ABinding.PeerIP) then
    Exit;
  // before: every probe got "ST: upnp:rootdevice", whatever was searched for - a
  // client asking for another type (or ssdp:all) saw a mismatched answer
  for lTarget in SsdpReplyTargets(IndyTextEncoding_ASCII.GetString(AData)) do
    try
      // unicast reply straight back to the prober with our discover.json LOCATION
      ABinding.SendTo(ABinding.PeerIP, ABinding.PeerPort,
        ToBytes(BuildSsdpReply(FLocation, lTarget), IndyTextEncoding_ASCII), ABinding.IPVersion);
    except
      // ignore send failures (prober gone, etc.)
    end;
end;

procedure TSsdpServer.Start;
var
  lSrv: TIdUDPServer;
  lBinding: TIdSocketHandle;
begin
  if FServer <> nil then
    Exit;
  lSrv := TIdUDPServer.Create(nil);
  try
    lSrv.ThreadedEvent := True;
    lSrv.OnUDPRead := DoRead;
    lSrv.DefaultPort := cSsdpPort;
    lSrv.Bindings.Clear;
    lBinding := lSrv.Bindings.Add;
    lBinding.IPVersion := Id_IPv4;
    lBinding.IP := cBindAnyIPv4;
    lBinding.Port := cSsdpPort;
    lBinding.ReuseSocket := rsTrue; // share 1900 with any other UPnP users on the host
    lSrv.Active := True;
    try
      lBinding.AddMulticastMembership(cSsdpGroup); // also see multicast M-SEARCH
    except
      // some stacks reject this; unicast replies still work for many setups
    end;
    FServer := lSrv;
    if Assigned(FLog) then
      FLog(Format('SSDP responder on UDP %d -> %s', [cSsdpPort, FLocation]));
  except
    on E: Exception do
    begin
      FreeAndNil(lSrv);
      if Assigned(FLog) then
        FLog('SSDP responder not started: ' + E.Message);
    end;
  end;
end;

procedure TSsdpServer.Stop;
begin
  if FServer = nil then
    Exit;
  try
    FServer.Active := False;
  except
    // shutting down: a failing socket close must not keep us from freeing it
  end;
  FreeAndNil(FServer);
end;

end.
