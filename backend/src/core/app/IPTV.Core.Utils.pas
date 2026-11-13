unit IPTV.Core.Utils;

{ Small conversion helpers shared by storage and the API serializers.
  Content-type sets <-> CSV text; TDateTime (UTC) <-> ISO-8601 text. }

interface

uses
  IPTV.Model.Types;

function ContentTypesToStr(const ACt: TContentTypes): string;
function StrToContentTypes(const AValue: string): TContentTypes;

function StrArrayToCsv(const A: TArray<string>; const ADelim: Char = ','): string;   // trims, drops blanks
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
function FoldDecorativeLetters(const S: string): string;

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

function DateTimeToIsoUtc(const ADt: TDateTime): string;   // '' when ADt = 0
function IsoUtcToDateTime(const AValue: string): TDateTime; // 0 when empty/invalid
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
function XtreamBase64(const S: string): string;

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
  System.SysUtils, System.Classes, System.Character, System.DateUtils,
  System.Generics.Collections, System.Hash, System.IOUtils, System.NetEncoding, System.StrUtils, System.RegularExpressions,
  System.Net.URLClient, System.Math
{$IFDEF MSWINDOWS}
  , Winapi.Windows, Winapi.PsAPI
{$ENDIF}
{$IFDEF POSIX}
  , Posix.SysTime
{$ENDIF}
  , IPTV.Model.Epg;

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
  Parts: TArray<string>;
begin
  // /proc/self/statm: "size resident shared text lib data dt" — fields in PAGES.
  // field[1] = resident set size; page size is 4096 on x86-64 Linux.
  Result := 0;
  try
    Parts := TFile.ReadAllText(cProcStatmPath).Trim.Split([' ']);
    if Length(Parts) >= 2 then
      Result := StrToInt64Def(Parts[1], 0) * cLinuxPageSize;
  except
    Result := 0;
  end;
end;
{$ELSE}
var
  Pmc: TProcessMemoryCounters;
begin
  Result := 0;
  Pmc := Default(TProcessMemoryCounters);
  Pmc.cb := SizeOf(Pmc);
  if GetProcessMemoryInfo(GetCurrentProcess, @Pmc, SizeOf(Pmc)) then
    Result := Int64(Pmc.WorkingSetSize);
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
  CT: TContentType;
  SL: TStringList;
begin
  SL := TStringList.Create;
  try
    SL.Delimiter := cContentTypeDelim;
    SL.StrictDelimiter := True;
    for CT := Low(TContentType) to High(TContentType) do
      if CT in ACt then
        SL.Add(ContentTypeNames[CT]);
    Result := SL.DelimitedText;
  finally
    SL.Free;
  end;
end;

function StrToContentTypes(const AValue: string): TContentTypes;
var
  Parts: TArray<string>;
  P: string;
begin
  Result := [];
  Parts := AValue.Split([cContentTypeDelim]);
  for P in Parts do
    if P.Trim <> '' then
      Include(Result, ContentTypeFromString(P.Trim));
end;

function StrArrayToCsv(const A: TArray<string>; const ADelim: Char = ','): string;
var
  S: string;
begin
  // PLAIN join — no quoting. TStringList.DelimitedText used to wrap an item that
  // contained a '"' (or the delimiter) in quotes and double its quotes, but
  // CsvToStrArray never unquotes: every save doubled the quotes again, until 6
  // exclude items had ~50 million '"' each (302 MB row, minute-long LIKEs, 8 s
  // /api/sources). Items are split on ADelim when read, so it can't be inside one.
  Result := '';
  for S in A do
    if S.Trim <> '' then
    begin
      if Result <> '' then
        Result := Result + ADelim;
      Result := Result + S.Trim;
    end;
end;

function CsvToStrArray(const AValue: string; const ADelim: Char = ','): TArray<string>;
var
  Parts: TArray<string>;
  P: string;
  L: TList<string>;
begin
  L := TList<string>.Create;
  try
    Parts := AValue.Split([ADelim]);
    for P in Parts do
      if P.Trim <> '' then
        L.Add(P.Trim);
    Result := L.ToArray;
  finally
    L.Free;
  end;
end;

function UrlQueryParam(const AUrl, AName: string): string;
var
  Q, Pair: string;
  QPos, EqPos, HashPos: Integer;
begin
  Result := '';
  QPos := AUrl.IndexOf('?');
  if QPos < 0 then
    Exit;
  Q := AUrl.Substring(QPos + 1);
  HashPos := Q.IndexOf('#'); // drop a trailing fragment
  if HashPos >= 0 then
    Q := Q.Substring(0, HashPos);
  for Pair in Q.Split(['&']) do
  begin
    EqPos := Pair.IndexOf('=');
    if (EqPos > 0) and SameText(Pair.Substring(0, EqPos), AName) then
      Exit(Pair.Substring(EqPos + 1));
  end;
end;

function CanonicalQuality(const AToken: string): string;
var
  U: string;
begin
  U := FoldDecorativeLetters(AToken.Trim).ToUpper;
  if (U = cQualityFullHd) or (U = cQualityFullHdDash) then
    Exit(cQualityFHD);
  // known quality labels (the '+' tiers are distinct from their base tier);
  // RAW = the providers' unprocessed/original feed tier
  if (U = cQualitySD) or (U = cQualityHD) or (U = cQualityFHD) or (U = cQualityUHD) or
     (U = cQuality4K) or (U = cQuality4KPlus) or (U = cQuality8K) or (U = cQuality8KPlus) or
     (U = cQualityQHD) or (U = cQuality2K) or (U = cQualityRaw) then
    Result := U
  else
    Result := '';
end;

function QualityRank(const AQuality: string): Integer;
const
  Ladder: array[0..10] of string =
    (cQuality8KPlus, cQuality8K, cQuality4KPlus, cQuality4K, cQualityUHD, cQualityQHD, cQuality2K,
     cQualityFHD, cQualityRaw, cQualityHD, cQualitySD);
var
  K: Integer;
  U: string;
begin
  U := CanonicalQuality(AQuality);
  for K := Low(Ladder) to High(Ladder) do
    if Ladder[K] = U then
      Exit(K);
  Result := Length(Ladder);
end;

function QualityMatchKey(const AName: string; out AQuality: string): string;
var
  Head: string;
begin
  Result := QualityMatchKey(AName, AQuality, Head);
end;

function QualityMatchKey(const AName: string; out AQuality, AHeadKey: string): string;
var
  Tokens: TArray<string>;
  Parts, HeadParts: TList<string>;
  I, QIdx: Integer;
  Ch: Char;
  Cur: string;
begin
  AQuality := '';
  // tokenise on any char that is NOT alphanumeric or '+' (so "4K+" stays one token)
  Tokens := [];
  Cur := '';
  for Ch in AName do
    if Ch.IsLetterOrDigit or (Ch = '+') then
      Cur := Cur + Ch
    else if Cur <> '' then
    begin
      Tokens := Tokens + [Cur];
      Cur := '';
    end;
  if Cur <> '' then
    Tokens := Tokens + [Cur];

  // the quality word is normally trailing — take the LAST token that is a quality
  QIdx := -1;
  for I := High(Tokens) downto 0 do
    if CanonicalQuality(Tokens[I]) <> '' then
    begin
      QIdx := I;
      Break;
    end;

  Parts := TList<string>.Create;
  HeadParts := TList<string>.Create;
  try
    for I := 0 to High(Tokens) do
      if I = QIdx then
        AQuality := CanonicalQuality(Tokens[I])
      else
      begin
        Parts.Add(FoldDecorativeLetters(Tokens[I]).ToLower);
        if (QIdx < 0) or (I < QIdx) then
          HeadParts.Add(Parts.Last);
      end;
    Result := string.Join(' ', Parts.ToArray);
    AHeadKey := string.Join(' ', HeadParts.ToArray);
  finally
    Parts.Free;
    HeadParts.Free;
  end;
end;

function M3uStreamId(const AUrl, AUser, APass: string): string;
const
  CRED = '~'; // deterministic placeholder; the discriminating stream id survives
var
  S: string;

  procedure Blank(const ACred: string);
  begin
    // length>=2 so a 1-char cred can't blanket-replace incidental characters
    if ACred.Length >= cMinCredLength then
      S := StringReplace(S, ACred, CRED, [rfReplaceAll]); // case-sensitive (URLs are)
  end;

begin
  S := AUrl;
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
  Result := THashSHA2.GetHashString(S);
end;

function IsPrefixSep(C: Char): Boolean;
begin
  // ASCII separators, plus the Unicode vertical-bar glyphs providers decorate
  // names with (e.g. "┃F1 TV┃", "│NL│") instead of the plain ASCII pipe. These
  // are > #255 so CharInSet (AnsiChar set) can't see them — test them explicitly.
  case C of
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
function TrimLeadingSeps(const S: string): string;
var
  I: Integer;
begin
  I := 1;
  while (I <= Length(S)) and IsPrefixSep(S[I]) do
    Inc(I);
  Result := Copy(S, I, MaxInt);
end;

// normalise a configured token: drop surrounding separators (so "NL |", "|NL|"
// all become "NL"), but keep any internal spaces (a token may be "NL HD").
function TrimTokenSeps(const S: string): string;
var
  A, B: Integer;
begin
  A := 1;
  B := Length(S);
  while (A <= B) and IsPrefixSep(S[A]) do Inc(A);
  while (B >= A) and IsPrefixSep(S[B]) do Dec(B);
  Result := Copy(S, A, B - A + 1);
end;

function StripNamePrefixes(const AName: string; const APrefixes: TArray<string>): string;
var
  Changed: Boolean;
  Guard, Pn, Rest: string;
  P: string;
  Iterations: Integer;
begin
  Result := AName.Trim;
  Iterations := 0;
  repeat
    Changed := False;
    Inc(Iterations);
    Guard := TrimLeadingSeps(Result);
    for P in APrefixes do
    begin
      Pn := TrimTokenSeps(P);
      if Pn = '' then
        Continue;
      if Guard.Length < Pn.Length then
        Continue;
      if not SameText(Copy(Guard, 1, Pn.Length), Pn) then
        Continue;
      // require a separator (or end of string) right after the token so a token
      // like "NL" matches "NL| ..." but never "Netherlands"
      Rest := Copy(Guard, Pn.Length + 1, MaxInt);
      if (Rest = '') or IsPrefixSep(Rest[1]) then
      begin
        Result := TrimLeadingSeps(Rest);
        Changed := True;
        Break;
      end;
    end;
  until (not Changed) or (Iterations > cMaxStripPasses);
  Result := Result.Trim;
end;

function FoldDecorativeChar(C: Char): Char;
begin
  case Ord(C) of
    // small capitals
    $1D00: Result := 'a'; $0299: Result := 'b'; $1D04: Result := 'c'; $1D05: Result := 'd';
    $1D07: Result := 'e'; $A730: Result := 'f'; $0262: Result := 'g'; $029C: Result := 'h';
    $026A: Result := 'i'; $1D0A: Result := 'j'; $1D0B: Result := 'k'; $029F: Result := 'l';
    $1D0D: Result := 'm'; $0274: Result := 'n'; $1D0F: Result := 'o'; $1D18: Result := 'p';
    $01EB: Result := 'q'; $0280: Result := 'r'; $A731: Result := 's'; $1D1B: Result := 't';
    $1D1C: Result := 'u'; $1D20: Result := 'v'; $1D21: Result := 'w'; $028F: Result := 'y';
    $1D22: Result := 'z';
    // superscript / modifier small letters
    $1D43: Result := 'a'; $1D47: Result := 'b'; $1D9C: Result := 'c'; $1D48: Result := 'd';
    $1D49: Result := 'e'; $1DA0: Result := 'f'; $1D4D: Result := 'g'; $02B0: Result := 'h';
    $2071: Result := 'i'; $02B2: Result := 'j'; $1D4F: Result := 'k'; $02E1: Result := 'l';
    $1D50: Result := 'm'; $207F: Result := 'n'; $1D52: Result := 'o'; $1D56: Result := 'p';
    $02B3: Result := 'r'; $02E2: Result := 's'; $1D57: Result := 't'; $1D58: Result := 'u';
    $1D5B: Result := 'v'; $02B7: Result := 'w'; $02E3: Result := 'x'; $02B8: Result := 'y';
    $1DBB: Result := 'z';
    // superscript capitals
    $1D2C: Result := 'A'; $1D2E: Result := 'B'; $1D30: Result := 'D'; $1D31: Result := 'E';
    $1D33: Result := 'G'; $1D34: Result := 'H'; $1D35: Result := 'I'; $1D36: Result := 'J';
    $1D37: Result := 'K'; $1D38: Result := 'L'; $1D39: Result := 'M'; $1D3A: Result := 'N';
    $1D3C: Result := 'O'; $1D3E: Result := 'P'; $1D3F: Result := 'R'; $1D40: Result := 'T';
    $1D41: Result := 'U'; $2C7D: Result := 'V'; $1D42: Result := 'W';
    // superscript digits
    $2070: Result := '0'; $00B9: Result := '1'; $00B2: Result := '2'; $00B3: Result := '3';
    cSuperscriptFour..cSuperscriptNine: Result := Char(Ord('4') + Ord(C) - cSuperscriptFour);
    // fullwidth forms
    cFullwidthDigitZero..cFullwidthDigitNine: Result := Char(Ord('0') + Ord(C) - cFullwidthDigitZero);
    cFullwidthUpperA..cFullwidthUpperZ: Result := Char(Ord('A') + Ord(C) - cFullwidthUpperA);
    cFullwidthLowerA..cFullwidthLowerZ: Result := Char(Ord('a') + Ord(C) - cFullwidthLowerA);
    cFullwidthPlus: Result := '+';
  else
    Result := C;
  end;
end;

function FoldDecorativeLetters(const S: string): string;
var
  I: Integer;
begin
  // 1:1 per UTF-16 unit (every mapped char is in the BMP), so lengths/indices
  // of the folded string line up with the original — StripNameSuffixes relies on it
  Result := S;
  for I := 1 to Length(Result) do
    Result[I] := FoldDecorativeChar(Result[I]);
end;

function IsSuffixSep(C: Char): Boolean;
begin
  // the prefix separators plus record/bullet glyphs providers put before a tag
  // ("NPO 1 HD <record-dot>rec")
  Result := IsPrefixSep(C) or (C = cSepRecordButton) or (C = cSepBlackCircle) or (C = cSepBullet) or
    (C = cSepMediumBlackCircle);
end;

function TrimTrailingSeps(const S: string): string;
var
  I: Integer;
begin
  I := Length(S);
  while (I >= 1) and IsSuffixSep(S[I]) do
    Dec(I);
  Result := Copy(S, 1, I);
end;

function StripNameSuffixes(const AName: string; const ASuffixes: TArray<string>): string;
var
  Changed: Boolean;
  Guard, Folded, Pn, Before: string;
  P: string;
  Iterations: Integer;
begin
  Result := AName.Trim;
  if Length(ASuffixes) = 0 then
    Exit;
  Iterations := 0;
  repeat
    Changed := False;
    Inc(Iterations);
    Guard := TrimTrailingSeps(Result);
    Folded := FoldDecorativeLetters(Guard);
    for P in ASuffixes do
    begin
      Pn := FoldDecorativeLetters(TrimTokenSeps(P));
      if Pn = '' then
        Continue;
      if Folded.Length < Pn.Length then
        Continue;
      if not SameText(Copy(Folded, Folded.Length - Pn.Length + 1, Pn.Length), Pn) then
        Continue;
      // require a separator (or start of string) right before the token, so the
      // token "HD" removes "NPO 1 HD" -> "NPO 1" but never eats "SPORT1HD"
      Before := Copy(Guard, 1, Guard.Length - Pn.Length);
      if (Before = '') or IsSuffixSep(Before[Before.Length]) then
      begin
        Result := TrimTrailingSeps(Before);
        Changed := True;
        Break;
      end;
    end;
  until (not Changed) or (Iterations > cMaxStripPasses);
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
  S, Tok: string;
  Toks, Keep: TArray<string>;
  I: Integer;
  Ch: Char;
  IsNoise: Boolean;
begin
  // fold decorative letters (ʀᴀᴡ, ʳᵉᶜ), lowercase, split on anything that is not
  // a letter/digit/'+' (pipes, ┃, ⏺, brackets, dots, slashes …)
  S := FoldDecorativeLetters(AName).ToLower;
  for I := 1 to Length(S) do
  begin
    Ch := S[I];
    if not (Ch.IsLetterOrDigit or (Ch = '+')) then
      S[I] := ' ';
  end;
  Toks := S.Split([' '], TStringSplitOptions.ExcludeEmpty);
  Keep := nil;
  for I := 0 to High(Toks) do
  begin
    Tok := Toks[I];
    // leading country tag ("NL | NPO 1", "┃NL┃ RTL 4") — only as the first word
    if (I = 0) and (Length(Toks) > 1) and (IndexStr(Tok, COUNTRIES) >= 0) then
      Continue;
    IsNoise := (CanonicalQuality(Tok) <> '') or (IndexStr(Tok, NOISE) >= 0);
    // keep a noise word when it is the whole name ("Channel 4" keeps 4 anyway)
    if IsNoise and (Length(Toks) > 1) then
      Continue;
    Keep := Keep + [Tok];
  end;
  Result := EpgKeyAlias(string.Join('', Keep));
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
  S: string;
  Dot, I: Integer;
begin
  S := AId.Trim.ToLower;
  if S.StartsWith(EXTRA_EPG_PREFIX) then
    S := S.Substring(Length(EXTRA_EPG_PREFIX));
  // drop a trailing COUNTRY suffix: "NPO.1.nl" / "npo1.nl" / "bbc.one.uk" - only
  // real country codes ("bbc.one" or "sport.hd" keep their last part)
  Dot := S.LastIndexOf('.');
  if (Dot > 0) and MatchText(S.Substring(Dot + 1), EPG_COUNTRY_CODES) then
    S := S.Substring(0, Dot);
  Result := '';
  for I := 1 to Length(S) do
    if S[I].IsLetterOrDigit or (S[I] = '+') then
      Result := Result + S[I];
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

function XtreamBase64(const S: string): string;
var
  Enc: TBase64Encoding;
begin
  Enc := TBase64Encoding.Create(cBase64NoLineBreaks);
  try
    Result := Enc.EncodeBytesToString(TEncoding.UTF8.GetBytes(S));
  finally
    Enc.Free;
  end;
end;

function XtreamTzOffsetMin(const ATimeNow: string; AUnixNow: Int64; out AMinutes: Integer): Boolean;
var
  Local, Utc: TDateTime;
  Diff: Int64;
begin
  AMinutes := 0;
  Result := False;
  if (AUnixNow <= 0) or not ParseTimeshiftStart(ATimeNow, Local) then
    Exit;
  Utc := UnixToDateTime(AUnixNow, True);
  Diff := SecondsBetween(Local, Utc);
  if Local < Utc then
    Diff := -Diff;
  // round to the nearest quarter hour (the two values are read a moment apart)
  AMinutes := Round(Diff / (cTzOffsetStepMin * SecsPerMin)) * cTzOffsetStepMin;
  if Abs(AMinutes) > cMaxTzOffsetMin then
  begin
    AMinutes := 0;
    Exit; // nonsense clock -> unknown
  end;
  Result := True;
end;

function ParseTimeshiftStart(const AValue: string; out ADt: TDateTime): Boolean;
var
  S: string;
  Parts: TArray<string>;
  Y, Mo, D, H, Mi, Se: Integer;
  Unix: Int64;
begin
  ADt := 0;
  S := AValue.Trim;
  Result := False;
  if S = '' then
    Exit;
  if TryStrToInt64(S, Unix) then
  begin
    if Unix < cMinUnixTimestamp then
      Exit;
    ADt := UnixToDateTime(Unix, True);
    Exit(True);
  end;
  // 2026-11-12:20-30 | 2026-11-12:20-30-00 | 2026-11-12 20:30[:00]
  Parts := S.Split(['-', ':', ' ', 'T']);
  if (Length(Parts) < cMinTimeshiftParts) or (Length(Parts) > cMaxTimeshiftParts) then
    Exit;
  Se := 0;
  if not (TryStrToInt(Parts[0], Y) and TryStrToInt(Parts[1], Mo) and TryStrToInt(Parts[2], D) and
          TryStrToInt(Parts[3], H) and TryStrToInt(Parts[4], Mi)) then
    Exit;
  if (Length(Parts) = cMaxTimeshiftParts) and not TryStrToInt(Parts[5], Se) then
    Exit;
  Result := TryEncodeDateTime(Y, Mo, D, H, Mi, Se, 0, ADt);
end;

function FormatTimeshiftStart(const ADt: TDateTime): string;
begin
  Result := FormatDateTime('yyyy"-"mm"-"dd":"hh"-"nn', ADt);
end;

function XtreamTimeshiftUrl(const ABaseUrl, AUser, APass: string; ADurationMin: Integer;
  AStartUtc: TDateTime; ATzOffsetMin: Integer; const AUpstreamId, AExt: string): string;
var
  Ext: string;
begin
  Ext := AExt;
  if Ext = '' then
    Ext := cDefaultStreamExt;
  Result := Format('%s/timeshift/%s/%s/%d/%s/%s.%s',
    [ABaseUrl.Trim.TrimRight(['/']), AUser.Trim, APass.Trim, ADurationMin,
     FormatTimeshiftStart(IncMinute(AStartUtc, ATzOffsetMin)), AUpstreamId, Ext]);
end;


end.
