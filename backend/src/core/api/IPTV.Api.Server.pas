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
  // Indy
  IdContext,
  IdHeaderList,
  // MARS
  MARS.Core.Engine.Interfaces,
  MARS.Core.RequestAndResponse.Interfaces,
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
    // serialises the runtime changes of the relay / SSDP / our config copy (settings
    // saves, Plex toggles, start/stop). A TMonitor: re-entrant on every platform
    // (SyncPlex -> SyncProxyServer). Lock order: TAppContext's config lock first.
    FSyncLock: TObject;
    FStopping: Boolean; // Stop began: a late settings save must not start a relay/SSDP again
    /// The configured HTTP(S) port.
    function GetPort: Integer;
    // the relay is needed by the global stream proxy OR by a Plex surface set to relay
    function NeedsProxyServer: Boolean;
    procedure SyncProxyServer; // start/stop/rebind the relay to match what's enabled
    procedure SyncSsdp; // start/stop/re-advertise SSDP to match FConfig (HDHR flag, location)
    /// The discover.json URL SSDP advertises for the current FConfig.
    function SsdpLocation: string;
    /// Indy hook, before any request body is read: a body above MaxBodyBytesFor (1 MB,
    /// 64 MB for the settings import) is refused with 413, a chunked one (size unknown)
    /// with 411.
    procedure DoHeadersAvailable(AContext: TIdContext; const AUri: string; AHeaders: TIdHeaderList;
      var VContinueProcessing: Boolean);
    /// The status/text of a request refused by DoHeadersAvailable.
    procedure DoHeadersBlocked(AContext: TIdContext; AHeaders: TIdHeaderList; var VResponseNo: Integer;
      var VResponseText, VContentText: string);
    /// Indy hook per new connection: a read timeout, so a client that sends its headers
    /// (or body) byte by byte can't hold one of the worker threads forever.
    procedure DoConnect(AContext: TIdContext);
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
    /// settings toggle. Transactional: a new port is bound BEFORE the old relay is
    /// stopped; when it can't bind, the running relay and our settings stay as they
    /// were and a 400 "Port N is in use" (EMARSHttpException) is raised.
    procedure SetProxy(AEnabled: Boolean; APort: Integer);
    /// Apply Plex settings live (re-reads the toggles; starts/stops SSDP and the relay a
    /// Plex surface needs). On failure our copy of the config is restored and a 400 raised.
    procedure SyncPlex(const AConfig: TAppConfig);
    /// The configured HTTP(S) port.
    property Port: Integer read GetPort;
    /// True between Start and Stop.
    property Running: Boolean read FRunning;
  end;

/// <summary>All X-Forwarded-For header lines of ARequest joined in order (see
/// IPTV.Api.AuthThrottle.JoinForwardedFor); '' when there is none.</summary>
function RequestForwardedFor(const ARequest: IMARSRequest): string;

/// <summary>The client address of ARequest: through a trusted proxy its
/// X-Forwarded-For client, else the socket peer (GAuthThrottle.ClientAddress).</summary>
function RequestClientIp(const ARequest: IMARSRequest): string;

/// <summary>Is ARequest from the local network (GAuthThrottle.IsLocalClient)?</summary>
function RequestIsLocal(const ARequest: IMARSRequest): Boolean;

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
  MARS.Core.Activation.InjectionService, // registers [Context] injection (Request/Response/URL)
  MARS.Core.MessageBodyWriter,
  MARS.Core.MessageBodyWriters,
  MARS.Core.MessageBodyReaders,
  MARS.Core.Exceptions,
  // MARS always injects a JWT token during activation, so a Token implementation
  // must be linked even though we don't authenticate (mORMot on Windows, JOSE on Linux).
{$IFDEF MSWINDOWS}
  MARS.mORMotJWT.Token,
{$ELSE}
  MARS.JOSEJWT.Token,
{$ENDIF}
  // own
  IPTV.Core.Utils,
  IPTV.App.Context,
  IPTV.Api.Security,
  IPTV.Api.Serializers,
  IPTV.Api.AuthThrottle,
  IPTV.Api.Mars.Admin,
  IPTV.Api.Mars.Xtream,
  IPTV.Api.Mars.Plex;

threadvar
  GReqStart: Int64;     // request start (TStopwatch ticks), per Indy worker thread
  GBlockStatus: Integer; // why DoHeadersAvailable refused this thread's request (411/413)

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
  GWarmGate: TEvent; // (the warm-up token itself: IPTV.Api.Security.GWarmToken)

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
  cMsgUnauthorized = 'Unauthorized';
  // the admin API without an admin password answers only the local network
  cMsgAdminLanOnly = 'Without an admin password the admin API only answers the local network - ' +
    'set an admin password';
  // DNS rebinding on the login-free box / Plex surfaces
  cMsgBoxHostNotAllowed = 'Host "%s" is not allowed for login-free access: use a login, the server''s ' +
    'address or add this host to allowedHosts';
  // admin request body nested deeper than cMaxJsonDepth (checked before MARS parses it)
  cMsgJsonTooDeep = 'JSON body nested too deeply (max %d levels)';
  // /api/health: liveness, needs no login
  cApiHealthSeg = 'health';
  cApiSegIndex = 1;
  cHttpStatusSuccessMin = 200;
  cHttpStatusSuccessMax = 299;
  cHttpStatusRedirectMax = 399;
  // a box login: ?username= or a path login (/live/{user}/{pass}/{id},
  // /timeshift/{user}/{pass}/...) = at least 3 segments
  cBoxUserQuery = 'username';
  cBoxPathLoginTokens = 3;
  // box routes that check a ?username= login and answer a wrong one with 401.
  // player_api.php is NOT one: it answers a wrong login with 200 + auth:0 (like real
  // panels), so its status says nothing about the login (TPlayerApiResource must clear
  // the counter itself on a resolved login);
  // the Plex routes have no login at all.
  cBoxQueryLoginRoutes: array[0..2] of string = ('get.php', 'xmltv.php', 'streaming');
  // box routes that carry the login in the path; a good one is answered with a 302
  cBoxPathLoginRoutes: array[0..3] of string = ('live', 'movie', 'series', 'timeshift');
  // every box route that may carry a login in ?username= (player_api.php too); without
  // one it serves the login-free default list - then the Host rule applies
  cBoxQueryRoutes: array[0..3] of string = ('player_api.php', 'get.php', 'xmltv.php', 'streaming');
  // Plex / HDHomeRun routes: no login at all (they carry the bouquet login) - the Host
  // rule always applies
  cMediaRoutes: array[0..4] of string = ('plex', 'discover.json', 'lineup.json', 'lineup_status.json',
    'lineup.post');
  // the admin password as the web app sends it, and the single-use token of a
  // download link (POST /api/download-token)
  cAdminPasswordHeader = 'X-Admin-Password';
  cDownloadTokenQuery = 'dt';
  // a path login of PathCred: token 1 = the user ('-' = the empty field, no login)
  cPathTokenUser = 1;
  // DNS-rebinding guard of the admin API without an admin password
  cHeaderHost = 'Host';
  cMsgHostNotAllowed = 'Host "%s" is not allowed: set an admin password or add this host to allowedHosts';
  // request-body cap (Indy, before the body is read)
  cHeaderContentLength = 'Content-Length';
  cHeaderTransferEncoding = 'Transfer-Encoding';
  cMsgBodyTooLarge = 'Request body too large';
  cMsgLengthRequired = 'Length Required';
  cMsgChunkedRefused = 'Chunked request bodies are not accepted - send a Content-Length';
  // per-connection read timeout (slow-header / slow-body clients)
  cConnectionReadTimeoutMs = 30000;
  // relay (re)bind failure
  cMsgPortInUse = 'Port %d is in use';
  cMsgPlexRelayFailed = 'Plex relay could not be started: %s';

const
  // startup warm-up (see GWarmGate); the header is IPTV.Api.AuthThrottle.cWarmupHeader
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
  cMethodOptions = 'OPTIONS'; // a CORS preflight carries no credentials
  cIgnoreCase = True;                  // string.StartsWith AIgnoreCase
  cHttpStatusOk = 200;
  cHttpStatusErrorMin = 400;
  cSlowRequestMs = 1000;               // log requests at least this slow

  // credential masking for the request log: /live|movie|series|stream|timeshift/{user}/{pass}
  // path segments AND ?username=&password=-style query keys
  cMaskPathPattern = '(/(live|movie|series|stream|timeshift)/)[^/]+/[^/]+';
  cMaskPathReplace = '$1***/***';
  cMaskQueryPattern = '([?&](username|password|pass|pw|dt|user|token|auth|mac)=)[^&]*';
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
  FSyncLock := TObject.Create;
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

function RequestForwardedFor(const ARequest: IMARSRequest): string;
var
  lLines: TArray<string>;
  i: Integer;
begin
  // RawHeaders.Values (GetHeaderParamValue by name) only returns the FIRST line of a
  // repeated header: read every X-Forwarded-For line
  lLines := nil;
  try
    for i := 0 to ARequest.GetHeaderParamCount - 1 do
      if SameText(ARequest.GetHeaderParamName(i).Trim, cHeaderForwardedFor) then
        lLines := lLines + [ARequest.GetHeaderParamValue(i)];
  except
    // a request type without indexed headers: the single value
    lLines := [ARequest.GetHeaderParamValue(cHeaderForwardedFor)];
  end;
  Result := JoinForwardedFor(lLines);
end;

function RequestClientIp(const ARequest: IMARSRequest): string;
begin
  Result := GAuthThrottle.ClientAddress(ARequest.RemoteIP, RequestForwardedFor(ARequest));
end;

function RequestIsLocal(const ARequest: IMARSRequest): Boolean;
begin
  Result := GAuthThrottle.IsLocalClient(ARequest.RemoteIP, RequestForwardedFor(ARequest));
end;

// the failed-login lockout key of a request: /api counts per admin surface, every
// other backend route per box surface (a box's wrong login can't lock the web app out)
function ThrottleKey(const AFirstSeg: string; const ARequest: IMARSRequest): string;
var
  lSurface: string;
begin
  if SameText(AFirstSeg, cApiRoot) then
    lSurface := cSurfaceAdmin
  else
    lSurface := cSurfaceBox;
  Result := GAuthThrottle.ClientKey(lSurface, ARequest.RemoteIP, RequestForwardedFor(ARequest));
end;

function IsRouteIn(const AFirstSeg: string; const ARoutes: array of string): Boolean;
var
  lRoute: string;
begin
  for lRoute in ARoutes do
    if SameText(AFirstSeg, lRoute) then
      Exit(True);
  Result := False;
end;

// a box request WITHOUT a real login (the login-free default list): no ?username= on
// the query routes, '-' / '' / no path login on the path routes
function IsLoginFreeBoxRequest(const AFirstSeg: string; const AURL: TMARSURL;
  const ARequest: IMARSRequest): Boolean;
begin
  if IsRouteIn(AFirstSeg, cBoxQueryRoutes) then
    Result := not IsRealLoginName(ARequest.GetQueryParamValue(cBoxUserQuery))
  else if IsRouteIn(AFirstSeg, cBoxPathLoginRoutes) then
    Result := not AURL.HasPathTokens(cBoxPathLoginTokens) or not IsRealLoginName(AURL.PathTokens[cPathTokenUser])
  else
    Result := False;
end;

// answer a request from BeforeHandleRequest (MARS dispatch stops)
procedure Refuse(const AResponse: IMARSResponse; AStatus: Integer; const AText: string);
begin
  AResponse.SetStatusCode(AStatus);
  AResponse.SetContentType(cMimeTextPlain);
  AResponse.SetContent(AText);
end;

function IsBoxPathLoginRoute(const AFirstSeg: string): Boolean;
var
  lRoute: string;
begin
  for lRoute in cBoxPathLoginRoutes do
    if SameText(AFirstSeg, lRoute) then
      Exit(True);
  Result := False;
end;

function IsBoxQueryLoginRoute(const AFirstSeg: string): Boolean;
var
  lRoute: string;
begin
  for lRoute in cBoxQueryLoginRoutes do
    if SameText(AFirstSeg, lRoute) then
      Exit(True);
  Result := False;
end;

// was this answer a successful login? /api: 2xx with the RIGHT admin password sent
// (/api/health answers 200 to any password, so the status alone proves nothing);
// box: 2xx (or the 302 of a stream/timeshift redirect) on a route that checks the
// login it carried (see cBoxQueryLoginRoutes / cBoxPathLoginRoutes).
function IsSuccessfulLogin(const AFirstSeg: string; const AURL: TMARSURL;
  const ARequest: IMARSRequest; AStatus: Integer; const AAdminPassword: string): Boolean;
begin
  if AStatus < cHttpStatusSuccessMin then
    Exit(False);
  if SameText(AFirstSeg, cApiRoot) then
    Result := (AStatus <= cHttpStatusSuccessMax) and (AAdminPassword <> '') and
      IsSamePassword(ARequest.GetHeaderParamValue(cAdminPasswordHeader), AAdminPassword)
  else if IsBoxPathLoginRoute(AFirstSeg) then
    // only a real login: /live/-/-/{id} (the login-free default list) proves nothing
    Result := (AStatus <= cHttpStatusRedirectMax) and AURL.HasPathTokens(cBoxPathLoginTokens) and
      IsRealLoginName(AURL.PathTokens[cPathTokenUser])
  else
    // same rule: ?username=- (the '-' placeholder) is the login-free default list too
    Result := (AStatus <= cHttpStatusSuccessMax) and IsBoxQueryLoginRoute(AFirstSeg) and
      IsRealLoginName(ARequest.GetQueryParamValue(cBoxUserQuery));
end;

function TApiServer.GetPort: Integer;
begin
  Result := FConfig.HttpPort;
end;

// the live admin password / Host-rule settings (App's config once it runs; until then
// our copy - the warm-up runs before App is set)
function LiveAdminPassword(const AFallback: TAppConfig): string;
begin
  if App <> nil then
    Result := App.Config.AdminPassword
  else
    Result := AFallback.AdminPassword;
end;

function IsAdminHostAccepted(const AHostHeader: string; const AFallback: TAppConfig): Boolean;
begin
  if App <> nil then
    Result := IsAllowedAdminHost(AHostHeader, App.Config.PublicBaseUrl, App.Config.AllowedHosts)
  else
    Result := IsAllowedAdminHost(AHostHeader, AFallback.PublicBaseUrl, AFallback.AllowedHosts);
end;

procedure TApiServer.DoHeadersAvailable(AContext: TIdContext; const AUri: string;
  AHeaders: TIdHeaderList; var VContinueProcessing: Boolean);
begin
  // MARS's Indy server buffers the whole body BEFORE any of our hooks (auth, CSRF)
  // run: refuse a size-less (chunked) or oversized body here, unread. The cap is
  // cMaxRequestBodyBytes (1 MB); only the settings import may send cMaxImportBodyBytes.
  GBlockStatus := 0;
  if AHeaders.Values[cHeaderTransferEncoding].Trim <> '' then
    GBlockStatus := cHttpLengthRequired
  else if ContentLengthExceeds(AHeaders.Values[cHeaderContentLength], MaxBodyBytesFor(AUri)) then
    GBlockStatus := cHttpPayloadTooLarge;
  if GBlockStatus <> 0 then
    VContinueProcessing := False;
end;

procedure TApiServer.DoHeadersBlocked(AContext: TIdContext; AHeaders: TIdHeaderList;
  var VResponseNo: Integer; var VResponseText, VContentText: string);
begin
  if GBlockStatus = cHttpLengthRequired then
  begin
    VResponseNo := cHttpLengthRequired;
    VResponseText := cMsgLengthRequired;
    VContentText := cMsgChunkedRefused;
    if Assigned(FLog) then
      FLog(Format('%-15s refused: chunked request body (411)', [AContext.Binding.PeerIP]));
    Exit;
  end;
  VResponseNo := cHttpPayloadTooLarge;
  VContentText := cMsgBodyTooLarge;
  if Assigned(FLog) then
    FLog(Format('%-15s refused: request body too large (Content-Length %s)',
      [AContext.Binding.PeerIP, AHeaders.Values[cHeaderContentLength]]));
end;

procedure TApiServer.DoConnect(AContext: TIdContext);
begin
  if (AContext <> nil) and (AContext.Connection <> nil) and (AContext.Connection.IOHandler <> nil) then
    AContext.Connection.IOHandler.ReadTimeout := cConnectionReadTimeoutMs;
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
  FStopping := False;

  FEngine := TMARSEngine.Create;
  FEngine.BasePath := ''; // mount applications at the site root

  // MARS's own per-IP request limiter (token bucket, checked before any routing):
  // against floods. Failed logins are limited separately (IPTV.Api.AuthThrottle).
  FEngine.Parameters.Values[cParamRateLimitRequests] := IntToStr(FConfig.RateLimitPerMinute);
  FEngine.Parameters.Values[cParamRateLimitWindow] := IntToStr(cRateLimitWindowSec);
  // behind a reverse proxy every client has the proxy's address: let the failed-login
  // lockout use X-Forwarded-For (only from the configured proxies). MARS's rate limiter
  // is NOT pointed at that header: it would believe it from ANY client, so a flooder
  // could dodge it by sending a fresh X-Forwarded-For per request. It keeps keying on
  // the socket address (behind a proxy: one shared bucket - raise rateLimitPerMinute).
  GAuthThrottle.TrustedProxies := FConfig.TrustedProxies;
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
      lFirst, lMasked, lPassword, lSent: string;
      lRetryAfter: Integer;
      lIsApi: Boolean;
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
      lIsApi := SameText(lFirst, cApiRoot);

      if (FWebRoot = '') or IsBackendRoute(lFirst) then
      begin
        // too many failed logins from this client: 429 until the lockout ends
        if GAuthThrottle.IsBlocked(ThrottleKey(lFirst, ARequest), lRetryAfter) then
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
        // DNS rebinding: with NO admin password a page on evil.example whose name
        // re-resolves to this LAN address could drive the API from the victim's
        // browser. Then only LAN-style Host names are accepted (with a password the
        // Host is not checked - reverse proxies may use any name).
        lPassword := LiveAdminPassword(FConfig);
        if lIsApi and (lPassword = '') and
           not IsAdminHostAccepted(ARequest.GetHeaderParamValue(cHeaderHost), FConfig) then
        begin
          Refuse(AResponse, cHttpStatusForbidden, Format(cMsgHostNotAllowed,
            [HostHeaderName(ARequest.GetHeaderParamValue(cHeaderHost))]));
          AHandled := True;
          Exit(False);
        end;
        // no admin password = no login on the admin API: then it answers only the local
        // network (a port-forward / public reverse proxy would hand it to the internet)
        if lIsApi and (lPassword = '') and not RequestIsLocal(ARequest) then
        begin
          Refuse(AResponse, cHttpStatusForbidden, cMsgAdminLanOnly);
          AHandled := True;
          Exit(False);
        end;
        // DNS rebinding on the surfaces a browser page could read without a login: the
        // Plex/HDHomeRun endpoints and a box route without a login (the default list)
        if (IsRouteIn(lFirst, cMediaRoutes) or IsLoginFreeBoxRequest(lFirst, AURL, ARequest)) and
           not IsAdminHostAccepted(ARequest.GetHeaderParamValue(cHeaderHost), FConfig) then
        begin
          Refuse(AResponse, cHttpStatusForbidden, Format(cMsgBoxHostNotAllowed,
            [HostHeaderName(ARequest.GetHeaderParamValue(cHeaderHost))]));
          AHandled := True;
          Exit(False);
        end;
        // with an admin password: check it BEFORE MARS parses the body ([BodyParam]), so
        // an anonymous client can't make the server parse anything. /api/health needs no
        // login; a download link (GET + ?dt= issued for exactly this path) passes too.
        if lIsApi and (lPassword <> '') and not SameText(ARequest.Method, cMethodOptions) and
           not (AURL.HasPathTokens(cApiSegIndex + 1) and SameText(AURL.PathTokens[cApiSegIndex], cApiHealthSeg)) then
        begin
          lSent := ARequest.GetHeaderParamValue(cAdminPasswordHeader);
          if not IsSamePassword(lSent, lPassword) and
             not (SameText(ARequest.Method, cMethodGet) and
                  GDownloadTokens.IsValid(ARequest.GetQueryParamValue(cDownloadTokenQuery), ARequest.GetRawPath)) then
          begin
            // a guess counts; a stale download token or the web app's first probe (no
            // password sent) is no guess
            if (lSent <> '') and not IsWarmupRequest(ARequest.GetHeaderParamValue(cWarmupHeader)) then
              GAuthThrottle.RegisterFailure(ThrottleKey(lFirst, ARequest));
            Refuse(AResponse, cHttpStatusUnauthorized, cMsgUnauthorized);
            AHandled := True;
            Exit(False);
          end;
        end;
        // a deeply nested JSON body would overflow the parser's stack: refused unparsed
        if lIsApi and not IsSafeMethod(ARequest.Method) and
           JsonNestingExceeds(ARequest.GetRawContent, cMaxJsonDepth) then
        begin
          Refuse(AResponse, cHttpBadRequest, Format(cMsgJsonTooDeep, [cMaxJsonDepth]));
          AHandled := True;
          Exit(False);
        end;
      end;

      // hold external backend requests until the startup warm-up has run
      if (FWebRoot = '') or IsBackendRoute(lFirst) then
        if (GWarmGate <> nil) and not IsWarmupRequest(ARequest.GetHeaderParamValue(cWarmupHeader)) then
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
      // a failed login counts towards the per-client lockout. On /api only when a
      // password was actually sent (the web app's first probe without one is no
      // guess); the box endpoints always carry a login. Our own warm-up requests
      // (bogus login on purpose) never count. A successful answer to a request that
      // carried a login clears the counter, so one good login undoes earlier typos.
      lFirst := '';
      if AURL.HasPathTokens then
        lFirst := AURL.PathTokens[0];
      if ((FWebRoot = '') or IsBackendRoute(lFirst)) and
         not IsWarmupRequest(ARequest.GetHeaderParamValue(cWarmupHeader)) then
      begin
        if AResponse.StatusCode = cHttpStatusUnauthorized then
        begin
          // on /api only a sent password is a guess (a bad / expired ?dt= is not)
          if not SameText(lFirst, cApiRoot) or
             (ARequest.GetHeaderParamValue(cAdminPasswordHeader) <> '') then
            GAuthThrottle.RegisterFailure(ThrottleKey(lFirst, ARequest));
        end
        else if IsSuccessfulLogin(lFirst, AURL, ARequest, AResponse.StatusCode, LiveAdminPassword(FConfig)) then
          GAuthThrottle.RegisterSuccess(ThrottleKey(lFirst, ARequest));
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
  NewWarmupToken; // CSPRNG (a Linux GUID is time-based)

  try
    FServer := TMARShttpServerIndy.Create(FEngine);
    FServer.OnHeadersAvailable := DoHeadersAvailable; // body cap, before the body is read
    FServer.OnHeadersBlocked := DoHeadersBlocked;
    FServer.OnConnect := DoConnect; // read timeout per connection
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

    TMonitor.Enter(FSyncLock);
    try
      SyncProxyServer; // start the stream relay if the global proxy OR a Plex proxy needs it
      SyncSsdp; // start the HDHomeRun discovery responder if Plex HDHR is enabled
    finally
      TMonitor.Exit(FSyncLock);
    end;
  except
    // e.g. the proxy port is taken: close the API listener we already opened, so
    // the process doesn't look alive while serving nothing (and a retry can bind)
    FRunning := True;
    Stop;
    raise;
  end;
  FRunning := True;
end;

function TApiServer.SsdpLocation: string;
var
  lScheme: string;
begin
  // the discover.json lives on httpPort; that port serves TLS when UseHttps is on,
  // so the SSDP LOCATION must use https there or Plex's fetch fails
  if FConfig.UseHttps then
    lScheme := cSchemeHttps
  else
    lScheme := cSchemeHttp;
  Result := Format('%s://%s:%d/discover.json', [lScheme, SafeUrlHost(FConfig.PublicBaseUrl, 'localhost'),
    FConfig.HttpPort]);
end;

procedure TApiServer.SyncSsdp;
var
  lLocation: string;
begin
  if FStopping then
    Exit;
  lLocation := SsdpLocation;
  // a changed publicBaseUrl must be advertised: the responder's LOCATION is fixed
  // per instance, so replace it
  if Assigned(FSsdp) and ((not FConfig.PlexHdhrEnabled) or (FSsdp.Location <> lLocation)) then
  begin
    FSsdp.Stop;
    FreeAndNil(FSsdp);
  end;
  if FConfig.PlexHdhrEnabled and not Assigned(FSsdp) then
  begin
    FSsdp := TSsdpServer.Create(lLocation, FLog);
    FSsdp.Start; // best-effort: logs and stays off when UDP 1900 can't bind
  end;
end;

procedure TApiServer.SyncPlex(const AConfig: TAppConfig);
var
  lOld: TAppConfig;
begin
  TMonitor.Enter(FSyncLock);
  try
    lOld := FConfig;
    FConfig := AConfig; // refresh our copy (SSDP location/host); endpoints read App.Config
    try
      // a Plex M3U/HDHR "relay" toggle may now need (or release) the relay; it can
      // fail to bind - then nothing changes (the relay sync is transactional)
      SyncProxyServer;
    except
      on E: Exception do
      begin
        FConfig := lOld;
        raise EMARSHttpException.Create(Format(cMsgPlexRelayFailed, [E.Message]), cHttpBadRequest);
      end;
    end;
    SyncSsdp;
  finally
    TMonitor.Exit(FSyncLock);
  end;
end;

function TApiServer.NeedsProxyServer: Boolean;
begin
  // the relay must run when the global stream proxy is on, OR when a Plex tuner
  // surface is set to relay (its lineup/playlist URLs point at the relay port) —
  // otherwise those URLs are dead and Plex gets no picture.
  Result := FConfig.ProxyStreams or FConfig.PlexM3uProxy or FConfig.PlexHdhrProxy;
end;

procedure TApiServer.SyncProxyServer;
var
  lNew: TStreamProxyServer;
begin
  if FStopping then
    Exit;
  if not NeedsProxyServer then
  begin
    if Assigned(FProxy) then
    begin
      FProxy.Stop;
      FreeAndNil(FProxy);
      FProxyActivePort := 0;
    end;
    Exit;
  end;
  if Assigned(FProxy) and (FProxyActivePort = FConfig.ProxyPort) then
    Exit; // already running on the right port
  // transactional: bind the new port FIRST; only when that worked the old relay goes
  // (a port that can't bind used to kill the working relay)
  lNew := TStreamProxyServer.Create(FConfig.ProxyPort, FLog);
  try
    lNew.Start;
  except
    on E: Exception do
    begin
      FreeAndNil(lNew);
      if Assigned(FLog) then
        FLog(Format('Stream proxy: port %d could not be opened: %s', [FConfig.ProxyPort, E.Message]));
      raise EMARSHttpException.Create(Format(cMsgPortInUse, [FConfig.ProxyPort]), cHttpBadRequest);
    end;
  end;
  if Assigned(FProxy) then
  begin
    FProxy.Stop;
    FreeAndNil(FProxy);
  end;
  FProxy := lNew;
  FProxyActivePort := FConfig.ProxyPort;
end;

procedure TApiServer.SetProxy(AEnabled: Boolean; APort: Integer);
var
  lOldEnabled: Boolean;
  lOldPort: Integer;
begin
  TMonitor.Enter(FSyncLock);
  try
    lOldEnabled := FConfig.ProxyStreams;
    lOldPort := FConfig.ProxyPort;
    FConfig.ProxyStreams := AEnabled;
    FConfig.ProxyPort := APort;
    try
      SyncProxyServer; // reconcile against the global + Plex proxy flags
    except
      // the running relay is untouched: keep our settings in line with it
      FConfig.ProxyStreams := lOldEnabled;
      FConfig.ProxyPort := lOldPort;
      raise;
    end;
  finally
    TMonitor.Exit(FSyncLock);
  end;
end;

destructor TApiServer.Destroy;
begin
  Stop;
  FreeAndNil(FSyncLock);
  inherited;
end;

procedure TApiServer.Stop;
begin
  if not FRunning then
    Exit;
  TMonitor.Enter(FSyncLock);
  try
    FStopping := True;
    if Assigned(FSsdp) then
    begin
      FSsdp.Stop;
      FreeAndNil(FSsdp);
    end;
    if Assigned(FProxy) then
    begin
      FProxy.Stop;
      FreeAndNil(FProxy);
      FProxyActivePort := 0;
    end;
  finally
    TMonitor.Exit(FSyncLock);
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
