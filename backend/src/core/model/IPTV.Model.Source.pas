unit IPTV.Model.Source;

{ An upstream IPTV provider: either an Xtream Codes portal or a (remote/local)
  M3U / M3U_plus playlist. Per source the operator can switch each content type
  (Live / Movies / Series / Radio) on or off — disabled types are never
  ingested nor offered downstream. }

interface

uses
  // RTL
  System.SysUtils,
  // Own units
  IPTV.Model.Types;

type
  /// One upstream provider (Xtream portal or M3U playlist) and its per-source settings.
  TSourceConfig = class
  private
    FId: Integer;
    FName: string;
    FKind: TSourceKind;
    FUrl: string;        // Xtream: server base (http://host:port). M3U: full URL or local path.
    FUsername: string;   // Xtream only
    FPassword: string;   // Xtream only
    FEpgUrl: string;     // optional XMLTV override; if empty we derive it (Xtream xmltv.php / M3U url-tvg)
    FUserAgent: string;  // optional per-provider UA; empty = use the built-in browser default
    FReferer: string;    // optional per-provider Referer header; some portals require it
    FForceHls: Boolean;  // live always handed to the box as .m3u8 (some providers drop .ts every ~20 s)
    FEnabled: Boolean;
    FContentTypes: TContentTypes;  // which content types to ingest from this source
    FIncludeFilters: TArray<string>; // if non-empty, keep only names matching one (prefix OR suffix)
    FExcludeFilters: TArray<string>; // drop names matching any (prefix OR suffix)
    FStripPrefixes: TArray<string>;  // leading tokens removed from a name when added to a list (e.g. "NL")
    FStripSuffixes: TArray<string>;  // trailing tokens removed likewise (e.g. "(S)", "rec")
    FLastRefreshUtc: TDateTime;
    // provider account info (Xtream user_info), filled on each refresh
    FAccountStatus: string;    // e.g. 'Active', 'Expired'; '' = unknown (never fetched / not Xtream)
    FExpiresUtc: TDateTime;    // 0 = no end date (or unknown when AccountStatus = '')
    FMaxConnections: Integer;  // 0 = unknown
    FPreferOwnEpg: Boolean;    // own guide before the extra (third-party) EPG source
    FTzOffsetMin: Integer;     // portal clock - UTC in minutes (Xtream server_info); timeshift
                               // start times are in the portal's local time
  public
    /// Creates an enabled source with every content type on.
    constructor Create;
    /// Copy every field (used to clone cached rows and to pre-load an update).
    procedure Assign(const ASrc: TSourceConfig);
    /// True when the source is enabled and ingests AType.
    function EnabledFor(AType: TContentType): Boolean;
    /// Apply the per-source name filters: include (whitelist) then exclude (blacklist),
    /// each matching when a token is a prefix OR suffix of the name (case-insensitive).
    function PassesNameFilter(const AName: string): Boolean;

    property Id: Integer read FId write FId;
    property Name: string read FName write FName;
    property Kind: TSourceKind read FKind write FKind;
    property Url: string read FUrl write FUrl;
    property Username: string read FUsername write FUsername;
    property Password: string read FPassword write FPassword;
    property EpgUrl: string read FEpgUrl write FEpgUrl;
    property UserAgent: string read FUserAgent write FUserAgent;
    property Referer: string read FReferer write FReferer;
    property ForceHls: Boolean read FForceHls write FForceHls;
    property Enabled: Boolean read FEnabled write FEnabled;
    property ContentTypes: TContentTypes read FContentTypes write FContentTypes;
    property IncludeFilters: TArray<string> read FIncludeFilters write FIncludeFilters;
    property ExcludeFilters: TArray<string> read FExcludeFilters write FExcludeFilters;
    property StripPrefixes: TArray<string> read FStripPrefixes write FStripPrefixes;
    property StripSuffixes: TArray<string> read FStripSuffixes write FStripSuffixes;
    property LastRefreshUtc: TDateTime read FLastRefreshUtc write FLastRefreshUtc;
    property AccountStatus: string read FAccountStatus write FAccountStatus;
    property ExpiresUtc: TDateTime read FExpiresUtc write FExpiresUtc;
    property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    property TzOffsetMin: Integer read FTzOffsetMin write FTzOffsetMin;
    /// Use this provider's own guide for its channels when it has data; the extra
    /// EPG source only fills gaps. Default (False): the extra source goes first.
    property PreferOwnEpg: Boolean read FPreferOwnEpg write FPreferOwnEpg;
  end;

const
  // a single name-filter token longer than this can't be a real channel/group
  // name; it is almost always a whole list pasted as one item. SQLite refuses LIKE
  // patterns over 50 000 chars ("LIKE or GLOB pattern too complex").
  MaxFilterTokenLen = 200;

/// Split tokens on line breaks (a pasted list), trim, drop empty ones and any
/// longer than MaxFilterTokenLen. Used everywhere filters are evaluated.
function CleanFilterTokens(const ATokens: TArray<string>): TArray<string>;
/// The first token longer than MaxFilterTokenLen after line-splitting, or ''.
function FirstTooLongFilterToken(const ATokens: TArray<string>): string;
type
  /// Include/exclude tokens cleaned, separator-normalised, lower-cased and SORTED
  /// once, so a name is matched by binary search over its word boundaries
  /// (O(words · log tokens)) instead of comparing it with every token.
  TPreparedNameFilter = record
    Inc: TArray<string>;
    Exc: TArray<string>;
  end;

/// Builds the prepared (cleaned, normalised, sorted) form of include/exclude tokens.
function PrepareNameFilter(const AInclude, AExclude: TArray<string>): TPreparedNameFilter;
/// Name passes a prepared include/exclude filter (see NamePassesFilters).
function PreparedNamePasses(const AFilter: TPreparedNameFilter; const AName: string): Boolean;
/// True when an EXCLUDE token matches the name (include tokens are not considered).
function PreparedNameExcluded(const AFilter: TPreparedNameFilter; const AName: string): Boolean;
/// Name passes include (keep only matches; ignored when it has no usable token)
/// and exclude (drop matches). Same word-boundary rule as the storage SQL.
/// Prepares per call — use PrepareNameFilter + PreparedNamePasses in loops.
function NamePassesFilters(const AName: string; const AInclude, AExclude: TArray<string>): Boolean;

implementation

uses
  // RTL
  System.StrUtils,
  System.Generics.Collections;

// Map every separator (| - : tab) to a space and trim, so a token can be matched
// as a whole, separator-delimited word — mirrors the storage NameFilterSql
// (NormCol) so "what gets filtered" == "what matches here". Note: internal space
// runs are NOT collapsed, exactly like NormCol — the prefix/suffix patterns below
// tolerate them, and not collapsing keeps the SQL and Pascal results identical.
function NormSeps(const AValue: string): string;
begin
  // ASCII separators + the Unicode vertical bars providers decorate names with
  // (┃ │ ¦ ｜ …) — keep in lockstep with Core.Utils.IsPrefixSep and the storage
  // NameFilterSql so strip/filter/match all treat the same chars as boundaries.
  Result := AValue
    .Replace('|', ' ').Replace('-', ' ').Replace(':', ' ').Replace(#9, ' ')
    .Replace(cSepBrokenBar, ' ').Replace(cSepBoxLight, ' ').Replace(cSepBoxHeavy, ' ')
    .Replace(cSepTripleDashLight, ' ').Replace(cSepTripleDashHeavy, ' ')
    .Replace(cSepQuadDashLight, ' ')
    .Replace(cSepQuadDashHeavy, ' ').Replace(cSepFullwidthBar, ' ')
    .Trim;
end;

// Does AToken appear as the first or last space-delimited word of AName?
function TokenMatchesName(const AName, AToken: string): Boolean;
var
  lName, lToken: string;
begin
  lToken := NormSeps(AToken);
  if lToken = '' then
    Exit(False);
  lName := NormSeps(AName);
  Result := SameText(lName, lToken) or StartsText(lToken + ' ', lName) or EndsText(' ' + lToken, lName);
end;

function MatchesAnyToken(const AName: string; const ATokens: TArray<string>): Boolean;
var
  lToken: string;
begin
  for lToken in ATokens do
    if TokenMatchesName(AName, lToken) then
      Exit(True);
  Result := False;
end;

function SplitFilterLines(const ATokens: TArray<string>): TArray<string>;
var
  lToken, lPart: string;
begin
  Result := [];
  for lToken in ATokens do
    // '"' is never part of a name token (see StrArrayToCsv)
    for lPart in lToken.Replace('"', '').Split([#13#10, #10, #13]) do
      if lPart.Trim <> '' then
        Result := Result + [lPart.Trim];
end;

function CleanFilterTokens(const ATokens: TArray<string>): TArray<string>;
var
  lToken: string;
begin
  Result := [];
  for lToken in SplitFilterLines(ATokens) do
    if (Length(lToken) <= MaxFilterTokenLen) and (NormSeps(lToken) <> '') then
      Result := Result + [lToken];
end;

function FirstTooLongFilterToken(const ATokens: TArray<string>): string;
var
  lToken: string;
begin
  for lToken in SplitFilterLines(ATokens) do
    if Length(lToken) > MaxFilterTokenLen then
      Exit(lToken);
  Result := '';
end;

function PrepareTokens(const ATokens: TArray<string>): TArray<string>;
var
  lToken: string;
begin
  Result := [];
  for lToken in CleanFilterTokens(ATokens) do
    Result := Result + [AnsiLowerCase(NormSeps(lToken))];
  TArray.Sort<string>(Result);
end;

function PrepareNameFilter(const AInclude, AExclude: TArray<string>): TPreparedNameFilter;
begin
  Result.Inc := PrepareTokens(AInclude);
  Result.Exc := PrepareTokens(AExclude);
end;

// ANormName = normalised, lower-cased name (N). True when a token equals the whole
// name, or the part before / after one of its spaces — exactly SameText(N,T) or
// StartsText(T+' ',N) or EndsText(' '+T,N) (the word-boundary rule of the SQL).
function NormNameMatchesAny(const ANormName: string; const ATokens: TArray<string>): Boolean;
var
  i, lDummy: Integer;
begin
  if Length(ATokens) = 0 then
    Exit(False);
  if TArray.BinarySearch<string>(ATokens, ANormName, lDummy) then
    Exit(True);
  for i := 1 to Length(ANormName) do
    if ANormName[i] = ' ' then
      if TArray.BinarySearch<string>(ATokens, Copy(ANormName, 1, i - 1), lDummy) or
         TArray.BinarySearch<string>(ATokens, Copy(ANormName, i + 1, MaxInt), lDummy) then
        Exit(True);
  Result := False;
end;

function PreparedNamePasses(const AFilter: TPreparedNameFilter; const AName: string): Boolean;
var
  lNormName: string;
begin
  if (Length(AFilter.Inc) = 0) and (Length(AFilter.Exc) = 0) then
    Exit(True);
  lNormName := AnsiLowerCase(NormSeps(AName));
  if (Length(AFilter.Inc) > 0) and not NormNameMatchesAny(lNormName, AFilter.Inc) then
    Exit(False);
  Result := not NormNameMatchesAny(lNormName, AFilter.Exc);
end;

function PreparedNameExcluded(const AFilter: TPreparedNameFilter; const AName: string): Boolean;
begin
  Result := (Length(AFilter.Exc) > 0) and NormNameMatchesAny(AnsiLowerCase(NormSeps(AName)), AFilter.Exc);
end;

function NamePassesFilters(const AName: string; const AInclude, AExclude: TArray<string>): Boolean;
begin
  Result := PreparedNamePasses(PrepareNameFilter(AInclude, AExclude), AName);
end;

constructor TSourceConfig.Create;
begin
  inherited;
  FEnabled := True;
  FContentTypes := AllContentTypes;
end;

procedure TSourceConfig.Assign(const ASrc: TSourceConfig);
begin
  FId := ASrc.FId;
  FName := ASrc.FName;
  FKind := ASrc.FKind;
  FUrl := ASrc.FUrl;
  FUsername := ASrc.FUsername;
  FPassword := ASrc.FPassword;
  FEpgUrl := ASrc.FEpgUrl;
  FUserAgent := ASrc.FUserAgent;
  FReferer := ASrc.FReferer;
  FForceHls := ASrc.FForceHls;
  FEnabled := ASrc.FEnabled;
  FContentTypes := ASrc.FContentTypes;
  FIncludeFilters := Copy(ASrc.FIncludeFilters);
  FExcludeFilters := Copy(ASrc.FExcludeFilters);
  FStripPrefixes := Copy(ASrc.FStripPrefixes);
  FStripSuffixes := Copy(ASrc.FStripSuffixes);
  FLastRefreshUtc := ASrc.FLastRefreshUtc;
  FAccountStatus := ASrc.FAccountStatus;
  FExpiresUtc := ASrc.FExpiresUtc;
  FMaxConnections := ASrc.FMaxConnections;
  FTzOffsetMin := ASrc.FTzOffsetMin;
  FPreferOwnEpg := ASrc.FPreferOwnEpg;
end;

function TSourceConfig.EnabledFor(AType: TContentType): Boolean;
begin
  Result := FEnabled and (AType in FContentTypes);
end;

function TSourceConfig.PassesNameFilter(const AName: string): Boolean;
begin
  Result := NamePassesFilters(AName, FIncludeFilters, FExcludeFilters);
end;

end.
