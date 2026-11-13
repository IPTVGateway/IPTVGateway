unit IPTV.Api.Server;

{ HTTP bootstrap on MARS-Curiosity (Andrea Magni). Owns a MARS engine + an Indy
  HTTP server and runs the admin REST API and the outgoing Xtream-portal
  emulation, both mounted at the root so boxes hit /player_api.php etc. and the
  React app hits /api/... directly.

  Resources register themselves (MARSRegister) in IPTV.Api.Mars.* units; the
  engine picks them up via the 'IPTV.Api.Mars.*' wildcard. TLS uses the engine's
  PortSSL + Indy.SSL.* parameters (deploy the OpenSSL libraries).

  TApiServer keeps the same Create(config)/Start/Stop surface, so TAppContext is
  unchanged by the Horse->MARS switch. }

interface

uses
  // MARS
  MARS.Core.Engine.Interfaces,
  MARS.http.Server.Indy,
  // own
  IPTV.App.Config,
  IPTV.Ingest.Service,
  IPTV.Api.ProxyServer,
  IPTV.Api.SsdpServer;

type
  /// The HTTP front end: MARS engine + Indy listener (admin API, Xtream portal,
  /// Plex surfaces, bundled admin UI), plus the optional stream relay and SSDP.
  TApiServer = class
  private
    FConfig: TAppConfig;
    FRunning: Boolean;
    FLog: TLogProc;
    FEngine: IMARSEngine;
    FServer: TMARShttpServerIndy;
    FProxy: TStreamProxyServer;
    FProxyActivePort: Integer; // port the relay is bound to (0 = not running)
    FSsdp: TSsdpServer; // HDHomeRun discovery for Plex (UDP 1900); nil when off
    FWebRoot: string; // static admin-UI files (SPA); '' => not bundled, API only
    /// The configured HTTP(S) port.
    function GetPort: Integer;
    // the relay is needed by the global stream proxy OR by a Plex surface set to relay
    function NeedsProxyServer: Boolean;
    procedure SyncProxyServer; // start/stop/rebind the relay to match what's enabled
    procedure SyncSsdp; // start/stop SSDP to match FConfig.PlexHdhrEnabled
  public
    /// Stops the server (if running) and frees it.
    destructor Destroy; override;
    /// Creates the server for AConfig; ALog receives request/lifecycle lines.
    constructor Create(const AConfig: TAppConfig; const ALog: TLogProc = nil);
    /// Builds the MARS engine, opens the listener, runs the warm-up and starts the
    /// relay/SSDP when enabled. Raises (after cleaning up) when a listener can't bind.
    procedure Start;
    /// Stops SSDP, the relay and the listener and releases the engine.
    procedure Stop;
    /// Start/stop (or rebind) the stream-relay server at runtime — backs the
    /// settings toggle. Recreates the relay if the port changed while running.
    procedure SetProxy(AEnabled: Boolean; APort: Integer);
    /// Apply Plex settings live (re-reads the toggles; starts/stops SSDP).
    procedure SyncPlex(const AConfig: TAppConfig);
    /// The configured HTTP(S) port.
    property Port: Integer read GetPort;
    /// True between Start and Stop.
    property Running: Boolean read FRunning;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.RegularExpressions,
  System.Net.URLClient,
  System.Net.HttpClient,
  System.Diagnostics,
  System.SyncObjs,
  System.StrUtils,
  // MARS
  MARS.Core.Activation,
  MARS.Core.Activation.Interfaces,
  MARS.Core.Engine,
  MARS.Core.Application.Interfaces,
  MARS.Core.URL,
  MARS.Core.RequestAndResponse.Interfaces,
  MARS.Core.Activation.InjectionService, // registers [Context] injection (Request/Response/URL)
  MARS.Core.MessageBodyWriter,
  MARS.Core.MessageBodyWriters,
  MARS.Core.MessageBodyReaders,
  // MARS always injects a JWT token during activation, so a Token implementation
  // must be linked even though we don't authenticate (mORMot on Windows, JOSE on Linux).
{$IFDEF MSWINDOWS}
  MARS.mORMotJWT.Token,
{$ELSE}
  MARS.JOSEJWT.Token,
{$ENDIF}
  // own
  IPTV.Core.Utils,
  IPTV.Api.AuthThrottle,
  IPTV.Api.Mars.Admin,
  IPTV.Api.Mars.Xtream,
  IPTV.Api.Mars.Plex;

threadvar
  GReqStart: Int64;     // request start (TStopwatch ticks), per Indy worker thread

var
  GErrorLog: TLogProc;  // target for the MARS invoke-error hook (registered once)
  GErrorHookRegistered: Boolean;
  // Startup warm-up gate (1.2.19 hang): right after a (re)start, two API requests
  // arriving in the same millisecond (an open admin tab polling) left EVERY later
  // MARS request hanging forever — /api/health included — while static files kept
  // working; a plain restart without the tab fixed it. Some lazy first-use init in
  // the activation path (likely the JWT token / OpenSSL load on Linux) is not
  // thread-safe. So the server first runs a few requests to itself, one at a time,
  // and external backend requests wait (no lock held; max cWarmupWaitMs) until that
  // is done.
  GWarmGate: TEvent;
  GWarmToken: string;

const
  // CSRF guard: state-changing /api calls must carry this header (the web app sends it)
  cClientHeader = 'X-IPTV-Client';
  // MARS engine parameters of its rate limiter
  cParamRateLimitRequests = 'RateLimit.Requests';
  cParamRateLimitWindow = 'RateLimit.Window';
  cRateLimitWindowSec = 60;
  cApiRoot = 'api';
  cHeaderRetryAfter = 'Retry-After';
  cMimeTextPlain = 'text/plain';
  cHttpStatusForbidden = 403;
  cHttpStatusUnauthorized = 401;
  // the admin password as the web app / download links send it
  cAdminPasswordHeader = 'X-Admin-Password';
  cAdminPasswordQuery = 'pw';

const
  // startup warm-up (see GWarmGate)
  cWarmupHeader = 'X-IPTV-Warmup';
  cWarmupWaitMs = 30000;
  cWarmupConnectTimeoutMs = 5000;
  cWarmupResponseTimeoutMs = 15000;
  cLoopbackHost = '127.0.0.1';
  // one request per resource class, strictly one after another
  cWarmupPaths: array[0..2] of string = ('/api/health', '/discover.json',
    '/player_api.php?username=warmup&password=warmup');
  // TEvent.Create arguments of the warm-up gate
  cManualReset = True;
  cInitiallySignaled = False;

  // MARS application
  cAppName = 'IPTVPlay';
  cAppResourceMask = 'IPTV.Api.Mars.*';
  cParamSslCertFile = 'Indy.SSL.CertFile';
  cParamSslKeyFile = 'Indy.SSL.KeyFile';
  cParamSslRootCertFile = 'Indy.SSL.RootCertFile';

  // first URL segments owned by the backend (admin API + Xtream portal + Plex).
  // catch-up: timeshift/{u}/{p}/... and streaming/timeshift.php MUST be listed,
  // else the SPA fallback answers them with index.html (200) and the box spins
  cBackendRoutes: array[0..13] of string =
    ('api', 'player_api.php', 'get.php', 'xmltv.php', 'live', 'movie', 'series',
     'timeshift', 'streaming',
     'plex', 'discover.json', 'lineup.json', 'lineup_status.json', 'lineup.post');

  // bundled admin UI
  cWebUiDir = 'webui';
  cIndexHtml = 'index.html';

  // HTTP
  cSchemeHttp = 'http';
  cSchemeHttps = 'https';
  cMethodGet = 'GET';
  cIgnoreCase = True;                  // string.StartsWith AIgnoreCase
  cHttpStatusOk = 200;
  cHttpStatusErrorMin = 400;
  cSlowRequestMs = 1000;               // log requests at least this slow

  // credential masking for the request log: /live|movie|series|stream|timeshift/{user}/{pass}
  // path segments AND ?username=&password=-style query keys
  cMaskPathPattern = '(/(live|movie|series|stream|timeshift)/)[^/]+/[^/]+';
  cMaskPathReplace = '$1***/***';
  cMaskQueryPattern = '([?&](username|password|pass|pw|user|token|auth|mac)=)[^&]*';
  cMaskQueryReplace = '$1***';

// warm-up requests go to our own (possibly self-signed) cert on loopback
procedure AcceptOwnCert(const ASender: TObject; const ARequest: TURLRequest;
  const ACertificate: TCertificate; var AAccepted: Boolean);
begin
  AAccepted := True;
end;

// mask credentials in a URL for logging: /live|movie|series|stream/{user}/{pass}
// path segments AND ?username=&password=-style query keys
function MaskUrl(const AUrl: string): string;
begin
  Result := TRegEx.Replace(AUrl, cMaskPathPattern, cMaskPathReplace, [roIgnoreCase]);
  Result := TRegEx.Replace(Result, cMaskQueryPattern, cMaskQueryReplace, [roIgnoreCase]);
end;

constructor TApiServer.Create(const AConfig: TAppConfig; const ALog: TLogProc);
begin
  inherited Create;
  FConfig := AConfig;
  FLog := ALog;
end;

// first URL segments owned by the backend (admin API + Xtream portal); anything
// else is treated as an admin-UI/static request.
function IsBackendRoute(const AFirstSeg: string): Boolean;
var
  lRoute: string;
begin
  for lRoute in cBackendRoutes do
    if SameText(AFirstSeg, lRoute) then
      Exit(True);
  Result := False;
end;

function MimeType(const AExt: string): string;
begin
  if SameText(AExt, '.html') then
    Result := 'text/html; charset=utf-8'
  else if SameText(AExt, '.js') or SameText(AExt, '.mjs') then
    Result := 'text/javascript; charset=utf-8'
  else if SameText(AExt, '.css') then
    Result := 'text/css; charset=utf-8'
  else if SameText(AExt, '.json') or SameText(AExt, '.map') then
    Result := 'application/json; charset=utf-8'
  else if SameText(AExt, '.svg') then
    Result := 'image/svg+xml'
  else if SameText(AExt, '.png') then
    Result := 'image/png'
  else if SameText(AExt, '.jpg') or SameText(AExt, '.jpeg') then
    Result := 'image/jpeg'
  else if SameText(AExt, '.ico') then
    Result := 'image/x-icon'
  else if SameText(AExt, '.woff2') then
    Result := 'font/woff2'
  else if SameText(AExt, '.woff') then
    Result := 'font/woff'
  else if SameText(AExt, '.txt') then
    Result := 'text/plain; charset=utf-8'
  else
    Result := 'application/octet-stream';
end;

function ServeStatic(const AWebRoot, ARawPath: string; const AResponse: IMARSResponse): Boolean;
var
  lRel, lFullPath: string;
  lQueryPos: Integer;
  lStream: TFileStream;
begin
  Result := False;
  if AWebRoot = '' then
    Exit;
  lRel := ARawPath;
  lQueryPos := Pos('?', lRel);
  if lQueryPos > 0 then
    lRel := Copy(lRel, 1, lQueryPos - 1);
  if (lRel = '') or (lRel = '/') then
    lRel := cIndexHtml;
  if lRel.Contains('..') then // path-traversal guard
    Exit;
  lRel := lRel.Replace('/', PathDelim, [rfReplaceAll]);
  while lRel.StartsWith(PathDelim) do
    lRel := lRel.Substring(1);
  lFullPath := TPath.Combine(AWebRoot, lRel);
  // Defence in depth: TPath.Combine returns a rooted/UNC second arg verbatim
  // (e.g. "C:\..."), so a crafted path could escape the web root. Reject anything
  // that doesn't canonicalise to a location inside AWebRoot.
  if not TPath.GetFullPath(lFullPath).StartsWith(
       IncludeTrailingPathDelimiter(TPath.GetFullPath(AWebRoot)), cIgnoreCase) then
    Exit;
  if not TFile.Exists(lFullPath) then
    lFullPath := TPath.Combine(AWebRoot, cIndexHtml); // SPA fallback
  if not TFile.Exists(lFullPath) then
    Exit;
  // Indy frees the stream after sending (FreeContentStream := True)
  lStream := TFileStream.Create(lFullPath, fmOpenRead or fmShareDenyWrite);
  AResponse.SetContentStream(lStream);
  AResponse.SetContentType(MimeType(ExtractFileExt(lFullPath)));
  AResponse.SetStatusCode(cHttpStatusOk);
  Result := True;
end;

function TApiServer.GetPort: Integer;
begin
  Result := FConfig.HttpPort;
end;

// methods that only read (no CSRF check needed)
function IsSafeMethod(const AMethod: string): Boolean;
begin
  Result := SameText(AMethod, 'GET') or SameText(AMethod, 'HEAD') or SameText(AMethod, 'OPTIONS');
end;

procedure TApiServer.Start;
var
  lRoot: string;
  lBase: string;
  lLog: TLogProc;
begin
  if FRunning then
    Exit;

  FEngine := TMARSEngine.Create;
  FEngine.BasePath := ''; // mount applications at the site root

  // MARS's own per-IP request limiter (token bucket, checked before any routing):
  // against floods. Failed logins are limited separately (IPTV.Api.AuthThrottle).
  FEngine.Parameters.Values[cParamRateLimitRequests] := IntToStr(FConfig.RateLimitPerMinute);
  FEngine.Parameters.Values[cParamRateLimitWindow] := IntToStr(cRateLimitWindowSec);
  if FConfig.UseHttps then
  begin
    if (FConfig.TlsCertFile = '') or (FConfig.TlsKeyFile = '') then
      raise Exception.Create('UseHttps is on but TlsCertFile/TlsKeyFile are not set');
    FEngine.Port := 0;
    FEngine.PortSSL := FConfig.HttpPort;
    FEngine.Parameters.Values[cParamSslCertFile] := FConfig.TlsCertFile;
    FEngine.Parameters.Values[cParamSslKeyFile] := FConfig.TlsKeyFile;
    FEngine.Parameters.Values[cParamSslRootCertFile] := FConfig.TlsRootCertFile;
  end
  else
  begin
    FEngine.Port := FConfig.HttpPort;
    FEngine.PortSSL := 0;
  end;

  // resources live in IPTV.Api.Mars.* and self-register via MARSRegister.
  // Empty app base + OnGetApplication fallback => every URL routes to this one
  // application, and resource [Path]'s (api, player_api.php, live, ...) match
  // from the site root.
  FEngine.AddApplication(cAppName, '', [cAppResourceMask]);
  FEngine.OnGetApplication :=
    procedure (const AEngine: IMARSEngine; const AURL: TMARSURL;
      const ARequest: IMARSRequest; const AResponse: IMARSResponse;
      var AApplication: IMARSApplication)
    begin
      if AApplication = nil then
        AApplication := AEngine.ApplicationByName(cAppName);
    end;

  // the bundled admin UI (built React app) lives in <exedir>/webui when present;
  // empty => the image/run is API-only (manage from the dev frontend instead).
  FWebRoot := '';
  lRoot := TPath.Combine(ExtractFilePath(ParamStr(0)), cWebUiDir);
  if TDirectory.Exists(lRoot) then
  begin
    FWebRoot := lRoot;
    if Assigned(FLog) then
      FLog('Admin UI served from ' + FWebRoot);
  end;

  // BeforeHandleRequest does two jobs: (1) log every request (creds masked) and
  // (2) serve the admin UI for any non-backend GET so http://host:port/ shows
  // the app. Returning False + AHandled := True stops MARS dispatch (we answered).
  FEngine.BeforeHandleRequest :=
    function (const AEngine: IMARSEngine; const AURL: TMARSURL;
      const ARequest: IMARSRequest; const AResponse: IMARSResponse;
      var AHandled: Boolean): Boolean
    var
      lFirst, lMasked: string;
      lRetryAfter: Integer;
    begin
      Result := True; // continue to MARS by default
      GReqStart := TStopwatch.GetTimeStamp; // per Indy thread; read in AfterHandleRequest
      if Assigned(FLog) then
      begin
        // Mask credentials before logging. TWO forms must be hidden:
        //  1) PATH segments — the live/movie/series stream endpoints are
        //     /live/{user}/{pass}/{id}, so the password sits in the path (no '=').
        //  2) query keys — get.php/player_api.php (?username=&password=), admin ?pw=, tokens, mac.
        lMasked := MaskUrl(AURL.URL);
        // client IP first: shows which box/app asked (e.g. two boxes fighting
        // over a single provider connection)
        FLog(Format('%-15s %s %s', [ARequest.RemoteIP, ARequest.Method, lMasked]));
      end;

      lFirst := '';
      if AURL.HasPathTokens then
        lFirst := AURL.PathTokens[0];

      if (FWebRoot = '') or IsBackendRoute(lFirst) then
      begin
        // too many failed logins from this client: 429 until the lockout ends
        if GAuthThrottle.IsBlocked(ARequest.RemoteIP, lRetryAfter) then
        begin
          AResponse.SetStatusCode(cHttpTooManyRequests);
          AResponse.SetHeader(cHeaderRetryAfter, IntToStr(lRetryAfter));
          AResponse.SetContentType(cMimeTextPlain);
          AResponse.SetContent('Too many failed logins - try again later');
          AHandled := True;
          Exit(False);
        end;
        // CSRF: a state-changing admin call must carry our own header. A page on
        // another site can't add a custom header without a CORS preflight, which
        // we never approve - so it can't make a logged-in (or password-less)
        // browser change settings behind the user's back.
        if SameText(lFirst, cApiRoot) and not IsSafeMethod(ARequest.Method) and
           (ARequest.GetHeaderParamValue(cClientHeader) = '') then
        begin
          AResponse.SetStatusCode(cHttpStatusForbidden);
          AResponse.SetContentType(cMimeTextPlain);
          AResponse.SetContent('Missing ' + cClientHeader + ' header');
          AHandled := True;
          Exit(False);
        end;
      end;

      // hold external backend requests until the startup warm-up has run
      if (FWebRoot = '') or IsBackendRoute(lFirst) then
        if (GWarmGate <> nil) and (ARequest.GetHeaderParamValue(cWarmupHeader) <> GWarmToken) then
          GWarmGate.WaitFor(cWarmupWaitMs);

      if (FWebRoot = '') then
        Exit;
      if not SameText(ARequest.Method, cMethodGet) then
        Exit;
      if IsBackendRoute(lFirst) then
        Exit; // /api, /player_api.php, /live, ... -> let MARS handle it
      if ServeStatic(FWebRoot, ARequest.GetRawPath, AResponse) then
      begin
        AHandled := True;  // we produced the response
        Result := False;   // stop MARS dispatch
      end;
    end;

  // Slow or failed requests: log status + duration (ms) so a hanging catalog
  // call or a 500 is visible in `docker logs` together with what ran alongside.
  FEngine.AfterHandleRequest :=
    procedure (const AEngine: IMARSEngine; const AURL: TMARSURL;
      const ARequest: IMARSRequest; const AResponse: IMARSResponse;
      var AHandled: Boolean)
    var
      lMs: Int64;
      lFirst: string;
    begin
      // a failed login counts towards the per-IP lockout. On /api only when a
      // password was actually sent (the web app's first probe without one is no
      // guess); the box endpoints always carry a login.
      if AResponse.StatusCode = cHttpStatusUnauthorized then
      begin
        lFirst := '';
        if AURL.HasPathTokens then
          lFirst := AURL.PathTokens[0];
        if not SameText(lFirst, cApiRoot) or
           (ARequest.GetHeaderParamValue(cAdminPasswordHeader) <> '') or
           (ARequest.GetQueryParamValue(cAdminPasswordQuery) <> '') then
          GAuthThrottle.RegisterFailure(ARequest.RemoteIP);
      end;
      if not Assigned(FLog) then
        Exit;
      lMs := (TStopwatch.GetTimeStamp - GReqStart) * 1000 div TStopwatch.Frequency;
      if (lMs >= cSlowRequestMs) or (AResponse.StatusCode >= cHttpStatusErrorMin) then
        FLog(Format('%-15s done %d in %d ms  %s %s',
          [ARequest.RemoteIP, AResponse.StatusCode, lMs, ARequest.Method, MaskUrl(AURL.URL)]));
    end;
  // The actual exception behind a 500 (MARS only answers "Internal server error").
  GErrorLog := FLog;
  if not GErrorHookRegistered then
  begin
    GErrorHookRegistered := True;
    TMARSActivation.RegisterInvokeError(
      procedure (const AActivation: IMARSActivation; const AException: Exception;
        var AHandled: Boolean)
      begin
        if Assigned(GErrorLog) then
          GErrorLog(Format('ERROR %s %s: %s: %s', [AActivation.Request.Method,
            MaskUrl(AActivation.URL.URL), AException.ClassName, AException.Message]));
      end);
  end;

  // close the warm-up gate BEFORE the listener opens (see GWarmGate)
  if GWarmGate = nil then
    GWarmGate := TEvent.Create(nil, cManualReset, cInitiallySignaled, '')
  else
    GWarmGate.ResetEvent;
  GWarmToken := TGUID.NewGuid.ToString;

  try
    FServer := TMARShttpServerIndy.Create(FEngine);
    FServer.Active := True;

    // warm up the MARS activation path with requests to ourselves, strictly one at a
    // time (each resource class once), then open the gate. On a background thread so
    // a stuck warm-up can never block startup; external requests wait at most
    // cWarmupWaitMs anyway.
    lBase := Format('%s://%s:%d', [IfThen(FConfig.UseHttps, cSchemeHttps, cSchemeHttp),
      cLoopbackHost, FConfig.HttpPort]);
    lLog := FLog;
    TThread.CreateAnonymousThread(
      procedure
      var
        lHttp: THTTPClient;
        lPath: string;
        lSw: TStopwatch;
      begin
        lSw := TStopwatch.StartNew;
        try
          lHttp := THTTPClient.Create;
          try
            lHttp.ConnectionTimeout := cWarmupConnectTimeoutMs;
            lHttp.ResponseTimeout := cWarmupResponseTimeoutMs;
            lHttp.CustomHeaders[cWarmupHeader] := GWarmToken;
            lHttp.ValidateServerCertificateCallback := AcceptOwnCert;
            for lPath in cWarmupPaths do
              try
                lHttp.Get(lBase + lPath).StatusCode;
              except
                // a failed warm-up request still exercised the path; carry on
              end;
          finally
            FreeAndNil(lHttp);
          end;
        except
          // warm-up is best-effort: whatever failed, the gate below must still open
        end;
        GWarmGate.SetEvent;
        if Assigned(lLog) then
          lLog(Format('warm-up done in %d ms - API open', [lSw.ElapsedMilliseconds]));
      end).Start;

    SyncProxyServer; // start the stream relay if the global proxy OR a Plex proxy needs it
    SyncSsdp; // start the HDHomeRun discovery responder if Plex HDHR is enabled
  except
    // e.g. the proxy port is taken: close the API listener we already opened, so
    // the process doesn't look alive while serving nothing (and a retry can bind)
    FRunning := True;
    Stop;
    raise;
  end;
  FRunning := True;
end;

procedure TApiServer.SyncSsdp;
var
  lUri: TURI;
  lScheme: string;
begin
  if FConfig.PlexHdhrEnabled and not Assigned(FSsdp) then
  begin
    // the discover.json lives on httpPort; that port serves TLS when UseHttps is on,
    // so the SSDP LOCATION must use https there or Plex's fetch fails
    if FConfig.UseHttps then
      lScheme := cSchemeHttps
    else
      lScheme := cSchemeHttp;
    FSsdp := TSsdpServer.Create(
      Format('%s://%s:%d/discover.json', [lScheme, SafeUrlHost(FConfig.PublicBaseUrl, 'localhost'),
        FConfig.HttpPort]), FLog);
    FSsdp.Start;
  end
  else if (not FConfig.PlexHdhrEnabled) and Assigned(FSsdp) then
  begin
    FSsdp.Stop;
    FreeAndNil(FSsdp);
  end;
end;

procedure TApiServer.SyncPlex(const AConfig: TAppConfig);
begin
  FConfig := AConfig; // refresh our copy (SSDP location/host); endpoints read App.Config
  SyncSsdp;
  SyncProxyServer; // a Plex M3U/HDHR "relay" toggle may now need (or release) the relay
end;

function TApiServer.NeedsProxyServer: Boolean;
begin
  // the relay must run when the global stream proxy is on, OR when a Plex tuner
  // surface is set to relay (its lineup/playlist URLs point at the relay port) —
  // otherwise those URLs are dead and Plex gets no picture.
  Result := FConfig.ProxyStreams or FConfig.PlexM3uProxy or FConfig.PlexHdhrProxy;
end;

procedure TApiServer.SyncProxyServer;
begin
  // stop the relay if it's no longer needed, or if the port changed while running
  if Assigned(FProxy) and ((not NeedsProxyServer) or (FProxyActivePort <> FConfig.ProxyPort)) then
  begin
    FProxy.Stop;
    FreeAndNil(FProxy);
    FProxyActivePort := 0;
  end;
  if NeedsProxyServer and not Assigned(FProxy) then
  begin
    FProxy := TStreamProxyServer.Create(FConfig.ProxyPort, FLog);
    FProxy.Start;
    FProxyActivePort := FConfig.ProxyPort;
  end;
end;

procedure TApiServer.SetProxy(AEnabled: Boolean; APort: Integer);
begin
  FConfig.ProxyStreams := AEnabled;
  FConfig.ProxyPort := APort;
  SyncProxyServer; // reconcile against the global + Plex proxy flags
end;

destructor TApiServer.Destroy;
begin
  Stop;
  inherited;
end;

procedure TApiServer.Stop;
begin
  if not FRunning then
    Exit;
  if Assigned(FSsdp) then
  begin
    FSsdp.Stop;
    FreeAndNil(FSsdp);
  end;
  if Assigned(FProxy) then
  begin
    FProxy.Stop;
    FreeAndNil(FProxy);
  end;
  // release any request still parked at the warm-up gate so shutdown can drain
  if GWarmGate <> nil then
    GWarmGate.SetEvent;
  if Assigned(FServer) then
  begin
    FServer.Active := False;
    FreeAndNil(FServer);
  end;
  FEngine := nil; // interface ref-count releases the engine
  FRunning := False;
end;

initialization

finalization
  FreeAndNil(GWarmGate);

end.
