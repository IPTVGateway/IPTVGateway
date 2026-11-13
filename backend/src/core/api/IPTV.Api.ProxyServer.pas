unit IPTV.Api.ProxyServer;

(* Optional stream-relay server on its own port (default 7778), separate from the
  MARS API (catalog/EPG/admin on httpPort). Built on a raw TIdHTTPServer so we
  can do a true chunked passthrough — MARS's response model assumes a finite
  body, which doesn't fit an open-ended live stream.

  Routes (the list login is in the path, like Xtream): GET /live|movie|series|stream/{user}/{pass}/{id}
  and catch-up GET /timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts
  -> resolve the list by credentials, look up the upstream URL, then pull it with
  a second TIdHTTP (VLC UA, follows the provider's own redirects) and pump the
  bytes straight to the client connection until either side closes.

  Video flows box <-> this server <-> provider — the point of proxy mode. *)

interface

uses
  IdHTTPServer, IdCustomHTTPServer, IdContext,
  IPTV.Ingest.Service;

type
  TStreamProxyServer = class
  private
    FServer: TIdHTTPServer;
    FLog: TLogProc;
    procedure DoCommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
  public
    constructor Create(APort: Integer; const ALog: TLogProc = nil);
    destructor Destroy; override;
    procedure Start;
    procedure Stop;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.StrUtils, System.RegularExpressions,
  IdHTTP, IdGlobal, IdIOHandler, IdSchedulerOfThreadPool, IdHeaderList,
  IdSSLOpenSSL, IdSSLOpenSSLHeaders,
  System.Generics.Collections,
  IPTV.Storage.Intf,
  IPTV.Model.Catalog, IPTV.Model.CustomList, IPTV.Model.Source, IPTV.App.Context,
  IPTV.Core.Utils, IPTV.Output.Builder;

const
  UA = 'VLC/3.0.20 LibVLC/3.0.20';
  // Cap concurrent relays so a burst of zapping can't spawn unbounded threads.
  ProxyMaxThreads = 200;

// Mask credentials before logging an upstream URL. Providers embed creds both as
// Xtream path segments (/live/{user}/{pass}/) and as query params
// (?username=&password=&token=). Never log either verbatim.
function MaskCreds(const AUrl: string): string;
begin
  Result := TRegEx.Replace(AUrl, '(/(live|movie|series|stream|timeshift)/)[^/]+/[^/]+/',
    '$1***/***/', [roIgnoreCase]);
  Result := TRegEx.Replace(Result, '([?&](username|password|pass|pw|user|token|auth|mac)=)[^&]*',
    '$1***', [roIgnoreCase]);
end;

// the operator's name for the source a stream belongs to (for the relay log);
// falls back to "source #id" when the row is gone. Takes the store by interface
// (not via global App) so a long-lived relay never touches App after it may be nil.
function ProviderName(const AStore: IStore; ASourceId: Integer): string;
var
  Sources: TObjectList<TSourceConfig>;
  S: TSourceConfig;
begin
  Result := Format('source #%d', [ASourceId]);
  if AStore = nil then
    Exit;
  Sources := AStore.LoadSources;
  try
    for S in Sources do
      if S.Id = ASourceId then
        Exit(S.Name);
  finally
    Sources.Free;
  end;
end;

type
  // write-only stream that forwards everything to a client connection
  TForwardStream = class(TStream)
  private
    FIO: TIdIOHandler;
    FBytes: Int64;
  public
    constructor Create(AIO: TIdIOHandler);
    function Write(const Buffer; Count: Longint): Longint; override;
    function Read(var Buffer; Count: Longint): Longint; override;
    function Seek(const Offset: Int64; Origin: TSeekOrigin): Int64; override;
    property Bytes: Int64 read FBytes;
  end;

constructor TForwardStream.Create(AIO: TIdIOHandler);
begin
  inherited Create;
  FIO := AIO;
end;

function TForwardStream.Write(const Buffer; Count: Longint): Longint;
var
  B: TIdBytes;
begin
  if Count > 0 then
  begin
    SetLength(B, Count);
    Move(Buffer, B[0], Count);
    FIO.Write(B); // raises when the client disconnects -> stops the relay
    Inc(FBytes, Count);
  end;
  Result := Count;
end;

function TForwardStream.Read(var Buffer; Count: Longint): Longint;
begin
  Result := 0;
end;

function TForwardStream.Seek(const Offset: Int64; Origin: TSeekOrigin): Int64;
begin
  Result := FBytes;
end;

{ TRelaySession — writes the client response header from the upstream's final
  response (so we mirror 200 vs 206 Partial Content), once, before the body
  starts streaming. One instance per relayed request → thread-safe. }

type
  TRelaySession = class
  private
    FIO: TIdIOHandler;
    FWritten: Boolean;
    FAllowFailover: Boolean;
    FFailedCode: Integer;
  public
    constructor Create(AIO: TIdIOHandler);
    /// When set, an upstream 4xx/5xx is NOT passed to the client: FailedCode is
    /// set instead, so the caller can try the next source.
    property AllowFailover: Boolean read FAllowFailover write FAllowFailover;
    property FailedCode: Integer read FFailedCode;
    procedure HeadersAvailable(Sender: TObject; AHeaders: TIdHeaderList; var VContinue: Boolean);
    /// True once we've written ANY response (header/body) to the client — after that
    /// we can no longer fail over to another source mid-response.
    property Wrote: Boolean read FWritten;
  end;

constructor TRelaySession.Create(AIO: TIdIOHandler);
begin
  inherited Create;
  FIO := AIO;
end;

procedure TRelaySession.HeadersAvailable(Sender: TObject; AHeaders: TIdHeaderList;
  var VContinue: Boolean);
var
  Code: Integer;
  CT, CR, CL, Hdr: string;
begin
  VContinue := True;
  Code := TIdHTTP(Sender).ResponseCode;
  if (Code >= 300) and (Code < 400) then
    Exit; // intermediate redirect — wait for the final response
  if FWritten then
    Exit;
  if (Code >= 400) and FAllowFailover then
  begin
    // nothing written yet: let the caller fail over to another source
    FFailedCode := Code;
    VContinue := False;
    Exit;
  end;
  FWritten := True;

  if Code >= 400 then
  begin
    // upstream error: tell the client and stop reading the error body
    FIO.Write(Format('HTTP/1.1 %d Upstream Error'#13#10'Connection: close'#13#10#13#10, [Code]));
    VContinue := False;
    Exit;
  end;

  // STRIP CR/LF from upstream header values before we concatenate them into our
  // own raw response header — an upstream (or a host it 302-redirects to) could
  // otherwise inject extra headers / a split response (HTTP response splitting).
  CT := AHeaders.Values['Content-Type'].Replace(#13, '').Replace(#10, '');
  if CT = '' then
    CT := 'video/mp2t';
  CR := AHeaders.Values['Content-Range'].Replace(#13, '').Replace(#10, '');
  CL := AHeaders.Values['Content-Length'].Replace(#13, '').Replace(#10, '');
  // Content-Length must be a plain number; ignore anything else (defence in depth)
  if (CL <> '') and (StrToInt64Def(CL, -1) < 0) then
    CL := '';

  if Code = 206 then
    Hdr := 'HTTP/1.1 206 Partial Content'#13#10
  else
    Hdr := 'HTTP/1.1 200 OK'#13#10;
  Hdr := Hdr + 'Content-Type: ' + CT + #13#10 + 'Accept-Ranges: bytes'#13#10 +
    // allow the in-browser Speler (mpegts.js) to fetch the relayed stream
    'Access-Control-Allow-Origin: *'#13#10;
  if CR <> '' then
    Hdr := Hdr + 'Content-Range: ' + CR + #13#10;
  if CL <> '' then
    Hdr := Hdr + 'Content-Length: ' + CL + #13#10;
  Hdr := Hdr + 'Connection: close'#13#10#13#10;
  FIO.Write(Hdr);
end;

{ TStreamProxyServer }

constructor TStreamProxyServer.Create(APort: Integer; const ALog: TLogProc);
begin
  inherited Create;
  FLog := ALog;
  FServer := TIdHTTPServer.Create(nil);
  FServer.DefaultPort := APort;
  FServer.OnCommandGet := DoCommandGet;
  // Bounded thread pool instead of Indy's default thread-per-connection, so a
  // zapping storm can't exhaust the machine (A4 of the proxy hardening spec).
  var Sched := TIdSchedulerOfThreadPool.Create(FServer);
  Sched.PoolSize := 20;       // pre-created workers
  Sched.MaxThreads := ProxyMaxThreads;
  FServer.Scheduler := Sched;
  FServer.KeepAlive := False; // streams are close-delimited; no server keep-alive
end;

destructor TStreamProxyServer.Destroy;
begin
  Stop;
  FServer.Free;
  inherited;
end;

procedure TStreamProxyServer.Start;
begin
  FServer.Active := True;
  if Assigned(FLog) then
    FLog(Format('Stream proxy listening on port %d', [FServer.DefaultPort]));
end;

procedure TStreamProxyServer.Stop;
begin
  if FServer.Active then
    FServer.Active := False;
end;

procedure TStreamProxyServer.DoCommandGet(AContext: TIdContext;
  ARequestInfo: TIdHTTPRequestInfo; AResponseInfo: TIdHTTPResponseInfo);
var
  Parts: TArray<string>;
  User, Pass, IdPart, S: string;
  Dot, StreamId: Integer;
  List: TCustomList;
  Stream: TStreamItem;
  Upstream: string;
  SrcId: Integer;
  Up: TIdHTTP;
  Fwd: TForwardStream;
  IO: TIdIOHandler;
  Session: TRelaySession;
  SSL: TIdSSLIOHandlerSocketOpenSSL;
  LStore: IStore;
  Candidates: TArray<string>;
  Idx: Integer;
  IsTimeshift: Boolean;
  TsStart: TDateTime;
  TsDur: Integer;
begin
  if App = nil then
  begin
    AResponseInfo.ResponseNo := 503;
    Exit;
  end;
  // Hold a local interface ref to the store: a relay can run for minutes/hours, and
  // if the service is stopping (App := nil, FStore := nil) mid-stream, this ref keeps
  // the store alive until the relay finishes — no use-after-free. Log via our own
  // FLog (not App.Log) for the same reason.
  LStore := App.Store;
  // /live/{user}/{pass}/{id}   (or movie|series|stream)
  Parts := ARequestInfo.Document.Split(['/']);
  // catch-up, query flavour: /streaming/timeshift.php?username=&password=&stream=&start=&duration=
  // -> rewritten to the path form below
  if (Length(Parts) = 3) and SameText(Parts[1], 'streaming') and SameText(Parts[2], 'timeshift.php') then
    Parts := ['', 'timeshift', ARequestInfo.Params.Values['username'], ARequestInfo.Params.Values['password'],
      ARequestInfo.Params.Values['duration'], ARequestInfo.Params.Values['start'],
      ARequestInfo.Params.Values['stream']];
  if Length(Parts) < 5 then
  begin
    AResponseInfo.ResponseNo := 400;
    Exit;
  end;
  // catch-up: /timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts
  IsTimeshift := SameText(Parts[1], 'timeshift');
  TsDur := 0;
  TsStart := 0;
  if IsTimeshift then
  begin
    if (Length(Parts) < 7) or not ParseTimeshiftStart(Parts[5], TsStart) then
    begin
      AResponseInfo.ResponseNo := 400;
      Exit;
    end;
    TsDur := StrToIntDef(Parts[4], 0);
    if TsDur <= 0 then
    begin
      AResponseInfo.ResponseNo := 400;
      Exit;
    end;
  end;
  User := Parts[2];
  Pass := Parts[3];
  if IsTimeshift then
    IdPart := Parts[6]
  else
    IdPart := Parts[4];
  S := IdPart;
  Dot := S.IndexOf('.');
  if Dot >= 0 then
    S := S.Substring(0, Dot);
  StreamId := StrToIntDef(S, 0);

  List := FindListForPath(LStore, User, Pass); // '-' = empty login, %-encoding
  if List = nil then
  begin
    AResponseInfo.ResponseNo := 401;
    Exit;
  end;
  try
    // scope to the authenticated list — don't relay a stream that isn't on it
    Stream := LStore.LoadListStreamById(List.Id, StreamId);
    if Stream = nil then
    begin
      AResponseInfo.ResponseNo := 404;
      Exit;
    end;
    try
      if IsTimeshift then
      begin
        Upstream := TimeshiftUpstreamUrl(LStore, Stream, TsDur, TsStart,
          IfThen(IdPart.Contains('.'), IdPart.Substring(IdPart.LastIndexOf('.') + 1), 'ts'));
        if Upstream = '' then
        begin
          AResponseInfo.ResponseNo := 404; // source isn't an Xtream portal
          Exit;
        end;
      end
      else
        Upstream := Stream.UpstreamUrl;
      SrcId := Stream.SourceId;
    finally
      Stream.Free;
    end;
  finally
    List.Free;
  end;

  // Candidate upstreams: the primary first, then the SAME channel from other sources
  // when failover is enabled — so a dead provider transparently falls back to another.
  // (Failover is only possible in relay mode; a single 302 redirect can't fail over.)
  Candidates := [Upstream];
  // (no failover for an archive: another provider's archive is a different recording)
  if App.Config.StreamFailover and not IsTimeshift then
    Candidates := Candidates + LStore.LoadStreamSiblings(StreamId);

  // We take the connection over completely: instead of letting Indy build a
  // response (it would emit a default text/html header + bogus Content-Length
  // and corrupt the stream), a TRelaySession writes our own header straight to
  // the socket from the upstream's final status — mirroring 200 vs 206 — right
  // before the body streams. Then TForwardStream pumps the body to the socket.
  IO := AContext.Connection.IOHandler;
  for Idx := 0 to High(Candidates) do
  begin
    Session := TRelaySession.Create(IO);
    Fwd := TForwardStream.Create(IO);
    Up := TIdHTTP.Create(nil);
    try
      Up.Request.UserAgent := UA;
      Up.HandleRedirects := True; // follow the provider's own 302(s)
      Up.RedirectMaximum := 5;
      Up.ConnectTimeout := 8000;  // fail fast on a dead node (A3)
      Up.ReadTimeout := 30000;
      // don't raise on 4xx/5xx; TRelaySession maps the status to the client
      Up.HTTPOptions := Up.HTTPOptions + [hoNoProtocolErrorException];
      Up.OnHeadersAvailable := Session.HeadersAvailable;
      Session.AllowFailover := Idx < High(Candidates);
      // Attach a TLS IOHandler unconditionally (Indy keeps it in PassThrough for
      // plain-http legs and only negotiates TLS for https) — a plain-http upstream
      // very commonly 302-redirects to an https streaming node, which would fail
      // with no IOHandler assigned. If OpenSSL libs are missing this raises and we
      // just log the closed relay.
      SSL := TIdSSLIOHandlerSocketOpenSSL.Create(Up);
      SSL.SSLOptions.SSLVersions := [sslvTLSv1_2];
      Up.IOHandler := SSL;
      // pass the box's Range / If-Range through so VOD seeking works (A6)
      if ARequestInfo.RawHeaders.Values['Range'] <> '' then
        Up.Request.CustomHeaders.AddValue('Range', ARequestInfo.RawHeaders.Values['Range']);
      if ARequestInfo.RawHeaders.Values['If-Range'] <> '' then
        Up.Request.CustomHeaders.AddValue('If-Range', ARequestInfo.RawHeaders.Values['If-Range']);
      if Assigned(FLog) then
        FLog(Format('proxy relay %s -> provider "%s" %s%s',
          [IdPart, ProviderName(LStore, SrcId), MaskCreds(Candidates[Idx]),
           IfThen(Idx > 0, ' (failover)', '')]));
      try
        Up.Get(Candidates[Idx], Fwd); // blocks, pumping bytes until upstream ends / client closes
        if Session.FailedCode > 0 then
        begin
          // upstream said 4xx/5xx and nothing reached the box: try the next source
          if Assigned(FLog) then
            FLog(Format('proxy relay %s: provider answered HTTP %d - trying next source',
              [IdPart, Session.FailedCode]));
          Continue;
        end;
        Break; // returned normally: streamed, or an upstream-error header was written
      except
        on E: Exception do
          // If nothing reached the client yet AND another source is available, fail
          // over to it. Otherwise (response already started, or last candidate) stop.
          if ((Fwd.Bytes = 0) and (not Session.Wrote) or (Session.FailedCode > 0)) and
             (Idx < High(Candidates)) then
          begin
            if Assigned(FLog) then
              FLog(Format('proxy relay %s: source unreachable (%s) — trying next source',
                [IdPart, E.Message]));
          end
          else
          begin
            if Assigned(FLog) then
              FLog(Format('proxy relay %s closed (%d bytes): %s', [IdPart, Fwd.Bytes, E.Message]));
            Break;
          end;
      end;
    finally
      Up.Free;
      Fwd.Free;
      Session.Free;
    end;
  end;
  try
    AContext.Connection.Disconnect;
  except
  end;
end;

end.
