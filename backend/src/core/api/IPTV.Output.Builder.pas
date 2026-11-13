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
  IPTV.Storage.Intf, IPTV.Model.CustomList, IPTV.Model.Catalog;

type
  /// Dummy-EPG generation settings (mirrors the config fields). Enabled=False =>
  /// no filler is emitted (behaviour identical to before this feature).
  TDummyEpgOptions = record
    Enabled: Boolean;
    BlockMinutes: Integer; // block length, aligned to whole local hours
    HoursBack: Integer;    // window start, hours before now
    HoursAhead: Integer;   // window end, hours after now
    class function Off: TDummyEpgOptions; static;
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
    class function None: TNameOptions; static;
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
function BuildXmltv(const AStore: IStore; AListId, AMaxDays: Integer;
  const ADummy: TDummyEpgOptions; const AGroups: TArray<string>;
  const ANames: TNameOptions): string; overload;
/// XMLTV over an already-selected channel list (+ dummy filling). AGuideIds[i] is the
/// published channel-id for AChannels[i] (from ComputeGuideIds); empty => plain ids.
function BuildXmltvChannels(const AStore: IStore; const AChannels: TOutputChannelList;
  AMaxDays: Integer; const ADummy: TDummyEpgOptions;
  const ADisplayNames: TArray<string> = nil;
  const AGuideIds: TArray<string> = nil): string;

/// A list login as a URL PATH segment: percent-encoded (a '/', '?' or '#' in a
/// password would break the path) and '-' for an empty one (an empty segment,
/// /live///12, is dropped or rejected by players and routers).
function PathCred(const S: string): string;

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
  System.SysUtils, System.Classes, System.Generics.Collections, System.DateUtils, System.StrUtils,
  System.NetEncoding,
  IPTV.Model.Types, IPTV.Model.Epg, IPTV.Model.Source, IPTV.Core.Utils;

function TimeshiftUpstreamUrl(const AStore: IStore; const AStream: TStreamItem;
  ADurationMin: Integer; AStartUtc: TDateTime; const AExt: string): string;
var
  Sources: TObjectList<TSourceConfig>;
  S: TSourceConfig;
begin
  Result := '';
  if AStream = nil then
    Exit;
  Sources := AStore.LoadSources;
  try
    for S in Sources do
      if S.Id = AStream.SourceId then
      begin
        if S.Kind = skXtream then
          Result := XtreamTimeshiftUrl(S.Url, S.Username, S.Password, ADurationMin,
            AStartUtc, S.TzOffsetMin, AStream.UpstreamId, AExt);
        Break;
      end;
  finally
    Sources.Free;
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

function XmlEscape(const S: string): string;
var
  SB: TStringBuilder;
  Ch: Char;
begin
  // control characters (other than tab/CR/LF) are not allowed in XML 1.0 at all:
  // one stray #1 in a provider title made strict guide parsers reject the file
  SB := TStringBuilder.Create(S.Length + 16);
  try
    for Ch in S do
      case Ch of
        '&': SB.Append('&amp;');
        '<': SB.Append('&lt;');
        '>': SB.Append('&gt;');
        '"': SB.Append('&quot;');
        #9, #10, #13: SB.Append(Ch);
        #0..#8, #11, #12, #14..#31, #$FFFE, #$FFFF: ; // dropped
      else
        SB.Append(Ch);
      end;
    Result := SB.ToString;
  finally
    SB.Free;
  end;
end;

function PathCred(const S: string): string;
const
  Unreserved = ['A'..'Z', 'a'..'z', '0'..'9', '-', '.', '_', '~'];
var
  B: TBytes;
  I: Integer;
begin
  if S = '' then
    Exit('-');
  Result := '';
  B := TEncoding.UTF8.GetBytes(S);
  for I := 0 to High(B) do
    if (B[I] < 128) and CharInSet(Char(B[I]), Unreserved) then
      Result := Result + Char(B[I])
    else
      Result := Result + '%' + IntToHex(B[I], 2);
end;

function FindListForPath(const AStore: IStore; const AUser, APass: string): TCustomList;
var
  U, P: string;
begin
  Result := AStore.FindListByCredentials(AUser, APass);
  if (Result = nil) and (AUser.Contains('%') or APass.Contains('%')) then
  begin
    try
      U := TNetEncoding.URL.URLDecode(AUser);
      P := TNetEncoding.URL.URLDecode(APass);
    except
      Exit(nil);
    end;
    Result := AStore.FindListByCredentials(U, P);
  end;
  if (Result = nil) and (AUser = '-') and (APass = '-') then
    Result := AStore.FindListByCredentials('', '');
end;

function XmltvTime(const ADtUtc: TDateTime): string;
begin
  if ADtUtc = 0 then
    Exit('');
  Result := FormatDateTime('yyyymmddhhnnss', ADtUtc) + ' +0000';
end;

// Make a value safe to drop inside a double-quoted #EXTINF attribute (and the
// trailing display name): strip the characters that would break the line —
// double-quotes and any CR/LF. (XMLTV output is escaped separately via XmlEscape.)
function M3uSafe(const S: string): string;
begin
  Result := S.Replace('"', '''', [rfReplaceAll])
             .Replace(#13, ' ', [rfReplaceAll])
             .Replace(#10, ' ', [rfReplaceAll]);
end;

function ChannelGuideId(const AChannel: TOutputChannel): string;
begin
  if AChannel.TvgId <> '' then
    Result := AChannel.TvgId
  else
    Result := 'iptv-' + AChannel.StreamItemId.ToString;
end;

function ChannelDisplayName(const AChannel: TOutputChannel;
  AShowGroup, AShowNumber: Boolean; ASeq, ATotal: Integer): string;
var
  Width: Integer;
  NumStr: string;
begin
  Result := AChannel.Name;
  // Compute the zero-padded number FIRST (same value as the lineup GuideNumber:
  // ASeq is the channel's 1-based position; width from the highest number ATotal).
  NumStr := '';
  if AShowNumber and (ASeq > 0) then
  begin
    if ATotal < ASeq then
      ATotal := ASeq;
    Width := Length(IntToStr(ATotal));
    NumStr := IntToStr(ASeq).PadLeft(Width, '0');
    // Idempotent: if the name already begins with exactly this number, don't
    // add it again (so re-processing or provider-numbered names don't double up).
    if Result.StartsWith(NumStr + ' ') then
      NumStr := '';
  end;
  // #$B7 = middle dot (·); kept as a code point so the source stays ASCII-safe
  if AShowGroup and (AChannel.GroupName <> '') then
    Result := AChannel.GroupName + ' ' + #$B7 + ' ' + Result;
  // zero-padded running number FIRST, so a name-sort yields the output order
  if NumStr <> '' then
    Result := NumStr + ' ' + Result;
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
    Result := Chr(Ord('A') + (AIndex mod 26)) + Result;
    AIndex := AIndex div 26;
  end;
end;

// source_id -> letter, assigned in the order LoadSources returns the providers
// (A = 1st source, B = 2nd, …). Caller frees.
function SourceLetterMap(const AStore: IStore): TDictionary<Integer, string>;
var
  Sources: TObjectList<TSourceConfig>;
  I: Integer;
begin
  Result := TDictionary<Integer, string>.Create;
  Sources := AStore.LoadSources;
  try
    for I := 0 to Sources.Count - 1 do
      Result.AddOrSetValue(Sources[I].Id, SourceLetter(I));
  finally
    Sources.Free;
  end;
end;

function OutputNumbers(const AChannels: TOutputChannelList): TArray<Integer>;
var
  Seen: TDictionary<Integer, Boolean>;
  I: Integer;
  Own: Boolean;
begin
  SetLength(Result, AChannels.Count);
  Own := AChannels.Count > 0;
  Seen := TDictionary<Integer, Boolean>.Create;
  try
    for I := 0 to AChannels.Count - 1 do
    begin
      if (AChannels[I].Number <= 0) or Seen.ContainsKey(AChannels[I].Number) then
      begin
        Own := False;
        Break;
      end;
      Seen.Add(AChannels[I].Number, True);
    end;
  finally
    Seen.Free;
  end;
  for I := 0 to AChannels.Count - 1 do
    if Own then
      Result[I] := AChannels[I].Number
    else
      Result[I] := I + 1;
end;

function MaxOf(const A: TArray<Integer>): Integer;
var
  V: Integer;
begin
  Result := 0;
  for V in A do
    if V > Result then
      Result := V;
end;

function ComputeDisplayNames(const AStore: IStore; const AChannels: TOutputChannelList;
  const AOpts: TNameOptions): TArray<string>;
var
  Nums: TArray<Integer>;
  Letters: TDictionary<Integer, string>;
  PerSource: TDictionary<Integer, Integer>;
  I, Seq, Total: Integer;
  C: TOutputChannel;
  Nm, L: string;
begin
  SetLength(Result, AChannels.Count);
  Nums := OutputNumbers(AChannels);
  Total := MaxOf(Nums);
  Letters := nil;
  if AOpts.ShowSource then
    Letters := SourceLetterMap(AStore);
  PerSource := TDictionary<Integer, Integer>.Create;
  try
    for I := 0 to AChannels.Count - 1 do
    begin
      C := AChannels[I];
      // number runs per-source when the source letter groups them, else globally
      if AOpts.ShowSource then
      begin
        Seq := 0;
        PerSource.TryGetValue(C.SourceId, Seq);
        Inc(Seq);
        PerSource.AddOrSetValue(C.SourceId, Seq);
      end
      else
        Seq := Nums[I]; // bouquet number (or position) — same as GuideNumber/tvg-chno
      Nm := ChannelDisplayName(C, AOpts.ShowGroup, AOpts.ShowNumber, Seq, Total);
      // per-source letter FIRST (a leading letter isn't stripped by Plex the way a
      // leading digit is, so it actually drives the sort → group by provider)
      if AOpts.ShowSource and (Letters <> nil) then
      begin
        L := '';
        if Letters.TryGetValue(C.SourceId, L) and (L <> '') and
           not Nm.StartsWith(L + ' ') then
          Nm := L + ' ' + Nm;
      end;
      Result[I] := Nm;
    end;
  finally
    PerSource.Free;
    Letters.Free;
  end;
end;

function ComputeGuideIds(const AChannels: TOutputChannelList; AIdSort: Boolean): TArray<string>;
var
  I, Width: Integer;
  Base: string;
  Nums: TArray<Integer>;
begin
  SetLength(Result, AChannels.Count);
  Nums := OutputNumbers(AChannels);
  Width := Length(IntToStr(MaxOf(Nums)));
  if Width < 1 then
    Width := 1;
  for I := 0 to AChannels.Count - 1 do
  begin
    Base := ChannelGuideId(AChannels[I]);
    if AIdSort then
    begin
      // zero-padded sort number in front so a string-sort of the id = bouquet order.
      // Plex SHOWS this id as the channel title in its Live TV tiles, so the number is
      // followed by the readable channel name ("01 NPO 1"), not the raw tvg-id; the
      // unique sort number alone keeps distinct channels distinct.
      if Trim(AChannels[I].Name) <> '' then
        Base := Trim(AChannels[I].Name);
      Result[I] := IntToStr(Nums[I]).PadLeft(Width, '0') + ' ' + Base;
    end
    else
      Result[I] := Base;
  end;
end;

function SelectOutputChannels(const AStore: IStore; AListId: Integer;
  const AGroups: TArray<string>): TOutputChannelList;
var
  All: TOutputChannelList;
  C: TOutputChannel;
  Keep: TStringList;
  Kept: TList<TOutputChannel>;
  G: string;
begin
  All := AStore.LoadOutputChannels(AListId);
  if Length(AGroups) = 0 then
    Exit(All); // no filter — hand the full list straight back (caller owns it)
  Result := TOutputChannelList.Create(True);
  Keep := TStringList.Create;
  Kept := TList<TOutputChannel>.Create;
  try
    Keep.CaseSensitive := False;
    Keep.Sorted := True;
    Keep.Duplicates := dupIgnore;
    for G in AGroups do
      if G.Trim <> '' then
        Keep.Add(G.Trim);
    // note the matches in canonical order, then move them over (Extract leaves the
    // non-kept channels in All so its Free disposes of exactly those)
    for C in All do
      if Keep.IndexOf(C.GroupName) >= 0 then
        Kept.Add(C);
    for C in Kept do
    begin
      All.Extract(C); // detach without freeing
      Result.Add(C);  // Result now owns it
    end;
  finally
    Kept.Free;
    Keep.Free;
    All.Free; // frees the channels left behind (the non-kept ones)
  end;
end;

function BuildM3UChannels(const AChannels: TOutputChannelList;
  const AStreamUrlPrefix: string; ASequentialChno: Boolean;
  const ADisplayNames: TArray<string>; const AGuideIds: TArray<string>): string;
var
  C: TOutputChannel;
  SB: TStringBuilder;
  Chno, DName, TvgId, Catchup: string;
  Seq: Integer;
  Nums: TArray<Integer>;
begin
  Nums := OutputNumbers(AChannels);
  SB := TStringBuilder.Create;
  try
    SB.AppendLine('#EXTM3U');
    Seq := 0;
    for C in AChannels do
    begin
      Inc(Seq);
      if ASequentialChno then
        // globally-unique running number (Plex M3U tuner needs no duplicates)
        Chno := Format(' tvg-chno="%d"', [Nums[Seq - 1]])
      else if C.Number > 0 then
        // convey the operator's channel number (drag/sort-by-Nr) to M3U players
        Chno := Format(' tvg-chno="%d"', [C.Number])
      else
        Chno := '';
      if (Seq - 1 <= High(ADisplayNames)) and (Length(ADisplayNames) > 0) then
        DName := ADisplayNames[Seq - 1] // pre-computed decorated name (Plex surfaces)
      else
        DName := C.Name;                // plain upstream name (box output)
      if (Seq - 1 <= High(AGuideIds)) and (Length(AGuideIds) > 0) then
        TvgId := AGuideIds[Seq - 1]     // pre-computed (maybe sort-prefixed) id
      else
        TvgId := ChannelGuideId(C);
      // catch-up for box players (TiviMate / OTT Navigator): "xc" = derive the
      // Xtream /timeshift/ URL from the stream URL — that is the provider's own
      // (direct) or our relay, which serves /timeshift/ as well. Plex ignores it.
      if (not ASequentialChno) and (C.ContentType = ctLive) and (C.ArchiveDays > 0) then
        Catchup := Format(' catchup="xc" catchup-days="%d"', [C.ArchiveDays])
      else
        Catchup := '';
      SB.AppendFormat('#EXTINF:-1 tvg-id="%s"%s tvg-name="%s" tvg-logo="%s" group-title="%s"%s,%s'#10,
        [M3uSafe(TvgId), Chno, M3uSafe(DName), M3uSafe(C.Logo),
         M3uSafe(C.GroupName), Catchup, M3uSafe(DName)]);
      if AStreamUrlPrefix <> '' then
        SB.AppendLine(AStreamUrlPrefix + C.StreamItemId.ToString + '.ts') // via our proxy
      else
        SB.AppendLine(C.UpstreamUrl); // RAW upstream URL — box talks straight to the provider
    end;
    Result := SB.ToString;
  finally
    SB.Free;
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
  Channels: TOutputChannelList;
  Names, Ids: TArray<string>;
begin
  Channels := SelectOutputChannels(AStore, AListId, AGroups);
  try
    Names := nil;
    if ANames.AnyName then
      Names := ComputeDisplayNames(AStore, Channels, ANames);
    Ids := nil;
    if ANames.IdSort then
      Ids := ComputeGuideIds(Channels, True);
    Result := BuildM3UChannels(Channels, AStreamUrlPrefix, ASequentialChno, Names, Ids);
  finally
    Channels.Free;
  end;
end;

// floor a local TDateTime to the whole hour
function FloorToHour(const ADt: TDateTime): TDateTime;
begin
  Result := Int(ADt * 24) / 24;
end;

// Emit dummy <programme> blocks for one channel across the configured window.
// Stepped in UTC on whole hours: local time has a gap at the spring DST change
// (ToUniversalTime raised ELocalTimeInvalid there) and a double hour in autumn.
procedure AppendDummy(ASB: TStringBuilder; const AGuideId, AName, ACategory: string;
  const ADummy: TDummyEpgOptions);
var
  NowU, BlockDays, EndU, B, StopU: TDateTime;
  Guard: Integer;
begin
  if ADummy.BlockMinutes <= 0 then
    Exit;
  NowU := NowUtc;
  BlockDays := ADummy.BlockMinutes / (24 * 60);
  B := FloorToHour(IncHour(NowU, -ADummy.HoursBack));
  EndU := IncHour(NowU, ADummy.HoursAhead);
  Guard := 0;
  while (B < EndU) and (Guard < 100000) do
  begin
    Inc(Guard);
    StopU := B + BlockDays;
    ASB.AppendFormat(
      '  <programme start="%s" stop="%s" channel="%s"><title>%s</title><desc>%s</desc><category>%s</category></programme>'#10,
      [XmltvTime(B), XmltvTime(StopU),
       XmlEscape(AGuideId), XmlEscape(AName), XmlEscape('Live programma'), XmlEscape(ACategory)]);
    B := StopU;
  end;
end;

function BuildXmltvChannels(const AStore: IStore; const AChannels: TOutputChannelList;
  AMaxDays: Integer; const ADummy: TDummyEpgOptions; const ADisplayNames: TArray<string>;
  const AGuideIds: TArray<string>): string;
var
  C: TOutputChannel;
  Upstreams, SeenEff: TStringList;
  EffById: TDictionary<string, TArray<string>>; // upstream tvg-id -> published id
  GroupById: TDictionary<string, string>; // published id -> group-title (category)
  NameById: TDictionary<string, string>;  // published id -> display name (dummy title)
  GotEpg: TStringList;                     // published ids that received ≥1 real programme
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  SB: TStringBuilder;
  ChannelLabel, Gid, Grp, DName, RId: string;
  Pubs: TArray<string>;
  I, Seq: Integer;
begin
  Upstreams := TStringList.Create;
  Upstreams.Sorted := True;
  Upstreams.Duplicates := dupIgnore;
  SeenEff := TStringList.Create;
  SeenEff.Sorted := True;
  SeenEff.Duplicates := dupIgnore;
  GotEpg := TStringList.Create;
  GotEpg.Sorted := True;
  GotEpg.Duplicates := dupIgnore;
  EffById := TDictionary<string, TArray<string>>.Create;
  GroupById := TDictionary<string, string>.Create;
  NameById := TDictionary<string, string>.Create;
  SB := TStringBuilder.Create;
  try
    SB.AppendLine('<?xml version="1.0" encoding="UTF-8"?>');
    SB.AppendLine('<tv generator-info-name="IPTVPlay">');
    Seq := 0;
    for C in AChannels do
    begin
      Inc(Seq); // position, to index the pre-computed display name / id
      if (Seq - 1 <= High(AGuideIds)) and (Length(AGuideIds) > 0) then
        Gid := AGuideIds[Seq - 1] // pre-computed (maybe sort-prefixed) published id
      else
        Gid := ChannelGuideId(C);
      // an override relabels the guide: advertise the published id, and pull EPG
      // stored under EITHER the upstream id OR the effective id (or the matched
      // extra guide), re-keyed to it. One stored id can feed several channels.
      for RId in C.EpgReadIds do
      begin
        if not EffById.TryGetValue(RId, Pubs) then
          Pubs := nil;
        if IndexStr(Gid, Pubs) < 0 then
          EffById.AddOrSetValue(RId, Pubs + [Gid]);
        Upstreams.Add(RId);
      end;
      // one <channel> per distinct published id; remember group + name (first seen)
      if SeenEff.IndexOf(Gid) < 0 then
      begin
        SeenEff.Add(Gid);
        if (Seq - 1 <= High(ADisplayNames)) and (Length(ADisplayNames) > 0) then
          DName := ADisplayNames[Seq - 1] // pre-computed decorated name (same as M3U/lineup)
        else
          DName := C.Name;
        GroupById.AddOrSetValue(Gid, C.GroupName);
        NameById.AddOrSetValue(Gid, DName);
        // <icon>: Plex takes the channel logo from the XMLTV guide (the HDHomeRun
        // lineup has no logo field), so publish the effective logo here too
        if C.Logo <> '' then
          SB.AppendFormat('  <channel id="%s"><display-name>%s</display-name><icon src="%s"/></channel>'#10,
            [XmlEscape(Gid), XmlEscape(DName), XmlEscape(C.Logo)])
        else
          SB.AppendFormat('  <channel id="%s"><display-name>%s</display-name></channel>'#10,
            [XmlEscape(Gid), XmlEscape(DName)]);
      end;
    end;

    Progs := AStore.LoadEpgForTvgIds(Upstreams.ToStringArray, AMaxDays);
    try
      for I := 0 to Progs.Count - 1 do
      begin
        P := Progs[I];
        // re-key the stored (upstream-id) programme to every published id using it
        if not EffById.TryGetValue(P.ChannelTvgId, Pubs) then
          Pubs := [P.ChannelTvgId];
        for ChannelLabel in Pubs do
        begin
        GotEpg.Add(ChannelLabel); // this published id has real data — no dummy for it
        SB.AppendFormat('  <programme start="%s" stop="%s" channel="%s"><title>%s</title><desc>%s</desc>',
          [XmltvTime(P.StartUtc), XmltvTime(P.StopUtc), XmlEscape(ChannelLabel),
           XmlEscape(P.Title), XmlEscape(P.Description)]);
        // keep the provider's own category (if any) ...
        if P.Category <> '' then
          SB.AppendFormat('<category>%s</category>', [XmlEscape(P.Category)]);
        // ... and ALWAYS add the group-title category (the guide's grouping), unless
        // it would just duplicate the provider one
        if GroupById.TryGetValue(ChannelLabel, Grp) and (Grp <> '') and
           not SameText(Grp, P.Category) then
          SB.AppendFormat('<category>%s</category>', [XmlEscape(Grp)]);
        SB.AppendLine('</programme>');
        end;
      end;
    finally
      Progs.Free;
    end;

    // fill the gaps: every published id with no real programme gets dummy blocks
    if ADummy.Enabled then
      for I := 0 to SeenEff.Count - 1 do
      begin
        Gid := SeenEff[I];
        if GotEpg.IndexOf(Gid) < 0 then
          AppendDummy(SB, Gid, NameById[Gid], GroupById[Gid], ADummy);
      end;

    SB.AppendLine('</tv>');
    Result := SB.ToString;
  finally
    SB.Free;
    Upstreams.Free;
    SeenEff.Free;
    GotEpg.Free;
    EffById.Free;
    GroupById.Free;
    NameById.Free;
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
  Channels: TOutputChannelList;
  Names, Ids: TArray<string>;
begin
  Channels := SelectOutputChannels(AStore, AListId, AGroups);
  try
    Names := nil;
    if ANames.AnyName then
      Names := ComputeDisplayNames(AStore, Channels, ANames);
    Ids := nil;
    if ANames.IdSort then
      Ids := ComputeGuideIds(Channels, True);
    Result := BuildXmltvChannels(AStore, Channels, AMaxDays, ADummy, Names, Ids);
  finally
    Channels.Free;
  end;
end;

function BuildXmltv(const AStore: IStore; AListId: Integer; AMaxDays: Integer): string;
begin
  Result := BuildXmltv(AStore, AListId, AMaxDays, TDummyEpgOptions.Off);
end;

end.
