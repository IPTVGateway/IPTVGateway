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
  System.SysUtils, System.Net.HttpClient;

type
  /// Raised when a provider is fronted by a Cloudflare browser (JS) challenge —
  /// it can't be fetched headless, so we surface a clear, actionable message.
  EProviderBlocked = class(Exception);

const
  // Per-request-type read timeouts (ms): portal API calls answer fast; bulk
  // playlist/EPG downloads can legitimately take much longer.
  TimeoutPortalMs = 15000;
  TimeoutBulkMs   = 60000;

function NewHttpClient(const AUserAgent: string = ''): THTTPClient;
/// GET the URL as text (http via Indy, https via the OS HTTP client). Raises on
/// a transport/HTTP error, or EProviderBlocked on a Cloudflare challenge.
/// AReferer sets a per-provider Referer header (some portals require it, #8).
function HttpGetString(const AUrl: string; const AUserAgent: string = '';
  AReadTimeoutMs: Integer = 30000; const AReferer: string = ''): string;
/// GET the URL as raw bytes, then decode honouring BOM/UTF-8/CP1251 — use for
/// playlists where the panel's charset is unknown.
function HttpGetText(const AUrl: string; const AUserAgent: string = '';
  AReadTimeoutMs: Integer = 30000; const AReferer: string = ''): string;
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
  System.Classes, System.NetConsts, System.Net.URLClient, System.ZLib, System.Math,
  IdHTTP, IdGlobal, IdCookieManager,
  IPTV.Core.Utils;

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
  Result.AcceptEncoding := 'identity';
  Result.HandleRedirects := True;
  Result.ConnectionTimeout := 15000; // ms
  Result.ResponseTimeout := 30000;   // ms
end;

// ── charset detection ──────────────────────────────────────────────────────

function IsValidUtf8(const B: TBytes): Boolean;
var
  I, N, Extra: Integer;
begin
  I := 0;
  N := Length(B);
  while I < N do
  begin
    if B[I] < $80 then
      Extra := 0
    else if (B[I] and $E0) = $C0 then
      Extra := 1
    else if (B[I] and $F0) = $E0 then
      Extra := 2
    else if (B[I] and $F8) = $F0 then
      Extra := 3
    else
      Exit(False);
    if I + Extra >= N then
      Exit(False);
    while Extra > 0 do
    begin
      Inc(I);
      if (B[I] and $C0) <> $80 then
        Exit(False);
      Dec(Extra);
    end;
    Inc(I);
  end;
  Result := True;
end;

const
  cCodePageWestern = 1252;  // superset of ISO-8859-1 (Latin-1)
  cCodePageCyrillic = 1251;
  cCodePageLatin9 = 28605;  // ISO-8859-15
  cDeclScanBytes = 256;     // the XML prolog sits at the very start
  // share of high (>= $C0) bytes among letters above which a non-UTF-8 text is
  // taken as Cyrillic: Russian text is nearly all high bytes, Western text only
  // has a few accented letters between ASCII
  cCyrillicHighShare = 0.3;

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
  lPos := Pos('encoding=', LowerCase(lHead));
  if lPos = 0 then
    Exit;
  lPos := lPos + Length('encoding=') + 1; // skip the quote
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
    else if lByte >= $C0 then
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

// Decode only the HEAD of a response for the challenge scan. A Cloudflare
// interstitial is a few KB; a real playlist/EPG can be hundreds of MB, and a
// Delphi UTF-16 string of it is ~2x that — never decode the whole body just to
// look for a token (this is the main per-fetch memory spike).
const
  CF_SCAN_BYTES = 32 * 1024;

function DecodeHead(const ABytes: TBytes): string;
begin
  if Length(ABytes) <= CF_SCAN_BYTES then
    Result := DecodeBytes(ABytes)
  else
    Result := DecodeBytes(Copy(ABytes, 0, CF_SCAN_BYTES));
end;

function IsCloudflareChallenge(const ABody, AServer: string; AStatus: Integer): Boolean;
begin
  // A managed JS challenge serves an interstitial HTML page (403/503) from the
  // cloudflare edge; the body carries the challenge token / "Just a moment".
  Result :=
    (Pos('__cf_chl', ABody) > 0) or
    (Pos('cf-chl', ABody) > 0) or
    (Pos('Just a moment', ABody) > 0) or
    ((AStatus = 403) and (Pos('Attention Required', ABody) > 0)) or
    (((AStatus = 403) or (AStatus = 503)) and SameText(AServer, 'cloudflare') and (Pos('challenge', ABody) > 0));
end;

procedure ApplyDebugProxyIndy(H: TIdHTTP);
var
  P: string;
  Colon: Integer;
begin
  P := GetEnvironmentVariable('IPTV_DEBUG_PROXY');
  if P = '' then
    Exit;
  Colon := P.LastIndexOf(':');
  if Colon > 0 then
  begin
    H.ProxyParams.ProxyServer := P.Substring(0, Colon);
    H.ProxyParams.ProxyPort := StrToIntDef(P.Substring(Colon + 1), 8080);
  end;
end;

procedure ApplyDebugProxyHttp(C: THTTPClient);
var
  P: string;
  Colon: Integer;
begin
  P := GetEnvironmentVariable('IPTV_DEBUG_PROXY');
  if P = '' then
    Exit;
  Colon := P.LastIndexOf(':');
  if Colon > 0 then
    C.ProxySettings := TProxySettings.Create(P.Substring(0, Colon),
      StrToIntDef(P.Substring(Colon + 1), 8080));
end;

// ── fetchers ────────────────────────────────────────────────────────────────

type
  // Indy here has no TLS handler (https goes through the OS client): a plain-http
  // portal that redirects to an https node is stopped and re-fetched over https
  TRedirectCatcher = class
  private
    FHttpsTarget: string;
  public
    procedure HandleRedirect(Sender: TObject; var ADest: string; var ANumRedirect: Integer;
      var AHandled: Boolean; var AMethod: TIdHTTPMethod);
    property HttpsTarget: string read FHttpsTarget;
  end;

procedure TRedirectCatcher.HandleRedirect(Sender: TObject; var ADest: string;
  var ANumRedirect: Integer; var AHandled: Boolean; var AMethod: TIdHTTPMethod);
begin
  if ADest.StartsWith('https:', True) then
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
  H: TIdHTTP;
  MS: TBytesStream;
  Attempt, Status: Integer;
  lCatcher: TRedirectCatcher;
begin
  Result := nil;
  lCatcher := TRedirectCatcher.Create;
  H := TIdHTTP.Create(nil);
  try
    H.OnRedirect := lCatcher.HandleRedirect;
    H.HandleRedirects := True;
    H.RedirectMaximum := 5;            // cap redirect chains (#3)
    H.AllowCookies := True;            // keep session cookies across redirects (#4)
    H.CookieManager := TIdCookieManager.Create(H);
    TIdHTTPAccess(H).IPVersion := Id_IPv4; // force IPv4 — broken IPv6 on some providers (#11)
    H.ConnectTimeout := 15000;
    H.ReadTimeout := AReadTimeoutMs;   // per request-type (#17)
    H.Request.Connection := 'close';   // avoid socket-reuse issues on portal calls (#12)
    // don't raise on a 4xx/5xx — we want the body so we can spot a Cloudflare
    // challenge page and decide on backoff ourselves (#13/#14)
    H.HTTPOptions := H.HTTPOptions + [hoNoProtocolErrorException, hoWantProtocolErrorContent];
    if AUserAgent <> '' then
      H.Request.UserAgent := AUserAgent
    else
      H.Request.UserAgent := DefaultUserAgent;
    // Look like a media client, not a browser: a real VLC/ffmpeg sends just
    // Accept: */* and NO Accept-Language. Sending browser-y headers under a VLC
    // UA is a fingerprint mismatch some WAFs drop (#2, B2).
    H.Request.Accept := '*/*';
    H.Request.AcceptEncoding := 'identity'; // no gzip (#2)
    if AReferer <> '' then
      H.Request.Referer := AReferer;   // some portals gate on Referer (#8)
    ApplyDebugProxyIndy(H);            // route via mitmproxy when IPTV_DEBUG_PROXY set (#18)

    Attempt := 0;
    repeat
      MS := TBytesStream.Create;
      try
        H.Get(AUrl, MS);
        if lCatcher.HttpsTarget <> '' then
          Exit(WinHttpGetBytes(lCatcher.HttpsTarget, AUserAgent, AReadTimeoutMs, AReferer));
        Status := H.ResponseCode;
        if ((Status = 429) or (Status = 503)) and (Attempt < 3) then
        begin
          Inc(Attempt);
          TThread.Sleep(500 * (1 shl Attempt)); // 1s, 2s, 4s backoff (#14)
          Continue;
        end;
        Result := Copy(MS.Bytes, 0, MS.Size);
        Break;
      finally
        MS.Free;
      end;
    until False;

    if IsCloudflareChallenge(DecodeHead(Result),
      H.Response.RawHeaders.Values['Server'], Status) then
      raise EProviderBlocked.Create(
        'Provider zit achter een Cloudflare browser-challenge — niet zonder browser op te halen.');
    if Status >= 400 then
      raise EIdHTTPProtocolException.CreateError(Status, H.ResponseText, DecodeBytes(Result));
    // Truncation guard: with identity encoding a declared Content-Length equals the
    // body length, so fewer received bytes means the connection dropped mid-transfer.
    // Fail rather than hand back a truncated playlist/EPG (for EPG, ReplaceEpg would
    // then DELETE the old programmes and store only the partial set).
    if (H.Response.ContentLength > 0) and (Length(Result) < H.Response.ContentLength) then
      raise Exception.CreateFmt('truncated response from %s: expected %d bytes, got %d',
        [MaskUrlSecrets(AUrl), H.Response.ContentLength, Length(Result)]);
  finally
    FreeAndNil(H);
    FreeAndNil(lCatcher);
  end;
end;

// https: the OS HTTP client handles TLS natively (no OpenSSL libs to deploy).
function WinHttpGetBytes(const AUrl, AUserAgent: string; AReadTimeoutMs: Integer;
  const AReferer: string): TBytes;
var
  Http: THTTPClient;
  MS: TBytesStream;
  Resp: IHTTPResponse;
  Attempt: Integer;
  Headers: TNetHeaders;
begin
  Result := nil;
  Headers := [];
  if AReferer <> '' then
    Headers := [TNameValuePair.Create('Referer', AReferer)]; // #8
  Http := NewHttpClient(AUserAgent);
  try
    Http.ResponseTimeout := AReadTimeoutMs;
    ApplyDebugProxyHttp(Http);
    Attempt := 0;
    repeat
      MS := TBytesStream.Create;
      try
        Resp := Http.Get(AUrl, MS, Headers);
        if ((Resp.StatusCode = 429) or (Resp.StatusCode = 503)) and (Attempt < 3) then
        begin
          Inc(Attempt);
          TThread.Sleep(500 * (1 shl Attempt));
          Continue;
        end;
        Result := Copy(MS.Bytes, 0, MS.Size);
        if IsCloudflareChallenge(DecodeHead(Result),
          Resp.HeaderValue['Server'], Resp.StatusCode) then
          raise EProviderBlocked.Create(
            'Provider zit achter een Cloudflare browser-challenge — niet zonder browser op te halen.');
        // surface real HTTP errors instead of returning the error-page body (which
        // parses to nothing → a silently empty/cleared catalog). Mirrors the Indy path.
        if Resp.StatusCode >= 400 then
          raise Exception.CreateFmt('HTTP %d fetching %s', [Resp.StatusCode, MaskUrlSecrets(AUrl)]);
        // truncation guard (see the Indy path): a short body vs a declared
        // Content-Length means a mid-transfer drop — fail instead of persisting
        // an incomplete playlist/EPG.
        if (Resp.ContentLength > 0) and (Length(Result) < Resp.ContentLength) then
          raise Exception.CreateFmt('truncated response from %s: expected %d bytes, got %d',
            [MaskUrlSecrets(AUrl), Resp.ContentLength, Length(Result)]);
        Break;
      finally
        MS.Free;
      end;
    until False;
  finally
    Http.Free;
  end;
end;

function HttpGetBytes(const AUrl, AUserAgent: string; AReadTimeoutMs: Integer;
  const AReferer: string): TBytes;
begin
  if AUrl.StartsWith('https', True) then
    Result := WinHttpGetBytes(AUrl, AUserAgent, AReadTimeoutMs, AReferer)
  else
    Result := IndyGetBytes(AUrl, AUserAgent, AReadTimeoutMs, AReferer);
end;

// A .gz download (e.g. a third-party XMLTV guide "guide.xml.gz") arrives as raw
// gzip bytes (we ask for identity encoding, so it is the FILE that is gzipped).
// Detect the gzip magic and inflate; anything else passes through unchanged.
function GunzipIfNeeded(const ABytes: TBytes): TBytes;
var
  Src: TBytesStream;
  Z: TZDecompressionStream;
  Dst: TBytesStream;
  Buf: TBytes;
  N: Integer;
begin
  if (Length(ABytes) < 2) or (ABytes[0] <> $1F) or (ABytes[1] <> $8B) then
    Exit(ABytes);
  Src := TBytesStream.Create(ABytes);
  try
    Z := TZDecompressionStream.Create(Src, 15 + 16); // 15 + 16 = gzip header
    try
      Dst := TBytesStream.Create;
      try
        // read in chunks: a decompression stream has no known Size to CopyFrom
        SetLength(Buf, 256 * 1024);
        repeat
          N := Z.Read(Buf[0], Length(Buf));
          if N > 0 then
            Dst.WriteBuffer(Buf[0], N);
        until N <= 0;
        Result := Copy(Dst.Bytes, 0, Dst.Size);
      finally
        Dst.Free;
      end;
    finally
      Z.Free;
    end;
  finally
    Src.Free;
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
