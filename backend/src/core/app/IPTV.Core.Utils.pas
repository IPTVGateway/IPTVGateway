unit IPTV.Core.Utils;

{ Small conversion helpers shared by storage and the API serializers.
  Content-type sets <-> CSV text; TDateTime (UTC) <-> ISO-8601 text. }

interface

uses
  // Own units
  IPTV.Model.Types;

/// Content-type set -> stored CSV form ("live,movie").
function ContentTypesToStr(const ACt: TContentTypes): string;
/// Stored CSV form -> content-type set (unknown names count as live).
function StrToContentTypes(const AValue: string): TContentTypes;

/// Plain join of the items with ADelim; trims, drops blanks.
function StrArrayToCsv(const AValues: TArray<string>; const ADelim: Char = ','): string;
/// Split on ADelim; trims, drops blanks.
function CsvToStrArray(const AValue: string; const ADelim: Char = ','): TArray<string>;

/// Strip leading provider prefixes from a channel name. Each token is matched
/// case-insensitively at the start of the name, ignoring surrounding separators
/// ( space | - : ) — so the single token "NL" removes "NL ", "NL|", "|NL|",
/// "NL - " etc. A separator (or end of string) must follow the token, so "NL"
/// never eats "Netherlands". Tokens are applied repeatedly, so "NL| UK| Name"
/// with tokens NL,UK collapses to "Name". Leftover leading separators are
/// trimmed. Returns the original (trimmed) name when nothing matches.
function StripNamePrefixes(const AName: string; const APrefixes: TArray<string>): string;

/// Mirror of StripNamePrefixes for TRAILING tokens (e.g. "(S)", "rec"): each
/// token is matched case-insensitively at the END of the name and must be
/// preceded by a separator (or be the whole name). Applied repeatedly; leftover
/// trailing separators (space | - : and record/dot glyphs) are trimmed.
/// Decorative letters are folded before comparing (see FoldDecorativeLetters),
/// so the token "rec" also removes the superscript "rec" some providers append.
function StripNameSuffixes(const AName: string; const ASuffixes: TArray<string>): string;

/// The name a channel gets on a list: prefixes, then suffixes stripped.
function CleanChannelName(const AName: string; const APrefixes, ASuffixes: TArray<string>): string;

/// Fold the decorative Unicode letters providers use (small capitals as in the
/// ProviderB "RAW" tag, superscript/modifier letters, fullwidth letters/digits) to
/// plain ASCII, so the small-caps RAW compares equal to "RAW". Others kept.
function FoldDecorativeLetters(const AValue: string): string;

/// Read a query-string parameter from a URL by name (case-insensitive); '' if
/// absent. Used to recover provider credentials embedded in a get.php playlist
/// URL (…?username=X&password=Y…) when the source's own fields are empty.
function UrlQueryParam(const AUrl, AName: string): string;

/// Canonical quality token (uppercased; FULLHD→FHD) if AToken is a known quality
/// label (SD/HD/FHD/UHD/4K/4K+/8K/8K+ …); '' otherwise. Used to spot the quality
/// word in a channel name so it can be swapped for another variant.
function CanonicalQuality(const AToken: string): string;
/// Sort rank of a canonical quality word along the nominal ladder (lower =
/// higher nominal tier): 8K+ 8K 4K+ 4K UHD QHD 2K FHD RAW HD SD, then none/other.
function QualityRank(const AQuality: string): Integer;

/// Split a channel name into a normalised "base key" (lowercased, the quality
/// word removed, separators collapsed to single spaces) and the detected quality
/// (canonical; '' if none). Two channels are quality variants of each other when
/// their base keys are equal — e.g. "NL| NPO 1 HD" and "NL| NPO 1 UHD" both key
/// to "nl npo 1". The LAST quality word is taken (quality is normally trailing).
function QualityMatchKey(const AName: string; out AQuality: string): string; overload;
/// As above, plus AHeadKey: only the tokens BEFORE the quality word (equal to
/// the base key when nothing follows it; the base key when no quality found).
/// A fallback match key that ignores tags after the quality ("RAW (S)").
function QualityMatchKey(const AName: string; out AQuality, AHeadKey: string): string; overload;

/// Stable, credential-INSENSITIVE identity for an M3U stream URL. Provider URLs
/// embed the account credentials (Xtream-style M3U: …/live/USER/PASS/ID.ts, or
/// ?username=USER&password=PASS); blanking the KNOWN user/pass before hashing
/// keeps the id constant when the same provider issues a NEW subscription — so a
/// credentials swap preserves the curated layout. Only the supplied creds are
/// stripped (no blind path-segment guessing); when both are empty it falls back
/// to hashing the whole URL (legacy behaviour — there's nothing to strip).
function M3uStreamId(const AUrl, AUser, APass: string): string;

/// ISO-8601 UTC text; '' when ADt = 0.
function DateTimeToIsoUtc(const ADt: TDateTime): string;
/// Parses ISO-8601 UTC text; 0 when empty/invalid.
function IsoUtcToDateTime(const AValue: string): TDateTime;
/// The current time in UTC, straight from the OS clock.
function NowUtc: TDateTime;

// -- Catch-up / timeshift (Xtream) --
// A box asks for a past programme as /timeshift/USER/PASS/MINUTES/START/ID.ts,
// START = 'YYYY-MM-DD:HH-MM' in the PORTAL's clock. We tell boxes timezone=UTC,
// so the start we receive is UTC and is shifted to the provider's clock.

/// Matching keys between a channel and an extra (third-party) XMLTV guide.
/// Name: decorative letters folded, lowercase, a leading country tag ("NL |")
/// and quality/noise words (HD, 4K, ʀᴀᴡ, rec, (S), channel) dropped, separators
/// removed: "NL | NPO 1 HD" -> "npo1", "Discovery Channel" -> "discovery".
function EpgNameKey(const AName: string): string;
/// Id: lowercase, "extra:" prefix and a trailing country suffix (.nl) dropped,
/// separators removed: "NPO.1.nl" and "npo1.nl" -> "npo1".
function EpgIdKey(const AId: string): string;

/// A URL with credentials hidden, for messages/logs: query keys username/password/
/// pass/pw/user/token/auth/mac -> ***, and the Xtream path form
/// /live|movie|series|timeshift/USER/PASS/ -> /live/***/***/.
function MaskUrlSecrets(const AUrl: string): string;

/// The public base URL as the operator typed it, made usable: trimmed, trailing
/// '/' removed, 'http://' added when no scheme was given. False when it still has
/// no host (then ANormalized is ''). '' stays '' (= not configured) and is valid.
function NormalizePublicBaseUrl(const AValue: string; out ANormalized: string): Boolean;
/// Password check in constant time (no early exit on the first differing char,
/// so the response time doesn't reveal how much of a guess was right).
function IsSamePassword(const AGiven, AExpected: string): Boolean;

/// Is AClientIp in AAllowed (exact IPs, or prefixes ending in a dot such as
/// "192.168.1.")? An empty list allows everyone; "::ffff:a.b.c.d" counts as a.b.c.d.
function IsClientInList(const AClientIp: string; const AAllowed: TArray<string>): Boolean;

/// Host of a URL, ADefault when it can't be parsed (never raises).
function SafeUrlHost(const AUrl, ADefault: string): string;
/// Port of a URL, 0 when absent or unparseable (never raises).
function SafeUrlPort(const AUrl: string): Integer;

/// Base64 of the UTF-8 text on ONE line, as Xtream portals send EPG title and
/// description. The RTL's TNetEncoding.Base64 wraps every 76 chars with CR/LF,
/// which some players reject (empty per-channel EPG on Formuler/MyTVOnline).
function XtreamBase64(const AValue: string): string;

/// Portal clock offset (local - UTC, minutes, rounded to 15) from Xtream
/// server_info.time_now ('yyyy-mm-dd hh:nn:ss') + timestamp_now (unix s).
function XtreamTzOffsetMin(const ATimeNow: string; AUnixNow: Int64; out AMinutes: Integer): Boolean;
/// Parse a timeshift start: 'YYYY-MM-DD:HH-MM[-SS]', 'YYYY-MM-DD HH:MM[:SS]' or unix seconds.
function ParseTimeshiftStart(const AValue: string; out ADt: TDateTime): Boolean;
/// The Xtream wire form 'YYYY-MM-DD:HH-MM'.
function FormatTimeshiftStart(const ADt: TDateTime): string;
/// Upstream Xtream timeshift URL; AStartUtc is shifted by ATzOffsetMin to the portal clock.
function XtreamTimeshiftUrl(const ABaseUrl, AUser, APass: string; ADurationMin: Integer;
  AStartUtc: TDateTime; ATzOffsetMin: Integer; const AUpstreamId, AExt: string): string;

/// Hand freed memory back to the OS after a big transient allocation (the EPG
/// parse). The memory manager already releases multi-hundred-MB blocks (the
/// XMLTV string) on free; this also reclaims the now-unused resident pages so
/// the reported RSS actually drops. Cheap; safe to call when idle.
procedure TrimProcessMemory;

/// The process's resident memory (RSS) in bytes — the actual figure the operator
/// sees for the container. Linux: from /proc/self/statm; Windows: WorkingSetSize.
/// 0 if it can't be read. Logged after a refresh so the RSS is visible over time.
function ProcessResidentBytes: Int64;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.Character,
  System.DateUtils,
  System.Generics.Collections,
  System.Hash,
  System.IOUtils,
  System.NetEncoding,
  System.StrUtils,
  System.RegularExpressions,
  System.Net.URLClient,
  System.Math,
{$IFDEF MSWINDOWS}
  Winapi.Windows,
  Winapi.PsAPI,
{$ENDIF}
{$IFDEF POSIX}
  Posix.SysTime,
{$ENDIF}
  // Own units
  IPTV.Model.Epg;

const
  // ProcessResidentBytes (Linux): statm counts pages; 4 KiB pages on x86-64
  cProcStatmPath = '/proc/self/statm';
  cLinuxPageSize = 4096;

  // stored form of a content-type set ("live,movie")
  cContentTypeDelim = ',';

  // quality vocabulary (CanonicalQuality / QualityRank); mirrored in the web
  // app's ListPanel.tsx QUALITIES - keep in sync
  cQualitySD = 'SD';
  cQualityHD = 'HD';
  cQualityFHD = 'FHD';
  cQualityUHD = 'UHD';
  cQuality4K = '4K';
  cQuality4KPlus = '4K+';
  cQuality8K = '8K';
  cQuality8KPlus = '8K+';
  cQualityQHD = 'QHD';
  cQuality2K = '2K';
  cQualityRaw = 'RAW';             // the providers' unprocessed/original feed tier
  cQualityFullHd = 'FULLHD';       // spellings folded to cQualityFHD
  cQualityFullHdDash = 'FULL-HD';

  // M3uStreamId: shorter credentials are not blanked (they'd hit incidental chars)
  cMinCredLength = 2;

  // StripNamePrefixes / StripNameSuffixes: upper bound on strip passes
  cMaxStripPasses = 16;

  // record / bullet glyphs providers put before a trailing tag ("NPO 1 HD ⏺rec")
  cSepRecordButton = #$23FA;       // ⏺ black circle for record
  cSepBlackCircle = #$25CF;        // ● black circle
  cSepBullet = #$2022;             // • bullet
  cSepMediumBlackCircle = #$26AB;  // ⚫ medium black circle

  // FoldDecorativeChar: contiguous Unicode ranges mapped by offset
  cSuperscriptFour = $2074;        // ⁴ .. ⁹ (U+2074..U+2079)
  cSuperscriptNine = $2079;
  cFullwidthDigitZero = $FF10;     // ０ .. ９
  cFullwidthDigitNine = $FF19;
  cFullwidthUpperA = $FF21;        // Ａ .. Ｚ
  cFullwidthUpperZ = $FF3A;
  cFullwidthLowerA = $FF41;        // ａ .. ｚ
  cFullwidthLowerZ = $FF5A;
  cFullwidthPlus = $FF0B;          // ＋

  // EpgKeyAlias: short form some providers use for National Geographic
  cNatGeoShort = 'natgeo';
  cNatGeoLong = 'nationalgeographic';

  // NormalizePublicBaseUrl
  cSchemeSep = '://';
  cDefaultScheme = 'http://';      // added when the operator typed no scheme

  // XtreamBase64: 0 chars per line = never wrap
  cBase64NoLineBreaks = 0;

  // XtreamTzOffsetMin: portal clocks are whole quarter hours off UTC, at most UTC±14 h
  cTzOffsetStepMin = 15;
  cMaxTzOffsetMin = 14 * MinsPerHour;

  // ParseTimeshiftStart: a plain number below this is no unix timestamp (1973-03-03)
  cMinUnixTimestamp = 100000000;
  // date-time parts: Y M D H Mi [S]
  cMinTimeshiftParts = 5;
  cMaxTimeshiftParts = 6;

  // XtreamTimeshiftUrl: container when the caller passes none
  cDefaultStreamExt = 'ts';

function ProcessResidentBytes: Int64;
{$IFDEF LINUX}
var
  lParts: TArray<string>;
begin
  // /proc/self/statm: "size resident shared text lib data dt" — fields in PAGES.
  // field[1] = resident set size; page size is 4096 on x86-64 Linux.
  Result := 0;
  try
    lParts := TFile.ReadAllText(cProcStatmPath).Trim.Split([' ']);
    if Length(lParts) >= 2 then
      Result := StrToInt64Def(lParts[1], 0) * cLinuxPageSize;
  except
    Result := 0;
  end;
end;
{$ELSE}
var
  lPmc: TProcessMemoryCounters;
begin
  Result := 0;
  lPmc := Default(TProcessMemoryCounters);
  lPmc.cb := SizeOf(lPmc);
  if GetProcessMemoryInfo(GetCurrentProcess, @lPmc, SizeOf(lPmc)) then
    Result := Int64(lPmc.WorkingSetSize);
end;
{$ENDIF}

procedure TrimProcessMemory;
begin
{$IFDEF MSWINDOWS}
  // -1/-1 tells Windows to trim the working set to the minimum; pages backing the
  // freed EPG string are released and the reported RSS drops.
  SetProcessWorkingSetSize(GetCurrentProcess, NativeUInt(-1), NativeUInt(-1));
{$ENDIF}
  // POSIX (the Docker/Linux64 build): nothing to do. The Delphi memory manager
  // allocates the multi-hundred-MB XMLTV string as a "large block" straight from
  // mmap and munmaps it on free, so that memory is already returned to the OS the
  // moment a refresh finishes. The only residual is the small-block reuse pool,
  // which no portable call hands back — we keep it small by not churning it (the
  // EPG reader copies only the <programme> blocks we keep).
end;

function ContentTypesToStr(const ACt: TContentTypes): string;
var
  lContentType: TContentType;
  lList: TStringList;
begin
  lList := TStringList.Create;
  try
    lList.Delimiter := cContentTypeDelim;
    lList.StrictDelimiter := True;
    for lContentType := Low(TContentType) to High(TContentType) do
      if lContentType in ACt then
        lList.Add(ContentTypeNames[lContentType]);
    Result := lList.DelimitedText;
  finally
    FreeAndNil(lList);
  end;
end;

function StrToContentTypes(const AValue: string): TContentTypes;
var
  lParts: TArray<string>;
  lPart: string;
begin
  Result := [];
  lParts := AValue.Split([cContentTypeDelim]);
  for lPart in lParts do
    if lPart.Trim <> '' then
      Include(Result, ContentTypeFromString(lPart.Trim));
end;

function StrArrayToCsv(const AValues: TArray<string>; const ADelim: Char = ','): string;
var
  lItem: string;
begin
  // PLAIN join — no quoting. TStringList.DelimitedText used to wrap an item that
  // contained a '"' (or the delimiter) in quotes and double its quotes, but
  // CsvToStrArray never unquotes: every save doubled the quotes again, until 6
  // exclude items had ~50 million '"' each (302 MB row, minute-long LIKEs, 8 s
  // /api/sources). Items are split on ADelim when read, so it can't be inside one.
  Result := '';
  for lItem in AValues do
    if lItem.Trim <> '' then
    begin
      if Result <> '' then
        Result := Result + ADelim;
      Result := Result + lItem.Trim;
    end;
end;

function CsvToStrArray(const AValue: string; const ADelim: Char = ','): TArray<string>;
var
  lParts: TArray<string>;
  lPart: string;
  lList: TList<string>;
begin
  lList := TList<string>.Create;
  try
    lParts := AValue.Split([ADelim]);
    for lPart in lParts do
      if lPart.Trim <> '' then
        lList.Add(lPart.Trim);
    Result := lList.ToArray;
  finally
    FreeAndNil(lList);
  end;
end;

function UrlQueryParam(const AUrl, AName: string): string;
var
  lQuery, lPair: string;
  lQueryPos, lEqPos, lHashPos: Integer;
begin
  Result := '';
  lQueryPos := AUrl.IndexOf('?');
  if lQueryPos < 0 then
    Exit;
  lQuery := AUrl.Substring(lQueryPos + 1);
  lHashPos := lQuery.IndexOf('#'); // drop a trailing fragment
  if lHashPos >= 0 then
    lQuery := lQuery.Substring(0, lHashPos);
  for lPair in lQuery.Split(['&']) do
  begin
    lEqPos := lPair.IndexOf('=');
    if (lEqPos > 0) and SameText(lPair.Substring(0, lEqPos), AName) then
      Exit(lPair.Substring(lEqPos + 1));
  end;
end;

function CanonicalQuality(const AToken: string): string;
var
  lUpper: string;
begin
  lUpper := FoldDecorativeLetters(AToken.Trim).ToUpper;
  if (lUpper = cQualityFullHd) or (lUpper = cQualityFullHdDash) then
    Exit(cQualityFHD);
  // known quality labels (the '+' tiers are distinct from their base tier);
  // RAW = the providers' unprocessed/original feed tier
  if (lUpper = cQualitySD) or (lUpper = cQualityHD) or (lUpper = cQualityFHD) or (lUpper = cQualityUHD) or
     (lUpper = cQuality4K) or (lUpper = cQuality4KPlus) or (lUpper = cQuality8K) or (lUpper = cQuality8KPlus) or
     (lUpper = cQualityQHD) or (lUpper = cQuality2K) or (lUpper = cQualityRaw) then
    Result := lUpper
  else
    Result := '';
end;

function QualityRank(const AQuality: string): Integer;
const
  Ladder: array[0..10] of string =
    (cQuality8KPlus, cQuality8K, cQuality4KPlus, cQuality4K, cQualityUHD, cQualityQHD, cQuality2K,
     cQualityFHD, cQualityRaw, cQualityHD, cQualitySD);
var
  k: Integer;
  lUpper: string;
begin
  lUpper := CanonicalQuality(AQuality);
  for k := Low(Ladder) to High(Ladder) do
    if Ladder[k] = lUpper then
      Exit(k);
  Result := Length(Ladder);
end;

function QualityMatchKey(const AName: string; out AQuality: string): string;
var
  lHead: string;
begin
  Result := QualityMatchKey(AName, AQuality, lHead);
end;

function QualityMatchKey(const AName: string; out AQuality, AHeadKey: string): string;
var
  lTokens: TArray<string>;
  lParts, lHeadParts: TList<string>;
  i, lQualityIdx: Integer;
  lCh: Char;
  lCur: string;
begin
  AQuality := '';
  // tokenise on any char that is NOT alphanumeric or '+' (so "4K+" stays one token)
  lTokens := [];
  lCur := '';
  for lCh in AName do
    if lCh.IsLetterOrDigit or (lCh = '+') then
      lCur := lCur + lCh
    else if lCur <> '' then
    begin
      lTokens := lTokens + [lCur];
      lCur := '';
    end;
  if lCur <> '' then
    lTokens := lTokens + [lCur];

  // the quality word is normally trailing — take the LAST token that is a quality
  lQualityIdx := -1;
  for i := High(lTokens) downto 0 do
    if CanonicalQuality(lTokens[i]) <> '' then
    begin
      lQualityIdx := i;
      Break;
    end;

  lParts := nil;
  lHeadParts := nil;
  try
    lParts := TList<string>.Create;
    lHeadParts := TList<string>.Create;
    for i := 0 to High(lTokens) do
      if i = lQualityIdx then
        AQuality := CanonicalQuality(lTokens[i])
      else
      begin
        lParts.Add(FoldDecorativeLetters(lTokens[i]).ToLower);
        if (lQualityIdx < 0) or (i < lQualityIdx) then
          lHeadParts.Add(lParts.Last);
      end;
    Result := string.Join(' ', lParts.ToArray);
    AHeadKey := string.Join(' ', lHeadParts.ToArray);
  finally
    FreeAndNil(lParts);
    FreeAndNil(lHeadParts);
  end;
end;

function M3uStreamId(const AUrl, AUser, APass: string): string;
const
  CRED = '~'; // deterministic placeholder; the discriminating stream id survives
var
  lUrl: string;

  procedure Blank(const ACred: string);
  begin
    // length>=2 so a 1-char cred can't blanket-replace incidental characters
    if ACred.Length >= cMinCredLength then
      lUrl := StringReplace(lUrl, ACred, CRED, [rfReplaceAll]); // case-sensitive (URLs are)
  end;

begin
  lUrl := AUrl;
  // blank the longer cred first so one can't partially mask the other
  if APass.Length >= AUser.Length then
  begin
    Blank(APass);
    Blank(AUser);
  end
  else
  begin
    Blank(AUser);
    Blank(APass);
  end;
  Result := THashSHA2.GetHashString(lUrl);
end;

function IsPrefixSep(AChar: Char): Boolean;
begin
  // ASCII separators, plus the Unicode vertical-bar glyphs providers decorate
  // names with (e.g. "┃F1 TV┃", "│NL│") instead of the plain ASCII pipe. These
  // are > #255 so CharInSet (AnsiChar set) can't see them — test them explicitly.
  case AChar of
    ' ', #9, '|', '-', ':',
    cSepBrokenBar,
    cSepBoxLight, cSepBoxHeavy,                  // the common ones
    cSepTripleDashLight, cSepTripleDashHeavy,
    cSepQuadDashLight, cSepQuadDashHeavy,
    cSepFullwidthBar:
      Result := True;
  else
    Result := False;
  end;
end;

// trim leading run of separator chars
function TrimLeadingSeps(const AValue: string): string;
var
  i: Integer;
begin
  i := 1;
  while (i <= Length(AValue)) and IsPrefixSep(AValue[i]) do
    Inc(i);
  Result := Copy(AValue, i, MaxInt);
end;

// normalise a configured token: drop surrounding separators (so "NL |", "|NL|"
// all become "NL"), but keep any internal spaces (a token may be "NL HD").
function TrimTokenSeps(const AValue: string): string;
var
  lFirst, lLast: Integer;
begin
  lFirst := 1;
  lLast := Length(AValue);
  while (lFirst <= lLast) and IsPrefixSep(AValue[lFirst]) do
    Inc(lFirst);
  while (lLast >= lFirst) and IsPrefixSep(AValue[lLast]) do
    Dec(lLast);
  Result := Copy(AValue, lFirst, lLast - lFirst + 1);
end;

function StripNamePrefixes(const AName: string; const APrefixes: TArray<string>): string;
var
  lChanged: Boolean;
  lGuard, lToken, lRest: string;
  lPrefix: string;
  lIterations: Integer;
begin
  Result := AName.Trim;
  lIterations := 0;
  repeat
    lChanged := False;
    Inc(lIterations);
    lGuard := TrimLeadingSeps(Result);
    for lPrefix in APrefixes do
    begin
      lToken := TrimTokenSeps(lPrefix);
      if lToken = '' then
        Continue;
      if lGuard.Length < lToken.Length then
        Continue;
      if not SameText(Copy(lGuard, 1, lToken.Length), lToken) then
        Continue;
      // require a separator (or end of string) right after the token so a token
      // like "NL" matches "NL| ..." but never "Netherlands"
      lRest := Copy(lGuard, lToken.Length + 1, MaxInt);
      if (lRest = '') or IsPrefixSep(lRest[1]) then
      begin
        Result := TrimLeadingSeps(lRest);
        lChanged := True;
        Break;
      end;
    end;
  until (not lChanged) or (lIterations > cMaxStripPasses);
  Result := Result.Trim;
end;

function FoldDecorativeChar(AChar: Char): Char;
begin
  case Ord(AChar) of
    // small capitals
    $1D00: Result := 'a';
    $0299: Result := 'b';
    $1D04: Result := 'c';
    $1D05: Result := 'd';
    $1D07: Result := 'e';
    $A730: Result := 'f';
    $0262: Result := 'g';
    $029C: Result := 'h';
    $026A: Result := 'i';
    $1D0A: Result := 'j';
    $1D0B: Result := 'k';
    $029F: Result := 'l';
    $1D0D: Result := 'm';
    $0274: Result := 'n';
    $1D0F: Result := 'o';
    $1D18: Result := 'p';
    $01EB: Result := 'q';
    $0280: Result := 'r';
    $A731: Result := 's';
    $1D1B: Result := 't';
    $1D1C: Result := 'u';
    $1D20: Result := 'v';
    $1D21: Result := 'w';
    $028F: Result := 'y';
    $1D22: Result := 'z';
    // superscript / modifier small letters
    $1D43: Result := 'a';
    $1D47: Result := 'b';
    $1D9C: Result := 'c';
    $1D48: Result := 'd';
    $1D49: Result := 'e';
    $1DA0: Result := 'f';
    $1D4D: Result := 'g';
    $02B0: Result := 'h';
    $2071: Result := 'i';
    $02B2: Result := 'j';
    $1D4F: Result := 'k';
    $02E1: Result := 'l';
    $1D50: Result := 'm';
    $207F: Result := 'n';
    $1D52: Result := 'o';
    $1D56: Result := 'p';
    $02B3: Result := 'r';
    $02E2: Result := 's';
    $1D57: Result := 't';
    $1D58: Result := 'u';
    $1D5B: Result := 'v';
    $02B7: Result := 'w';
    $02E3: Result := 'x';
    $02B8: Result := 'y';
    $1DBB: Result := 'z';
    // superscript capitals
    $1D2C: Result := 'A';
    $1D2E: Result := 'B';
    $1D30: Result := 'D';
    $1D31: Result := 'E';
    $1D33: Result := 'G';
    $1D34: Result := 'H';
    $1D35: Result := 'I';
    $1D36: Result := 'J';
    $1D37: Result := 'K';
    $1D38: Result := 'L';
    $1D39: Result := 'M';
    $1D3A: Result := 'N';
    $1D3C: Result := 'O';
    $1D3E: Result := 'P';
    $1D3F: Result := 'R';
    $1D40: Result := 'T';
    $1D41: Result := 'U';
    $2C7D: Result := 'V';
    $1D42: Result := 'W';
    // superscript digits
    $2070: Result := '0';
    $00B9: Result := '1';
    $00B2: Result := '2';
    $00B3: Result := '3';
    cSuperscriptFour..cSuperscriptNine: Result := Char(Ord('4') + Ord(AChar) - cSuperscriptFour);
    // fullwidth forms
    cFullwidthDigitZero..cFullwidthDigitNine: Result := Char(Ord('0') + Ord(AChar) - cFullwidthDigitZero);
    cFullwidthUpperA..cFullwidthUpperZ: Result := Char(Ord('A') + Ord(AChar) - cFullwidthUpperA);
    cFullwidthLowerA..cFullwidthLowerZ: Result := Char(Ord('a') + Ord(AChar) - cFullwidthLowerA);
    cFullwidthPlus: Result := '+';
  else
    Result := AChar;
  end;
end;

function FoldDecorativeLetters(const AValue: string): string;
var
  i: Integer;
begin
  // 1:1 per UTF-16 unit (every mapped char is in the BMP), so lengths/indices
  // of the folded string line up with the original — StripNameSuffixes relies on it
  Result := AValue;
  for i := 1 to Length(Result) do
    Result[i] := FoldDecorativeChar(Result[i]);
end;

function IsSuffixSep(AChar: Char): Boolean;
begin
  // the prefix separators plus record/bullet glyphs providers put before a tag
  // ("NPO 1 HD <record-dot>rec")
  Result := IsPrefixSep(AChar) or (AChar = cSepRecordButton) or (AChar = cSepBlackCircle) or
    (AChar = cSepBullet) or (AChar = cSepMediumBlackCircle);
end;

function TrimTrailingSeps(const AValue: string): string;
var
  i: Integer;
begin
  i := Length(AValue);
  while (i >= 1) and IsSuffixSep(AValue[i]) do
    Dec(i);
  Result := Copy(AValue, 1, i);
end;

function StripNameSuffixes(const AName: string; const ASuffixes: TArray<string>): string;
var
  lChanged: Boolean;
  lGuard, lFolded, lToken, lBefore: string;
  lSuffix: string;
  lIterations: Integer;
begin
  Result := AName.Trim;
  if Length(ASuffixes) = 0 then
    Exit;
  lIterations := 0;
  repeat
    lChanged := False;
    Inc(lIterations);
    lGuard := TrimTrailingSeps(Result);
    lFolded := FoldDecorativeLetters(lGuard);
    for lSuffix in ASuffixes do
    begin
      lToken := FoldDecorativeLetters(TrimTokenSeps(lSuffix));
      if lToken = '' then
        Continue;
      if lFolded.Length < lToken.Length then
        Continue;
      if not SameText(Copy(lFolded, lFolded.Length - lToken.Length + 1, lToken.Length), lToken) then
        Continue;
      // require a separator (or start of string) right before the token, so the
      // token "HD" removes "NPO 1 HD" -> "NPO 1" but never eats "SPORT1HD"
      lBefore := Copy(lGuard, 1, lGuard.Length - lToken.Length);
      if (lBefore = '') or IsSuffixSep(lBefore[lBefore.Length]) then
      begin
        Result := TrimTrailingSeps(lBefore);
        lChanged := True;
        Break;
      end;
    end;
  until (not lChanged) or (lIterations > cMaxStripPasses);
  Result := Result.Trim;
  if Result = '' then
    Result := AName.Trim; // never strip a name down to nothing
end;

function CleanChannelName(const AName: string; const APrefixes, ASuffixes: TArray<string>): string;
begin
  Result := StripNameSuffixes(StripNamePrefixes(AName, APrefixes), ASuffixes);
end;

function DateTimeToIsoUtc(const ADt: TDateTime): string;
begin
  if ADt = 0 then
    Exit('');
  Result := DateToISO8601(ADt, True);
end;

function IsoUtcToDateTime(const AValue: string): TDateTime;
begin
  if AValue.Trim = '' then
    Exit(0);
  if not TryISO8601ToDate(AValue, Result, True) then
    Result := 0;
end;

function NowUtc: TDateTime;
{$IFDEF MSWINDOWS}
var
  lSystemTime: TSystemTime;
begin
  // straight from the OS clock: converting local time back is ambiguous in the
  // autumn DST hour (02:00-03:00 occurs twice) and was an hour off then
  GetSystemTime(lSystemTime);
  Result := SystemTimeToDateTime(lSystemTime);
end;
{$ELSE}
const
  cMicrosecondsPerDay = 86400000000.0;
var
  lTime: timeval;
begin
  gettimeofday(lTime, nil);
  Result := UnixToDateTime(lTime.tv_sec, True) + lTime.tv_usec / cMicrosecondsPerDay;
end;
{$ENDIF}

// -- matching keys for an extra (third-party) XMLTV guide --------------------

function EpgKeyAlias(const AKey: string): string;
begin
  Result := AKey;
  // a few common short forms providers use for the same channel
  if Result.StartsWith(cNatGeoShort) then
    Result := cNatGeoLong + Result.Substring(Length(cNatGeoShort));
  // the unnumbered main channel is number 1 in the guides
  if Result = 'ziggosport' then
    Result := 'ziggosport1'
  else if Result = 'espn1' then
    Result := 'espn';
end;

function EpgNameKey(const AName: string): string;
const
  COUNTRIES: array[0..19] of string = ('nl', 'be', 'uk', 'gb', 'de', 'fr', 'us', 'es', 'it',
    'pl', 'pt', 'tr', 'ca', 'au', 'dk', 'se', 'no', 'fi', 'at', 'ch');
  NOISE: array[0..9] of string = ('rec', 's', 'hevc', 'h265', 'h264', '50fps', '60fps',
    'backup', 'vip', 'channel');
var
  lKey, lTok: string;
  lToks, lKeep: TArray<string>;
  i: Integer;
  lCh: Char;
  lIsNoise: Boolean;
begin
  // fold decorative letters (ʀᴀᴡ, ʳᵉᶜ), lowercase, split on anything that is not
  // a letter/digit/'+' (pipes, ┃, ⏺, brackets, dots, slashes …)
  lKey := FoldDecorativeLetters(AName).ToLower;
  for i := 1 to Length(lKey) do
  begin
    lCh := lKey[i];
    if not (lCh.IsLetterOrDigit or (lCh = '+')) then
      lKey[i] := ' ';
  end;
  lToks := lKey.Split([' '], TStringSplitOptions.ExcludeEmpty);
  lKeep := nil;
  for i := 0 to High(lToks) do
  begin
    lTok := lToks[i];
    // leading country tag ("NL | NPO 1", "┃NL┃ RTL 4") — only as the first word
    if (i = 0) and (Length(lToks) > 1) and (IndexStr(lTok, COUNTRIES) >= 0) then
      Continue;
    lIsNoise := (CanonicalQuality(lTok) <> '') or (IndexStr(lTok, NOISE) >= 0);
    // keep a noise word when it is the whole name ("Channel 4" keeps 4 anyway)
    if lIsNoise and (Length(lToks) > 1) then
      Continue;
    lKeep := lKeep + [lTok];
  end;
  Result := EpgKeyAlias(string.Join('', lKeep));
end;

const
  EPG_COUNTRY_CODES: array[0..63] of string = (
    'nl', 'be', 'de', 'uk', 'gb', 'fr', 'es', 'it', 'pt', 'us', 'ca', 'au', 'at', 'ch',
    'pl', 'tr', 'gr', 'se', 'no', 'dk', 'fi', 'ie', 'ro', 'hu', 'cz', 'sk', 'hr', 'rs',
    'si', 'bg', 'al', 'ar', 'br', 'mx', 'in', 'pk', 'ru', 'ua', 'il', 'ae', 'sa', 'eg',
    'ma', 'tn', 'dz', 'nz', 'za', 'ph', 'id', 'my', 'th', 'vn', 'jp', 'kr', 'hk', 'sg',
    'lu', 'lt', 'lv', 'ee', 'cy', 'mk', 'ba', 'xk');

function EpgIdKey(const AId: string): string;
var
  lKey: string;
  lDot, i: Integer;
begin
  lKey := AId.Trim.ToLower;
  if lKey.StartsWith(EXTRA_EPG_PREFIX) then
    lKey := lKey.Substring(Length(EXTRA_EPG_PREFIX));
  // drop a trailing COUNTRY suffix: "NPO.1.nl" / "npo1.nl" / "bbc.one.uk" - only
  // real country codes ("bbc.one" or "sport.hd" keep their last part)
  lDot := lKey.LastIndexOf('.');
  if (lDot > 0) and MatchText(lKey.Substring(lDot + 1), EPG_COUNTRY_CODES) then
    lKey := lKey.Substring(0, lDot);
  Result := '';
  for i := 1 to Length(lKey) do
    if lKey[i].IsLetterOrDigit or (lKey[i] = '+') then
      Result := Result + lKey[i];
  Result := EpgKeyAlias(Result);
end;

function NormalizePublicBaseUrl(const AValue: string; out ANormalized: string): Boolean;
var
  lUrl, lHost: string;
begin
  lUrl := AValue.Trim;
  ANormalized := '';
  // "http://" alone: stripping its slashes below would leave "http:" as a host
  if lUrl.Contains(cSchemeSep) and
     (lUrl.Substring(lUrl.IndexOf(cSchemeSep) + Length(cSchemeSep)).Trim(['/']) = '') then
    Exit(False);
  while lUrl.EndsWith('/') do
    lUrl := lUrl.Substring(0, lUrl.Length - 1);
  ANormalized := '';
  if lUrl = '' then
    Exit(True);
  if not lUrl.Contains(cSchemeSep) then
    lUrl := cDefaultScheme + lUrl; // "192.168.1.10:9000" is what people type
  // a host must follow the scheme (TURI accepts "http://" with an empty host)
  lHost := lUrl.Substring(lUrl.IndexOf(cSchemeSep) + Length(cSchemeSep));
  if lHost.IndexOfAny(['/', ':', '?', '#']) >= 0 then
    lHost := lHost.Substring(0, lHost.IndexOfAny(['/', ':', '?', '#']));
  Result := (lHost <> '') and (SafeUrlHost(lUrl, '') <> '');
  if Result then
    ANormalized := lUrl;
end;

function IsSamePassword(const AGiven, AExpected: string): Boolean;
var
  lGiven, lExpected: TBytes;
  lDiff, i: Integer;
begin
  lGiven := TEncoding.UTF8.GetBytes(AGiven);
  lExpected := TEncoding.UTF8.GetBytes(AExpected);
  lDiff := Length(lGiven) xor Length(lExpected);
  for i := 0 to High(lExpected) do
    if i < Length(lGiven) then
      lDiff := lDiff or (lGiven[i] xor lExpected[i])
    else
      lDiff := lDiff or lExpected[i] or 1;
  Result := lDiff = 0;
end;

function IsClientInList(const AClientIp: string; const AAllowed: TArray<string>): Boolean;
const
  cIpv4MappedPrefix = '::ffff:'; // an IPv4 client seen through an IPv6 socket
var
  lIp, lEntry: string;
begin
  if Length(AAllowed) = 0 then
    Exit(True);
  lIp := AClientIp.Trim;
  if lIp.StartsWith(cIpv4MappedPrefix, True) then
    lIp := lIp.Substring(Length(cIpv4MappedPrefix));
  for lEntry in AAllowed do
    if SameText(lIp, lEntry.Trim) or (lEntry.Trim.EndsWith('.') and lIp.StartsWith(lEntry.Trim)) then
      Exit(True);
  Result := False;
end;

function SafeUrlHost(const AUrl, ADefault: string): string;
begin
  Result := ADefault;
  if AUrl.Trim = '' then
    Exit;
  try
    Result := TURI.Create(AUrl.Trim).Host;
  except
    Result := ADefault;
  end;
  if Result = '' then
    Result := ADefault;
end;

function SafeUrlPort(const AUrl: string): Integer;
begin
  Result := 0;
  if AUrl.Trim = '' then
    Exit;
  try
    Result := Max(0, TURI.Create(AUrl.Trim).Port);
  except
    Result := 0;
  end;
end;

function MaskUrlSecrets(const AUrl: string): string;
begin
  Result := TRegEx.Replace(AUrl, '(/(live|movie|series|timeshift)/)[^/?#]+/[^/?#]+/', '$1***/***/',
    [roIgnoreCase]);
  Result := TRegEx.Replace(Result, '([?&](username|password|pass|pw|user|token|auth|mac)=)[^&#]*', '$1***',
    [roIgnoreCase]);
end;

function XtreamBase64(const AValue: string): string;
var
  lEncoding: TBase64Encoding;
begin
  lEncoding := TBase64Encoding.Create(cBase64NoLineBreaks);
  try
    Result := lEncoding.EncodeBytesToString(TEncoding.UTF8.GetBytes(AValue));
  finally
    FreeAndNil(lEncoding);
  end;
end;

function XtreamTzOffsetMin(const ATimeNow: string; AUnixNow: Int64; out AMinutes: Integer): Boolean;
var
  lLocal, lUtc: TDateTime;
  lDiff: Int64;
begin
  AMinutes := 0;
  Result := False;
  if (AUnixNow <= 0) or not ParseTimeshiftStart(ATimeNow, lLocal) then
    Exit;
  lUtc := UnixToDateTime(AUnixNow, True);
  lDiff := SecondsBetween(lLocal, lUtc);
  if lLocal < lUtc then
    lDiff := -lDiff;
  // round to the nearest quarter hour (the two values are read a moment apart)
  AMinutes := Round(lDiff / (cTzOffsetStepMin * SecsPerMin)) * cTzOffsetStepMin;
  if Abs(AMinutes) > cMaxTzOffsetMin then
  begin
    AMinutes := 0;
    Exit; // nonsense clock -> unknown
  end;
  Result := True;
end;

function ParseTimeshiftStart(const AValue: string; out ADt: TDateTime): Boolean;
var
  lValue: string;
  lParts: TArray<string>;
  lYear, lMonth, lDay, lHour, lMinute, lSecond: Integer;
  lUnix: Int64;
begin
  ADt := 0;
  lValue := AValue.Trim;
  Result := False;
  if lValue = '' then
    Exit;
  if TryStrToInt64(lValue, lUnix) then
  begin
    if lUnix < cMinUnixTimestamp then
      Exit;
    ADt := UnixToDateTime(lUnix, True);
    Exit(True);
  end;
  // 2026-11-12:20-30 | 2026-11-12:20-30-00 | 2026-11-12 20:30[:00]
  lParts := lValue.Split(['-', ':', ' ', 'T']);
  if (Length(lParts) < cMinTimeshiftParts) or (Length(lParts) > cMaxTimeshiftParts) then
    Exit;
  lSecond := 0;
  if not (TryStrToInt(lParts[0], lYear) and TryStrToInt(lParts[1], lMonth) and
          TryStrToInt(lParts[2], lDay) and TryStrToInt(lParts[3], lHour) and
          TryStrToInt(lParts[4], lMinute)) then
    Exit;
  if (Length(lParts) = cMaxTimeshiftParts) and not TryStrToInt(lParts[5], lSecond) then
    Exit;
  Result := TryEncodeDateTime(lYear, lMonth, lDay, lHour, lMinute, lSecond, 0, ADt);
end;

function FormatTimeshiftStart(const ADt: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd":"hh"-"nn', ADt);
end;

function XtreamTimeshiftUrl(const ABaseUrl, AUser, APass: string; ADurationMin: Integer;
  AStartUtc: TDateTime; ATzOffsetMin: Integer; const AUpstreamId, AExt: string): string;
var
  lExt: string;
begin
  lExt := AExt;
  if lExt = '' then
    lExt := cDefaultStreamExt;
  Result := Format('%s/timeshift/%s/%s/%d/%s/%s.%s',
    [ABaseUrl.Trim.TrimRight(['/']), AUser.Trim, APass.Trim, ADurationMin,
     FormatTimeshiftStart(IncMinute(AStartUtc, ATzOffsetMin)), AUpstreamId, lExt]);
end;

end.
