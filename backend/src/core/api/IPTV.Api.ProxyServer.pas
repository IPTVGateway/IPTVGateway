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
  // Indy
  IdHTTPServer,
  IdCustomHTTPServer,
  IdContext,
  // own
  IPTV.Ingest.Service;

type
  /// Stream-relay server (proxy mode): its own TIdHTTPServer that resolves a list
  /// stream and pumps the upstream bytes to the box.
  TStreamProxyServer = class
  private
    FServer: TIdHTTPServer;
    FLog: TLogProc;
    /// Handles one relay request (GET/HEAD) on an Indy worker thread.
    procedure DoCommandGet(AContext: TIdContext; ARequestInfo: TIdHTTPRequestInfo;
      AResponseInfo: TIdHTTPResponseInfo);
  public
    /// Creates the (inactive) relay server for APort with a bounded thread pool.
    constructor Create(APort: Integer; const ALog: TLogProc = nil);
    /// Stops the server and frees it.
    destructor Destroy; override;
    /// Opens the listener.
    procedure Start;
    /// Closes the listener (no-op when not active).
    procedure Stop;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.StrUtils,
  System.RegularExpressions,
  System.NetEncoding,
  System.Generics.Collections,
  // Indy
  IdHTTP,
  IdGlobal,
  IdIOHandler,
  IdSchedulerOfThreadPool,
  IdHeaderList,
  IdSSLOpenSSL,
  IdSSLOpenSSLHeaders,
  // own
  IPTV.Storage.Intf,
  IPTV.Model.Catalog,
  IPTV.Model.CustomList,
  IPTV.Model.Source,
  IPTV.App.Context,
  IPTV.Core.Utils,
  IPTV.Output.Builder,
  IPTV.Api.AuthThrottle,
  IPTV.Model.Types;

const
  // upstream client
  cRelayUserAgent = 'VLC/3.0.20 LibVLC/3.0.20';
  cMaxRedirects = 5;
  cTimeoutConnectMs = 8000;            // fail fast on a dead node (A3)
  cTimeoutReadMs = 30000;

  // thread pool: cap concurrent relays so a burst of zapping can't spawn
  // unbounded threads
  cProxyPoolSize = 20;                 // pre-created workers
  cProxyMaxThreads = 200;

  // HTTP status codes
  cHttpStatusOk = 200;
  cHttpStatusPartialContent = 206;
  cHttpStatusRedirectMin = 300;
  cHttpStatusErrorMin = 400;
  cHttpStatusBadRequest = 400;
  cHttpStatusUnauthorized = 401;
  cHttpStatusNotFound = 404;
  cHttpStatusServiceUnavailable = 503;

  // headers / MIME
  cHeaderContentType = 'Content-Type';
  cHeaderContentRange = 'Content-Range';
  cHeaderContentLength = 'Content-Length';
  cHeaderRange = 'Range';
  cHeaderIfRange = 'If-Range';
  cMimeMpegTs = 'video/mp2t';
  cMethodHead = 'HEAD';

  // stream extensions
  cExtTs = 'ts';
  cExtHls = 'm3u8';

  // request path: /{kind}/{user}/{pass}/{id}
  //   catch-up:   /timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts
  //   query form: /streaming/timeshift.php?username=&password=&stream=&start=&duration=
  cPathStreaming = 'streaming';
  cPathTimeshiftPhp = 'timeshift.php';
  cPathTimeshift = 'timeshift';
  cHeaderRetryAfter = 'Retry-After';
  // the first path segment the relay answers (anything else is a 404)
  cRelayKinds: array[0..4] of string = ('live', 'movie', 'series', 'stream', cPathTimeshift);
  cQueryUsername = 'username';
  cQueryPassword = 'password';
  cQueryDuration = 'duration';
  cQueryStart = 'start';
  cQueryStream = 'stream';
  cSegKind = 1;                        // Parts[0] is the '' before the leading '/'
  cSegUser = 2;
  cSegPass = 3;
  cSegId = 4;
  cSegTsMinutes = 4;
  cSegTsStart = 5;
  cSegTsId = 6;
  cSegCountTimeshiftPhp = 3;           // '', streaming, timeshift.php
  cSegCountMin = cSegId + 1;
  cSegCountTimeshift = cSegTsId + 1;

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
  lSources: TObjectList<TSourceConfig>;
  lSource: TSourceConfig;
begin
  Result := Format('source #%d', [ASourceId]);
  if AStore = nil then
    Exit;
  lSources := AStore.LoadSources;
  try
    for lSource in lSources do
      if lSource.Id = ASourceId then
        Exit(lSource.Name);
  finally
    FreeAndNil(lSources);
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
  lBuf: TIdBytes;
begin
  if Count > 0 then
  begin
    SetLength(lBuf, Count);
    Move(Buffer, lBuf[0], Count);
    FIO.Write(lBuf); // raises when the client disconnects -> stops the relay
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
    procedure HeadersAvailable(ASender: TObject; AHeaders: TIdHeaderList; var AContinue: Boolean);
    /// True once we've written ANY response (header/body) to the client — after that
    /// we can no longer fail over to another source mid-response.
    property Wrote: Boolean read FWritten;
  end;

constructor TRelaySession.Create(AIO: TIdIOHandler);
begin
  inherited Create;
  FIO := AIO;
end;

procedure TRelaySession.HeadersAvailable(ASender: TObject; AHeaders: TIdHeaderList;
  var AContinue: Boolean);
var
  lCode: Integer;
  lContentType, lContentRange, lContentLength, lHeader: string;
begin
  AContinue := True;
  lCode := TIdHTTP(ASender).ResponseCode;
  if (lCode >= cHttpStatusRedirectMin) and (lCode < cHttpStatusErrorMin) then
    Exit; // intermediate redirect — wait for the final response
  if FWritten then
    Exit;
  if (lCode >= cHttpStatusErrorMin) and FAllowFailover then
  begin
    // nothing written yet: let the caller fail over to another source
    FFailedCode := lCode;
    AContinue := False;
    Exit;
  end;
  FWritten := True;

  if lCode >= cHttpStatusErrorMin then
  begin
    // upstream error: tell the client and stop reading the error body
    FIO.Write(Format('HTTP/1.1 %d Upstream Error'#13#10'Connection: close'#13#10#13#10, [lCode]));
    AContinue := False;
    Exit;
  end;

  // STRIP CR/LF from upstream header values before we concatenate them into our
  // own raw response header — an upstream (or a host it 302-redirects to) could
  // otherwise inject extra headers / a split response (HTTP response splitting).
  lContentType := AHeaders.Values[cHeaderContentType].Replace(#13, '').Replace(#10, '');
  if lContentType = '' then
    lContentType := cMimeMpegTs;
  lContentRange := AHeaders.Values[cHeaderContentRange].Replace(#13, '').Replace(#10, '');
  lContentLength := AHeaders.Values[cHeaderContentLength].Replace(#13, '').Replace(#10, '');
  // Content-Length must be a plain number; ignore anything else (defence in depth)
  if (lContentLength <> '') and (StrToInt64Def(lContentLength, -1) < 0) then
    lContentLength := '';

  if lCode = cHttpStatusPartialContent then
    lHeader := 'HTTP/1.1 206 Partial Content'#13#10
  else
    lHeader := 'HTTP/1.1 200 OK'#13#10;
  lHeader := lHeader + cHeaderContentType + ': ' + lContentType + #13#10 + 'Accept-Ranges: bytes'#13#10 +
    // allow the in-browser Speler (mpegts.js) to fetch the relayed stream
    'Access-Control-Allow-Origin: *'#13#10;
  if lContentRange <> '' then
    lHeader := lHeader + cHeaderContentRange + ': ' + lContentRange + #13#10;
  if lContentLength <> '' then
    lHeader := lHeader + cHeaderContentLength + ': ' + lContentLength + #13#10;
  lHeader := lHeader + 'Connection: close'#13#10#13#10;
  FIO.Write(lHeader);
end;

// path segments of a raw request URI (query dropped), each percent-decoded
function RawPathSegments(const AUri: string): TArray<string>;
var
  lPath: string;
  lQ, i: Integer;
begin
  lPath := AUri;
  lQ := lPath.IndexOf('?');
  if lQ >= 0 then
    lPath := lPath.Substring(0, lQ);
  Result := lPath.Split(['/']);
  for i := 0 to High(Result) do
    try
      Result[i] := TNetEncoding.URL.URLDecode(Result[i]);
    except
      // malformed escape: keep the segment as sent
    end;
end;

{ TStreamProxyServer }

constructor TStreamProxyServer.Create(APort: Integer; const ALog: TLogProc);
var
  lSched: TIdSchedulerOfThreadPool;
begin
  inherited Create;
  FLog := ALog;
  FServer := TIdHTTPServer.Create(nil);
  FServer.DefaultPort := APort;
  FServer.OnCommandGet := DoCommandGet;
  // Bounded thread pool instead of Indy's default thread-per-connection, so a
  // zapping storm can't exhaust the machine (A4 of the proxy hardening spec).
  lSched := TIdSchedulerOfThreadPool.Create(FServer);
  lSched.PoolSize := cProxyPoolSize;
  lSched.MaxThreads := cProxyMaxThreads;
  FServer.Scheduler := lSched;
  FServer.KeepAlive := False; // streams are close-delimited; no server keep-alive
end;

destructor TStreamProxyServer.Destroy;
begin
  Stop;
  FreeAndNil(FServer);
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
  lParts: TArray<string>;
  lUser, lPass, lIdPart, lIdText: string;
  lDot, lStreamId: Integer;
  lList: TCustomList;
  lStream: TStreamItem;
  lUpstream: string;
  lSrcId: Integer;
  lListId: Integer;
  lUp: TIdHTTP;
  lFwd: TForwardStream;
  lIO: TIdIOHandler;
  lSession: TRelaySession;
  lSsl: TIdSSLIOHandlerSocketOpenSSL;
  lStore: IStore;
  lCandidates: TArray<string>;
  lIdx: Integer;
  lIsTimeshift: Boolean;
  lTsStart: TDateTime;
  lTsDur: Integer;
  lSource: TSourceConfig;
  lHlsUrl: string;
  lRetryAfter: Integer;
  lThrottleKey: string;
  lSibling: string;
begin
  lHlsUrl := '';
  if App = nil then
  begin
    AResponseInfo.ResponseNo := cHttpStatusServiceUnavailable;
    Exit;
  end;
  // the same lockout key as the box endpoints on the API port (behind a trusted
  // reverse proxy: the client from X-Forwarded-For, not the proxy's address)
  lThrottleKey := GAuthThrottle.ClientKey(cSurfaceBox, AContext.Binding.PeerIP,
    ARequestInfo.RawHeaders.Values[cHeaderForwardedFor]);
  // too many failed logins from this client: 429 until the lockout ends
  if GAuthThrottle.IsBlocked(lThrottleKey, lRetryAfter) then
  begin
    AResponseInfo.ResponseNo := cHttpTooManyRequests;
    AResponseInfo.CustomHeaders.Values[cHeaderRetryAfter] := IntToStr(lRetryAfter);
    Exit;
  end;
  // Hold a local interface ref to the store: a relay can run for minutes/hours, and
  // if the service is stopping (App := nil, FStore := nil) mid-stream, this ref keeps
  // the store alive until the relay finishes — no use-after-free. Log via our own
  // FLog (not App.Log) for the same reason.
  lStore := App.Store;
  // /live/{user}/{pass}/{id}   (or movie|series|stream)
  // Split the RAW path, then decode each segment: Indy's Document is already
  // decoded, so a '/' in a password (sent as %2F) would split the login in two.
  lParts := RawPathSegments(ARequestInfo.URI);
  // catch-up, query flavour: /streaming/timeshift.php?username=&password=&stream=&start=&duration=
  // -> rewritten to the path form below
  if (Length(lParts) = cSegCountTimeshiftPhp) and SameText(lParts[1], cPathStreaming) and
    SameText(lParts[2], cPathTimeshiftPhp) then
    lParts := ['', cPathTimeshift, ARequestInfo.Params.Values[cQueryUsername],
      ARequestInfo.Params.Values[cQueryPassword],
      ARequestInfo.Params.Values[cQueryDuration], ARequestInfo.Params.Values[cQueryStart],
      ARequestInfo.Params.Values[cQueryStream]];
  if Length(lParts) < cSegCountMin then
  begin
    AResponseInfo.ResponseNo := cHttpStatusBadRequest;
    Exit;
  end;
  // catch-up: /timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts
  if not MatchText(lParts[cSegKind], cRelayKinds) then
  begin
    AResponseInfo.ResponseNo := cHttpStatusNotFound; // e.g. /anything/u/p/12
    Exit;
  end;
  lIsTimeshift := SameText(lParts[cSegKind], cPathTimeshift);
  lTsDur := 0;
  lTsStart := 0;
  if lIsTimeshift then
  begin
    if (Length(lParts) < cSegCountTimeshift) or not ParseTimeshiftStart(lParts[cSegTsStart], lTsStart) then
    begin
      AResponseInfo.ResponseNo := cHttpStatusBadRequest;
      Exit;
    end;
    lTsDur := StrToIntDef(lParts[cSegTsMinutes], 0);
    if lTsDur <= 0 then
    begin
      AResponseInfo.ResponseNo := cHttpStatusBadRequest;
      Exit;
    end;
  end;
  lUser := lParts[cSegUser];
  lPass := lParts[cSegPass];
  if lIsTimeshift then
    lIdPart := lParts[cSegTsId]
  else
    lIdPart := lParts[cSegId];
  lIdText := lIdPart;
  lDot := lIdText.IndexOf('.');
  if lDot >= 0 then
    lIdText := lIdText.Substring(0, lDot);
  lStreamId := StrToIntDef(lIdText, 0);

  lList := FindListForPath(lStore, lUser, lPass); // '-' = empty login, %-encoding
  if lList = nil then
  begin
    GAuthThrottle.RegisterFailure(lThrottleKey); // a wrong bouquet login
    AResponseInfo.ResponseNo := cHttpStatusUnauthorized;
    Exit;
  end;
  GAuthThrottle.RegisterSuccess(lThrottleKey);
  lListId := lList.Id; // failover below plays through this list (a mirror's own account)
  try
    // scope to the authenticated list — don't relay a stream that isn't on it
    lStream := lStore.LoadListStreamById(lList.Id, lStreamId);
    if lStream = nil then
    begin
      AResponseInfo.ResponseNo := cHttpStatusNotFound;
      Exit;
    end;
    try
      if lIsTimeshift then
      begin
        lUpstream := TimeshiftUpstreamUrl(lStore, lListId, lStream, lTsDur, lTsStart,
          IfThen(lIdPart.Contains('.'), lIdPart.Substring(lIdPart.LastIndexOf('.') + 1), cExtTs));
        if lUpstream = '' then
        begin
          AResponseInfo.ResponseNo := cHttpStatusNotFound; // source isn't an Xtream portal
          Exit;
        end;
      end
      else
      begin
        lUpstream := lStream.UpstreamUrl;
        // HLS (asked as .m3u8, the source forces it, or the upstream URL itself is
        // a playlist - e.g. an M3U source's .../playlist.m3u8) can't be relayed as
        // one byte stream: bounce the box to the provider's playlist instead
        if lStream.ContentType = ctLive then
        begin
          lSource := FindSourceById(lStore, lStream.SourceId);
          try
            if SameText(UrlExt(lIdPart), cExtHls) or ((lSource <> nil) and lSource.ForceHls) or
               SameText(UrlExt(lUpstream), cExtHls) then
              lHlsUrl := LiveUpstreamUrl(lStore, lStream, cExtHls);
          finally
            FreeAndNil(lSource);
          end;
          if not SameText(UrlExt(lHlsUrl), cExtHls) then
            lHlsUrl := '';
        end;
      end;
      lSrcId := lStream.SourceId;
    finally
      FreeAndNil(lStream);
    end;
  finally
    FreeAndNil(lList);
  end;

  // HLS first, so a HEAD probe on such a channel gets the same 302 as the GET
  if lHlsUrl <> '' then
  begin
    if Assigned(FLog) then
      FLog(Format('proxy relay %s: HLS -> 302 to the provider %s', [lIdPart, MaskCreds(lHlsUrl)]));
    AResponseInfo.Redirect(lHlsUrl);
    Exit;
  end;

  // HEAD (players probing the URL): answer the headers, never start a relay that
  // would pull the whole stream from the provider
  if SameText(ARequestInfo.Command, cMethodHead) then
  begin
    AResponseInfo.ResponseNo := cHttpStatusOk;
    AResponseInfo.ContentType := cMimeMpegTs;
    Exit;
  end;

  // Candidate upstreams: the primary first, then the SAME channel from other sources
  // when failover is enabled — so a dead provider transparently falls back to another.
  // (Failover is only possible in relay mode; a single 302 redirect can't fail over.)
  lCandidates := [lUpstream];
  // (no failover for an archive: another provider's archive is a different recording;
  // and no HLS sibling: this relay pumps one TS byte stream, a playlist is useless)
  if App.Config.StreamFailover and not lIsTimeshift then
    for lSibling in lStore.LoadStreamSiblingsForList(lListId, lStreamId) do
      if not SameText(UrlExt(lSibling), cExtHls) then
        lCandidates := lCandidates + [lSibling];

  // We take the connection over completely: instead of letting Indy build a
  // response (it would emit a default text/html header + bogus Content-Length
  // and corrupt the stream), a TRelaySession writes our own header straight to
  // the socket from the upstream's final status — mirroring 200 vs 206 — right
  // before the body streams. Then TForwardStream pumps the body to the socket.
  lIO := AContext.Connection.IOHandler;
  for lIdx := 0 to High(lCandidates) do
  begin
    lSession := nil;
    lFwd := nil;
    lUp := nil;
    try
      lSession := TRelaySession.Create(lIO);
      lFwd := TForwardStream.Create(lIO);
      lUp := TIdHTTP.Create(nil);
      lUp.Request.UserAgent := cRelayUserAgent;
      lUp.HandleRedirects := True; // follow the provider's own 302(s)
      lUp.RedirectMaximum := cMaxRedirects;
      lUp.ConnectTimeout := cTimeoutConnectMs;
      lUp.ReadTimeout := cTimeoutReadMs;
      // don't raise on 4xx/5xx; TRelaySession maps the status to the client
      lUp.HTTPOptions := lUp.HTTPOptions + [hoNoProtocolErrorException];
      lUp.OnHeadersAvailable := lSession.HeadersAvailable;
      lSession.AllowFailover := lIdx < High(lCandidates);
      // Attach a TLS IOHandler unconditionally (Indy keeps it in PassThrough for
      // plain-http legs and only negotiates TLS for https) — a plain-http upstream
      // very commonly 302-redirects to an https streaming node, which would fail
      // with no IOHandler assigned. If OpenSSL libs are missing this raises and we
      // just log the closed relay.
      lSsl := TIdSSLIOHandlerSocketOpenSSL.Create(lUp);
      lSsl.SSLOptions.SSLVersions := [sslvTLSv1_2];
      lUp.IOHandler := lSsl;
      // pass the box's Range / If-Range through so VOD seeking works (A6)
      if ARequestInfo.RawHeaders.Values[cHeaderRange] <> '' then
        lUp.Request.CustomHeaders.AddValue(cHeaderRange, ARequestInfo.RawHeaders.Values[cHeaderRange]);
      if ARequestInfo.RawHeaders.Values[cHeaderIfRange] <> '' then
        lUp.Request.CustomHeaders.AddValue(cHeaderIfRange, ARequestInfo.RawHeaders.Values[cHeaderIfRange]);
      if Assigned(FLog) then
        FLog(Format('proxy relay %s -> provider "%s" %s%s',
          [lIdPart, ProviderName(lStore, lSrcId), MaskCreds(lCandidates[lIdx]),
           IfThen(lIdx > 0, ' (failover)', '')]));
      try
        lUp.Get(lCandidates[lIdx], lFwd); // blocks, pumping bytes until upstream ends / client closes
        if lSession.FailedCode > 0 then
        begin
          // upstream said 4xx/5xx and nothing reached the box: try the next source
          if Assigned(FLog) then
            FLog(Format('proxy relay %s: provider answered HTTP %d - trying next source',
              [lIdPart, lSession.FailedCode]));
          Continue;
        end;
        Break; // returned normally: streamed, or an upstream-error header was written
      except
        on E: Exception do
          // If nothing reached the client yet AND another source is available, fail
          // over to it. Otherwise (response already started, or last candidate) stop.
          if ((lFwd.Bytes = 0) and (not lSession.Wrote) or (lSession.FailedCode > 0)) and
             (lIdx < High(lCandidates)) then
          begin
            if Assigned(FLog) then
              FLog(Format('proxy relay %s: source unreachable (%s) — trying next source',
                [lIdPart, E.Message]));
          end
          else
          begin
            if Assigned(FLog) then
              FLog(Format('proxy relay %s closed (%d bytes): %s', [lIdPart, lFwd.Bytes, E.Message]));
            // nothing sent yet: a real status instead of an empty reply
            if (lFwd.Bytes = 0) and not lSession.Wrote then
              try
                lIO.Write('HTTP/1.1 502 Bad Gateway'#13#10'Connection: close'#13#10#13#10);
              except
                // the box is gone already: nothing to tell it
              end;
            Break;
          end;
      end;
    finally
      FreeAndNil(lUp);
      FreeAndNil(lFwd);
      FreeAndNil(lSession);
    end;
  end;
  try
    AContext.Connection.Disconnect;
  except
    // the box may already have dropped the connection: nothing left to close
  end;
end;

end.
