unit IPTV.Api.RelayRules;

(* Pure, testable rules of the stream relay (IPTV.Api.ProxyServer), no Indy / MARS:
  - the box's stream id part ({id} or {id}.{ext}): the id strictly as digits, the
    extension only ts / m3u8;
  - the send timeout towards the box (short for live, long for pausable VOD/archive);
  - the 302 target of a portal route asked on the relay port (publicBaseUrl first, a
    Host header only when it can't point the box at a foreign host);
  - refusing a request body on the relay port (413 / 411);
  - the upstream target guard: never a loopback address, only http(s) redirects,
    no hop from a public upstream to an internal address. *)

interface

uses
  // RTL
  System.SysUtils,
  // own units
  IPTV.Model.Types;

const
  /// <summary>Send timeout towards the box for a live relay: a stalled box ends the
  /// relay quickly, so the provider connection is released.</summary>
  cRelaySendTimeoutLiveMs = 30000;
  /// <summary>Send timeout for movie / series / episode / catch-up: a paused player
  /// stops reading for minutes, the relay must survive that.</summary>
  cRelaySendTimeoutVodMs = 10 * 60 * 1000;
  /// <summary>Read timeout on a relay connection while its request is read.</summary>
  cRelayRequestReadTimeoutMs = 30000;
  /// <summary>HTTP 411 Length Required (a chunked request body on the relay).</summary>
  cHttpLengthRequired = 411;
  /// <summary>HTTP 413 Payload Too Large (any request body on the relay).</summary>
  cHttpRelayPayloadTooLarge = 413;

/// <summary>Splits the box's id part ('123', '123.ts', '123.m3u8'). AStreamId: the
/// part before the first '.', digits only (else False). AExt: 'ts' / 'm3u8' via
/// LiveRequestExt, '' for none or anything else.</summary>
function ParseRelayIdPart(const AIdPart: string; out AStreamId: Integer; out AExt: string): Boolean;

/// <summary>Send timeout towards the box: cRelaySendTimeoutLiveMs for a live channel,
/// cRelaySendTimeoutVodMs for VOD / series / an archive (timeshift).</summary>
function RelaySendTimeoutMs(AContentType: TContentType; AIsTimeshift: Boolean): Integer;

/// <summary>Is publicBaseUrl usable as the address boxes reach us on? Not when empty,
/// unparseable, the image template's placeholder or a loopback host.</summary>
function IsUsablePublicBaseUrl(const APublicBaseUrl: string): Boolean;

/// <summary>The 302 target of a portal route (player_api.php...) asked on the relay
/// port. With a usable publicBaseUrl: its scheme, host, port (and path prefix) +
/// APathAndQuery. Otherwise scheme from AUseHttps, port AHttpPort and the host of the
/// box's Host header when IsAllowedAdminHost accepts it and it is a plain host name /
/// IP literal, else AListenHost (the address the connection arrived on).</summary>
function RelayApiBounceUrl(const APublicBaseUrl: string; const AAllowedHosts: TArray<string>;
  const AHostHeader, AListenHost: string; AUseHttps: Boolean; AHttpPort: Integer;
  const APathAndQuery: string): string;

/// <summary>The status a relay request with these body headers is refused with:
/// cHttpLengthRequired for any Transfer-Encoding, cHttpRelayPayloadTooLarge for a
/// Content-Length other than 0 / empty; 0 = no body, accept.</summary>
function RelayBodyRefusal(const AContentLength, ATransferEncoding: string): Integer;

/// <summary>True for a loopback / unspecified IP literal (127/8, 0/8, ::1, ::, and
/// their ::ffff:-mapped forms) or the name localhost / *.localhost.</summary>
function IsLoopbackHost(const AHost: string): Boolean;

/// <summary>Does AHost point at loopback? A literal / localhost directly, another name
/// via AResolve (name -> IP; nil or a failed lookup = not loopback).</summary>
function HostResolvesToLoopback(const AHost: string; const AResolve: TFunc<string, string>): Boolean;

/// <summary>The host of a redirect target / upstream URL ('' for a relative path;
/// '//host/x' counts as host). AScheme gets the lower-case scheme ('' when none).</summary>
function RelayUrlHost(const AUrl: string; out AScheme: string): string;

/// <summary>May the relay fetch the FIRST upstream URL AUrl? Only http(s), never a
/// loopback host.</summary>
function IsRelayUpstreamAllowed(const AUrl: string; const AResolve: TFunc<string, string>): Boolean;

/// <summary>May the relay follow a provider redirect from AOriginalHost to ADest?
/// Relative: yes. Absolute: only http(s), never loopback, and no hop to an internal
/// address unless the original upstream is internal itself (IsRedirectAllowed).</summary>
function IsRelayRedirectAllowed(const AOriginalHost, ADest: string;
  const AResolve: TFunc<string, string>): Boolean;

/// <summary>May the relay stay connected to APeerIp, the address it actually connected
/// to (checked on every hop, so a DNS answer that changes between check and connect
/// can't slip through)? Never loopback; a private/LAN address only when AAllowInternal
/// (the provider is configured with a server on the LAN).</summary>
function IsRelayPeerAllowed(const APeerIp: string; AAllowInternal: Boolean): Boolean;

/// <summary>True when AUpstreamHost is the host of one of the configured source servers
/// (AConfiguredHosts) AND that host is internal - only then may the relay reach LAN
/// addresses for it. A host taken from playlist content alone never qualifies.</summary>
function IsConfiguredInternalHost(const AUpstreamHost: string; const AConfiguredHosts: TArray<string>;
  const AResolve: TFunc<string, string>): Boolean;

implementation

uses
  // own units
  IPTV.Core.Utils,
  IPTV.Output.Builder,
  IPTV.Api.Security;

const
  cIdExtSeparator = '.';
  cSchemeHttp = 'http';
  cSchemeHttps = 'https';
  cSchemeSep = '://';
  cProtocolRelative = '//';
  cPublicUrlPlaceholder = 'your-unraid-host'; // the Docker image template's value
  cFallbackListenHost = 'localhost';
  cAnyAddressV4 = '0.0.0.0';
  cAnyAddressV6 = '::';
  cLocalhost = 'localhost';
  cLocalhostSuffix = '.localhost';
  cHostChars = ['a'..'z', '0'..'9', '.', '-', '_'];
  cDigits = ['0'..'9'];
  cHexChars = ['0'..'9', 'a'..'f'];
  cMaxIdDigits = 9;                    // fits an Integer
  // IP layout
  cIpv4Parts = 4;
  cIpv4MaxOctet = 255;
  cIpv4MaxDigits = 3;
  cIpv6Words = 8;
  cIpv6MaxHexDigits = 4;
  cIpv6MappedIndex = 5;
  cIpv6MappedWord = $FFFF;
  cIpv6TailWords = 2;                  // an IPv4 tail fills two words
  cIpv6LoopbackLast = 1;
  cBitsPerByte = 8;
  cOctetLoopback = 127;
  cOctetThisNet = 0;
  cHexPrefix = '$';
  cZoneSeparator = '%';
  cCompressed = '::';

function ParseRelayIdPart(const AIdPart: string; out AStreamId: Integer; out AExt: string): Boolean;
var
  lDot: Integer;
  lId: string;
  lChar: Char;
begin
  AStreamId := 0;
  AExt := '';
  lDot := AIdPart.IndexOf(cIdExtSeparator);
  if lDot >= 0 then
  begin
    lId := AIdPart.Substring(0, lDot);
    AExt := LiveRequestExt(AIdPart.Substring(lDot + 1));
  end
  else
    lId := AIdPart;
  if (lId = '') or (lId.Length > cMaxIdDigits) then
    Exit(False);
  for lChar in lId do
    if not CharInSet(lChar, cDigits) then
      Exit(False);
  AStreamId := StrToInt(lId);
  Result := AStreamId > 0;
end;

function RelaySendTimeoutMs(AContentType: TContentType; AIsTimeshift: Boolean): Integer;
begin
  if (AContentType = ctLive) and not AIsTimeshift then
    Result := cRelaySendTimeoutLiveMs
  else
    Result := cRelaySendTimeoutVodMs;
end;

function IsUsablePublicBaseUrl(const APublicBaseUrl: string): Boolean;
var
  lScheme, lHost: string;
begin
  if (APublicBaseUrl.Trim = '') or APublicBaseUrl.Contains(cPublicUrlPlaceholder) then
    Exit(False);
  lHost := RelayUrlHost(APublicBaseUrl.Trim, lScheme);
  Result := ((lScheme = cSchemeHttp) or (lScheme = cSchemeHttps)) and (lHost <> '') and
    not IsLoopbackHost(lHost);
end;

// a Host header value only names a host: no userinfo, path, query or other junk
function IsPlainHostName(const AHost: string): Boolean;
var
  lChar: Char;
begin
  if AHost = '' then
    Exit(False);
  if IsIpLiteral(AHost) then
    Exit(True);
  for lChar in AHost do
    if not CharInSet(lChar, cHostChars) then
      Exit(False);
  Result := True;
end;

function BracketIpv6(const AHost: string): string;
begin
  if AHost.Contains(':') and not AHost.StartsWith('[') then
    Result := '[' + AHost + ']'
  else
    Result := AHost;
end;

function RelayApiBounceUrl(const APublicBaseUrl: string; const AAllowedHosts: TArray<string>;
  const AHostHeader, AListenHost: string; AUseHttps: Boolean; AHttpPort: Integer;
  const APathAndQuery: string): string;
var
  lScheme, lHost, lBase: string;
  lAuthorityEnd: Integer;
begin
  if IsUsablePublicBaseUrl(APublicBaseUrl) then
  begin
    // scheme://host[:port][/prefix] as configured - the address the box can reach,
    // also behind Docker port mapping or a reverse proxy
    lBase := APublicBaseUrl.Trim;
    lAuthorityEnd := lBase.IndexOfAny(['?', '#'], lBase.IndexOf(cSchemeSep) + Length(cSchemeSep));
    if lAuthorityEnd >= 0 then
      lBase := lBase.Substring(0, lAuthorityEnd);
    Exit(lBase.TrimRight(['/']) + APathAndQuery);
  end;
  lHost := HostHeaderName(AHostHeader);
  if not (IsPlainHostName(lHost) and IsAllowedAdminHost(lHost, APublicBaseUrl, AAllowedHosts)) then
    lHost := HostHeaderName(AListenHost);
  if (lHost = '') or (lHost = cAnyAddressV4) or (lHost = cAnyAddressV6) or not IsPlainHostName(lHost) then
    lHost := cFallbackListenHost;
  if AUseHttps then
    lScheme := cSchemeHttps
  else
    lScheme := cSchemeHttp;
  Result := Format('%s://%s:%d%s', [lScheme, BracketIpv6(lHost), AHttpPort, APathAndQuery]);
end;

function RelayBodyRefusal(const AContentLength, ATransferEncoding: string): Integer;
var
  lLength: Int64;
begin
  if ATransferEncoding.Trim <> '' then
    Exit(cHttpLengthRequired);
  if AContentLength.Trim = '' then
    Exit(0);
  if TryStrToInt64(AContentLength.Trim, lLength) and (lLength = 0) then
    Result := 0
  else
    Result := cHttpRelayPayloadTooLarge; // a body, or a value we can't trust
end;

function StripHostBrackets(const AHost: string): string;
var
  lZone: Integer;
begin
  Result := AHost.Trim.ToLower;
  if Result.StartsWith('[') and Result.EndsWith(']') then
    Result := Result.Substring(1, Length(Result) - 2);
  lZone := Result.IndexOf(cZoneSeparator);
  if lZone >= 0 then
    Result := Result.Substring(0, lZone);
  while Result.EndsWith('.') do
    Result := Result.Substring(0, Length(Result) - 1);
end;

// strict dotted IPv4: 4 decimal octets, no leading zeros
function TryStrictIpv4(const AText: string; out AFirst, ASecond, AThird, AFourth: Integer): Boolean;
var
  lParts: TArray<string>;
  lValues: array[0..cIpv4Parts - 1] of Integer;
  lChar: Char;
  i: Integer;
begin
  Result := False;
  AFirst := 0;
  ASecond := 0;
  AThird := 0;
  AFourth := 0;
  lParts := AText.Split([cIdExtSeparator]);
  if Length(lParts) <> cIpv4Parts then
    Exit;
  for i := 0 to cIpv4Parts - 1 do
  begin
    if (lParts[i] = '') or (lParts[i].Length > cIpv4MaxDigits) or ((lParts[i].Length > 1) and (lParts[i][1] = '0')) then
      Exit;
    for lChar in lParts[i] do
      if not CharInSet(lChar, cDigits) then
        Exit;
    lValues[i] := StrToInt(lParts[i]);
    if lValues[i] > cIpv4MaxOctet then
      Exit;
  end;
  AFirst := lValues[0];
  ASecond := lValues[1];
  AThird := lValues[2];
  AFourth := lValues[3];
  Result := True;
end;

function IsLoopbackIpv4Octet(AFirst: Integer): Boolean;
begin
  Result := (AFirst = cOctetLoopback) or (AFirst = cOctetThisNet);
end;

// the 16-bit words of one side of a '::' (an IPv4 tail allowed when AAllowTail)
function TryIpv6Words(const ARun: string; AAllowTail: Boolean; out AWords: TArray<Word>): Boolean;
var
  lParts: TArray<string>;
  lValue, lA, lB, lC, lD, i: Integer;
  lChar: Char;
begin
  Result := False;
  AWords := [];
  if ARun = '' then
    Exit(True);
  lParts := ARun.Split([':']);
  for i := 0 to High(lParts) do
  begin
    if AAllowTail and (i = High(lParts)) and lParts[i].Contains(cIdExtSeparator) then
    begin
      if not TryStrictIpv4(lParts[i], lA, lB, lC, lD) then
        Exit;
      AWords := AWords + [Word((lA shl cBitsPerByte) or lB), Word((lC shl cBitsPerByte) or lD)];
      Continue;
    end;
    if (lParts[i] = '') or (lParts[i].Length > cIpv6MaxHexDigits) then
      Exit;
    for lChar in lParts[i] do
      if not CharInSet(lChar, cHexChars) then
        Exit;
    lValue := StrToInt(cHexPrefix + lParts[i]);
    AWords := AWords + [Word(lValue)];
  end;
  Result := True;
end;

function TryIpv6(const AText: string; out AWords: TArray<Word>): Boolean;
var
  lPos, i: Integer;
  lHead, lTail: TArray<Word>;
begin
  Result := False;
  SetLength(AWords, cIpv6Words);
  for i := 0 to cIpv6Words - 1 do
    AWords[i] := 0;
  lPos := AText.IndexOf(cCompressed);
  if lPos >= 0 then
  begin
    if AText.IndexOf(cCompressed, lPos + 1) >= 0 then
      Exit;
    if not TryIpv6Words(AText.Substring(0, lPos), False, lHead) or
       not TryIpv6Words(AText.Substring(lPos + Length(cCompressed)), True, lTail) then
      Exit;
    if Length(lHead) + Length(lTail) > cIpv6Words - 1 then
      Exit;
  end
  else
  begin
    if not TryIpv6Words(AText, True, lHead) or (Length(lHead) <> cIpv6Words) then
      Exit;
    lTail := [];
  end;
  for i := 0 to High(lHead) do
    AWords[i] := lHead[i];
  for i := 0 to High(lTail) do
    AWords[cIpv6Words - Length(lTail) + i] := lTail[i];
  Result := True;
end;

function IsLoopbackHost(const AHost: string): Boolean;
var
  lHost: string;
  lA, lB, lC, lD, i: Integer;
  lWords: TArray<Word>;
  lZeroHead: Boolean;
begin
  lHost := StripHostBrackets(AHost);
  if lHost = '' then
    Exit(False);
  if (lHost = cLocalhost) or lHost.EndsWith(cLocalhostSuffix) then
    Exit(True);
  if TryStrictIpv4(lHost, lA, lB, lC, lD) then
    Exit(IsLoopbackIpv4Octet(lA));
  if not lHost.Contains(':') or not TryIpv6(lHost, lWords) then
    Exit(False);
  lZeroHead := True;
  for i := 0 to cIpv6MappedIndex - 1 do
    if lWords[i] <> 0 then
      lZeroHead := False;
  if not lZeroHead then
    Exit(False);
  // ::ffff:127.x.x.x / ::ffff:0.x.x.x
  if lWords[cIpv6MappedIndex] = cIpv6MappedWord then
    Exit(IsLoopbackIpv4Octet(lWords[cIpv6Words - cIpv6TailWords] shr cBitsPerByte));
  // :: and ::1
  Result := (lWords[cIpv6MappedIndex] = 0) and (lWords[cIpv6Words - cIpv6TailWords] = 0) and
    (lWords[cIpv6Words - 1] <= cIpv6LoopbackLast);
end;

function HostResolvesToLoopback(const AHost: string; const AResolve: TFunc<string, string>): Boolean;
var
  lHost, lIp: string;
  lA, lB, lC, lD: Integer;
  lWords: TArray<Word>;
begin
  lHost := StripHostBrackets(AHost);
  if lHost = '' then
    Exit(False);
  if IsLoopbackHost(lHost) then
    Exit(True);
  // a strict literal is classified already; anything looser goes to the resolver
  if TryStrictIpv4(lHost, lA, lB, lC, lD) or (lHost.Contains(':') and TryIpv6(lHost, lWords)) or
     not Assigned(AResolve) then
    Exit(False);
  // a name (also '0177.0.0.1' or '2130706433', which the OS resolver reads as 127.0.0.1)
  try
    lIp := AResolve(lHost);
    Result := (lIp <> '') and IsLoopbackHost(lIp);
  except
    Result := False; // no address: the request itself will fail
  end;
end;

function RelayUrlHost(const AUrl: string; out AScheme: string): string;
var
  lUrl, lAuthority: string;
  lSep, lEnd, lAt, lPort: Integer;
begin
  Result := '';
  AScheme := '';
  lUrl := AUrl.Trim;
  if lUrl.StartsWith(cProtocolRelative) then
    lAuthority := lUrl.Substring(Length(cProtocolRelative))
  else
  begin
    lSep := lUrl.IndexOf(cSchemeSep);
    // a scheme only when '://' comes before any path / query character
    if (lSep <= 0) or (lUrl.IndexOfAny(['/', '?', '#']) < lSep) then
      Exit;
    AScheme := lUrl.Substring(0, lSep).ToLower;
    lAuthority := lUrl.Substring(lSep + Length(cSchemeSep));
  end;
  // a backslash ends the authority too (browsers / some clients treat it as '/')
  lEnd := lAuthority.IndexOfAny(['/', '?', '#', '\']);
  if lEnd >= 0 then
    lAuthority := lAuthority.Substring(0, lEnd);
  lAt := lAuthority.LastIndexOf('@');
  if lAt >= 0 then
    lAuthority := lAuthority.Substring(lAt + 1); // userinfo is not the host
  if lAuthority.StartsWith('[') then
  begin
    lPort := lAuthority.IndexOf(']');
    if lPort > 0 then
      lAuthority := lAuthority.Substring(1, lPort - 1);
  end
  else if lAuthority.CountChar(':') = 1 then
    lAuthority := lAuthority.Substring(0, lAuthority.IndexOf(':'));
  Result := StripHostBrackets(lAuthority);
end;

function IsHttpScheme(const AScheme: string): Boolean;
begin
  Result := (AScheme = cSchemeHttp) or (AScheme = cSchemeHttps);
end;

function IsRelayUpstreamAllowed(const AUrl: string; const AResolve: TFunc<string, string>): Boolean;
var
  lScheme, lHost: string;
begin
  lHost := RelayUrlHost(AUrl, lScheme);
  Result := IsHttpScheme(lScheme) and (lHost <> '') and not HostResolvesToLoopback(lHost, AResolve);
end;

function IsRelayRedirectAllowed(const AOriginalHost, ADest: string;
  const AResolve: TFunc<string, string>): Boolean;
var
  lScheme, lHost: string;
begin
  lHost := RelayUrlHost(ADest, lScheme);
  if (lHost = '') and (lScheme = '') then
  begin
    // relative path: stays on the current hop's (already checked) host - unless it
    // smuggles a scheme in after all ('file:...', 'javascript:...')
    Result := not ADest.Trim.Contains(':') or ADest.Trim.StartsWith('/');
    Exit;
  end;
  if lScheme <> '' then
    if not IsHttpScheme(lScheme) then
      Exit(False);
  if (lHost = '') or HostResolvesToLoopback(lHost, AResolve) then
    Exit(False);
  Result := IsRedirectAllowed(AOriginalHost, lHost, AResolve);
end;

function IsRelayPeerAllowed(const APeerIp: string; AAllowInternal: Boolean): Boolean;
var
  lPeer: string;
begin
  lPeer := StripHostBrackets(APeerIp.Trim);
  if lPeer = '' then
    Exit(False);
  if IsLoopbackHost(lPeer) then
    Exit(False);
  Result := AAllowInternal or not IsPrivateAddress(lPeer);
end;

function IsConfiguredInternalHost(const AUpstreamHost: string; const AConfiguredHosts: TArray<string>;
  const AResolve: TFunc<string, string>): Boolean;
var
  lHost: string;
begin
  Result := False;
  if AUpstreamHost.Trim = '' then
    Exit;
  for lHost in AConfiguredHosts do
    if SameText(lHost.Trim, AUpstreamHost.Trim) then
      Exit(HostIsInternal(lHost, AResolve));
end;

end.
