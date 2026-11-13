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
  end;

implementation

uses
  // RTL
  System.SysUtils;

const
  // SSDP / UPnP discovery
  cSsdpPort = 1900;
  cSsdpGroup = '239.255.255.250';
  cBindAnyIPv4 = '0.0.0.0';
  // tokens of a discovery probe (matched on the upper-cased datagram)
  cProbeMSearch = 'M-SEARCH';
  cProbeSsdpDiscover = 'SSDP:DISCOVER';

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

procedure TSsdpServer.DoRead(AThread: TIdUDPListenerThread; const AData: TIdBytes;
  ABinding: TIdSocketHandle);
var
  lMsg, lResp: string;
begin
  lMsg := UpperCase(IndyTextEncoding_ASCII.GetString(AData));
  // only answer discovery probes (M-SEARCH ... Man: "ssdp:discover")
  if (Pos(cProbeMSearch, lMsg) = 0) or (Pos(cProbeSsdpDiscover, lMsg) = 0) then
    Exit;
  // unicast reply straight back to the prober with our discover.json LOCATION
  lResp :=
    'HTTP/1.1 200 OK'#13#10 +
    'CACHE-CONTROL: max-age=1800'#13#10 +
    'EXT:'#13#10 +
    'LOCATION: ' + FLocation + #13#10 +
    'SERVER: IPTVPlay/1.0 UPnP/1.0 HDHomeRun/1.0'#13#10 +
    'ST: upnp:rootdevice'#13#10 +
    'USN: uuid:iptvplay-hdhomerun::upnp:rootdevice'#13#10 +
    #13#10;
  try
    ABinding.SendTo(ABinding.PeerIP, ABinding.PeerPort,
      ToBytes(lResp, IndyTextEncoding_ASCII), ABinding.IPVersion);
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
