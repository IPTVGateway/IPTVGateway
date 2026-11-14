unit IPTV.Api.Security;

{ Pure, testable security helpers of the HTTP surfaces (no MARS, no Indy):
  - address classification (private / loopback / link-local / CGNAT, IPv4 + IPv6 incl.
    the ::ffff:-mapped form) for the LAN-only default rules and the relay's redirect
    guard;
  - the Host-header rule against DNS rebinding (admin API without an admin password,
    login-free box and Plex/HDHomeRun surfaces);
  - the request-body cap checked before a body is read, and the JSON nesting-depth
    scan run before MARS parses a body;
  - short-lived download tokens (?dt=), each bound to the one path it was issued for,
    so download links never carry the admin password;
  - a cross-platform CSPRNG (BCryptGenRandom / /dev/urandom) for tokens;
  - the startup warm-up token (its requests never count as failed logins). }

interface

uses
  // RTL
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections;

const
  /// <summary>Largest request body accepted on most routes; a bigger Content-Length is
  /// answered 413 before the body is read.</summary>
  cMaxRequestBodyBytes = Int64(1) * 1024 * 1024;
  /// <summary>Largest body of the settings import (POST /api/import), the one route
  /// whose legit body (a full settings bundle) can be big.</summary>
  cMaxImportBodyBytes = Int64(64) * 1024 * 1024;
  /// <summary>Request path of the settings import (the route allowed cMaxImportBodyBytes).</summary>
  cImportPath = '/api/import';
  /// <summary>Deepest JSON nesting ([ and {) accepted in an admin request body.</summary>
  cMaxJsonDepth = 64;
  /// <summary>Lifetime of a download token, milliseconds (usable several times within
  /// it: download managers fetch a link twice).</summary>
  cDownloadTokenLifetimeMs = 60000;
  /// <summary>Random bytes of a download / warm-up token (hex: twice as many chars).</summary>
  cTokenRandomBytes = 32;

/// <summary>True for an IPv4 or IPv6 literal (brackets and a zone id allowed).</summary>
function IsIpLiteral(const AHost: string): Boolean;

/// <summary>True for loopback (127/8, ::1), private (10/8, 172.16/12, 192.168/16,
/// fc00::/7), shared/CGNAT (100.64/10 - Tailscale), link-local (169.254/16, fe80::/10)
/// and unspecified (0/8, ::) addresses, also as ::ffff:-mapped IPv4. False for public
/// addresses and non-IP text (an IPv4 octet with a leading zero is not an address).</summary>
function IsPrivateAddress(const AIp: string): Boolean;

/// <summary>May this client use the login-free Plex/HDHomeRun endpoints? With an
/// allow-list: only its entries (exact IPs or prefixes ending in '.'); without one:
/// only private/local addresses.</summary>
function IsMediaClientPermitted(const AClientIp: string; const AAllowed: TArray<string>): Boolean;

/// <summary>The lockout key part of a client address: an IPv6 client by its /64 prefix
/// ('2001:db8:1:2::/64' - one host owns the whole /64), a ::ffff:-mapped one as IPv4,
/// anything else trimmed as given.</summary>
function ClientAddressKey(const AIp: string): string;

/// <summary>The host name of a Host header value: lower case, port, brackets and a
/// trailing dot removed ('[::1]:7777' -> '::1', 'NAS.lan:9000' -> 'nas.lan').</summary>
function HostHeaderName(const AHostHeader: string): string;

/// <summary>The DNS-rebinding rule of the admin API without an admin password (and of
/// the login-free box / Plex surfaces): the Host must be an IP literal, localhost, a
/// single-label name, a name under .local / .lan / .home.arpa / .internal / .box /
/// .home / .localdomain / .ts.net / .myunraid.net, the host of APublicBaseUrl or one of
/// AAllowedHosts. An empty Host (no browser omits it) passes.</summary>
function IsAllowedAdminHost(const AHostHeader, APublicBaseUrl: string;
  const AAllowedHosts: TArray<string>): Boolean;

/// <summary>AAllowedHosts plus the host name of AHostHeader when that Host would
/// otherwise not pass IsAllowedAdminHost (keeps the admin from locking himself out with
/// an import). Unchanged for an empty Host or one allowed anyway.</summary>
function HostsKeepingCurrent(const AHostHeader, APublicBaseUrl: string;
  const AAllowedHosts: TArray<string>): TArray<string>;

/// <summary>Does AHost (a name or IP literal) point at a loopback / private /
/// link-local address? Names other than localhost are resolved with AResolve (name ->
/// IP; nil = names count as public); a failed lookup counts as public.</summary>
function HostIsInternal(const AHost: string; const AResolve: TFunc<string, string>): Boolean;

/// <summary>May the relay follow a provider redirect from AOriginalHost to ATargetHost?
/// Not to an internal address - unless the original upstream is internal itself (a
/// provider on the LAN). An empty target host (relative redirect) stays on the
/// original host and is allowed.</summary>
function IsRedirectAllowed(const AOriginalHost, ATargetHost: string;
  const AResolve: TFunc<string, string>): Boolean;

/// <summary>True when a Content-Length header value is a number above AMax.</summary>
function ContentLengthExceeds(const AValue: string; AMax: Int64): Boolean;

/// <summary>The body cap of a request target (raw URI, path or absolute form; a query is
/// ignored): cMaxImportBodyBytes for the settings import, else cMaxRequestBodyBytes.</summary>
function MaxBodyBytesFor(const AUri: string): Int64;

/// <summary>True when the JSON text in ABody nests [ / { deeper than AMaxDepth
/// (brackets inside strings, also after escapes, don't count). Not a validator: any
/// byte sequence is scanned.</summary>
function JsonNestingExceeds(const ABody: TBytes; AMaxDepth: Integer): Boolean;

/// <summary>A box login name that proves a login: not empty and not the '-' placeholder
/// of the login-free default list.</summary>
function IsRealLoginName(const AUser: string): Boolean;

/// <summary>ACount bytes from the OS CSPRNG (BCryptGenRandom on Windows, /dev/urandom
/// on POSIX). Raises when the OS source is unavailable.</summary>
function SecureRandomBytes(ACount: Integer): TBytes;

/// <summary>A lower-case hex token of AByteCount CSPRNG bytes (URL-safe).</summary>
function SecureRandomHex(AByteCount: Integer = cTokenRandomBytes): string;

/// <summary>May a download token be issued for APath? Only the bouquet export
/// downloads: /api/lists/{id}/export.m3u and /api/lists/{id}/export.xmltv.</summary>
function IsDownloadTokenPath(const APath: string): Boolean;

/// <summary>APath without a query string or fragment.</summary>
function PathWithoutQuery(const APath: string): string;

/// <summary>The URLs ANewUrls as the web app sent them back, each masked secret ('***',
/// from MaskUrlQuerySecrets) replaced by the stored value (RestoreMaskedUrlSecrets).
/// The stored URL of entry i is AStoredUrls[i] when it has the same URL without query,
/// else the first stored URL that has; none = the masked parameter is dropped (a
/// secret is never moved onto another host).</summary>
function RestoreMaskedUrlList(const ANewUrls, AStoredUrls: TArray<string>): TArray<string>;

/// <summary>Starts a new warm-up run: a fresh random token in GWarmToken.</summary>
procedure NewWarmupToken;

/// <summary>Is AHeaderValue (of the warm-up header) the current warm-up token? False
/// while no warm-up token exists and for any other value.</summary>
function IsWarmupRequest(const AHeaderValue: string): Boolean;

type
  /// <summary>Short-lived tokens that authenticate an admin GET of ONE path (a download
  /// link) instead of the admin password. Usable several times until they expire. In
  /// memory only; thread-safe.</summary>
  TDownloadTokens = class
  private
    type
      TTokenEntry = record
        Path: string;
        ExpiryMs: UInt64; // monotonic ms
      end;
  private
    FLock: TCriticalSection;
    FTokens: TDictionary<string, TTokenEntry>;
    FLifetimeMs: UInt64;
    procedure PruneLocked(ANowMs: UInt64);
  public
    /// <summary>Tokens live ALifetimeMs milliseconds.</summary>
    constructor Create(ALifetimeMs: Integer = cDownloadTokenLifetimeMs);
    /// <summary>Frees the table.</summary>
    destructor Destroy; override;
    /// <summary>A fresh random token, valid for APath only (its query is ignored).</summary>
    function Issue(const APath: string): string;
    /// <summary>True for a known, unexpired token issued for APath (query ignored).
    /// The token stays valid until it expires.</summary>
    function IsValid(const AToken, APath: string): Boolean;
  end;

var
  /// <summary>The process-wide download tokens (created in initialization).</summary>
  GDownloadTokens: TDownloadTokens;
  /// <summary>Token of the server's own startup warm-up requests ('' = none yet).</summary>
  GWarmToken: string;

implementation

uses
  // RTL
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
  System.Classes,
  System.RegularExpressions,
  // own units
  IPTV.Core.Utils;

{$IFDEF MSWINDOWS}
const
  cBCryptDll = 'bcrypt.dll';
  cBCryptUseSystemPreferredRng = $00000002; // BCRYPT_USE_SYSTEM_PREFERRED_RNG
  cStatusSuccess = 0;

function BCryptGenRandom(AAlgorithm: Pointer; ABuffer: PByte; ABufferSize: ULONG;
  AFlags: ULONG): LongInt; stdcall; external cBCryptDll name 'BCryptGenRandom';
{$ENDIF}

const
  cIpv4Parts = 4;
  cIpv4MaxOctet = 255;
  cIpv4MaxDigits = 3;
  cIpv6Words = 8;
  cIpv6PrefixWords = 4;  // a /64 = the first four 16-bit words
  cIpv6MaxHexDigits = 4;
  cIpv6MappedWord = $FFFF;
  cIpv6MappedIndex = 5;  // ::ffff:a.b.c.d = words 0..4 zero, word 5 = $FFFF
  cIpv6UlaMask = $FE00;  // fc00::/7
  cIpv6UlaPrefix = $FC00;
  cIpv6LinkLocalMask = $FFC0; // fe80::/10
  cIpv6LinkLocalPrefix = $FE80;
  cIpv6LoopbackLast = 1;
  cIpv6PrefixSuffix = '::/64';
  cHexPrefix = '$';
  cBitsPerByte = 8;
  cByteMask = $FF;

  // IPv4 ranges (first octet / second octet)
  cOctetThisNet = 0;
  cOctetPrivateA = 10;
  cOctetLoopback = 127;
  cOctetLinkLocalA = 169;
  cOctetLinkLocalB = 254;
  cOctetPrivateB = 172;
  cOctetPrivateBMin = 16;
  cOctetPrivateBMax = 31;
  cOctetPrivateC = 192;
  cOctetPrivateCB = 168;
  cOctetSharedA = 100;      // 100.64.0.0/10 (RFC 6598 shared / CGNAT, Tailscale)
  cOctetSharedMask = $C0;
  cOctetSharedPrefix = 64;

  // host names
  cLocalhost = 'localhost';
  cLocalhostSuffix = '.localhost';
  // LAN / home-router / VPN names: .box = fritz.box, .ts.net = Tailscale MagicDNS,
  // .myunraid.net = Unraid Connect
  cLocalSuffixes: array[0..8] of string = ('.local', '.lan', '.home.arpa', '.internal', '.box',
    '.home', '.localdomain', '.ts.net', '.myunraid.net');
  cZoneSeparator = '%';
  cWordSeparator = ':';
  cCompressed = '::';

  // download tokens
  cMaxTokens = 1000;
  cDownloadPathPattern = '^/api/lists/[0-9]+/export\.(m3u|xmltv)$';
  cHexDigits = '0123456789abcdef';
  cNibbleBits = 4;
  cNibbleMask = $0F;
{$IFDEF POSIX}
  cUrandomPath = '/dev/urandom';
{$ENDIF}

  // URIs
  cSchemeSeparator = '://';
  cQueryMark = '?';
  cFragmentMark = '#';
  cPathRoot = '/';
  cLoginPlaceholder = '-';

  // JSON scan
  cJsonQuote = Ord('"');
  cJsonEscape = Ord('\');
  cJsonOpenArray = Ord('[');
  cJsonOpenObject = Ord('{');
  cJsonCloseArray = Ord(']');
  cJsonCloseObject = Ord('}');

function TryParseIPv4(const AText: string; out AOctets: TBytes): Boolean;
var
  lParts: TArray<string>;
  lValue: Integer;
  i, j: Integer;
begin
  Result := False;
  SetLength(AOctets, cIpv4Parts);
  lParts := AText.Split(['.']);
  if Length(lParts) <> cIpv4Parts then
    Exit;
  for i := 0 to cIpv4Parts - 1 do
  begin
    if (lParts[i] = '') or (Length(lParts[i]) > cIpv4MaxDigits) then
      Exit;
    // '010' / '0177': inet_aton (WinSock, glibc) reads a leading zero as octal - so it
    // is no address here, else a guard and the socket would disagree on its meaning
    if (Length(lParts[i]) > 1) and (lParts[i][1] = '0') then
      Exit;
    for j := 1 to Length(lParts[i]) do
      if not CharInSet(lParts[i][j], ['0'..'9']) then
        Exit;
    lValue := StrToInt(lParts[i]);
    if lValue > cIpv4MaxOctet then
      Exit;
    AOctets[i] := Byte(lValue);
  end;
  Result := True;
end;

// the 16-bit words of one ':'-separated run ('' = none); a trailing a.b.c.d is two words
function TryParseIPv6Run(const ARun: string; AAllowIpv4Tail: Boolean; out AWords: TArray<Word>): Boolean;
var
  lGroups: TArray<string>;
  lOctets: TBytes;
  lValue: Integer;
  i, j: Integer;
begin
  Result := False;
  AWords := nil;
  if ARun = '' then
    Exit(True);
  lGroups := ARun.Split([cWordSeparator]);
  for i := 0 to High(lGroups) do
  begin
    if AAllowIpv4Tail and (i = High(lGroups)) and lGroups[i].Contains('.') then
    begin
      if not TryParseIPv4(lGroups[i], lOctets) then
        Exit;
      AWords := AWords + [Word((lOctets[0] shl cBitsPerByte) or lOctets[1]),
        Word((lOctets[2] shl cBitsPerByte) or lOctets[3])];
      Continue;
    end;
    if (lGroups[i] = '') or (Length(lGroups[i]) > cIpv6MaxHexDigits) then
      Exit;
    for j := 1 to Length(lGroups[i]) do
      if not CharInSet(lGroups[i][j], ['0'..'9', 'a'..'f', 'A'..'F']) then
        Exit;
    lValue := StrToInt(cHexPrefix + lGroups[i]);
    AWords := AWords + [Word(lValue)];
  end;
  Result := True;
end;

function TryParseIPv6(const AText: string; out AWords: TArray<Word>): Boolean;
var
  lText: string;
  lPos: Integer;
  lHead, lTail: TArray<Word>;
  i: Integer;
begin
  Result := False;
  AWords := nil;
  lText := AText;
  lPos := lText.IndexOf(cZoneSeparator);
  if lPos >= 0 then
    lText := lText.Substring(0, lPos);
  if not lText.Contains(cWordSeparator) then
    Exit;
  lPos := lText.IndexOf(cCompressed);
  if lPos >= 0 then
  begin
    if lText.IndexOf(cCompressed, lPos + 1) >= 0 then
      Exit; // '::' at most once
    if not TryParseIPv6Run(lText.Substring(0, lPos), False, lHead) or
       not TryParseIPv6Run(lText.Substring(lPos + Length(cCompressed)), True, lTail) then
      Exit;
    if Length(lHead) + Length(lTail) > cIpv6Words - 1 then
      Exit;
    SetLength(AWords, cIpv6Words);
    for i := 0 to cIpv6Words - 1 do
      AWords[i] := 0;
    for i := 0 to High(lHead) do
      AWords[i] := lHead[i];
    for i := 0 to High(lTail) do
      AWords[cIpv6Words - Length(lTail) + i] := lTail[i];
  end
  else
  begin
    if not TryParseIPv6Run(lText, True, AWords) or (Length(AWords) <> cIpv6Words) then
      Exit;
  end;
  Result := True;
end;

// trimmed, without the [ ] of a bracketed IPv6 literal
function StripBrackets(const AHost: string): string;
begin
  Result := AHost.Trim;
  if Result.StartsWith('[') and Result.EndsWith(']') then
    Result := Result.Substring(1, Length(Result) - 2);
end;

function IsIpLiteral(const AHost: string): Boolean;
var
  lOctets: TBytes;
  lWords: TArray<Word>;
  lHost: string;
begin
  lHost := StripBrackets(AHost);
  Result := TryParseIPv4(lHost, lOctets) or TryParseIPv6(lHost, lWords);
end;

function IsPrivateIPv4(const AOctets: TBytes): Boolean;
begin
  Result := (AOctets[0] = cOctetThisNet) or (AOctets[0] = cOctetPrivateA) or
    (AOctets[0] = cOctetLoopback) or
    ((AOctets[0] = cOctetLinkLocalA) and (AOctets[1] = cOctetLinkLocalB)) or
    ((AOctets[0] = cOctetPrivateB) and (AOctets[1] >= cOctetPrivateBMin) and
     (AOctets[1] <= cOctetPrivateBMax)) or
    ((AOctets[0] = cOctetPrivateC) and (AOctets[1] = cOctetPrivateCB)) or
    ((AOctets[0] = cOctetSharedA) and ((AOctets[1] and cOctetSharedMask) = cOctetSharedPrefix));
end;

// is AWords an ::ffff:a.b.c.d address? AOctets = its IPv4 part
function TryMappedIPv4(const AWords: TArray<Word>; out AOctets: TBytes): Boolean;
var
  i: Integer;
begin
  Result := False;
  for i := 0 to cIpv6MappedIndex - 1 do
    if AWords[i] <> 0 then
      Exit;
  if AWords[cIpv6MappedIndex] <> cIpv6MappedWord then
    Exit;
  SetLength(AOctets, cIpv4Parts);
  AOctets[0] := Byte(AWords[6] shr cBitsPerByte);
  AOctets[1] := Byte(AWords[6] and cByteMask);
  AOctets[2] := Byte(AWords[7] shr cBitsPerByte);
  AOctets[3] := Byte(AWords[7] and cByteMask);
  Result := True;
end;

function IsPrivateAddress(const AIp: string): Boolean;
var
  lHost: string;
  lOctets: TBytes;
  lWords: TArray<Word>;
  lZeroHead: Boolean;
  i: Integer;
begin
  lHost := StripBrackets(AIp);
  if TryParseIPv4(lHost, lOctets) then
    Exit(IsPrivateIPv4(lOctets));
  if not TryParseIPv6(lHost, lWords) then
    Exit(False);
  // ::ffff:a.b.c.d - an IPv4 client seen through an IPv6 socket
  if TryMappedIPv4(lWords, lOctets) then
    Exit(IsPrivateIPv4(lOctets));
  lZeroHead := True;
  for i := 0 to cIpv6MappedIndex - 1 do
    if lWords[i] <> 0 then
      lZeroHead := False;
  // :: (unspecified) and ::1 (loopback)
  if lZeroHead and (lWords[cIpv6MappedIndex] = 0) and (lWords[6] = 0) and
     ((lWords[7] = 0) or (lWords[7] = cIpv6LoopbackLast)) then
    Exit(True);
  Result := ((lWords[0] and cIpv6UlaMask) = cIpv6UlaPrefix) or
    ((lWords[0] and cIpv6LinkLocalMask) = cIpv6LinkLocalPrefix);
end;

function IsMediaClientPermitted(const AClientIp: string; const AAllowed: TArray<string>): Boolean;
begin
  if Length(AAllowed) = 0 then
    Result := IsPrivateAddress(AClientIp)
  else
    Result := IsClientInList(AClientIp, AAllowed);
end;

function ClientAddressKey(const AIp: string): string;
var
  lHost: string;
  lOctets: TBytes;
  lWords: TArray<Word>;
  i: Integer;
begin
  Result := AIp.Trim;
  lHost := StripBrackets(Result);
  if TryParseIPv4(lHost, lOctets) or not TryParseIPv6(lHost, lWords) then
    Exit;
  if TryMappedIPv4(lWords, lOctets) then
    Exit(Format('%d.%d.%d.%d', [lOctets[0], lOctets[1], lOctets[2], lOctets[3]]));
  // an IPv6 host typically owns a whole /64: keying per address would give a guesser
  // 2^64 fresh keys
  Result := '';
  for i := 0 to cIpv6PrefixWords - 1 do
  begin
    if i > 0 then
      Result := Result + cWordSeparator;
    Result := Result + IntToHex(lWords[i], 1).ToLower;
  end;
  Result := Result + cIpv6PrefixSuffix;
end;

function HostHeaderName(const AHostHeader: string): string;
var
  lPos: Integer;
begin
  Result := AHostHeader.Trim.ToLower;
  if Result.StartsWith('[') then
  begin
    lPos := Result.IndexOf(']');
    if lPos > 0 then
      Result := Result.Substring(1, lPos - 1);
  end
  else if Result.CountChar(cWordSeparator) = 1 then
    Result := Result.Substring(0, Result.IndexOf(cWordSeparator));
  while Result.EndsWith('.') do
    Result := Result.Substring(0, Length(Result) - 1);
end;

function IsAllowedAdminHost(const AHostHeader, APublicBaseUrl: string;
  const AAllowedHosts: TArray<string>): Boolean;
var
  lHost, lSuffix, lEntry: string;
begin
  lHost := HostHeaderName(AHostHeader);
  if (lHost = '') or IsIpLiteral(lHost) then
    Exit(True);
  if (lHost = cLocalhost) or lHost.EndsWith(cLocalhostSuffix) then
    Exit(True);
  if not lHost.Contains('.') then
    Exit(True); // single-label name: resolved on the LAN, not a rebinding domain
  for lSuffix in cLocalSuffixes do
    if lHost.EndsWith(lSuffix) then
      Exit(True);
  if (APublicBaseUrl.Trim <> '') and (lHost = HostHeaderName(SafeUrlHost(APublicBaseUrl, ''))) then
    Exit(True);
  for lEntry in AAllowedHosts do
    if (lEntry.Trim <> '') and (lHost = HostHeaderName(lEntry)) then
      Exit(True);
  Result := False;
end;

function HostsKeepingCurrent(const AHostHeader, APublicBaseUrl: string;
  const AAllowedHosts: TArray<string>): TArray<string>;
var
  lHost: string;
begin
  Result := Copy(AAllowedHosts);
  lHost := HostHeaderName(AHostHeader);
  if (lHost = '') or IsAllowedAdminHost(AHostHeader, APublicBaseUrl, AAllowedHosts) then
    Exit;
  Result := Result + [lHost];
end;

function HostIsInternal(const AHost: string; const AResolve: TFunc<string, string>): Boolean;
var
  lHost, lIp: string;
begin
  lHost := HostHeaderName(StripBrackets(AHost));
  if lHost = '' then
    Exit(False);
  if (lHost = cLocalhost) or lHost.EndsWith(cLocalhostSuffix) then
    Exit(True);
  if IsIpLiteral(lHost) then
    Exit(IsPrivateAddress(lHost));
  Result := False;
  if not Assigned(AResolve) then
    Exit;
  try
    lIp := AResolve(lHost);
    Result := (lIp <> '') and IsPrivateAddress(lIp);
  except
    Result := False; // no address: the request itself will fail
  end;
end;

function IsRedirectAllowed(const AOriginalHost, ATargetHost: string;
  const AResolve: TFunc<string, string>): Boolean;
begin
  if ATargetHost.Trim = '' then
    Exit(True);
  Result := HostIsInternal(AOriginalHost, AResolve) or not HostIsInternal(ATargetHost, AResolve);
end;

function ContentLengthExceeds(const AValue: string; AMax: Int64): Boolean;
var
  lLength: Int64;
begin
  Result := TryStrToInt64(AValue.Trim, lLength) and (lLength > AMax);
end;

function PathWithoutQuery(const APath: string): string;
var
  lPos: Integer;
begin
  Result := APath;
  lPos := Result.IndexOfAny([cQueryMark, cFragmentMark]);
  if lPos >= 0 then
    Result := Result.Substring(0, lPos);
end;

function RestoreMaskedUrlList(const ANewUrls, AStoredUrls: TArray<string>): TArray<string>;
var
  lBase, lStored: string;
  i, j: Integer;
begin
  SetLength(Result, Length(ANewUrls));
  for i := 0 to High(ANewUrls) do
  begin
    lBase := PathWithoutQuery(ANewUrls[i].Trim);
    lStored := '';
    if (i <= High(AStoredUrls)) and SameText(PathWithoutQuery(AStoredUrls[i].Trim), lBase) then
      lStored := AStoredUrls[i].Trim
    else
      for j := 0 to High(AStoredUrls) do
        if SameText(PathWithoutQuery(AStoredUrls[j].Trim), lBase) then
        begin
          lStored := AStoredUrls[j].Trim;
          Break;
        end;
    Result[i] := RestoreMaskedUrlSecrets(ANewUrls[i].Trim, lStored);
  end;
end;

function MaxBodyBytesFor(const AUri: string): Int64;
var
  lPath: string;
  lPos: Integer;
begin
  lPath := PathWithoutQuery(AUri.Trim);
  // absolute-form request target: http://host:port/api/import
  lPos := lPath.IndexOf(cSchemeSeparator);
  if lPos >= 0 then
  begin
    lPath := lPath.Substring(lPos + Length(cSchemeSeparator));
    lPos := lPath.IndexOf(cPathRoot);
    if lPos >= 0 then
      lPath := lPath.Substring(lPos)
    else
      lPath := cPathRoot;
  end;
  while lPath.EndsWith(cPathRoot) and (Length(lPath) > 1) do
    lPath := lPath.Substring(0, Length(lPath) - 1);
  if SameText(lPath, cImportPath) then
    Result := cMaxImportBodyBytes
  else
    Result := cMaxRequestBodyBytes;
end;

function JsonNestingExceeds(const ABody: TBytes; AMaxDepth: Integer): Boolean;
var
  lDepth: Integer;
  lInString, lEscaped: Boolean;
  lByte: Byte;
  i: Integer;
begin
  lDepth := 0;
  lInString := False;
  lEscaped := False;
  for i := 0 to High(ABody) do
  begin
    lByte := ABody[i];
    if lInString then
    begin
      if lEscaped then
        lEscaped := False
      else if lByte = cJsonEscape then
        lEscaped := True
      else if lByte = cJsonQuote then
        lInString := False;
      Continue;
    end;
    if lByte = cJsonQuote then
      lInString := True
    else if (lByte = cJsonOpenArray) or (lByte = cJsonOpenObject) then
    begin
      Inc(lDepth);
      if lDepth > AMaxDepth then
        Exit(True);
    end
    else if ((lByte = cJsonCloseArray) or (lByte = cJsonCloseObject)) and (lDepth > 0) then
      Dec(lDepth);
  end;
  Result := False;
end;

function IsRealLoginName(const AUser: string): Boolean;
begin
  Result := (AUser.Trim <> '') and (AUser.Trim <> cLoginPlaceholder);
end;

function SecureRandomBytes(ACount: Integer): TBytes;
{$IFDEF POSIX}
var
  lStream: TFileStream;
{$ENDIF}
begin
  SetLength(Result, ACount);
  if ACount <= 0 then
    Exit;
{$IFDEF MSWINDOWS}
  if BCryptGenRandom(nil, @Result[0], ULONG(ACount), cBCryptUseSystemPreferredRng) <> cStatusSuccess then
    raise Exception.Create('BCryptGenRandom failed');
{$ENDIF}
{$IFDEF POSIX}
  lStream := TFileStream.Create(cUrandomPath, fmOpenRead or fmShareDenyNone);
  try
    lStream.ReadBuffer(Result[0], ACount);
  finally
    FreeAndNil(lStream);
  end;
{$ENDIF}
end;

function SecureRandomHex(AByteCount: Integer): string;
var
  lBytes: TBytes;
  lBuilder: TStringBuilder;
  i: Integer;
begin
  lBytes := SecureRandomBytes(AByteCount);
  lBuilder := TStringBuilder.Create(Length(lBytes) * 2);
  try
    for i := 0 to High(lBytes) do
    begin
      lBuilder.Append(cHexDigits.Chars[lBytes[i] shr cNibbleBits]);
      lBuilder.Append(cHexDigits.Chars[lBytes[i] and cNibbleMask]);
    end;
    Result := lBuilder.ToString;
  finally
    FreeAndNil(lBuilder);
  end;
end;

function IsDownloadTokenPath(const APath: string): Boolean;
begin
  Result := TRegEx.IsMatch(APath, cDownloadPathPattern);
end;

procedure NewWarmupToken;
begin
  GWarmToken := SecureRandomHex;
end;

function IsWarmupRequest(const AHeaderValue: string): Boolean;
var
  lToken: string;
begin
  lToken := GWarmToken;
  Result := (lToken <> '') and (AHeaderValue <> '') and IsSamePassword(AHeaderValue, lToken);
end;

{ TDownloadTokens }

constructor TDownloadTokens.Create(ALifetimeMs: Integer);
begin
  inherited Create;
  FLock := TCriticalSection.Create;
  FTokens := TDictionary<string, TTokenEntry>.Create;
  if ALifetimeMs > 0 then
    FLifetimeMs := UInt64(ALifetimeMs)
  else
    FLifetimeMs := 0;
end;

destructor TDownloadTokens.Destroy;
begin
  FreeAndNil(FTokens);
  FreeAndNil(FLock);
  inherited;
end;

procedure TDownloadTokens.PruneLocked(ANowMs: UInt64);
var
  lPair: TPair<string, TTokenEntry>;
  lExpired: TList<string>;
  lKey: string;
begin
  lExpired := TList<string>.Create;
  try
    for lPair in FTokens do
      if lPair.Value.ExpiryMs <= ANowMs then
        lExpired.Add(lPair.Key);
    for lKey in lExpired do
      FTokens.Remove(lKey);
  finally
    FreeAndNil(lExpired);
  end;
end;

function TDownloadTokens.Issue(const APath: string): string;
var
  lNowMs: UInt64;
  lEntry: TTokenEntry;
begin
  // CSPRNG, not GUIDs (on Linux TGUID.NewGuid is time-based, i.e. guessable)
  Result := SecureRandomHex;
  lNowMs := TThread.GetTickCount64;
  lEntry.Path := PathWithoutQuery(APath);
  lEntry.ExpiryMs := lNowMs + FLifetimeMs;
  FLock.Acquire;
  try
    PruneLocked(lNowMs);
    if FTokens.Count >= cMaxTokens then
      FTokens.Clear; // only live tokens are lost - a new click issues another
    FTokens.AddOrSetValue(Result, lEntry);
  finally
    FLock.Release;
  end;
end;

function TDownloadTokens.IsValid(const AToken, APath: string): Boolean;
var
  lEntry: TTokenEntry;
begin
  Result := False;
  if AToken = '' then
    Exit;
  FLock.Acquire;
  try
    if not FTokens.TryGetValue(AToken, lEntry) then
      Exit;
    if lEntry.ExpiryMs <= TThread.GetTickCount64 then
    begin
      FTokens.Remove(AToken);
      Exit;
    end;
    Result := lEntry.Path = PathWithoutQuery(APath);
  finally
    FLock.Release;
  end;
end;

initialization
  GDownloadTokens := TDownloadTokens.Create;

finalization
  FreeAndNil(GDownloadTokens);

end.
