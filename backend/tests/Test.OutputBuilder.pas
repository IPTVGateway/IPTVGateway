unit Test.OutputBuilder;

{ Tests for IPTV.Output.Builder against a seeded store: the M3U carries raw
  upstream URLs, and the XMLTV is restricted to the chosen channels' tvg-ids. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>IPTV.Output.Builder tests (M3U, XMLTV, naming, numbering, EPG) against a seeded store.</summary>
  [TestFixture]
  TOutputBuilderTests = class
  private
    FDbPath: string;
  public
    /// <summary>Picks a fresh temp database path.</summary>
    [Setup] procedure Setup;
    /// <summary>Deletes the temp database (incl. -wal/-shm).</summary>
    [TearDown] procedure TearDown;
    /// <summary>The M3U embeds the raw upstream URL of chosen channels only.</summary>
    [Test] procedure M3UContainsRawUpstreamUrl;
    /// <summary>The XMLTV holds only the chosen channels' tvg-ids.</summary>
    [Test] procedure XmltvOnlyForChosenTvgIds;
    /// <summary>The XMLTV channel element carries the effective logo.</summary>
    [Test] procedure XmltvChannelCarriesLogo;
    /// <summary>A per-item tvg-id override drives the M3U and XMLTV ids.</summary>
    [Test] procedure ItemTvgIdOverrideFlowsToOutput;
    /// <summary>A tvg-id override re-keys the upstream EPG.</summary>
    [Test] procedure ItemTvgIdOverrideRelabelsUpstreamEpg;
    /// <summary>Sequential tvg-chno numbering is unique.</summary>
    [Test] procedure M3uSequentialChnoIsUnique;
    /// <summary>Dummy EPG fills channels without a guide.</summary>
    [Test] procedure DummyFillsChannelsWithoutEpg;
    /// <summary>Real programmes carry the group-title as category.</summary>
    [Test] procedure ProgrammesCarryGroupCategory;
    /// <summary>The group filter narrows M3U and XMLTV alike, case-insensitively.</summary>
    [Test] procedure GroupFilterIsConsistentAndCaseInsensitive;
    /// <summary>The group prefix appears in the visible name only.</summary>
    [Test] procedure GroupPrefixInName;
    /// <summary>The number prefix follows the output order.</summary>
    [Test] procedure NumberPrefixInName;
    /// <summary>Number padding follows the total and is idempotent.</summary>
    [Test] procedure SortNumberPaddingAndIdempotency;
    /// <summary>The source letter groups channels by provider.</summary>
    [Test] procedure SourceLetterGroupsByProvider;
    /// <summary>The id-sort prefix reorders and keeps the EPG coupled.</summary>
    [Test] procedure IdSortPrefixReordersAndKeepsEpg;
    /// <summary>Plex surfaces use unique bouquet numbers, else positions.</summary>
    [Test] procedure PlexUsesUniqueBouquetNumbers;
    /// <summary>Catch-up data flows from the catalog to the output.</summary>
    [Test] procedure CatchupFlowsFromCatalogToOutput;
    /// <summary>Only one source's guide is served per tvg-id.</summary>
    [Test] procedure EpgOfOneSourcePerChannel;
    /// <summary>An extra guide wins unless the source prefers its own EPG.</summary>
    [Test] procedure ExtraGuideFirstUnlessSourcePrefersOwn;
    /// <summary>Two tvg-ids that differ only in case each get their channel and programmes.</summary>
    [Test] procedure XmltvKeepsCaseDistinctTvgIds;
    /// <summary>A '+' in a login that MARS decoded to ' ' still finds the list.</summary>
    [Test] procedure FindListForPathReadsSpaceAsPlus;
    /// <summary>The media-server base URL follows publicBaseUrl's scheme and port.</summary>
    [Test] procedure MediaServerBaseUrlFollowsPublicBaseUrl;
  end;

implementation

uses
  // RTL
  System.Generics.Collections,
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList,
  IPTV.Storage.Intf,
  IPTV.Storage.SQLite,
  IPTV.Output.Builder,
  IPTV.Core.Utils;

function NewStore(const APath: string): IStore;
begin
  Result := TSQLiteStore.Create(APath);
  Result.Init;
end;

function MakeStream(ACt: TContentType; const AUp, AName, ATvg, AUrl: string): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.SourceId := 1;
  Result.ContentType := ACt;
  Result.UpstreamId := AUp;
  Result.Name := AName;
  Result.TvgId := ATvg;
  Result.UpstreamUrl := AUrl;
end;

// as MakeStream, plus an upstream group-title (becomes the channel's group name)
function MakeStreamG(ACt: TContentType; const AUp, AName, ATvg, AGroup, AUrl: string): TStreamItem;
begin
  Result := MakeStream(ACt, AUp, AName, ATvg, AUrl);
  Result.GroupTitle := AGroup;
end;

// how many times ASub occurs in AText (non-overlapping)
function CountSubstr(const AText, ASub: string): Integer;
var
  lPos: Integer;
begin
  Result := 0;
  lPos := Pos(ASub, AText);
  while lPos > 0 do
  begin
    Inc(Result);
    lPos := Pos(ASub, AText, lPos + Length(ASub));
  end;
end;

// add every stream matching AFilterSearch ('' => all) to a fresh list; returns list id
function SeedListAll(const AStore: IStore): Integer;
var
  lList: TCustomList;
  lListId: Integer;
  lFilter: TCatalogFilter;
  lItem: TCustomItem;
  i: Integer;
  lStreams: TStreamItemList;
begin
  lList := TCustomList.Create;
  try
    lList.Name := 'L';
    lListId := AStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;
  lFilter := Default(TCatalogFilter);
  lStreams := AStore.LoadStreams(lFilter);
  try
    for i := 0 to lStreams.Count - 1 do
    begin
      lItem := TCustomItem.Create;
      try
        lItem.ListId := lListId;
        lItem.StreamItemId := lStreams[i].Id;
        lItem.ContentType := ctLive;
        AStore.SaveItem(lItem);
      finally
        FreeAndNil(lItem);
      end;
    end;
  finally
    FreeAndNil(lStreams);
  end;
  Result := lListId;
end;

procedure TOutputBuilderTests.Setup;
begin
  FDbPath := TPath.Combine(TPath.GetTempPath, 'iptvob_' + TGUID.NewGuid.ToString + '.sqlite');
end;

procedure TOutputBuilderTests.TearDown;

  procedure Del(const APath: string);
  begin
    if TFile.Exists(APath) then
      TFile.Delete(APath);
  end;

begin
  Del(FDbPath);
  Del(FDbPath + '-wal');
  Del(FDbPath + '-shm');
end;

// Seed: two streams (nl1 on the list, uk1 NOT on the list), EPG for both.
// Returns the list id.
function Seed(const AStore: IStore): Integer;
var
  lSnap: TSourceSnapshot;
  lList: TCustomList;
  lProgs: TEpgProgrammeList;
  lProg: TEpgProgramme;
  lFilter: TCatalogFilter;
  lListId: Integer;
  lItem: TCustomItem;
  lStreams: TStreamItemList;
begin
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(ctLive, 's1', 'NPO 1', 'nl1', 'http://provider/live/u/p/1.ts'));
  lSnap.Streams.Add(MakeStream(ctLive, 's2', 'BBC One', 'uk1', 'http://provider/live/u/p/2.ts'));
  AStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lProgs := TEpgProgrammeList.Create(True);
  lProg := TEpgProgramme.Create;
  lProg.ChannelTvgId := 'nl1';
  lProg.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  lProg.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0);
  lProg.Title := 'NL News';
  lProgs.Add(lProg);
  lProg := TEpgProgramme.Create;
  lProg.ChannelTvgId := 'uk1';
  lProg.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  lProg.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0);
  lProg.Title := 'UK News';
  lProgs.Add(lProg);
  AStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);

  lList := TCustomList.Create;
  try
    lList.Name := 'L';
    lListId := AStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;

  // put only NPO 1 (nl1) on the list
  lFilter := Default(TCatalogFilter);
  lFilter.Search := 'NPO';
  lStreams := AStore.LoadStreams(lFilter);
  try
    lItem := TCustomItem.Create;
    try
      lItem.ListId := lListId;
      lItem.StreamItemId := lStreams[0].Id;
      lItem.ContentType := ctLive;
      AStore.SaveItem(lItem);
    finally
      FreeAndNil(lItem);
    end;
  finally
    FreeAndNil(lStreams);
  end;

  Result := lListId;
end;

procedure TOutputBuilderTests.M3UContainsRawUpstreamUrl;
var
  lStore: IStore;
  lM3U: string;
  lListId: Integer;
begin
  lStore := NewStore(FDbPath);
  lListId := Seed(lStore);
  lM3U := BuildM3U(lStore, lListId);
  Assert.IsTrue(lM3U.StartsWith('#EXTM3U'), 'must be a valid M3U header');
  Assert.IsTrue(lM3U.Contains('http://provider/live/u/p/1.ts'), 'raw upstream URL must be embedded');
  Assert.IsTrue(lM3U.Contains('tvg-id="nl1"'), 'EXTINF carries tvg-id');
  Assert.IsFalse(lM3U.Contains('uk1'), 'channel not on the list must be absent');
end;

// Plex reads channel logos from the XMLTV <channel><icon>, not from the lineup.
procedure TOutputBuilderTests.XmltvChannelCarriesLogo;
var
  lStore: IStore;
  lXml: string;
  lListId: Integer;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lListId := Seed(lStore);
  lItems := lStore.LoadItems(lListId);
  try
    lItems[0].LogoOverride := 'http://logo/npo1.png';
    lStore.SaveItem(lItems[0]);
  finally
    FreeAndNil(lItems);
  end;
  lXml := BuildXmltv(lStore, lListId);
  Assert.IsTrue(lXml.Contains('<channel id="nl1"><display-name>NPO 1</display-name>' +
    '<icon src="http://logo/npo1.png"/></channel>'),
    'channel element carries the effective logo');
end;

procedure TOutputBuilderTests.XmltvOnlyForChosenTvgIds;
var
  lStore: IStore;
  lXml: string;
  lListId: Integer;
begin
  lStore := NewStore(FDbPath);
  lListId := Seed(lStore);
  lXml := BuildXmltv(lStore, lListId);
  Assert.IsTrue(lXml.Contains('<channel id="nl1">'), 'chosen channel present');
  Assert.IsTrue(lXml.Contains('NL News'), 'chosen channel programme present');
  Assert.IsFalse(lXml.Contains('uk1'), 'unchosen tvg-id must be excluded from EPG');
  Assert.IsFalse(lXml.Contains('UK News'), 'unchosen programme must be excluded');
end;

// A channel with a MISSING upstream tvg-id gets a per-item override; the override
// must drive BOTH the M3U tvg-id and the XMLTV <channel id> (and thus the EPG).
procedure TOutputBuilderTests.ItemTvgIdOverrideFlowsToOutput;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lList: TCustomList;
  lProgs: TEpgProgrammeList;
  lProg: TEpgProgramme;
  lFilter: TCatalogFilter;
  lItem: TCustomItem;
  lListId: Integer;
  lM3U, lXml: string;
  lStreams: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(ctLive, 's9', 'Local Channel', '', 'http://provider/live/u/p/9.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // EPG only exists under the OVERRIDE id
  lProgs := TEpgProgrammeList.Create(True);
  lProg := TEpgProgramme.Create;
  lProg.ChannelTvgId := 'over.id';
  lProg.StartUtc := EncodeDateTime(2026, 6, 14, 20, 0, 0, 0);
  lProg.StopUtc := EncodeDateTime(2026, 6, 14, 21, 0, 0, 0);
  lProg.Title := 'Over News';
  lProgs.Add(lProg);
  lStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);

  lList := TCustomList.Create;
  try
    lList.Name := 'L';
    lListId := lStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;

  lFilter := Default(TCatalogFilter);
  lFilter.Search := 'Local';
  lStreams := lStore.LoadStreams(lFilter);
  try
    lItem := TCustomItem.Create;
    try
      lItem.ListId := lListId;
      lItem.StreamItemId := lStreams[0].Id;
      lItem.ContentType := ctLive;
      lItem.TvgIdOverride := 'over.id';
      lStore.SaveItem(lItem);
    finally
      FreeAndNil(lItem);
    end;
  finally
    FreeAndNil(lStreams);
  end;

  lM3U := BuildM3U(lStore, lListId);
  Assert.IsTrue(lM3U.Contains('tvg-id="over.id"'), 'M3U uses the per-item tvg-id override');

  lXml := BuildXmltv(lStore, lListId);
  Assert.IsTrue(lXml.Contains('<channel id="over.id">'), 'XMLTV channel id uses the override');
  Assert.IsTrue(lXml.Contains('Over News'), 'EPG resolves via the override id');
end;

// Relabel direction: the provider EPG is stored under the UPSTREAM id, and the
// override re-keys it on output. The guide must follow the channel to the override
// id (and the upstream id must NOT leak into the served XMLTV).
procedure TOutputBuilderTests.ItemTvgIdOverrideRelabelsUpstreamEpg;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lList: TCustomList;
  lProgs: TEpgProgrammeList;
  lProg: TEpgProgramme;
  lFilter: TCatalogFilter;
  lItem: TCustomItem;
  lListId: Integer;
  lXml: string;
  lStreams: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(ctLive, 's7', 'Sport HD', 'prov.x', 'http://provider/live/u/p/7.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // provider EPG is stored under the UPSTREAM id 'prov.x'
  lProgs := TEpgProgrammeList.Create(True);
  lProg := TEpgProgramme.Create;
  lProg.ChannelTvgId := 'prov.x';
  lProg.StartUtc := EncodeDateTime(2026, 6, 14, 20, 0, 0, 0);
  lProg.StopUtc := EncodeDateTime(2026, 6, 14, 21, 0, 0, 0);
  lProg.Title := 'Big Match';
  lProgs.Add(lProg);
  lStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);

  lList := TCustomList.Create;
  try
    lList.Name := 'L';
    lListId := lStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;

  // override re-keys the channel to 'mine.x'
  lFilter := Default(TCatalogFilter);
  lFilter.Search := 'Sport';
  lStreams := lStore.LoadStreams(lFilter);
  try
    lItem := TCustomItem.Create;
    try
      lItem.ListId := lListId;
      lItem.StreamItemId := lStreams[0].Id;
      lItem.ContentType := ctLive;
      lItem.TvgIdOverride := 'mine.x';
      lStore.SaveItem(lItem);
    finally
      FreeAndNil(lItem);
    end;
  finally
    FreeAndNil(lStreams);
  end;

  lXml := BuildXmltv(lStore, lListId);
  Assert.IsTrue(lXml.Contains('<channel id="mine.x">'), 'channel advertised under the override id');
  Assert.IsTrue(lXml.Contains('channel="mine.x"'), 'upstream EPG is re-keyed to the override id');
  Assert.IsTrue(lXml.Contains('Big Match'), 'the upstream programme still appears');
  Assert.IsFalse(lXml.Contains('prov.x'), 'the raw upstream id must not leak into the output');
end;

// With ASequentialChno the M3U must number channels 1..N globally-unique (Plex M3U
// tuners reject duplicate channel numbers) — even when items carry colliding
// per-group numbers (e.g. two groups each starting at 1).
procedure TOutputBuilderTests.M3uSequentialChnoIsUnique;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lList: TCustomList;
  lFilter: TCatalogFilter;
  lListId: Integer;
  lM3U: string;
  lItem: TCustomItem;
  lStreams: TStreamItemList;
  i: Integer;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(ctLive, 'a', 'Alpha', 'a.nl', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(ctLive, 'b', 'Bravo', 'b.nl', 'http://p/b.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lList := TCustomList.Create;
  try
    lList.Name := 'L';
    lListId := lStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;

  // both items get channel_number = 1 (the colliding per-group case)
  lFilter := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lFilter);
  try
    for i := 0 to lStreams.Count - 1 do
    begin
      lItem := TCustomItem.Create;
      try
        lItem.ListId := lListId;
        lItem.StreamItemId := lStreams[i].Id;
        lItem.ContentType := ctLive;
        lItem.ChannelNumber := 1;
        lStore.SaveItem(lItem);
      finally
        FreeAndNil(lItem);
      end;
    end;
  finally
    FreeAndNil(lStreams);
  end;

  lM3U := BuildM3U(lStore, lListId, '', True); // sequential
  Assert.IsTrue(lM3U.Contains('tvg-chno="1"'), 'first channel numbered 1');
  Assert.IsTrue(lM3U.Contains('tvg-chno="2"'), 'second channel numbered 2 (not a duplicate 1)');
end;

// A channel WITHOUT real EPG (incl. one with no tvg-id at all) gets dummy blocks
// carrying the group-title as <category>; a channel WITH EPG keeps its programme
// and gets no dummy. Also verifies the synthetic id (iptv-<sid>) couples the M3U
// and XMLTV for the id-less channel.
procedure TOutputBuilderTests.DummyFillsChannelsWithoutEpg;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lProgs: TEpgProgrammeList;
  lProg: TEpgProgramme;
  lListId: Integer;
  lXml, lM3U: string;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStreamG(ctLive, 's1', 'NPO 1', 'nl1', 'Nederland', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStreamG(ctLive, 's2', 'Filler HD', 'fx', 'Sport', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStreamG(ctLive, 's3', 'No Guide', '', 'Sport', 'http://p/3.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // real EPG only for nl1
  lProgs := TEpgProgrammeList.Create(True);
  lProg := TEpgProgramme.Create;
  lProg.ChannelTvgId := 'nl1';
  lProg.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  lProg.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0);
  lProg.Title := 'NL News';
  lProgs.Add(lProg);
  lStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);

  lListId := SeedListAll(lStore);

  lXml := BuildXmltv(lStore, lListId, 0, TDummyEpgOptions.Make(True, 120, 12, 48));
  Assert.IsTrue(lXml.Contains('Live programma'), 'dummy programmes are generated');
  Assert.IsTrue(lXml.Contains('<category>Sport</category>'), 'dummy carries the group-title category');
  Assert.IsTrue(lXml.Contains('channel id="iptv-'), 'id-less channel gets a synthetic id');
  Assert.IsTrue(lXml.Contains('NL News'), 'the channel WITH real EPG keeps its programme');
  // the real-EPG channel must NOT also get dummy filler under its id
  Assert.IsFalse(lXml.Contains('channel="nl1"><title>Live programma'),
    'a channel with real EPG gets no dummy');

  lM3U := BuildM3U(lStore, lListId);
  Assert.IsTrue(lM3U.Contains('tvg-id="iptv-'), 'M3U uses the same synthetic id, so dummy couples');
end;

// Every real programme gets the channel's group-title as a <category>, so the
// Plex/Jellyfin guide can group by it.
procedure TOutputBuilderTests.ProgrammesCarryGroupCategory;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lProgs: TEpgProgrammeList;
  lProg: TEpgProgramme;
  lListId: Integer;
  lXml: string;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStreamG(ctLive, 's1', 'NPO 1', 'nl1', 'Nederland', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lProgs := TEpgProgrammeList.Create(True);
  lProg := TEpgProgramme.Create;
  lProg.ChannelTvgId := 'nl1';
  lProg.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  lProg.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0);
  lProg.Title := 'NL News';
  lProgs.Add(lProg);
  lStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);

  lListId := SeedListAll(lStore);

  lXml := BuildXmltv(lStore, lListId, 0, TDummyEpgOptions.Off);
  Assert.IsTrue(lXml.Contains('NL News'), 'the real programme is present');
  Assert.IsTrue(lXml.Contains('<category>Nederland</category>'),
    'the real programme carries the group-title category');
end;

// The global group filter narrows M3U + XMLTV to the SAME channel set (matching is
// case-insensitive), so the box's documents always agree.
procedure TOutputBuilderTests.GroupFilterIsConsistentAndCaseInsensitive;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lListId: Integer;
  lM3U, lXml: string;
  lChannels: TOutputChannelList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStreamG(ctLive, 'a', 'Alpha', 'a.nl', 'News', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStreamG(ctLive, 'b', 'Bravo', 'b.nl', 'Sport', 'http://p/b.ts'));
  lSnap.Streams.Add(MakeStreamG(ctLive, 'c', 'Charlie', 'c.nl', 'Sport', 'http://p/c.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lListId := SeedListAll(lStore);

  // filter to 'sport' (lower-case) — must match the 'Sport' group (2 channels)
  lChannels := SelectOutputChannels(lStore, lListId, ['sport']);
  try
    Assert.AreEqual(2, lChannels.Count, 'two channels are in the Sport group');
  finally
    FreeAndNil(lChannels);
  end;

  lM3U := BuildM3U(lStore, lListId, '', False, ['sport']);
  lXml := BuildXmltv(lStore, lListId, 0, TDummyEpgOptions.Off, ['sport']);
  Assert.AreEqual(2, CountSubstr(lM3U, '#EXTINF'), 'M3U has exactly the 2 Sport channels');
  Assert.AreEqual(2, CountSubstr(lXml, '<channel '), 'XMLTV has exactly the 2 Sport channels');
  Assert.IsFalse(lM3U.Contains('Alpha'), 'the News-group channel is filtered out of the M3U');
  Assert.IsFalse(lXml.Contains('a.nl'), 'the News-group channel is filtered out of the XMLTV');
end;

// With APrefixGroup the visible name is "Group · Name" in BOTH the M3U (tvg-name +
// display) and the XMLTV <channel>, while group-title and the tvg-id are unchanged.
procedure TOutputBuilderTests.GroupPrefixInName;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lListId: Integer;
  lM3U, lXml: string;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStreamG(ctLive, 'a', 'NPO 1', 'nl1', 'Sport', 'http://p/a.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lListId := SeedListAll(lStore);

  // default (no prefix): plain name
  lM3U := BuildM3U(lStore, lListId);
  Assert.IsTrue(lM3U.Contains('group-title="Sport"'), 'group-title stays the group');
  Assert.IsTrue(lM3U.Contains(',NPO 1'#10) or lM3U.Contains(',NPO 1'), 'plain display name by default');

  // with prefix on: name becomes "Sport <middot> NPO 1"
  lM3U := BuildM3U(lStore, lListId, '', False, nil, TNameOptions.Make(True, False, False));
  Assert.IsTrue(lM3U.Contains('Sport ' + #$B7 + ' NPO 1'), 'M3U name is prefixed with the group');
  Assert.IsTrue(lM3U.Contains('group-title="Sport"'), 'group-title is unchanged when prefixing');
  Assert.IsTrue(lM3U.Contains('tvg-id="nl1"'), 'tvg-id is unchanged when prefixing');

  lXml := BuildXmltv(lStore, lListId, 0, TDummyEpgOptions.Off, nil, TNameOptions.Make(True, False, False));
  Assert.IsTrue(lXml.Contains('<display-name>Sport ' + #$B7 + ' NPO 1</display-name>'),
    'XMLTV channel display-name is prefixed with the group');
end;

// With ANumberName the visible name is prefixed with a running number in OUTPUT
// order (groups A→Z, channels A→Z), so a name-sort on the consumer reproduces the
// bouquet order. Combinable with the group prefix.
procedure TOutputBuilderTests.NumberPrefixInName;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lListId: Integer;
  lM3U, lXml: string;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  // canonical order is by group A→Z then channel: News/Alpha (1), Sport/Bravo (2)
  lSnap.Streams.Add(MakeStreamG(ctLive, 'a', 'Alpha', 'a.nl', 'News', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStreamG(ctLive, 'b', 'Bravo', 'b.nl', 'Sport', 'http://p/b.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lListId := SeedListAll(lStore);

  // number only: "1 Alpha" before "2 Bravo"
  lM3U := BuildM3U(lStore, lListId, '', False, nil, TNameOptions.Make(False, True, False));
  Assert.IsTrue(lM3U.Contains(',1 Alpha'), 'first channel numbered 1 in the name');
  Assert.IsTrue(lM3U.Contains(',2 Bravo'), 'second channel numbered 2 in the name');
  Assert.IsTrue(lM3U.IndexOf('1 Alpha') < lM3U.IndexOf('2 Bravo'), 'numbers follow output order');

  lXml := BuildXmltv(lStore, lListId, 0, TDummyEpgOptions.Off, nil, TNameOptions.Make(False, True, False));
  Assert.IsTrue(lXml.Contains('<display-name>1 Alpha</display-name>'), 'XMLTV name numbered too');

  // number + group together: "1 News · Alpha"
  lM3U := BuildM3U(lStore, lListId, '', False, nil, TNameOptions.Make(True, True, False));
  Assert.IsTrue(lM3U.Contains('1 News ' + #$B7 + ' Alpha'), 'number + group combine in the name');
end;

// After "Renumber bouquet" (unique numbers 100, 101, 200 …) the Plex surfaces use
// those numbers (GuideNumber/tvg-chno/id-sort prefix); with a duplicate or a
// missing number they fall back to the running position 1,2,3.
procedure TOutputBuilderTests.PlexUsesUniqueBouquetNumbers;
var
  lList: TOutputChannelList;
  lM3U: string;

  procedure Add(const AName: string; ANumber: Integer);
  var
    lChannel: TOutputChannel;
  begin
    lChannel := TOutputChannel.Create;
    lChannel.Name := AName;
    lChannel.Number := ANumber;
    lChannel.StreamItemId := lList.Count + 1;
    lList.Add(lChannel);
  end;

begin
  lList := TOutputChannelList.Create(True);
  try
    Add('NPO 1', 100);
    Add('NPO 2', 101);
    Add('ESPN 3', 312);
    Assert.AreEqual<Integer>(312, OutputNumbers(lList)[2], 'own numbers when unique');
    Assert.AreEqual('312 ESPN 3', ComputeGuideIds(lList, True)[2], 'id-sort uses the bouquet number');
    Assert.AreEqual('100 NPO 1', ComputeGuideIds(lList, True)[0]);
    lM3U := BuildM3UChannels(lList, '', True);
    Assert.IsTrue(lM3U.Contains('tvg-chno="312"'), 'Plex M3U chno = bouquet number');

    lList[1].Number := 100; // duplicate -> fall back to positions
    Assert.AreEqual<Integer>(3, OutputNumbers(lList)[2], 'position when not unique');
    Assert.AreEqual('3 ESPN 3', ComputeGuideIds(lList, True)[2]);
    lList[1].Number := 0;   // missing -> positions too
    Assert.AreEqual<Integer>(2, OutputNumbers(lList)[1]);
  finally
    FreeAndNil(lList);
  end;
end;

// ChannelDisplayName is the SINGLE numbering source shared by the XMLTV
// display-name and the lineup GuideName/Number: ASeq is the channel's position
// (== the lineup GuideNumber), zero-padded on the highest number (ATotal). Verify
// the padding width, idempotency, and that the emitted number equals the seq.
procedure TOutputBuilderTests.SortNumberPaddingAndIdempotency;
var
  lChannel: TOutputChannel;

  function DisplayNum(const AName: string; ASeq, ATotal: Integer): string;
  begin
    lChannel.Name := AName;
    Result := ChannelDisplayName(lChannel, False, True, ASeq, ATotal);
  end;

begin
  lChannel := TOutputChannel.Create;
  try
    // zero-padding follows the width of the HIGHEST number (ATotal)
    Assert.AreEqual('5 News', DisplayNum('News', 5, 9), 'single digit when < 10 channels');
    Assert.AreEqual('05 News', DisplayNum('News', 5, 12), 'two digits at 12 channels');
    Assert.AreEqual('005 News', DisplayNum('News', 5, 200), 'three digits at 200 channels');
    Assert.AreEqual('97 News', DisplayNum('News', 97, 97), '97 of 97 → two digits');
    Assert.AreEqual('097 News', DisplayNum('News', 97, 100), '97 of 100 → three digits');

    // idempotent: a name that ALREADY starts with exactly this (padded) number is
    // not prefixed again
    Assert.AreEqual('05 News', DisplayNum('05 News', 5, 12), 'no double prefix when already numbered');
    Assert.AreEqual('5 News', DisplayNum('5 News', 5, 9), 'idempotent, unpadded width');
    // but a DIFFERENTLY-padded leading number is still prefixed (not the same token)
    Assert.AreEqual('05 5 News', DisplayNum('5 News', 5, 12), 'different width is not treated as already-prefixed');

    // the emitted number equals the seq (== lineup GuideNumber) — strip padding
    Assert.AreEqual<Integer>(5, StrToInt(DisplayNum('News', 5, 200).Split([' '])[0]),
      'display-name number equals the seq / GuideNumber');
  finally
    FreeAndNil(lChannel);
  end;
end;

// With ShowSource, each channel gets a per-provider letter (A = 1st source, B =
// 2nd) so Plex groups+sorts by provider; the number resets per source. Verify the
// M3U and XMLTV display names, that both surfaces agree, and that provider A sorts
// before provider B (A… < B…).
procedure TOutputBuilderTests.SourceLetterGroupsByProvider;
var
  lStore: IStore;
  lSource1, lSource2: TSourceConfig;
  lSid1, lSid2: Integer;
  lSnap: TSourceSnapshot;
  lList: TCustomList;
  lListId: Integer;
  lFilter: TCatalogFilter;
  lItem: TCustomItem;
  lM3U, lXml: string;
  i: Integer;
  lStreams: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  // two providers, in this order → A, B
  lSource1 := TSourceConfig.Create;
  try
    lSource1.Name := 'Provider One';
    lSource1.Kind := skM3U;
    lSid1 := lStore.SaveSource(lSource1);
  finally
    FreeAndNil(lSource1);
  end;
  lSource2 := TSourceConfig.Create;
  try
    lSource2.Name := 'Provider Two';
    lSource2.Kind := skM3U;
    lSid2 := lStore.SaveSource(lSource2);
  finally
    FreeAndNil(lSource2);
  end;

  lSnap := TSourceSnapshot.Create(lSid1);
  lSnap.Streams.Add(MakeStreamG(ctLive, 'a', 'NPO 1', 'nl1', 'News', 'http://p1/a.ts'));
  lSnap.Streams.Add(MakeStreamG(ctLive, 'b', 'NPO 2', 'nl2', 'News', 'http://p1/b.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lSnap := TSourceSnapshot.Create(lSid2);
  lSnap.Streams.Add(MakeStreamG(ctLive, 'c', 'HBO', 'hbo', 'Film', 'http://p2/c.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lList := TCustomList.Create;
  try
    lList.Name := 'L';
    lListId := lStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;
  lFilter := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lFilter);
  try
    for i := 0 to lStreams.Count - 1 do
    begin
      lItem := TCustomItem.Create;
      try
        lItem.ListId := lListId;
        lItem.StreamItemId := lStreams[i].Id;
        lItem.ContentType := ctLive;
        lStore.SaveItem(lItem);
      finally
        FreeAndNil(lItem);
      end;
    end;
  finally
    FreeAndNil(lStreams);
  end;

  // source letter + number (resets per source): provider 1 → "A 1/2 NPO…",
  // provider 2 → "B 1 HBO". (Our file stays in canonical/group order; the letter is
  // what makes PLEX's own alphabetical sort group by provider.)
  lM3U := BuildM3U(lStore, lListId, '', False, nil, TNameOptions.Make(False, True, True));
  Assert.IsTrue(lM3U.Contains(',A 1 NPO 1'), 'provider A, first channel');
  Assert.IsTrue(lM3U.Contains(',A 2 NPO 2'), 'provider A, second channel — number increments within the source');
  Assert.IsTrue(lM3U.Contains(',B 1 HBO'), 'provider B channel, number resets to 1');
  // intent: Plex sorts these names alphabetically, so provider A precedes provider B
  Assert.IsTrue('A 1 NPO 1' < 'B 1 HBO', 'the A/B prefixes sort provider A before B');

  // XMLTV display-name matches the M3U (single source of truth)
  lXml := BuildXmltv(lStore, lListId, 0, TDummyEpgOptions.Off, nil, TNameOptions.Make(False, True, True));
  Assert.IsTrue(lXml.Contains('<display-name>A 1 NPO 1</display-name>'), 'XMLTV name matches the M3U');
  Assert.IsTrue(lXml.Contains('<display-name>B 1 HBO</display-name>'), 'XMLTV B channel matches');
  // the channel id / tvg-id is NOT touched
  Assert.IsTrue(lXml.Contains('<channel id="nl1">'), 'tvg-id id untouched by the source letter');
end;

// With IdSort, the published channel-id (M3U tvg-id AND XMLTV channel/programme id)
// is prefixed with a zero-padded sort number in output order — so a consumer that
// sorts by id (Plex) follows the bouquet. The real upstream EPG must still couple
// (channel + programme re-keyed together), and the plain box output stays untouched.
procedure TOutputBuilderTests.IdSortPrefixReordersAndKeepsEpg;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lProgs: TEpgProgrammeList;
  lProg: TEpgProgramme;
  lListId: Integer;
  lM3U, lXml, lPlainM3U: string;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  // canonical order: group News/Alpha (1), then Sport/Bravo (2)
  lSnap.Streams.Add(MakeStreamG(ctLive, 'a', 'Alpha', 'a.nl', 'News', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStreamG(ctLive, 'b', 'Bravo', 'b.nl', 'Sport', 'http://p/b.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // real EPG stored under the upstream tvg-id 'a.nl'
  lProgs := TEpgProgrammeList.Create(True);
  lProg := TEpgProgramme.Create;
  lProg.ChannelTvgId := 'a.nl';
  lProg.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  lProg.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0);
  lProg.Title := 'Alpha News';
  lProgs.Add(lProg);
  lStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);

  lListId := SeedListAll(lStore);

  // plain box output keeps the real tvg-id (no prefix)
  lPlainM3U := BuildM3U(lStore, lListId);
  Assert.IsTrue(lPlainM3U.Contains('tvg-id="a.nl"'), 'box output keeps the real tvg-id');
  Assert.IsFalse(lPlainM3U.Contains('tvg-id="1 Alpha"'), 'box output is NOT id-prefixed');

  // Plex M3U: id = sort number (width 1 for 2 channels) + readable channel name,
  // because Plex shows the id as the tile title: "1 Alpha", "2 Bravo"
  lM3U := BuildM3U(lStore, lListId, '', False, nil, TNameOptions.Make(False, False, False, True));
  Assert.IsTrue(lM3U.Contains('tvg-id="1 Alpha"'), 'Plex M3U tvg-id = sort number + name');
  Assert.IsTrue(lM3U.Contains('tvg-id="2 Bravo"'), 'second channel prefixed 2');
  Assert.IsFalse(lM3U.Contains('tvg-id="1_a.nl"'), 'no raw tvg-id in the Plex id');

  // XMLTV: channel id AND programme channel both use the prefixed id (so EPG couples),
  // and the real programme is present (re-keyed from a.nl → "1 Alpha")
  lXml := BuildXmltv(lStore, lListId, 0, TDummyEpgOptions.Off, nil, TNameOptions.Make(False, False, False, True));
  Assert.IsTrue(lXml.Contains('<channel id="1 Alpha">'), 'XMLTV channel id is the prefixed id');
  Assert.IsTrue(lXml.Contains('channel="1 Alpha">'), 'programme is re-keyed to the prefixed id');
  Assert.IsTrue(lXml.Contains('Alpha News'), 'the real EPG programme still appears (coupling kept)');
  // sort intent: "1 Alpha" < "2 Bravo" so an id-sort yields bouquet order
  Assert.IsTrue('1 Alpha' < '2 Bravo', 'prefixed ids sort in bouquet order');
end;

// catch-up: archive_days survives the merge, reaches the output channel and
// the M3U (box only, not Plex); the timeshift URL uses the source's creds,
// the provider's stream id and its clock offset.
procedure TOutputBuilderTests.CatchupFlowsFromCatalogToOutput;
var
  lStore: IStore;
  lSource: TSourceConfig;
  lSnap: TSourceSnapshot;
  lArchived: TStreamItem;
  lListId: Integer;
  lChannels: TOutputChannelList;
  lM3U: string;
  lChannel: TOutputChannel;
  lStreams: TStreamItemList;
  lStream: TStreamItem;
  lSources: TObjectList<TSourceConfig>;
begin
  lStore := NewStore(FDbPath);
  lSource := TSourceConfig.Create;
  try
    lSource.Name := 'P';
    lSource.Kind := skXtream;
    lSource.Url := 'http://prov.tv/';
    lSource.Username := 'pu';
    lSource.Password := 'pp';
    lSource.Enabled := True;
    lSource.TzOffsetMin := 60;
    lStore.SaveSource(lSource);
    Assert.AreEqual(1, lSource.Id, 'first source gets id 1 (MakeStream uses source 1)');
  finally
    FreeAndNil(lSource);
  end;
  lSources := lStore.LoadSources;
  try
    Assert.AreEqual(60, lSources[0].TzOffsetMin, 'tz offset persisted');
  finally
    FreeAndNil(lSources);
  end;

  lSnap := TSourceSnapshot.Create(1);
  lArchived := MakeStream(ctLive, '4711', 'NPO 1', 'nl1', 'http://prov.tv/live/pu/pp/4711.ts');
  lArchived.ArchiveDays := 3;
  lSnap.Streams.Add(lArchived);
  lSnap.Streams.Add(MakeStream(ctLive, '4712', 'NPO 4K', 'nl1', 'http://prov.tv/live/pu/pp/4712.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lListId := SeedListAll(lStore);

  lChannels := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual(2, lChannels.Count);
    for lChannel in lChannels do
      if lChannel.Name = 'NPO 1' then
      begin
        Assert.AreEqual(3, lChannel.ArchiveDays);
        Assert.AreEqual('4711', lChannel.UpstreamId);
      end
      else
        Assert.AreEqual(0, lChannel.ArchiveDays);
    lM3U := BuildM3UChannels(lChannels, '', False);
    Assert.AreEqual(1, CountSubstr(lM3U, 'catchup="xc" catchup-days="3"'), 'only the archived channel');
    Assert.IsFalse(BuildM3UChannels(lChannels, '', True).Contains('catchup='), 'not on the Plex M3U');
  finally
    FreeAndNil(lChannels);
  end;

  // a re-merge without archive clears it again
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(ctLive, '4711', 'NPO 1', 'nl1', 'http://prov.tv/live/pu/pp/4711.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lStreams := lStore.LoadStreams(Default(TCatalogFilter));
  try
    for lStream in lStreams do
      if lStream.UpstreamId = '4711' then
      begin
        Assert.AreEqual(0, lStream.ArchiveDays, 'archive dropped upstream');
        Assert.AreEqual('http://prov.tv/timeshift/pu/pp/60/2026-11-12:21-00/4711.ts',
          TimeshiftUpstreamUrl(lStore, 0, lStream, 60, EncodeDateTime(2026, 11, 12, 20, 0, 0, 0), ''));
      end;
  finally
    FreeAndNil(lStreams);
  end;
end;

// Two providers deliver a guide for the same tvg-id: the output must carry ONE
// of them (the one with most upcoming programmes), not both — else every
// programme shows twice on the box (per-channel EPG) and in xmltv.php.
procedure TOutputBuilderTests.EpgOfOneSourcePerChannel;
var
  lStore: IStore;
  lProgs: TEpgProgrammeList;
  lGot: TEpgProgrammeList;
  lHour: Integer;
  lProgramme: TEpgProgramme;

  procedure Add(AList: TEpgProgrammeList; const ATvg: string; AStartHoursFromNow: Integer);
  var
    lProg: TEpgProgramme;
  begin
    lProg := TEpgProgramme.Create;
    lProg.ChannelTvgId := ATvg;
    lProg.StartUtc := IncHour(NowUtc, AStartHoursFromNow);
    lProg.StopUtc := IncHour(lProg.StartUtc, 1);
    lProg.Title := 'P' + AStartHoursFromNow.ToString;
    AList.Add(lProg);
  end;

begin
  lStore := NewStore(FDbPath);
  // source 1: mostly the past; source 2: covers the coming hours
  lProgs := TEpgProgrammeList.Create(True);
  for lHour := -6 to 1 do
    Add(lProgs, 'npo1.nl', lHour);
  Add(lProgs, 'only1.nl', 0);
  lStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);
  lProgs := TEpgProgrammeList.Create(True);
  for lHour := 0 to 5 do
    Add(lProgs, 'npo1.nl', lHour);
  lStore.ReplaceEpg(2, lProgs);
  FreeAndNil(lProgs);

  lGot := lStore.LoadEpgForTvgIds(['npo1.nl', 'only1.nl']);
  try
    for lProgramme in lGot do
      if lProgramme.ChannelTvgId = 'npo1.nl' then
        Assert.AreEqual(2, lProgramme.SourceId, 'the source with most upcoming programmes wins');
    Assert.AreEqual(6 + 1, lGot.Count, 'npo1.nl once (6 from source 2) + only1.nl');
  finally
    FreeAndNil(lGot);
  end;
end;

// An extra (third-party) guide matched by NAME replaces the provider's guide for
// the channel - the channel keeps its own id - unless its source prefers its own
// EPG (and that has upcoming programmes).
procedure TOutputBuilderTests.ExtraGuideFirstUnlessSourcePrefersOwn;
var
  lStore: IStore;
  lSource: TSourceConfig;
  lSnap: TSourceSnapshot;
  lProgs: TEpgProgrammeList;
  lChannels: TOutputChannelList;
  lListId, lHour: Integer;
  lXml: string;
  lInfo: TEpgChannelInfo;
  lChannel: TOutputChannel;
  lSources: TObjectList<TSourceConfig>;

  procedure Add(AList: TEpgProgrammeList; const ATvg, ATitle: string; AHours: Integer);
  var
    lProg: TEpgProgramme;
  begin
    lProg := TEpgProgramme.Create;
    lProg.ChannelTvgId := ATvg;
    lProg.StartUtc := IncHour(NowUtc, AHours);
    lProg.StopUtc := IncHour(lProg.StartUtc, 1);
    lProg.Title := ATitle;
    AList.Add(lProg);
  end;

begin
  lStore := NewStore(FDbPath);
  lSource := TSourceConfig.Create;
  try
    lSource.Name := 'P';
    lSource.Kind := skXtream;
    lSource.Url := 'http://p';
    lSource.Enabled := True;
    lStore.SaveSource(lSource); // id 1
  finally
    FreeAndNil(lSource);
  end;
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(ctLive, '1', 'NL | NPO 1 HD', 'npo1.nl', 'http://p/live/u/p/1.ts'));
  lSnap.Streams.Add(MakeStream(ctLive, '2', 'NL | UNKNOWN TV', 'unknown.nl', 'http://p/live/u/p/2.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lListId := SeedListAll(lStore);

  lProgs := TEpgProgrammeList.Create(True);
  Add(lProgs, 'npo1.nl', 'Provider show', 0);
  Add(lProgs, 'unknown.nl', 'Unknown show', 0);
  lStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);

  lProgs := TEpgProgrammeList.Create(True);
  for lHour := 0 to 3 do
    Add(lProgs, EXTRA_EPG_PREFIX + 'NPO.1.nl', 'Guide show', lHour);
  lInfo.Id := 'NPO.1.nl';
  lInfo.Name := 'NPO 1';
  lStore.ReplaceExtraEpg(-1, [lInfo], lProgs);
  FreeAndNil(lProgs);

  lChannels := lStore.LoadOutputChannels(lListId);
  try
    for lChannel in lChannels do
      if lChannel.TvgId = 'npo1.nl' then
        Assert.AreEqual(EXTRA_EPG_PREFIX + 'NPO.1.nl', lChannel.ExtraGuideId, 'matched by name')
      else
        Assert.AreEqual('', lChannel.ExtraGuideId, 'no match -> own guide');
    lXml := BuildXmltvChannels(lStore, lChannels, 0, TDummyEpgOptions.Off, nil, nil);
    Assert.AreEqual(4, CountSubstr(lXml, '<title>Guide show</title>'), 'extra guide used');
    Assert.IsFalse(lXml.Contains('Provider show'), 'provider guide replaced');
    Assert.IsTrue(lXml.Contains('channel="npo1.nl"'), 'channel keeps its own id');
    Assert.IsFalse(lXml.Contains('extra:'), 'storage prefix never leaks');
    Assert.IsTrue(lXml.Contains('Unknown show'), 'unmatched channel keeps its own guide');
  finally
    FreeAndNil(lChannels);
  end;

  // the provider prefers its own guide -> own guide again (it has data)
  lSources := lStore.LoadSources;
  try
    lSources[0].PreferOwnEpg := True;
    lStore.SaveSource(lSources[0]);
  finally
    FreeAndNil(lSources);
  end;
  lChannels := lStore.LoadOutputChannels(lListId);
  try
    for lChannel in lChannels do
      Assert.AreEqual('', lChannel.ExtraGuideId, 'prefer own EPG');
  finally
    FreeAndNil(lChannels);
  end;

  // removing the extra URL clears its slot
  lStore.ClearExtraEpgBelow(0);
  lProgs := lStore.LoadEpgForTvgIds([EXTRA_EPG_PREFIX + 'NPO.1.nl']);
  try
    Assert.AreEqual(0, lProgs.Count, 'slot cleared');
  finally
    FreeAndNil(lProgs);
  end;
end;

// 'NPO1.nl' and 'npo1.nl' are two guide ids (the store and its lookups are
// case-sensitive): the XMLTV must not fold them into one
procedure TOutputBuilderTests.XmltvKeepsCaseDistinctTvgIds;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lProgs: TEpgProgrammeList;
  lListId: Integer;
  lXml: string;

  procedure Add(const ATvg, ATitle: string);
  var
    lProg: TEpgProgramme;
  begin
    lProg := TEpgProgramme.Create;
    lProg.ChannelTvgId := ATvg;
    lProg.StartUtc := IncHour(NowUtc, 1);
    lProg.StopUtc := IncHour(lProg.StartUtc, 1);
    lProg.Title := ATitle;
    lProgs.Add(lProg);
  end;

begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(ctLive, 'u1', 'Upper', 'NPO1.nl', 'http://provider/live/u/p/1.ts'));
  lSnap.Streams.Add(MakeStream(ctLive, 'u2', 'Lower', 'npo1.nl', 'http://provider/live/u/p/2.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lProgs := TEpgProgrammeList.Create(True);
  Add('NPO1.nl', 'Upper show');
  Add('npo1.nl', 'Lower show');
  lStore.ReplaceEpg(1, lProgs);
  FreeAndNil(lProgs);
  lListId := SeedListAll(lStore);

  lXml := BuildXmltv(lStore, lListId);
  Assert.IsTrue(lXml.Contains('<channel id="NPO1.nl">'), 'upper-case id has its channel');
  Assert.IsTrue(lXml.Contains('<channel id="npo1.nl">'), 'lower-case id has its channel');
  Assert.IsTrue(lXml.Contains('channel="NPO1.nl"><title>Upper show</title>'), 'upper-case id keeps its programme');
  Assert.IsTrue(lXml.Contains('channel="npo1.nl"><title>Lower show</title>'), 'lower-case id keeps its programme');
end;

procedure TOutputBuilderTests.FindListForPathReadsSpaceAsPlus;
var
  lStore: IStore;
  lList, lFound: TCustomList;
begin
  lStore := NewStore(FDbPath);
  lList := TCustomList.Create;
  try
    lList.Name := 'L';
    lList.OutputUsername := 'box+1';
    lList.OutputPassword := 'a+b';
    lStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;
  lFound := FindListForPath(lStore, 'box+1', 'a+b');
  try
    Assert.IsNotNull(lFound, 'login as stored');
  finally
    FreeAndNil(lFound);
  end;
  // what MARS hands us after form-decoding the path tokens
  lFound := FindListForPath(lStore, 'box 1', 'a b');
  try
    Assert.IsNotNull(lFound, '+ decoded to a space still matches');
  finally
    FreeAndNil(lFound);
  end;
  lFound := FindListForPath(lStore, 'box 1', 'a c');
  try
    Assert.IsNull(lFound, 'a wrong password still fails');
  finally
    FreeAndNil(lFound);
  end;
end;

procedure TOutputBuilderTests.MediaServerBaseUrlFollowsPublicBaseUrl;
begin
  // Docker port mapping: container 7777 published as 9000
  Assert.AreEqual('http://192.168.1.250:9000', MediaServerBaseUrl('http://192.168.1.250:9000', False, 7777),
    'port of publicBaseUrl');
  Assert.AreEqual('https://tv.example:8443', MediaServerBaseUrl('https://tv.example:8443/', False, 7777),
    'scheme of publicBaseUrl');
  Assert.AreEqual('https://localhost:7777', MediaServerBaseUrl('', True, 7777), 'no publicBaseUrl: config');
  Assert.AreEqual('http://localhost:7777', MediaServerBaseUrl('', False, 7777), 'no publicBaseUrl, no TLS');
end;

initialization
  TDUnitX.RegisterTestFixture(TOutputBuilderTests);

end.
