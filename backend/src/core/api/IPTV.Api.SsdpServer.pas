unit IPTV.Api.SsdpServer;

{ Minimal SSDP (UPnP discovery) responder so Plex auto-detects the emulated
  HDHomeRun tuner. Listens on UDP 1900 (multicast 239.255.255.250) and answers
  M-SEARCH probes with a LOCATION pointing at our /discover.json. That's all Plex
  needs to then pull discover.json + lineup.json over HTTP (the httpPort, 7777).

  Runs only while Plex HDHomeRun emulation is enabled. Best-effort: if the socket
  can't bind (port in use), it logs and stays off rather than killing the host. }

interface

uses
  IdGlobal, IdUDPServer, IdSocketHandle;

type
  TLogProc = reference to procedure(const AMsg: string);

  TSsdpServer = class
  private
    FServer: TIdUDPServer;
    FLocation: string;
    FLog: TLogProc;
    procedure DoRead(AThread: TIdUDPListenerThread; const AData: TIdBytes;
      ABinding: TIdSocketHandle);
  public
    // ALocation = absolute URL of our discover.json (e.g. http://host:7777/discover.json)
    constructor Create(const ALocation: string; const ALog: TLogProc = nil);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

implementation

uses
  System.SysUtils;

const
  SSDP_PORT = 1900;
  SSDP_GROUP = '239.255.255.250';

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
  Msg, Resp: string;
begin
  Msg := UpperCase(IndyTextEncoding_ASCII.GetString(AData));
  // only answer discovery probes (M-SEARCH ... Man: "ssdp:discover")
  if (Pos('M-SEARCH', Msg) = 0) or (Pos('SSDP:DISCOVER', Msg) = 0) then
    Exit;
  // unicast reply straight back to the prober with our discover.json LOCATION
  Resp :=
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
      ToBytes(Resp, IndyTextEncoding_ASCII), ABinding.IPVersion);
  except
    // ignore send failures (prober gone, etc.)
  end;
end;

procedure TSsdpServer.Start;
var
  Srv: TIdUDPServer;
  B: TIdSocketHandle;
begin
  if FServer <> nil then
    Exit;
  Srv := TIdUDPServer.Create(nil);
  try
    Srv.ThreadedEvent := True;
    Srv.OnUDPRead := DoRead;
    Srv.DefaultPort := SSDP_PORT;
    Srv.Bindings.Clear;
    B := Srv.Bindings.Add;
    B.IPVersion := Id_IPv4;
    B.IP := '0.0.0.0';
    B.Port := SSDP_PORT;
    B.ReuseSocket := rsTrue; // share 1900 with any other UPnP users on the host
    Srv.Active := True;
    try
      B.AddMulticastMembership(SSDP_GROUP); // also see multicast M-SEARCH
    except
      // some stacks reject this; unicast replies still work for many setups
    end;
    FServer := Srv;
    if Assigned(FLog) then
      FLog(Format('SSDP responder on UDP %d -> %s', [SSDP_PORT, FLocation]));
  except
    on E: Exception do
    begin
      Srv.Free;
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
  end;
  FreeAndNil(FServer);
end;

end.
