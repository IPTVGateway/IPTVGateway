unit IPTV.Source.Http;

{ Shared HTTP fetch for the source readers.

  Why a hybrid: many Xtream/IPTV panels (often behind Cloudflare/WAFs) return
  plain-HTTP responses that Windows' WinHTTP — the backend of
  System.Net.HttpClient on Windows — refuses to parse ("WinHTTP error 12152 /
  invalid server response"), while browsers, IPTV boxes, libcurl and Indy handle
  them fine. So:
    - http  URLs go through Indy (TIdHTTP, raw sockets, lenient parser);
    - https URLs go through System.Net.HttpClient, which uses the OS TLS stack
      natively (no OpenSSL deployment needed) and copes with TLS endpoints.
  On Linux System.Net.HttpClient already uses libcurl, but Indy works there too,
  so the same code path is fine cross-platform.

  Hardening (provider-compat spec): per-provider User-Agent, forced IPv4,
  Connection: close, cookie jar, identity encoding, per-request-type timeouts,
  exponential backoff on 429/503, Cloudflare-challenge detection, an optional
  debug proxy (env IPTV_DEBUG_PROXY=host:port), and raw-byte charset detection
  (BOM / UTF-8 / CP1251) for playlists. All requests send a full browser-like
  header set; bare-UA requests get dropped by some WAFs. }

interface

uses
  // RTL
  System.SysUtils,
  System.Net.HttpClient;

type
  /// Raised when a provider is fronted by a Cloudflare browser (JS) challenge —
  /// it can't be fetched headless, so we surface a clear, actionable message.
  EProviderBlocked = class(Exception);

const
  // Per-request-type read timeouts (ms): portal API calls answer fast; bulk
  // playlist/EPG downloads can legitimately take much longer.
  TimeoutPortalMs = 15000;
  TimeoutBulkMs   = 60000;
  // read timeout when the caller names none (also the THTTPClient response timeout)
  cTimeoutDefaultReadMs = 30000;

/// A THTTPClient with browser-like headers, identity encoding, redirects and the
/// default timeouts. Caller frees.
function NewHttpClient(const AUserAgent: string = ''): THTTPClient;
/// GET the URL as text (http via Indy, https via the OS HTTP client). Raises on
/// a transport/HTTP error, or EProviderBlocked on a Cloudflare challenge.
/// AReferer sets a per-provider Referer header (some portals require it, #8).
function HttpGetString(const AUrl: string; const AUserAgent: string = '';
  AReadTimeoutMs: Integer = cTimeoutDefaultReadMs; const AReferer: string = ''): string;
/// GET the URL as raw bytes, then decode honouring BOM/UTF-8/CP1251 — use for
/// playlists where the panel's charset is unknown.
function HttpGetText(const AUrl: string; const AUserAgent: string = '';
  AReadTimeoutMs: Integer = cTimeoutDefaultReadMs; const AReferer: string = ''): string;
/// Decode bytes: honour a BOM; else accept valid UTF-8; else fall back to
/// Windows-1251 (common on RU/UA panels).
function DecodeBytes(const ABytes: TBytes): string;

const
  DefaultUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 ' +
    '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36';
  DefaultAccept =
    'text/html,application/xhtml+xml,application/xml;q=0.9,application/json,*/*;q=0.8';
  DefaultAcceptLanguage = 'en-US,en;q=0.9,nl;q=0.8';

implementation

uses
  // RTL
  System.Classes,
  System.NetConsts,
  System.Net.URLClient,
  System.ZLib,
  System.Math,
  // Indy
  IdHTTP,
  IdGlobal,
  IdCookieManager,
  // Own units
  IPTV.Core.Utils;

const
  // connection setup
  cTimeoutConnectMs = 15000;
  cMaxRedirects = 5;              // cap redirect chains (#3)
  cAcceptEncodingIdentity = 'identity';
  cAcceptAny = '*/*';
  cConnectionClose = 'close';
  cSchemeHttps = 'https';
  cIgnoreCase = True;             // string.StartsWith AIgnoreCase
  cHeaderServer = 'Server';
  cHeaderReferer = 'Referer';

  // HTTP status codes
  cHttpStatusErrorMin = 400;
  cHttpStatusForbidden = 403;
  cHttpStatusTooManyRequests = 429;
  cHttpStatusServiceUnavailable = 503;

  // retry with exponential backoff on 429/503 (#14): 1s, 2s, 4s
  cMaxRetries = 3;
  cBackoffBaseMs = 500;

  // debug proxy (#18): env IPTV_DEBUG_PROXY=host:port
  cEnvDebugProxy = 'IPTV_DEBUG_PROXY';
  cDebugProxyDefaultPort = 8080;

  // charset detection
  cCodePageWestern = 1252;  // superset of ISO-8859-1 (Latin-1)
  cCodePageCyrillic = 1251;
  cCodePageLatin9 = 28605;  // ISO-8859-15
  cDeclScanBytes = 256;     // the XML prolog sits at the very start
  cXmlEncodingAttr = 'encoding=';
  // share of high (>= $C0) bytes among letters above which a non-UTF-8 text is
  // taken as Cyrillic: Russian text is nearly all high bytes, Western text only
  // has a few accented letters between ASCII
  cCyrillicHighShare = 0.3;
  cLegacyHighLetterMin = $C0; // CP1251: the Cyrillic letters are $C0..$FF

  // UTF-8 lead/continuation byte masks
  cUtf8AsciiMax = $80;        // below: a 1-byte (ASCII) sequence
  cUtf8Lead2Mask = $E0;
  cUtf8Lead2Bits = $C0;
  cUtf8Lead3Mask = $F0;
  cUtf8Lead3Bits = $E0;
  cUtf8Lead4Mask = $F8;
  cUtf8Lead4Bits = $F0;
  cUtf8ContMask = $C0;
  cUtf8ContBits = $80;

  // Decode only the HEAD of a response for the challenge scan. A Cloudflare
  // interstitial is a few KB; a real playlist/EPG can be hundreds of MB, and a
  // Delphi UTF-16 string of it is ~2x that — never decode the whole body just to
  // look for a token (this is the main per-fetch memory spike).
  cCloudflareScanBytes = 32 * 1024;
  cServerCloudflare = 'cloudflare';

  // gzip (.xml.gz guides)
  cGzipMagic1 = $1F;
  cGzipMagic2 = $8B;
  cZlibWindowBitsGzip = 15 + 16; // 15 + 16 = gzip header
  cGunzipChunkBytes = 256 * 1024;

type
  // IPVersion is protected on TIdHTTP in this Indy; a same-unit descendant cast
  // exposes it so we can force IPv4 (#11).
  TIdHTTPAccess = class(TIdHTTP);

function NewHttpClient(const AUserAgent: string): THTTPClient;
begin
  Result := THTTPClient.Create;
  if AUserAgent <> '' then
    Result.UserAgent := AUserAgent
  else
    Result.UserAgent := DefaultUserAgent;
  Result.Accept := DefaultAccept;
  Result.AcceptLanguage := DefaultAcceptLanguage;
  Result.AcceptEncoding := cAcceptEncodingIdentity;
  Result.HandleRedirects := True;
  Result.ConnectionTimeout := cTimeoutConnectMs;
  Result.ResponseTimeout := cTimeoutDefaultReadMs;
end;

// ── charset detection ──────────────────────────────────────────────────────

function IsValidUtf8(const ABytes: TBytes): Boolean;
var
  i, lLen, lExtra: Integer;
begin
  i := 0;
  lLen := Length(ABytes);
  while i < lLen do
  begin
    if ABytes[i] < cUtf8AsciiMax then
      lExtra := 0
    else if (ABytes[i] and cUtf8Lead2Mask) = cUtf8Lead2Bits then
      lExtra := 1
    else if (ABytes[i] and cUtf8Lead3Mask) = cUtf8Lead3Bits then
      lExtra := 2
    else if (ABytes[i] and cUtf8Lead4Mask) = cUtf8Lead4Bits then
      lExtra := 3
    else
      Exit(False);
    if i + lExtra >= lLen then
      Exit(False);
    while lExtra > 0 do
    begin
      Inc(i);
      if (ABytes[i] and cUtf8ContMask) <> cUtf8ContBits then
        Exit(False);
      Dec(lExtra);
    end;
    Inc(i);
  end;
  Result := True;
end;

// code page named by an XML prolog (<?xml ... encoding="ISO-8859-1"?>), 0 if none / unknown
function DeclaredCodePage(const ABytes: TBytes): Integer;
var
  lHead, lEnc: string;
  lPos, lEnd, i: Integer;
begin
  Result := 0;
  SetLength(lHead, Min(Length(ABytes), cDeclScanBytes));
  for i := 1 to Length(lHead) do
    lHead[i] := Char(ABytes[i - 1]); // ASCII view is enough for the prolog
  lPos := Pos(cXmlEncodingAttr, LowerCase(lHead));
  if lPos = 0 then
    Exit;
  lPos := lPos + Length(cXmlEncodingAttr) + 1; // skip the quote
  lEnd := lPos;
  while (lEnd <= Length(lHead)) and not CharInSet(lHead[lEnd], ['"', '''', '?', ' ']) do
    Inc(lEnd);
  lEnc := LowerCase(Copy(lHead, lPos, lEnd - lPos));
  if (lEnc = 'iso-8859-1') or (lEnc = 'latin1') or (lEnc = 'latin-1') or (lEnc = 'windows-1252') then
    Result := cCodePageWestern
  else if lEnc = 'iso-8859-15' then
    Result := cCodePageLatin9
  else if lEnc = 'windows-1251' then
    Result := cCodePageCyrillic;
end;

// non-UTF-8 text without a declaration: Cyrillic (1251) or Western (1252)?
function GuessLegacyCodePage(const ABytes: TBytes): Integer;
var
  lLetters, lHigh: Int64;
  i: Integer;
  lByte: Byte;
begin
  lLetters := 0;
  lHigh := 0;
  for i := 0 to High(ABytes) do
  begin
    lByte := ABytes[i];
    if (lByte >= Ord('A')) and (lByte <= Ord('z')) then
      Inc(lLetters)
    else if lByte >= cLegacyHighLetterMin then
    begin
      Inc(lLetters);
      Inc(lHigh);
    end;
  end;
  if (lLetters > 0) and (lHigh / lLetters > cCyrillicHighShare) then
    Result := cCodePageCyrillic
  else
    Result := cCodePageWestern;
end;

function DecodeBytes(const ABytes: TBytes): string;
var
  lEnc: TEncoding;
  lBomLen, lCodePage: Integer;
begin
  if Length(ABytes) = 0 then
    Exit('');
  // nil: detect any BOM (UTF-8, and UTF-16 LE/BE too)
  lEnc := nil;
  lBomLen := TEncoding.GetBufferEncoding(ABytes, lEnc, TEncoding.UTF8);
  if lBomLen > 0 then
    Exit(lEnc.GetString(ABytes, lBomLen, Length(ABytes) - lBomLen));
  if IsValidUtf8(ABytes) then
    Exit(TEncoding.UTF8.GetString(ABytes));
  // not UTF-8: the XML prolog's encoding, else a Cyrillic/Western guess (older
  // European grabbers send ISO-8859-1; it used to come out as Cyrillic)
  lCodePage := DeclaredCodePage(ABytes);
  if lCodePage = 0 then
    lCodePage := GuessLegacyCodePage(ABytes);
  // guarded: a code page may be unavailable on a bare Linux without ICU
  try
    lEnc := TEncoding.GetEncoding(lCodePage);
    try
      Result := lEnc.GetString(ABytes);
    finally
      FreeAndNil(lEnc);
    end;
  except
    Result := TEncoding.ANSI.GetString(ABytes);
  end;
end;

// ── Cloudflare challenge + debug proxy ──────────────────────────────────────

// Decode only the HEAD of a response for the challenge scan (cCloudflareScanBytes).
function DecodeHead(const ABytes: TBytes): string;
begin
  if Length(ABytes) <= cCloudflareScanBytes then
    Result := DecodeBytes(ABytes)
  else
    Result := DecodeBytes(Copy(ABytes, 0, cCloudflareScanBytes));
end;

function IsCloudflareChallenge(const ABody, AServer: string; AStatus: Integer): Boolean;
begin
  // A managed JS challenge serves an interstitial HTML page (403/503) from the
  // cloudflare edge; the body carries the challenge token / "Just a moment".
  Result :=
    (Pos('__cf_chl', ABody) > 0) or
    (Pos('cf-chl', ABody) > 0) or
    (Pos('Just a moment', ABody) > 0) or
    ((AStatus = cHttpStatusForbidden) and (Pos('Attention Required', ABody) > 0)) or
    (((AStatus = cHttpStatusForbidden) or (AStatus = cHttpStatusServiceUnavailable)) and
      SameText(AServer, cServerCloudflare) and (Pos('challenge', ABody) > 0));
end;

// 429 / 503 = the provider asks us to slow down: retry with backoff
function IsRetryStatus(AStatus: Integer): Boolean;
begin
  Result := (AStatus = cHttpStatusTooManyRequests) or (AStatus = cHttpStatusServiceUnavailable);
end;

procedure ApplyDebugProxyIndy(AHttp: TIdHTTP);
var
  lProxy: string;
  lColon: Integer;
begin
  lProxy := GetEnvironmentVariable(cEnvDebugProxy);
  if lProxy = '' then
    Exit;
  lColon := lProxy.LastIndexOf(':');
  if lColon > 0 then
  begin
    AHttp.ProxyParams.ProxyServer := lProxy.Substring(0, lColon);
    AHttp.ProxyParams.ProxyPort := StrToIntDef(lProxy.Substring(lColon + 1), cDebugProxyDefaultPort);
  end;
end;

procedure ApplyDebugProxyHttp(AClient: THTTPClient);
var
  lProxy: string;
  lColon: Integer;
begin
  lProxy := GetEnvironmentVariable(cEnvDebugProxy);
  if lProxy = '' then
    Exit;
  lColon := lProxy.LastIndexOf(':');
  if lColon > 0 then
    AClient.ProxySettings := TProxySettings.Create(lProxy.Substring(0, lColon),
      StrToIntDef(lProxy.Substring(lColon + 1), cDebugProxyDefaultPort));
end;

// ── fetchers ────────────────────────────────────────────────────────────────

type
  // Indy here has no TLS handler (https goes through the OS client): a plain-http
  // portal that redirects to an https node is stopped and re-fetched over https
  TRedirectCatcher = class
  private
    FHttpsTarget: string;
  public
    procedure HandleRedirect(ASender: TObject; var ADest: string; var ANumRedirect: Integer;
      var AHandled: Boolean; var AMethod: TIdHTTPMethod);
    property HttpsTarget: string read FHttpsTarget;
  end;

procedure TRedirectCatcher.HandleRedirect(ASender: TObject; var ADest: string;
  var ANumRedirect: Integer; var AHandled: Boolean; var AMethod: TIdHTTPMethod);
begin
  if ADest.StartsWith(cSchemeHttps + ':', cIgnoreCase) then
  begin
    FHttpsTarget := ADest;
    AHandled := False; // stop Indy here; WinHttpGetBytes takes over
  end;
end;

function WinHttpGetBytes(const AUrl, AUserAgent: string; AReadTimeoutMs: Integer;
  const AReferer: string): TBytes; forward;

// http: Indy parses the response itself and tolerates the slightly non-standard
// HTTP that WinHTTP rejects with 12152.
function IndyGetBytes(const AUrl, AUserAgent: string; AReadTimeoutMs: Integer;
  const AReferer: string): TBytes;
var
  lHttp: TIdHTTP;
  lStream: TBytesStream;
  lAttempt, lStatus: Integer;
  lCatcher: TRedirectCatcher;
begin
  Result := nil;
  lCatcher := nil;
  lHttp := nil;
  try
    lCatcher := TRedirectCatcher.Create;
    lHttp := TIdHTTP.Create(nil);
    lHttp.OnRedirect := lCatcher.HandleRedirect;
    lHttp.HandleRedirects := True;
    lHttp.RedirectMaximum := cMaxRedirects; // cap redirect chains (#3)
    lHttp.AllowCookies := True;            // keep session cookies across redirects (#4)
    lHttp.CookieManager := TIdCookieManager.Create(lHttp);
    TIdHTTPAccess(lHttp).IPVersion := Id_IPv4; // force IPv4 — broken IPv6 on some providers (#11)
    lHttp.ConnectTimeout := cTimeoutConnectMs;
    lHttp.ReadTimeout := AReadTimeoutMs;   // per request-type (#17)
    lHttp.Request.Connection := cConnectionClose; // avoid socket-reuse issues on portal calls (#12)
    // don't raise on a 4xx/5xx — we want the body so we can spot a Cloudflare
    // challenge page and decide on backoff ourselves (#13/#14)
    lHttp.HTTPOptions := lHttp.HTTPOptions + [hoNoProtocolErrorException, hoWantProtocolErrorContent];
    if AUserAgent <> '' then
      lHttp.Request.UserAgent := AUserAgent
    else
      lHttp.Request.UserAgent := DefaultUserAgent;
    // Look like a media client, not a browser: a real VLC/ffmpeg sends just
    // Accept: */* and NO Accept-Language. Sending browser-y headers under a VLC
    // UA is a fingerprint mismatch some WAFs drop (#2, B2).
    lHttp.Request.Accept := cAcceptAny;
    lHttp.Request.AcceptEncoding := cAcceptEncodingIdentity; // no gzip (#2)
    if AReferer <> '' then
      lHttp.Request.Referer := AReferer;   // some portals gate on Referer (#8)
    ApplyDebugProxyIndy(lHttp);            // route via mitmproxy when IPTV_DEBUG_PROXY set (#18)

    lAttempt := 0;
    repeat
      lStream := TBytesStream.Create;
      try
        lHttp.Get(AUrl, lStream);
        if lCatcher.HttpsTarget <> '' then
          Exit(WinHttpGetBytes(lCatcher.HttpsTarget, AUserAgent, AReadTimeoutMs, AReferer));
        lStatus := lHttp.ResponseCode;
        if IsRetryStatus(lStatus) and (lAttempt < cMaxRetries) then
        begin
          Inc(lAttempt);
          TThread.Sleep(cBackoffBaseMs * (1 shl lAttempt)); // 1s, 2s, 4s backoff (#14)
          Continue;
        end;
        Result := Copy(lStream.Bytes, 0, lStream.Size);
        Break;
      finally
        FreeAndNil(lStream);
      end;
    until False;

    if IsCloudflareChallenge(DecodeHead(Result),
      lHttp.Response.RawHeaders.Values[cHeaderServer], lStatus) then
      raise EProviderBlocked.Create(
        'Provider zit achter een Cloudflare browser-challenge — niet zonder browser op te halen.');
    if lStatus >= cHttpStatusErrorMin then
      raise EIdHTTPProtocolException.CreateError(lStatus, lHttp.ResponseText, DecodeBytes(Result));
    // Truncation guard: with identity encoding a declared Content-Length equals the
    // body length, so fewer received bytes means the connection dropped mid-transfer.
    // Fail rather than hand back a truncated playlist/EPG (for EPG, ReplaceEpg would
    // then DELETE the old programmes and store only the partial set).
    if (lHttp.Response.ContentLength > 0) and (Length(Result) < lHttp.Response.ContentLength) then
      raise Exception.CreateFmt('truncated response from %s: expected %d bytes, got %d',
        [MaskUrlSecrets(AUrl), lHttp.Response.ContentLength, Length(Result)]);
  finally
    FreeAndNil(lHttp);
    FreeAndNil(lCatcher);
  end;
end;

// https: the OS HTTP client handles TLS natively (no OpenSSL libs to deploy).
function WinHttpGetBytes(const AUrl, AUserAgent: string; AReadTimeoutMs: Integer;
  const AReferer: string): TBytes;
var
  lHttp: THTTPClient;
  lStream: TBytesStream;
  lResp: IHTTPResponse;
  lAttempt: Integer;
  lHeaders: TNetHeaders;
begin
  Result := nil;
  lHeaders := [];
  if AReferer <> '' then
    lHeaders := [TNameValuePair.Create(cHeaderReferer, AReferer)]; // #8
  lHttp := NewHttpClient(AUserAgent);
  try
    lHttp.ResponseTimeout := AReadTimeoutMs;
    ApplyDebugProxyHttp(lHttp);
    lAttempt := 0;
    repeat
      lStream := TBytesStream.Create;
      try
        lResp := lHttp.Get(AUrl, lStream, lHeaders);
        if IsRetryStatus(lResp.StatusCode) and (lAttempt < cMaxRetries) then
        begin
          Inc(lAttempt);
          TThread.Sleep(cBackoffBaseMs * (1 shl lAttempt));
          Continue;
        end;
        Result := Copy(lStream.Bytes, 0, lStream.Size);
        if IsCloudflareChallenge(DecodeHead(Result),
          lResp.HeaderValue[cHeaderServer], lResp.StatusCode) then
          raise EProviderBlocked.Create(
            'Provider zit achter een Cloudflare browser-challenge — niet zonder browser op te halen.');
        // surface real HTTP errors instead of returning the error-page body (which
        // parses to nothing → a silently empty/cleared catalog). Mirrors the Indy path.
        if lResp.StatusCode >= cHttpStatusErrorMin then
          raise Exception.CreateFmt('HTTP %d fetching %s', [lResp.StatusCode, MaskUrlSecrets(AUrl)]);
        // truncation guard (see the Indy path): a short body vs a declared
        // Content-Length means a mid-transfer drop — fail instead of persisting
        // an incomplete playlist/EPG.
        if (lResp.ContentLength > 0) and (Length(Result) < lResp.ContentLength) then
          raise Exception.CreateFmt('truncated response from %s: expected %d bytes, got %d',
            [MaskUrlSecrets(AUrl), lResp.ContentLength, Length(Result)]);
        Break;
      finally
        FreeAndNil(lStream);
      end;
    until False;
  finally
    FreeAndNil(lHttp);
  end;
end;

function HttpGetBytes(const AUrl, AUserAgent: string; AReadTimeoutMs: Integer;
  const AReferer: string): TBytes;
begin
  if AUrl.StartsWith(cSchemeHttps, cIgnoreCase) then
    Result := WinHttpGetBytes(AUrl, AUserAgent, AReadTimeoutMs, AReferer)
  else
    Result := IndyGetBytes(AUrl, AUserAgent, AReadTimeoutMs, AReferer);
end;

// A .gz download (e.g. a third-party XMLTV guide "guide.xml.gz") arrives as raw
// gzip bytes (we ask for identity encoding, so it is the FILE that is gzipped).
// Detect the gzip magic and inflate; anything else passes through unchanged.
function GunzipIfNeeded(const ABytes: TBytes): TBytes;
var
  lSrc: TBytesStream;
  lZip: TZDecompressionStream;
  lDst: TBytesStream;
  lBuf: TBytes;
  lRead: Integer;
begin
  if (Length(ABytes) < 2) or (ABytes[0] <> cGzipMagic1) or (ABytes[1] <> cGzipMagic2) then
    Exit(ABytes);
  lSrc := TBytesStream.Create(ABytes);
  try
    lZip := TZDecompressionStream.Create(lSrc, cZlibWindowBitsGzip);
    try
      lDst := TBytesStream.Create;
      try
        // read in chunks: a decompression stream has no known Size to CopyFrom
        SetLength(lBuf, cGunzipChunkBytes);
        repeat
          lRead := lZip.Read(lBuf[0], Length(lBuf));
          if lRead > 0 then
            lDst.WriteBuffer(lBuf[0], lRead);
        until lRead <= 0;
        Result := Copy(lDst.Bytes, 0, lDst.Size);
      finally
        FreeAndNil(lDst);
      end;
    finally
      FreeAndNil(lZip);
    end;
  finally
    FreeAndNil(lSrc);
  end;
end;

function HttpGetText(const AUrl: string; const AUserAgent: string;
  AReadTimeoutMs: Integer; const AReferer: string): string;
begin
  Result := DecodeBytes(GunzipIfNeeded(HttpGetBytes(AUrl, AUserAgent, AReadTimeoutMs, AReferer)));
end;

function HttpGetString(const AUrl: string; const AUserAgent: string;
  AReadTimeoutMs: Integer; const AReferer: string): string;
begin
  // JSON/XML is UTF-8, but DecodeBytes also strips a leading BOM — a raw
  // UTF8.GetString would keep U+FEFF and make TJSONObject.ParseJSONValue fail.
  Result := DecodeBytes(HttpGetBytes(AUrl, AUserAgent, AReadTimeoutMs, AReferer));
end;

end.
