unit IPTV.Output.Builder;

{ Builds the curated list's output documents from the store, in canonical order
  (favorite groups first, groups A→Z, channels A→Z). Shared by:
    - the live Xtream-portal endpoints (get.php / xmltv.php),
    - the Plex/Jellyfin surfaces (/plex/... + the HDHomeRun lineup.json), and
    - the admin "export" endpoints that download the same content as files.

  M3U embeds the RAW upstream URL (video never flows through us). XMLTV is
  restricted to the chosen channels' guide ids.

  Global group filter: SelectOutputChannels narrows the list to a set of group
  titles (case-insensitive; empty = all). M3U, XMLTV and the lineup all run through
  it, so the box's three documents describe the identical channel set.

  Guide ids: a channel is published under its effective tvg-id, or — when it has
  none — a stable synthetic id (iptv-<streamItemId>) used identically in the M3U and
  the XMLTV, so dummy EPG couples to id-less channels too.

  Categories: EVERY <programme> (real or dummy) carries a <category> with the
  channel's group-title, so the Plex/Jellyfin guide groups by it. A provider's own
  category (if any) is kept alongside it.

  Dummy EPG: channels with NO real programmes get filler blocks (so Plex/Jellyfin
  don't show "Unknown airing"); channels with real EPG keep their programmes. }

interface

uses
  // own
  IPTV.Storage.Intf,
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.CustomList,
  IPTV.Model.Catalog;

type
  /// Dummy-EPG generation settings (mirrors the config fields). Enabled=False =>
  /// no filler is emitted (behaviour identical to before this feature).
  TDummyEpgOptions = record
    Enabled: Boolean;
    BlockMinutes: Integer; // block length, aligned to whole local hours
    HoursBack: Integer;    // window start, hours before now
    HoursAhead: Integer;   // window end, hours after now
    /// Options with dummy EPG disabled.
    class function Off: TDummyEpgOptions; static;
    /// Options from the individual config values.
    class function Make(AEnabled: Boolean; ABlockMinutes, AHoursBack,
      AHoursAhead: Integer): TDummyEpgOptions; static;
  end;

/// Catch-up: the provider's timeshift URL for a (list-scoped) stream, the start
/// shifted from UTC to the portal's clock. '' when the stream's source is not an
/// Xtream portal (only Xtream exposes /timeshift) or no longer exists.
function TimeshiftUpstreamUrl(const AStore: IStore; const AStream: TStreamItem;
  ADurationMin: Integer; AStartUtc: TDateTime; const AExt: string): string;

/// Load the list's output channels (canonical order) filtered to AGroups
/// (case-insensitive match on the effective group name; empty AGroups => all).
/// Caller owns the returned list.
function SelectOutputChannels(const AStore: IStore; AListId: Integer;
  const AGroups: TArray<string> = nil): TOutputChannelList;

type
  /// How the visible channel name is decorated on the Plex/Jellyfin surfaces (never
  /// the plain box output). Each is off by default and they combine:
  ///   ShowSource → per-provider letter ("A "…, A=1st source) so Plex groups+sorts
  ///                by provider (a leading LETTER isn't stripped like a leading digit)
  ///   ShowNumber → zero-padded sort number in output order ("018 "); resets per
  ///                source when ShowSource is on ("A 018 …", "B 001 …")
  ///   ShowGroup  → the group title ("Sport · ")
  /// giving e.g. "A 018 Sport · NPO 1".
  ///   IdSort     → separately, prefix the published channel-ID with a zero-padded
  ///                sort number + the channel name ("01 NPO 1") — Plex sorts its guide by
  ///                the channel-id, not the name, so THIS is what actually reorders
  ///                it. Re-keys the M3U tvg-id + XMLTV channel/programme ids together.
  TNameOptions = record
    ShowGroup, ShowNumber, ShowSource, IdSort: Boolean;
    /// No decoration at all (the plain box output).
    class function None: TNameOptions; static;
    /// Options from the individual toggles.
    class function Make(AGroup, ANumber, ASource: Boolean; AIdSort: Boolean = False): TNameOptions; static;
    function AnyName: Boolean;   // any of the visible-NAME decorations
    function Any: Boolean;       // any decoration at all (name or id)
  end;

/// Load the list's output channels (canonical order) filtered to AGroups
/// (case-insensitive match on the effective group name; empty AGroups => all).
/// Caller owns the returned list.
// (declared above)

/// The per-channel visible display names for the whole (already-selected) list —
/// the SINGLE source of truth shared by the M3U, the XMLTV and the HDHomeRun
/// lineup, so all three agree. Result[i] corresponds to AChannels[i].
function ComputeDisplayNames(const AStore: IStore; const AChannels: TOutputChannelList;
  const AOpts: TNameOptions): TArray<string>;

/// The per-channel published channel-IDs for the whole (already-selected) list. With
/// AIdSort, each is a zero-padded sort number in output order followed by the
/// channel name ("01 NPO 1") so Plex's id-sort follows the bouquet and the id that
/// Plex shows as the tile title is readable;
/// without it, the plain guide id. Result[i] corresponds to AChannels[i]. Used
/// identically by the M3U (tvg-id) and the XMLTV (channel + programme ids).
function ComputeGuideIds(const AChannels: TOutputChannelList; AIdSort: Boolean): TArray<string>;

/// The channel numbers the media-server surfaces publish (HDHomeRun GuideNumber,
/// Plex tvg-chno, id-sort prefix, number-in-name): the operator's own bouquet
/// numbers when every channel has one (> 0) and they are all distinct (e.g. after
/// "Renumber bouquet": 100…, 200…); otherwise the running position 1,2,3… — Plex
/// rejects duplicate numbers and per-group numbering restarts at 1.
function OutputNumbers(const AChannels: TOutputChannelList): TArray<Integer>;

// AStreamUrlPrefix: when set (proxy mode), each entry's URL becomes
// AStreamUrlPrefix + <streamItemId>.ts; when '' the RAW upstream URL is used.
// ASequentialChno: emit tvg-chno = 1,2,3… in output order (globally UNIQUE) instead
// of the operator's per-group numbers — required by Plex's M3U tuner, which rejects
// a playlist with duplicate channel numbers. AGroups: global group filter.
// ANames: how to decorate the visible name (Plex surfaces only).
function BuildM3U(const AStore: IStore; AListId: Integer; const AStreamUrlPrefix: string = '';
  ASequentialChno: Boolean = False; const AGroups: TArray<string> = nil): string; overload;
/// M3U of the list with a global group filter and display-name decoration (ANames).
function BuildM3U(const AStore: IStore; AListId: Integer; const AStreamUrlPrefix: string;
  ASequentialChno: Boolean; const AGroups: TArray<string>;
  const ANames: TNameOptions): string; overload;
/// M3U over an already-selected channel list. ADisplayNames[i] is the visible name
/// for AChannels[i] (from ComputeDisplayNames); empty => plain upstream names.
/// AGuideIds[i] is the tvg-id for AChannels[i] (from ComputeGuideIds); empty => plain.
function BuildM3UChannels(const AChannels: TOutputChannelList;
  const AStreamUrlPrefix: string; ASequentialChno: Boolean;
  const ADisplayNames: TArray<string> = nil;
  const AGuideIds: TArray<string> = nil): string;

// AMaxDays > 0 caps the guide to that many days ahead (0 = whatever the providers gave).
function BuildXmltv(const AStore: IStore; AListId: Integer; AMaxDays: Integer = 0): string; overload;
/// XMLTV with dummy-EPG filling and an optional global group filter.
function BuildXmltv(const AStore: IStore; AListId, AMaxDays: Integer;
  const ADummy: TDummyEpgOptions; const AGroups: TArray<string> = nil): string; overload;
/// XMLTV with dummy-EPG filling, a global group filter and name/id decoration (ANames).
function BuildXmltv(const AStore: IStore; AListId, AMaxDays: Integer;
  const ADummy: TDummyEpgOptions; const AGroups: TArray<string>;
  const ANames: TNameOptions): string; overload;
/// XMLTV over an already-selected channel list (+ dummy filling). AGuideIds[i] is the
/// published channel-id for AChannels[i] (from ComputeGuideIds); empty => plain ids.
function BuildXmltvChannels(const AStore: IStore; const AChannels: TOutputChannelList;
  AMaxDays: Integer; const ADummy: TDummyEpgOptions;
  const ADisplayNames: TArray<string> = nil;
  const AGuideIds: TArray<string> = nil): string;

/// Extension of a URL's file name ('mkv' for .../123.mkv?x=1), '' if none.
function UrlExt(const AUrl: string): string;

/// AUrl with the file extension in its PATH replaced by AExt (never inside the query).
function SwapUrlExt(const AUrl, AExt: string): string;

/// LIVE only: the upstream URL in the container the box asked for (.ts / .m3u8).
/// Only an Xtream source's .ts/.m3u8 URL is rewritten; any other URL (an M3U HLS
/// playlist, a radio .mp3, a play.php?id=) and every non-live item come back as-is.
function LiveUpstreamUrl(const AStore: IStore; const AStream: TStreamItem; const AExt: string): string;

/// The source with id ASourceId (caller frees), nil when it is gone.
function FindSourceById(const AStore: IStore; ASourceId: Integer): TSourceConfig;

/// Drop (and free) every channel whose content type is not in ATypes.
procedure KeepContentTypes(AChannels: TOutputChannelList; const ATypes: TContentTypes);

/// A list login as a URL PATH segment: percent-encoded (a '/', '?' or '#' in a
/// password would break the path) and '-' for an empty one (an empty segment,
/// /live///12, is dropped or rejected by players and routers).
function PathCred(const AValue: string): string;

/// The list a box logs in as, given credentials taken from a URL path: as-is,
/// else percent-decoded, else '-'/'-' as the empty login. Caller frees; nil = none.
function FindListForPath(const AStore: IStore; const AUser, APass: string): TCustomList;

/// The guide id a channel is published under: its effective tvg-id, or a stable
/// synthetic id (iptv-<streamItemId>) when it has no tvg-id.
function ChannelGuideId(const AChannel: TOutputChannel): string;
/// One channel's display name with a zero-padded sort number (ASeq of ATotal) and/or
/// its group: "[NNN ][Group · ]Name". The per-source letter is layered on separately
/// by ComputeDisplayNames.
function ChannelDisplayName(const AChannel: TOutputChannel;
  AShowGroup, AShowNumber: Boolean; ASeq: Integer = 0; ATotal: Integer = 0): string;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.DateUtils,
  System.StrUtils,
  System.NetEncoding,
  // own
  IPTV.Model.Epg,
  IPTV.Core.Utils;

const
  // stream extensions
  cExtTs = 'ts';
  cExtHls = 'm3u8';

  /// how PathCred writes an empty login field into a URL path
  cPathCredEmpty = '-';
  // RFC 3986 unreserved characters: written as-is by PathCred, all else %XX
  cUrlUnreserved = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'];
  cAsciiLimit = 128;

  // published guide id of a channel without tvg-id: iptv-<streamItemId>
  cSyntheticGuideIdPrefix = 'iptv-';

  // XMLTV timestamps (we always publish UTC)
  cXmltvTimeFormat = 'yyyymmddhhnnss';
  cXmltvUtcOffset = ' +0000';
  cXmlEscapeHeadroom = 16;             // extra builder capacity for entities

  // display-name decoration
  cGroupSeparator = #$B7;              // middle dot; a code point keeps the source ASCII-safe
  cLetterCount = 26;                   // source letters A..Z, then AA, AB, ...

  // content types per output surface
  cLinearContentTypes = [ctLive, ctRadio];          // guide + Plex/Jellyfin tuner
  cBoxContentTypes = [ctLive, ctRadio, ctMovie];    // box M3U (series = container)
  cIdSort = True;                      // ComputeGuideIds: prefix the sort number

  // dummy EPG
  cDummyDescription = 'Live programma';
  cDummyMaxBlocks = 100000;            // guard against a runaway window

function UrlExt(const AUrl: string): string;
var
  lQuery, lDot, lSlash, lPathEnd: Integer;
begin
  Result := '';
  lQuery := AUrl.IndexOf('?');
  if lQuery >= 0 then
    lPathEnd := lQuery
  else
    lPathEnd := AUrl.Length;
  lDot := AUrl.LastIndexOf('.', lPathEnd - 1);
  lSlash := AUrl.LastIndexOf('/', lPathEnd - 1);
  if (lDot > lSlash) and (lDot >= 0) then
    Result := AUrl.Substring(lDot + 1, lPathEnd - lDot - 1);
end;

function SwapUrlExt(const AUrl, AExt: string): string;
var
  lQuery, lDot, lSlash, lPathEnd: Integer;
begin
  Result := AUrl;
  if AExt = '' then
    Exit;
  // only the extension in the PATH; a query value may contain dots too
  lQuery := AUrl.IndexOf('?');
  if lQuery >= 0 then
    lPathEnd := lQuery
  else
    lPathEnd := AUrl.Length;
  lDot := AUrl.LastIndexOf('.', lPathEnd - 1);
  lSlash := AUrl.LastIndexOf('/', lPathEnd - 1);
  if (lDot > lSlash) and (lDot >= 0) then
    Result := AUrl.Substring(0, lDot) + '.' + AExt + AUrl.Substring(lPathEnd);
end;

function FindSourceById(const AStore: IStore; ASourceId: Integer): TSourceConfig;
var
  lSources: TObjectList<TSourceConfig>;
  i: Integer;
begin
  Result := nil;
  lSources := AStore.LoadSources;
  try
    for i := 0 to lSources.Count - 1 do
      if lSources[i].Id = ASourceId then
        Exit(lSources.Extract(lSources[i]));
  finally
    FreeAndNil(lSources);
  end;
end;

function LiveUpstreamUrl(const AStore: IStore; const AStream: TStreamItem; const AExt: string): string;
var
  lSource: TSourceConfig;
  lCurrent: string;
begin
  Result := AStream.UpstreamUrl;
  if (AExt = '') or (AStream.ContentType <> ctLive) then
    Exit;
  lCurrent := UrlExt(Result);
  if not (SameText(lCurrent, cExtTs) or SameText(lCurrent, cExtHls)) then
    Exit;
  lSource := FindSourceById(AStore, AStream.SourceId);
  try
    if (lSource <> nil) and (lSource.Kind = skXtream) then
      Result := SwapUrlExt(Result, AExt);
  finally
    FreeAndNil(lSource);
  end;
end;

procedure KeepContentTypes(AChannels: TOutputChannelList; const ATypes: TContentTypes);
var
  i: Integer;
begin
  for i := AChannels.Count - 1 downto 0 do
    if not (AChannels[i].ContentType in ATypes) then
      AChannels.Delete(i); // owned list: frees it
end;

function TimeshiftUpstreamUrl(const AStore: IStore; const AStream: TStreamItem;
  ADurationMin: Integer; AStartUtc: TDateTime; const AExt: string): string;
var
  lSources: TObjectList<TSourceConfig>;
  lSource: TSourceConfig;
begin
  Result := '';
  if AStream = nil then
    Exit;
  lSources := AStore.LoadSources;
  try
    for lSource in lSources do
      if lSource.Id = AStream.SourceId then
      begin
        if lSource.Kind = skXtream then
          Result := XtreamTimeshiftUrl(lSource.Url, lSource.Username, lSource.Password, ADurationMin,
            AStartUtc, lSource.TzOffsetMin, AStream.UpstreamId, AExt);
        Break;
      end;
  finally
    FreeAndNil(lSources);
  end;
end;

class function TDummyEpgOptions.Off: TDummyEpgOptions;
begin
  Result := Default(TDummyEpgOptions);
  Result.Enabled := False;
end;

class function TNameOptions.None: TNameOptions;
begin
  Result := Default(TNameOptions);
end;

class function TNameOptions.Make(AGroup, ANumber, ASource: Boolean; AIdSort: Boolean): TNameOptions;
begin
  Result.ShowGroup := AGroup;
  Result.ShowNumber := ANumber;
  Result.ShowSource := ASource;
  Result.IdSort := AIdSort;
end;

function TNameOptions.AnyName: Boolean;
begin
  Result := ShowGroup or ShowNumber or ShowSource;
end;

function TNameOptions.Any: Boolean;
begin
  Result := AnyName or IdSort;
end;

class function TDummyEpgOptions.Make(AEnabled: Boolean; ABlockMinutes, AHoursBack,
  AHoursAhead: Integer): TDummyEpgOptions;
begin
  Result.Enabled := AEnabled;
  Result.BlockMinutes := ABlockMinutes;
  Result.HoursBack := AHoursBack;
  Result.HoursAhead := AHoursAhead;
end;

function XmlEscape(const AValue: string): string;
var
  lSB: TStringBuilder;
  lCh: Char;
begin
  // control characters (other than tab/CR/LF) are not allowed in XML 1.0 at all:
  // one stray #1 in a provider title made strict guide parsers reject the file
  lSB := TStringBuilder.Create(AValue.Length + cXmlEscapeHeadroom);
  try
    for lCh in AValue do
      case lCh of
        '&': lSB.Append('&amp;');
        '<': lSB.Append('&lt;');
        '>': lSB.Append('&gt;');
        '"': lSB.Append('&quot;');
        #9, #10, #13: lSB.Append(lCh);
        #0..#8, #11, #12, #14..#31, #$FFFE, #$FFFF: ; // dropped
      else
        lSB.Append(lCh);
      end;
    Result := lSB.ToString;
  finally
    FreeAndNil(lSB);
  end;
end;

function PathCred(const AValue: string): string;
var
  lBytes: TBytes;
  i: Integer;
begin
  if AValue = '' then
    Exit(cPathCredEmpty);
  Result := '';
  lBytes := TEncoding.UTF8.GetBytes(AValue);
  for i := 0 to High(lBytes) do
    if (lBytes[i] < cAsciiLimit) and CharInSet(Char(lBytes[i]), cUrlUnreserved) then
      Result := Result + Char(lBytes[i])
    else
      Result := Result + '%' + IntToHex(lBytes[i], 2);
end;

function FindListForPath(const AStore: IStore; const AUser, APass: string): TCustomList;
var
  lUser, lPass: string;

  function Dash(const AValue: string): string;
  begin
    if AValue = cPathCredEmpty then
      Result := ''
    else
      Result := AValue;
  end;

begin
  Result := AStore.FindListByCredentials(AUser, APass);
  if Result <> nil then
    Exit;
  lUser := AUser;
  lPass := APass;
  if AUser.Contains('%') or APass.Contains('%') then
  begin
    try
      lUser := TNetEncoding.URL.URLDecode(AUser);
      lPass := TNetEncoding.URL.URLDecode(APass);
      Result := AStore.FindListByCredentials(lUser, lPass);
      if Result <> nil then
        Exit;
    except
      Exit(nil); // malformed escape
    end;
  end;
  // PathCred writes '-' for EACH empty field (a login with only a username too)
  if (lUser = cPathCredEmpty) or (lPass = cPathCredEmpty) then
    Result := AStore.FindListByCredentials(Dash(lUser), Dash(lPass));
end;

function XmltvTime(const ADtUtc: TDateTime): string;
begin
  if ADtUtc = 0 then
    Exit('');
  Result := FormatDateTime(cXmltvTimeFormat, ADtUtc) + cXmltvUtcOffset;
end;

// Make a value safe to drop inside a double-quoted #EXTINF attribute (and the
// trailing display name): strip the characters that would break the line —
// double-quotes and any CR/LF. (XMLTV output is escaped separately via XmlEscape.)
function M3uSafe(const AValue: string): string;
begin
  Result := AValue.Replace('"', '''', [rfReplaceAll])
             .Replace(#13, ' ', [rfReplaceAll])
             .Replace(#10, ' ', [rfReplaceAll]);
end;

function ChannelGuideId(const AChannel: TOutputChannel): string;
begin
  if AChannel.TvgId <> '' then
    Result := AChannel.TvgId
  else
    Result := cSyntheticGuideIdPrefix + AChannel.StreamItemId.ToString;
end;

function ChannelDisplayName(const AChannel: TOutputChannel;
  AShowGroup, AShowNumber: Boolean; ASeq, ATotal: Integer): string;
var
  lWidth: Integer;
  lNumStr: string;
begin
  Result := AChannel.Name;
  // Compute the zero-padded number FIRST (same value as the lineup GuideNumber:
  // ASeq is the channel's 1-based position; width from the highest number ATotal).
  lNumStr := '';
  if AShowNumber and (ASeq > 0) then
  begin
    if ATotal < ASeq then
      ATotal := ASeq;
    lWidth := Length(IntToStr(ATotal));
    lNumStr := IntToStr(ASeq).PadLeft(lWidth, '0');
    // Idempotent: if the name already begins with exactly this number, don't
    // add it again (so re-processing or provider-numbered names don't double up).
    if Result.StartsWith(lNumStr + ' ') then
      lNumStr := '';
  end;
  if AShowGroup and (AChannel.GroupName <> '') then
    Result := AChannel.GroupName + ' ' + cGroupSeparator + ' ' + Result;
  // zero-padded running number FIRST, so a name-sort yields the output order
  if lNumStr <> '' then
    Result := lNumStr + ' ' + Result;
end;

// Excel-column-style letters for a 0-based index: 0→A … 25→Z, 26→AA, 27→AB …
// (only reached beyond 26 sources; keeps every letter sortable/unique).
function SourceLetter(AIndex: Integer): string;
begin
  Result := '';
  Inc(AIndex); // 1-based
  while AIndex > 0 do
  begin
    Dec(AIndex);
    Result := Chr(Ord('A') + (AIndex mod cLetterCount)) + Result;
    AIndex := AIndex div cLetterCount;
  end;
end;

// source_id -> letter, assigned in the order LoadSources returns the providers
// (A = 1st source, B = 2nd, …). Caller frees.
function SourceLetterMap(const AStore: IStore): TDictionary<Integer, string>;
var
  lSources: TObjectList<TSourceConfig>;
  i: Integer;
begin
  Result := TDictionary<Integer, string>.Create;
  lSources := AStore.LoadSources;
  try
    for i := 0 to lSources.Count - 1 do
      Result.AddOrSetValue(lSources[i].Id, SourceLetter(i));
  finally
    FreeAndNil(lSources);
  end;
end;

function OutputNumbers(const AChannels: TOutputChannelList): TArray<Integer>;
var
  lSeen: TDictionary<Integer, Boolean>;
  i: Integer;
  lOwn: Boolean;
begin
  SetLength(Result, AChannels.Count);
  lOwn := AChannels.Count > 0;
  lSeen := TDictionary<Integer, Boolean>.Create;
  try
    for i := 0 to AChannels.Count - 1 do
    begin
      if (AChannels[i].Number <= 0) or lSeen.ContainsKey(AChannels[i].Number) then
      begin
        lOwn := False;
        Break;
      end;
      lSeen.Add(AChannels[i].Number, True);
    end;
  finally
    FreeAndNil(lSeen);
  end;
  for i := 0 to AChannels.Count - 1 do
    if lOwn then
      Result[i] := AChannels[i].Number
    else
      Result[i] := i + 1;
end;

function MaxOf(const AValues: TArray<Integer>): Integer;
var
  lValue: Integer;
begin
  Result := 0;
  for lValue in AValues do
    if lValue > Result then
      Result := lValue;
end;

function ComputeDisplayNames(const AStore: IStore; const AChannels: TOutputChannelList;
  const AOpts: TNameOptions): TArray<string>;
var
  lNums: TArray<Integer>;
  lLetters: TDictionary<Integer, string>;
  lPerSource: TDictionary<Integer, Integer>;
  i, lSeq, lTotal: Integer;
  lChannel: TOutputChannel;
  lName, lLetter: string;
begin
  SetLength(Result, AChannels.Count);
  lNums := OutputNumbers(AChannels);
  lTotal := MaxOf(lNums);
  lLetters := nil;
  lPerSource := nil;
  try
    if AOpts.ShowSource then
      lLetters := SourceLetterMap(AStore);
    lPerSource := TDictionary<Integer, Integer>.Create;
    for i := 0 to AChannels.Count - 1 do
    begin
      lChannel := AChannels[i];
      // number runs per-source when the source letter groups them, else globally
      if AOpts.ShowSource then
      begin
        lSeq := 0;
        lPerSource.TryGetValue(lChannel.SourceId, lSeq);
        Inc(lSeq);
        lPerSource.AddOrSetValue(lChannel.SourceId, lSeq);
      end
      else
        lSeq := lNums[i]; // bouquet number (or position) — same as GuideNumber/tvg-chno
      lName := ChannelDisplayName(lChannel, AOpts.ShowGroup, AOpts.ShowNumber, lSeq, lTotal);
      // per-source letter FIRST (a leading letter isn't stripped by Plex the way a
      // leading digit is, so it actually drives the sort → group by provider)
      if AOpts.ShowSource and (lLetters <> nil) then
      begin
        lLetter := '';
        if lLetters.TryGetValue(lChannel.SourceId, lLetter) and (lLetter <> '') and
           not lName.StartsWith(lLetter + ' ') then
          lName := lLetter + ' ' + lName;
      end;
      Result[i] := lName;
    end;
  finally
    FreeAndNil(lPerSource);
    FreeAndNil(lLetters);
  end;
end;

function ComputeGuideIds(const AChannels: TOutputChannelList; AIdSort: Boolean): TArray<string>;
var
  i, lWidth: Integer;
  lBase: string;
  lNums: TArray<Integer>;
begin
  SetLength(Result, AChannels.Count);
  lNums := OutputNumbers(AChannels);
  lWidth := Length(IntToStr(MaxOf(lNums)));
  if lWidth < 1 then
    lWidth := 1;
  for i := 0 to AChannels.Count - 1 do
  begin
    lBase := ChannelGuideId(AChannels[i]);
    if AIdSort then
    begin
      // zero-padded sort number in front so a string-sort of the id = bouquet order.
      // Plex SHOWS this id as the channel title in its Live TV tiles, so the number is
      // followed by the readable channel name ("01 NPO 1"), not the raw tvg-id; the
      // unique sort number alone keeps distinct channels distinct.
      if Trim(AChannels[i].Name) <> '' then
        lBase := Trim(AChannels[i].Name);
      Result[i] := IntToStr(lNums[i]).PadLeft(lWidth, '0') + ' ' + lBase;
    end
    else
      Result[i] := lBase;
  end;
end;

function SelectOutputChannels(const AStore: IStore; AListId: Integer;
  const AGroups: TArray<string>): TOutputChannelList;
var
  lAll: TOutputChannelList;
  lChannel: TOutputChannel;
  lKeep: TStringList;
  lKept: TList<TOutputChannel>;
  lGroup: string;
begin
  lAll := AStore.LoadOutputChannels(AListId);
  if Length(AGroups) = 0 then
    Exit(lAll); // no filter — hand the full list straight back (caller owns it)
  Result := TOutputChannelList.Create(True);
  lKeep := nil;
  lKept := nil;
  try
    lKeep := TStringList.Create;
    lKept := TList<TOutputChannel>.Create;
    lKeep.CaseSensitive := False;
    lKeep.Sorted := True;
    lKeep.Duplicates := dupIgnore;
    for lGroup in AGroups do
      if lGroup.Trim <> '' then
        lKeep.Add(lGroup.Trim);
    // note the matches in canonical order, then move them over (Extract leaves the
    // non-kept channels in All so its Free disposes of exactly those)
    for lChannel in lAll do
      if lKeep.IndexOf(lChannel.GroupName) >= 0 then
        lKept.Add(lChannel);
    for lChannel in lKept do
    begin
      lAll.Extract(lChannel); // detach without freeing
      Result.Add(lChannel);  // Result now owns it
    end;
  finally
    FreeAndNil(lKept);
    FreeAndNil(lKeep);
    FreeAndNil(lAll); // frees the channels left behind (the non-kept ones)
  end;
end;

function BuildM3UChannels(const AChannels: TOutputChannelList;
  const AStreamUrlPrefix: string; ASequentialChno: Boolean;
  const ADisplayNames: TArray<string>; const AGuideIds: TArray<string>): string;
var
  lChannel: TOutputChannel;
  lSB: TStringBuilder;
  lChno, lDName, lTvgId, lCatchup: string;
  lSeq: Integer;
  lNums: TArray<Integer>;
begin
  lNums := OutputNumbers(AChannels);
  lSB := TStringBuilder.Create;
  try
    lSB.AppendLine('#EXTM3U');
    lSeq := 0;
    for lChannel in AChannels do
    begin
      Inc(lSeq);
      if ASequentialChno then
        // globally-unique running number (Plex M3U tuner needs no duplicates)
        lChno := Format(' tvg-chno="%d"', [lNums[lSeq - 1]])
      else if lChannel.Number > 0 then
        // convey the operator's channel number (drag/sort-by-Nr) to M3U players
        lChno := Format(' tvg-chno="%d"', [lChannel.Number])
      else
        lChno := '';
      if (lSeq - 1 <= High(ADisplayNames)) and (Length(ADisplayNames) > 0) then
        lDName := ADisplayNames[lSeq - 1] // pre-computed decorated name (Plex surfaces)
      else
        lDName := lChannel.Name;            // plain upstream name (box output)
      if (lSeq - 1 <= High(AGuideIds)) and (Length(AGuideIds) > 0) then
        lTvgId := AGuideIds[lSeq - 1]       // pre-computed (maybe sort-prefixed) id
      else
        lTvgId := ChannelGuideId(lChannel);
      // catch-up for box players (TiviMate / OTT Navigator): "xc" = derive the
      // Xtream /timeshift/ URL from the stream URL — that is the provider's own
      // (direct) or our relay, which serves /timeshift/ as well. Plex ignores it.
      if (not ASequentialChno) and (lChannel.ContentType = ctLive) and (lChannel.ArchiveDays > 0) then
        lCatchup := Format(' catchup="xc" catchup-days="%d"', [lChannel.ArchiveDays])
      else
        lCatchup := '';
      lSB.AppendFormat('#EXTINF:-1 tvg-id="%s"%s tvg-name="%s" tvg-logo="%s" group-title="%s"%s,%s'#10,
        [M3uSafe(lTvgId), lChno, M3uSafe(lDName), M3uSafe(lChannel.Logo),
         M3uSafe(lChannel.GroupName), lCatchup, M3uSafe(lDName)]);
      if AStreamUrlPrefix <> '' then
        lSB.AppendLine(AStreamUrlPrefix + lChannel.StreamItemId.ToString + '.' + cExtTs) // via our proxy
      else
        lSB.AppendLine(lChannel.UpstreamUrl); // RAW upstream URL — box talks straight to the provider
    end;
    Result := lSB.ToString;
  finally
    FreeAndNil(lSB);
  end;
end;

function BuildM3U(const AStore: IStore; AListId: Integer; const AStreamUrlPrefix: string;
  ASequentialChno: Boolean; const AGroups: TArray<string>): string;
begin
  Result := BuildM3U(AStore, AListId, AStreamUrlPrefix, ASequentialChno, AGroups, TNameOptions.None);
end;

function BuildM3U(const AStore: IStore; AListId: Integer; const AStreamUrlPrefix: string;
  ASequentialChno: Boolean; const AGroups: TArray<string>;
  const ANames: TNameOptions): string;
var
  lChannels: TOutputChannelList;
  lNames, lIds: TArray<string>;
begin
  lChannels := SelectOutputChannels(AStore, AListId, AGroups);
  try
    // a series item is a container (get_series_info), not a playable file; the
    // Plex/Jellyfin tuner (sequential numbers) only takes linear channels
    if ASequentialChno then
      KeepContentTypes(lChannels, cLinearContentTypes)
    else
      KeepContentTypes(lChannels, cBoxContentTypes);
    lNames := nil;
    if ANames.AnyName then
      lNames := ComputeDisplayNames(AStore, lChannels, ANames);
    lIds := nil;
    if ANames.IdSort then
      lIds := ComputeGuideIds(lChannels, cIdSort);
    Result := BuildM3UChannels(lChannels, AStreamUrlPrefix, ASequentialChno, lNames, lIds);
  finally
    FreeAndNil(lChannels);
  end;
end;

// floor a local TDateTime to the whole hour
function FloorToHour(const ADt: TDateTime): TDateTime;
begin
  Result := Int(ADt * HoursPerDay) / HoursPerDay;
end;

// Emit dummy <programme> blocks for one channel across the configured window.
// Stepped in UTC on whole hours: local time has a gap at the spring DST change
// (ToUniversalTime raised ELocalTimeInvalid there) and a double hour in autumn.
procedure AppendDummy(ASB: TStringBuilder; const AGuideId, AName, ACategory: string;
  const ADummy: TDummyEpgOptions);
var
  lNowU, lBlockDays, lEndU, lBlock, lStopU: TDateTime;
  lGuard: Integer;
begin
  if ADummy.BlockMinutes <= 0 then
    Exit;
  lNowU := NowUtc;
  lBlockDays := ADummy.BlockMinutes / MinsPerDay;
  lBlock := FloorToHour(IncHour(lNowU, -ADummy.HoursBack));
  lEndU := IncHour(lNowU, ADummy.HoursAhead);
  lGuard := 0;
  while (lBlock < lEndU) and (lGuard < cDummyMaxBlocks) do
  begin
    Inc(lGuard);
    lStopU := lBlock + lBlockDays;
    ASB.AppendFormat(
      '  <programme start="%s" stop="%s" channel="%s"><title>%s</title><desc>%s</desc>' +
      '<category>%s</category></programme>'#10,
      [XmltvTime(lBlock), XmltvTime(lStopU),
       XmlEscape(AGuideId), XmlEscape(AName), XmlEscape(cDummyDescription), XmlEscape(ACategory)]);
    lBlock := lStopU;
  end;
end;

function BuildXmltvChannels(const AStore: IStore; const AChannels: TOutputChannelList;
  AMaxDays: Integer; const ADummy: TDummyEpgOptions; const ADisplayNames: TArray<string>;
  const AGuideIds: TArray<string>): string;
var
  lChannel: TOutputChannel;
  lUpstreams, lSeenEff: TStringList;
  lEffById: TDictionary<string, TArray<string>>; // upstream tvg-id -> published id
  lGroupById: TDictionary<string, string>; // published id -> group-title (category)
  lNameById: TDictionary<string, string>;  // published id -> display name (dummy title)
  lGotEpg: TStringList;                     // published ids that received ≥1 real programme
  lProgs: TEpgProgrammeList;
  lProg: TEpgProgramme;
  lSB: TStringBuilder;
  lChannelLabel, lGid, lGrp, lDName, lRId: string;
  lPubs: TArray<string>;
  i, lSeq: Integer;
begin
  lUpstreams := nil;
  lSeenEff := nil;
  lGotEpg := nil;
  lEffById := nil;
  lGroupById := nil;
  lNameById := nil;
  lSB := nil;
  try
    lUpstreams := TStringList.Create;
    lUpstreams.Sorted := True;
    lUpstreams.Duplicates := dupIgnore;
    lSeenEff := TStringList.Create;
    lSeenEff.Sorted := True;
    lSeenEff.Duplicates := dupIgnore;
    lGotEpg := TStringList.Create;
    lGotEpg.Sorted := True;
    lGotEpg.Duplicates := dupIgnore;
    lEffById := TDictionary<string, TArray<string>>.Create;
    lGroupById := TDictionary<string, string>.Create;
    lNameById := TDictionary<string, string>.Create;
    lSB := TStringBuilder.Create;
    lSB.AppendLine('<?xml version="1.0" encoding="UTF-8"?>');
    lSB.AppendLine('<tv generator-info-name="IPTVPlay">');
    lSeq := 0;
    for lChannel in AChannels do
    begin
      Inc(lSeq); // position, to index the pre-computed display name / id
      if (lSeq - 1 <= High(AGuideIds)) and (Length(AGuideIds) > 0) then
        lGid := AGuideIds[lSeq - 1] // pre-computed (maybe sort-prefixed) published id
      else
        lGid := ChannelGuideId(lChannel);
      // an override relabels the guide: advertise the published id, and pull EPG
      // stored under EITHER the upstream id OR the effective id (or the matched
      // extra guide), re-keyed to it. One stored id can feed several channels.
      for lRId in lChannel.EpgReadIds do
      begin
        if not lEffById.TryGetValue(lRId, lPubs) then
          lPubs := nil;
        if IndexStr(lGid, lPubs) < 0 then
          lEffById.AddOrSetValue(lRId, lPubs + [lGid]);
        lUpstreams.Add(lRId);
      end;
      // one <channel> per distinct published id; remember group + name (first seen)
      if lSeenEff.IndexOf(lGid) < 0 then
      begin
        lSeenEff.Add(lGid);
        if (lSeq - 1 <= High(ADisplayNames)) and (Length(ADisplayNames) > 0) then
          lDName := ADisplayNames[lSeq - 1] // pre-computed decorated name (same as M3U/lineup)
        else
          lDName := lChannel.Name;
        lGroupById.AddOrSetValue(lGid, lChannel.GroupName);
        lNameById.AddOrSetValue(lGid, lDName);
        // <icon>: Plex takes the channel logo from the XMLTV guide (the HDHomeRun
        // lineup has no logo field), so publish the effective logo here too
        if lChannel.Logo <> '' then
          lSB.AppendFormat('  <channel id="%s"><display-name>%s</display-name><icon src="%s"/></channel>'#10,
            [XmlEscape(lGid), XmlEscape(lDName), XmlEscape(lChannel.Logo)])
        else
          lSB.AppendFormat('  <channel id="%s"><display-name>%s</display-name></channel>'#10,
            [XmlEscape(lGid), XmlEscape(lDName)]);
      end;
    end;

    lProgs := AStore.LoadEpgForTvgIds(lUpstreams.ToStringArray, AMaxDays);
    try
      for i := 0 to lProgs.Count - 1 do
      begin
        lProg := lProgs[i];
        // re-key the stored (upstream-id) programme to every published id using it
        if not lEffById.TryGetValue(lProg.ChannelTvgId, lPubs) then
          lPubs := [lProg.ChannelTvgId];
        for lChannelLabel in lPubs do
        begin
          lGotEpg.Add(lChannelLabel); // this published id has real data — no dummy for it
          lSB.AppendFormat('  <programme start="%s" stop="%s" channel="%s"><title>%s</title><desc>%s</desc>',
            [XmltvTime(lProg.StartUtc), XmltvTime(lProg.StopUtc), XmlEscape(lChannelLabel),
             XmlEscape(lProg.Title), XmlEscape(lProg.Description)]);
          // keep the provider's own category (if any) ...
          if lProg.Category <> '' then
            lSB.AppendFormat('<category>%s</category>', [XmlEscape(lProg.Category)]);
          // ... and ALWAYS add the group-title category (the guide's grouping), unless
          // it would just duplicate the provider one
          if lGroupById.TryGetValue(lChannelLabel, lGrp) and (lGrp <> '') and
             not SameText(lGrp, lProg.Category) then
            lSB.AppendFormat('<category>%s</category>', [XmlEscape(lGrp)]);
          lSB.AppendLine('</programme>');
        end;
      end;
    finally
      FreeAndNil(lProgs);
    end;

    // fill the gaps: every published id with no real programme gets dummy blocks
    if ADummy.Enabled then
      for i := 0 to lSeenEff.Count - 1 do
      begin
        lGid := lSeenEff[i];
        if lGotEpg.IndexOf(lGid) < 0 then
          AppendDummy(lSB, lGid, lNameById[lGid], lGroupById[lGid], ADummy);
      end;

    lSB.AppendLine('</tv>');
    Result := lSB.ToString;
  finally
    FreeAndNil(lSB);
    FreeAndNil(lUpstreams);
    FreeAndNil(lSeenEff);
    FreeAndNil(lGotEpg);
    FreeAndNil(lEffById);
    FreeAndNil(lGroupById);
    FreeAndNil(lNameById);
  end;
end;

function BuildXmltv(const AStore: IStore; AListId, AMaxDays: Integer;
  const ADummy: TDummyEpgOptions; const AGroups: TArray<string>): string;
begin
  Result := BuildXmltv(AStore, AListId, AMaxDays, ADummy, AGroups, TNameOptions.None);
end;

function BuildXmltv(const AStore: IStore; AListId, AMaxDays: Integer;
  const ADummy: TDummyEpgOptions; const AGroups: TArray<string>;
  const ANames: TNameOptions): string;
var
  lChannels: TOutputChannelList;
  lNames, lIds: TArray<string>;
begin
  lChannels := SelectOutputChannels(AStore, AListId, AGroups);
  try
    KeepContentTypes(lChannels, cLinearContentTypes); // a guide is for linear channels only
    lNames := nil;
    if ANames.AnyName then
      lNames := ComputeDisplayNames(AStore, lChannels, ANames);
    lIds := nil;
    if ANames.IdSort then
      lIds := ComputeGuideIds(lChannels, cIdSort);
    Result := BuildXmltvChannels(AStore, lChannels, AMaxDays, ADummy, lNames, lIds);
  finally
    FreeAndNil(lChannels);
  end;
end;

function BuildXmltv(const AStore: IStore; AListId: Integer; AMaxDays: Integer): string;
begin
  Result := BuildXmltv(AStore, AListId, AMaxDays, TDummyEpgOptions.Off);
end;

end.
