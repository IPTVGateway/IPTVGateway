unit Test.OutputBuilder;

{ Tests for IPTV.Output.Builder against a seeded store: the M3U carries raw
  upstream URLs, and the XMLTV is restricted to the chosen channels' tvg-ids. }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TOutputBuilderTests = class
  private
    FDbPath: string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure M3UContainsRawUpstreamUrl;
    [Test] procedure XmltvOnlyForChosenTvgIds;
    [Test] procedure XmltvChannelCarriesLogo;
    [Test] procedure ItemTvgIdOverrideFlowsToOutput;
    [Test] procedure ItemTvgIdOverrideRelabelsUpstreamEpg;
    [Test] procedure M3uSequentialChnoIsUnique;
    [Test] procedure DummyFillsChannelsWithoutEpg;
    [Test] procedure ProgrammesCarryGroupCategory;
    [Test] procedure GroupFilterIsConsistentAndCaseInsensitive;
    [Test] procedure GroupPrefixInName;
    [Test] procedure NumberPrefixInName;
    [Test] procedure SortNumberPaddingAndIdempotency;
    [Test] procedure SourceLetterGroupsByProvider;
    [Test] procedure IdSortPrefixReordersAndKeepsEpg;
    [Test] procedure PlexUsesUniqueBouquetNumbers;
    [Test] procedure CatchupFlowsFromCatalogToOutput;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.DateUtils,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.Epg, IPTV.Model.CustomList,
  IPTV.Storage.Intf, IPTV.Storage.SQLite, IPTV.Output.Builder;

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
  P: Integer;
begin
  Result := 0;
  P := Pos(ASub, AText);
  while P > 0 do
  begin
    Inc(Result);
    P := Pos(ASub, AText, P + Length(ASub));
  end;
end;

// add every stream matching AFilterSearch ('' => all) to a fresh list; returns list id
function SeedListAll(const Store: IStore): Integer;
var
  Lst: TCustomList;
  ListId: Integer;
  F: TCatalogFilter;
  It: TCustomItem;
  I: Integer;
begin
  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    for I := 0 to Streams.Count - 1 do
    begin
      It := TCustomItem.Create;
      try
        It.ListId := ListId; It.StreamItemId := Streams[I].Id; It.ContentType := ctLive;
        Store.SaveItem(It);
      finally It.Free; end;
    end;
  finally Streams.Free; end;
  Result := ListId;
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
function Seed(const Store: IStore): Integer;
var
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  F: TCatalogFilter;
  ListId: Integer;
  It: TCustomItem;
begin
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(ctLive, 's1', 'NPO 1', 'nl1', 'http://provider/live/u/p/1.ts'));
  Snap.Streams.Add(MakeStream(ctLive, 's2', 'BBC One', 'uk1', 'http://provider/live/u/p/2.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Progs := TEpgProgrammeList.Create(True);
  P := TEpgProgramme.Create; P.ChannelTvgId := 'nl1';
  P.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  P.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0); P.Title := 'NL News'; Progs.Add(P);
  P := TEpgProgramme.Create; P.ChannelTvgId := 'uk1';
  P.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  P.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0); P.Title := 'UK News'; Progs.Add(P);
  Store.ReplaceEpg(1, Progs);
  Progs.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  // put only NPO 1 (nl1) on the list
  F := Default(TCatalogFilter); F.Search := 'NPO';
  var Streams := Store.LoadStreams(F);
  try
    It := TCustomItem.Create;
    try
      It.ListId := ListId; It.StreamItemId := Streams[0].Id; It.ContentType := ctLive;
      Store.SaveItem(It);
    finally It.Free; end;
  finally Streams.Free; end;

  Result := ListId;
end;

procedure TOutputBuilderTests.M3UContainsRawUpstreamUrl;
var
  Store: IStore;
  M3U: string;
begin
  Store := NewStore(FDbPath);
  var ListId := Seed(Store);
  M3U := BuildM3U(Store, ListId);
  Assert.IsTrue(M3U.StartsWith('#EXTM3U'), 'must be a valid M3U header');
  Assert.IsTrue(M3U.Contains('http://provider/live/u/p/1.ts'), 'raw upstream URL must be embedded');
  Assert.IsTrue(M3U.Contains('tvg-id="nl1"'), 'EXTINF carries tvg-id');
  Assert.IsFalse(M3U.Contains('uk1'), 'channel not on the list must be absent');
end;

// Plex reads channel logos from the XMLTV <channel><icon>, not from the lineup.
procedure TOutputBuilderTests.XmltvChannelCarriesLogo;
var
  Store: IStore;
  Xml: string;
begin
  Store := NewStore(FDbPath);
  var ListId := Seed(Store);
  var Items := Store.LoadItems(ListId);
  try
    Items[0].LogoOverride := 'http://logo/npo1.png';
    Store.SaveItem(Items[0]);
  finally Items.Free; end;
  Xml := BuildXmltv(Store, ListId);
  Assert.IsTrue(Xml.Contains('<channel id="nl1"><display-name>NPO 1</display-name><icon src="http://logo/npo1.png"/></channel>'),
    'channel element carries the effective logo');
end;

procedure TOutputBuilderTests.XmltvOnlyForChosenTvgIds;
var
  Store: IStore;
  Xml: string;
begin
  Store := NewStore(FDbPath);
  var ListId := Seed(Store);
  Xml := BuildXmltv(Store, ListId);
  Assert.IsTrue(Xml.Contains('<channel id="nl1">'), 'chosen channel present');
  Assert.IsTrue(Xml.Contains('NL News'), 'chosen channel programme present');
  Assert.IsFalse(Xml.Contains('uk1'), 'unchosen tvg-id must be excluded from EPG');
  Assert.IsFalse(Xml.Contains('UK News'), 'unchosen programme must be excluded');
end;

// A channel with a MISSING upstream tvg-id gets a per-item override; the override
// must drive BOTH the M3U tvg-id and the XMLTV <channel id> (and thus the EPG).
procedure TOutputBuilderTests.ItemTvgIdOverrideFlowsToOutput;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  F: TCatalogFilter;
  It: TCustomItem;
  ListId: Integer;
  M3U, Xml: string;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(ctLive, 's9', 'Local Channel', '', 'http://provider/live/u/p/9.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // EPG only exists under the OVERRIDE id
  Progs := TEpgProgrammeList.Create(True);
  P := TEpgProgramme.Create; P.ChannelTvgId := 'over.id';
  P.StartUtc := EncodeDateTime(2026, 6, 14, 20, 0, 0, 0);
  P.StopUtc := EncodeDateTime(2026, 6, 14, 21, 0, 0, 0); P.Title := 'Over News'; Progs.Add(P);
  Store.ReplaceEpg(1, Progs);
  Progs.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  F := Default(TCatalogFilter); F.Search := 'Local';
  var Streams := Store.LoadStreams(F);
  try
    It := TCustomItem.Create;
    try
      It.ListId := ListId; It.StreamItemId := Streams[0].Id; It.ContentType := ctLive;
      It.TvgIdOverride := 'over.id';
      Store.SaveItem(It);
    finally It.Free; end;
  finally Streams.Free; end;

  M3U := BuildM3U(Store, ListId);
  Assert.IsTrue(M3U.Contains('tvg-id="over.id"'), 'M3U uses the per-item tvg-id override');

  Xml := BuildXmltv(Store, ListId);
  Assert.IsTrue(Xml.Contains('<channel id="over.id">'), 'XMLTV channel id uses the override');
  Assert.IsTrue(Xml.Contains('Over News'), 'EPG resolves via the override id');
end;

// Relabel direction: the provider EPG is stored under the UPSTREAM id, and the
// override re-keys it on output. The guide must follow the channel to the override
// id (and the upstream id must NOT leak into the served XMLTV).
procedure TOutputBuilderTests.ItemTvgIdOverrideRelabelsUpstreamEpg;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  F: TCatalogFilter;
  It: TCustomItem;
  ListId: Integer;
  Xml: string;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(ctLive, 's7', 'Sport HD', 'prov.x', 'http://provider/live/u/p/7.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // provider EPG is stored under the UPSTREAM id 'prov.x'
  Progs := TEpgProgrammeList.Create(True);
  P := TEpgProgramme.Create; P.ChannelTvgId := 'prov.x';
  P.StartUtc := EncodeDateTime(2026, 6, 14, 20, 0, 0, 0);
  P.StopUtc := EncodeDateTime(2026, 6, 14, 21, 0, 0, 0); P.Title := 'Big Match'; Progs.Add(P);
  Store.ReplaceEpg(1, Progs);
  Progs.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  // override re-keys the channel to 'mine.x'
  F := Default(TCatalogFilter); F.Search := 'Sport';
  var Streams := Store.LoadStreams(F);
  try
    It := TCustomItem.Create;
    try
      It.ListId := ListId; It.StreamItemId := Streams[0].Id; It.ContentType := ctLive;
      It.TvgIdOverride := 'mine.x';
      Store.SaveItem(It);
    finally It.Free; end;
  finally Streams.Free; end;

  Xml := BuildXmltv(Store, ListId);
  Assert.IsTrue(Xml.Contains('<channel id="mine.x">'), 'channel advertised under the override id');
  Assert.IsTrue(Xml.Contains('channel="mine.x"'), 'upstream EPG is re-keyed to the override id');
  Assert.IsTrue(Xml.Contains('Big Match'), 'the upstream programme still appears');
  Assert.IsFalse(Xml.Contains('prov.x'), 'the raw upstream id must not leak into the output');
end;

// With ASequentialChno the M3U must number channels 1..N globally-unique (Plex M3U
// tuners reject duplicate channel numbers) — even when items carry colliding
// per-group numbers (e.g. two groups each starting at 1).
procedure TOutputBuilderTests.M3uSequentialChnoIsUnique;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  F: TCatalogFilter;
  ListId: Integer;
  M3U: string;
  It: TCustomItem;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(ctLive, 'a', 'Alpha', 'a.nl', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(ctLive, 'b', 'Bravo', 'b.nl', 'http://p/b.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  // both items get channel_number = 1 (the colliding per-group case)
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    for var I := 0 to Streams.Count - 1 do
    begin
      It := TCustomItem.Create;
      try
        It.ListId := ListId; It.StreamItemId := Streams[I].Id;
        It.ContentType := ctLive; It.ChannelNumber := 1;
        Store.SaveItem(It);
      finally It.Free; end;
    end;
  finally Streams.Free; end;

  M3U := BuildM3U(Store, ListId, '', True); // sequential
  Assert.IsTrue(M3U.Contains('tvg-chno="1"'), 'first channel numbered 1');
  Assert.IsTrue(M3U.Contains('tvg-chno="2"'), 'second channel numbered 2 (not a duplicate 1)');
end;

// A channel WITHOUT real EPG (incl. one with no tvg-id at all) gets dummy blocks
// carrying the group-title as <category>; a channel WITH EPG keeps its programme
// and gets no dummy. Also verifies the synthetic id (iptv-<sid>) couples the M3U
// and XMLTV for the id-less channel.
procedure TOutputBuilderTests.DummyFillsChannelsWithoutEpg;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  ListId: Integer;
  Xml, M3U: string;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStreamG(ctLive, 's1', 'NPO 1', 'nl1', 'Nederland', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStreamG(ctLive, 's2', 'Filler HD', 'fx', 'Sport', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStreamG(ctLive, 's3', 'No Guide', '', 'Sport', 'http://p/3.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // real EPG only for nl1
  Progs := TEpgProgrammeList.Create(True);
  P := TEpgProgramme.Create; P.ChannelTvgId := 'nl1';
  P.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  P.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0); P.Title := 'NL News'; Progs.Add(P);
  Store.ReplaceEpg(1, Progs);
  Progs.Free;

  ListId := SeedListAll(Store);

  Xml := BuildXmltv(Store, ListId, 0, TDummyEpgOptions.Make(True, 120, 12, 48));
  Assert.IsTrue(Xml.Contains('Live programma'), 'dummy programmes are generated');
  Assert.IsTrue(Xml.Contains('<category>Sport</category>'), 'dummy carries the group-title category');
  Assert.IsTrue(Xml.Contains('channel id="iptv-'), 'id-less channel gets a synthetic id');
  Assert.IsTrue(Xml.Contains('NL News'), 'the channel WITH real EPG keeps its programme');
  // the real-EPG channel must NOT also get dummy filler under its id
  Assert.IsFalse(Xml.Contains('channel="nl1"><title>Live programma'),
    'a channel with real EPG gets no dummy');

  M3U := BuildM3U(Store, ListId);
  Assert.IsTrue(M3U.Contains('tvg-id="iptv-'), 'M3U uses the same synthetic id, so dummy couples');
end;

// Every real programme gets the channel's group-title as a <category>, so the
// Plex/Jellyfin guide can group by it.
procedure TOutputBuilderTests.ProgrammesCarryGroupCategory;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  ListId: Integer;
  Xml: string;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStreamG(ctLive, 's1', 'NPO 1', 'nl1', 'Nederland', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Progs := TEpgProgrammeList.Create(True);
  P := TEpgProgramme.Create; P.ChannelTvgId := 'nl1';
  P.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  P.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0); P.Title := 'NL News'; Progs.Add(P);
  Store.ReplaceEpg(1, Progs);
  Progs.Free;

  ListId := SeedListAll(Store);

  Xml := BuildXmltv(Store, ListId, 0, TDummyEpgOptions.Off);
  Assert.IsTrue(Xml.Contains('NL News'), 'the real programme is present');
  Assert.IsTrue(Xml.Contains('<category>Nederland</category>'),
    'the real programme carries the group-title category');
end;

// The global group filter narrows M3U + XMLTV to the SAME channel set (matching is
// case-insensitive), so the box's documents always agree.
procedure TOutputBuilderTests.GroupFilterIsConsistentAndCaseInsensitive;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  ListId: Integer;
  M3U, Xml: string;
  Channels: TOutputChannelList;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStreamG(ctLive, 'a', 'Alpha', 'a.nl', 'News', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStreamG(ctLive, 'b', 'Bravo', 'b.nl', 'Sport', 'http://p/b.ts'));
  Snap.Streams.Add(MakeStreamG(ctLive, 'c', 'Charlie', 'c.nl', 'Sport', 'http://p/c.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  ListId := SeedListAll(Store);

  // filter to 'sport' (lower-case) — must match the 'Sport' group (2 channels)
  Channels := SelectOutputChannels(Store, ListId, ['sport']);
  try
    Assert.AreEqual(2, Channels.Count, 'two channels are in the Sport group');
  finally
    Channels.Free;
  end;

  M3U := BuildM3U(Store, ListId, '', False, ['sport']);
  Xml := BuildXmltv(Store, ListId, 0, TDummyEpgOptions.Off, ['sport']);
  Assert.AreEqual(2, CountSubstr(M3U, '#EXTINF'), 'M3U has exactly the 2 Sport channels');
  Assert.AreEqual(2, CountSubstr(Xml, '<channel '), 'XMLTV has exactly the 2 Sport channels');
  Assert.IsFalse(M3U.Contains('Alpha'), 'the News-group channel is filtered out of the M3U');
  Assert.IsFalse(Xml.Contains('a.nl'), 'the News-group channel is filtered out of the XMLTV');
end;

// With APrefixGroup the visible name is "Group · Name" in BOTH the M3U (tvg-name +
// display) and the XMLTV <channel>, while group-title and the tvg-id are unchanged.
procedure TOutputBuilderTests.GroupPrefixInName;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  ListId: Integer;
  M3U, Xml: string;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStreamG(ctLive, 'a', 'NPO 1', 'nl1', 'Sport', 'http://p/a.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  ListId := SeedListAll(Store);

  // default (no prefix): plain name
  M3U := BuildM3U(Store, ListId);
  Assert.IsTrue(M3U.Contains('group-title="Sport"'), 'group-title stays the group');
  Assert.IsTrue(M3U.Contains(',NPO 1'#10) or M3U.Contains(',NPO 1'), 'plain display name by default');

  // with prefix on: name becomes "Sport <middot> NPO 1"
  M3U := BuildM3U(Store, ListId, '', False, nil, TNameOptions.Make(True, False, False));
  Assert.IsTrue(M3U.Contains('Sport ' + #$B7 + ' NPO 1'), 'M3U name is prefixed with the group');
  Assert.IsTrue(M3U.Contains('group-title="Sport"'), 'group-title is unchanged when prefixing');
  Assert.IsTrue(M3U.Contains('tvg-id="nl1"'), 'tvg-id is unchanged when prefixing');

  Xml := BuildXmltv(Store, ListId, 0, TDummyEpgOptions.Off, nil, TNameOptions.Make(True, False, False));
  Assert.IsTrue(Xml.Contains('<display-name>Sport ' + #$B7 + ' NPO 1</display-name>'),
    'XMLTV channel display-name is prefixed with the group');
end;

// With ANumberName the visible name is prefixed with a running number in OUTPUT
// order (groups A→Z, channels A→Z), so a name-sort on the consumer reproduces the
// bouquet order. Combinable with the group prefix.
procedure TOutputBuilderTests.NumberPrefixInName;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  ListId: Integer;
  M3U, Xml: string;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  // canonical order is by group A→Z then channel: News/Alpha (1), Sport/Bravo (2)
  Snap.Streams.Add(MakeStreamG(ctLive, 'a', 'Alpha', 'a.nl', 'News', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStreamG(ctLive, 'b', 'Bravo', 'b.nl', 'Sport', 'http://p/b.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  ListId := SeedListAll(Store);

  // number only: "1 Alpha" before "2 Bravo"
  M3U := BuildM3U(Store, ListId, '', False, nil, TNameOptions.Make(False, True, False));
  Assert.IsTrue(M3U.Contains(',1 Alpha'), 'first channel numbered 1 in the name');
  Assert.IsTrue(M3U.Contains(',2 Bravo'), 'second channel numbered 2 in the name');
  Assert.IsTrue(M3U.IndexOf('1 Alpha') < M3U.IndexOf('2 Bravo'), 'numbers follow output order');

  Xml := BuildXmltv(Store, ListId, 0, TDummyEpgOptions.Off, nil, TNameOptions.Make(False, True, False));
  Assert.IsTrue(Xml.Contains('<display-name>1 Alpha</display-name>'), 'XMLTV name numbered too');

  // number + group together: "1 News · Alpha"
  M3U := BuildM3U(Store, ListId, '', False, nil, TNameOptions.Make(True, True, False));
  Assert.IsTrue(M3U.Contains('1 News ' + #$B7 + ' Alpha'), 'number + group combine in the name');
end;

// After "Renumber bouquet" (unique numbers 100, 101, 200 …) the Plex surfaces use
// those numbers (GuideNumber/tvg-chno/id-sort prefix); with a duplicate or a
// missing number they fall back to the running position 1,2,3.
procedure TOutputBuilderTests.PlexUsesUniqueBouquetNumbers;
var
  L: TOutputChannelList;

  procedure Add(const AName: string; ANumber: Integer);
  var
    C: TOutputChannel;
  begin
    C := TOutputChannel.Create;
    C.Name := AName;
    C.Number := ANumber;
    C.StreamItemId := L.Count + 1;
    L.Add(C);
  end;

begin
  L := TOutputChannelList.Create(True);
  try
    Add('NPO 1', 100);
    Add('NPO 2', 101);
    Add('ESPN 3', 312);
    Assert.AreEqual<Integer>(312, OutputNumbers(L)[2], 'own numbers when unique');
    Assert.AreEqual('312 ESPN 3', ComputeGuideIds(L, True)[2], 'id-sort uses the bouquet number');
    Assert.AreEqual('100 NPO 1', ComputeGuideIds(L, True)[0]);
    var M3U := BuildM3UChannels(L, '', True);
    Assert.IsTrue(M3U.Contains('tvg-chno="312"'), 'Plex M3U chno = bouquet number');

    L[1].Number := 100; // duplicate -> fall back to positions
    Assert.AreEqual<Integer>(3, OutputNumbers(L)[2], 'position when not unique');
    Assert.AreEqual('3 ESPN 3', ComputeGuideIds(L, True)[2]);
    L[1].Number := 0;   // missing -> positions too
    Assert.AreEqual<Integer>(2, OutputNumbers(L)[1]);
  finally
    L.Free;
  end;
end;

// ChannelDisplayName is the SINGLE numbering source shared by the XMLTV
// display-name and the lineup GuideName/Number: ASeq is the channel's position
// (== the lineup GuideNumber), zero-padded on the highest number (ATotal). Verify
// the padding width, idempotency, and that the emitted number equals the seq.
procedure TOutputBuilderTests.SortNumberPaddingAndIdempotency;
var
  C: TOutputChannel;

  function DisplayNum(const AName: string; ASeq, ATotal: Integer): string;
  begin
    C.Name := AName;
    Result := ChannelDisplayName(C, False, True, ASeq, ATotal);
  end;

begin
  C := TOutputChannel.Create;
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
    C.Free;
  end;
end;

// With ShowSource, each channel gets a per-provider letter (A = 1st source, B =
// 2nd) so Plex groups+sorts by provider; the number resets per source. Verify the
// M3U and XMLTV display names, that both surfaces agree, and that provider A sorts
// before provider B (A… < B…).
procedure TOutputBuilderTests.SourceLetterGroupsByProvider;
var
  Store: IStore;
  S1, S2: TSourceConfig;
  Sid1, Sid2: Integer;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId: Integer;
  F: TCatalogFilter;
  It: TCustomItem;
  M3U, Xml: string;
  I: Integer;
begin
  Store := NewStore(FDbPath);
  // two providers, in this order → A, B
  S1 := TSourceConfig.Create;
  try S1.Name := 'Provider One'; S1.Kind := skM3U; Sid1 := Store.SaveSource(S1); finally S1.Free; end;
  S2 := TSourceConfig.Create;
  try S2.Name := 'Provider Two'; S2.Kind := skM3U; Sid2 := Store.SaveSource(S2); finally S2.Free; end;

  Snap := TSourceSnapshot.Create(Sid1);
  Snap.Streams.Add(MakeStreamG(ctLive, 'a', 'NPO 1', 'nl1', 'News', 'http://p1/a.ts'));
  Snap.Streams.Add(MakeStreamG(ctLive, 'b', 'NPO 2', 'nl2', 'News', 'http://p1/b.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Snap := TSourceSnapshot.Create(Sid2);
  Snap.Streams.Add(MakeStreamG(ctLive, 'c', 'HBO', 'hbo', 'Film', 'http://p2/c.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    for I := 0 to Streams.Count - 1 do
    begin
      It := TCustomItem.Create;
      try
        It.ListId := ListId; It.StreamItemId := Streams[I].Id; It.ContentType := ctLive;
        Store.SaveItem(It);
      finally It.Free; end;
    end;
  finally Streams.Free; end;

  // source letter + number (resets per source): provider 1 → "A 1/2 NPO…",
  // provider 2 → "B 1 HBO". (Our file stays in canonical/group order; the letter is
  // what makes PLEX's own alphabetical sort group by provider.)
  M3U := BuildM3U(Store, ListId, '', False, nil, TNameOptions.Make(False, True, True));
  Assert.IsTrue(M3U.Contains(',A 1 NPO 1'), 'provider A, first channel');
  Assert.IsTrue(M3U.Contains(',A 2 NPO 2'), 'provider A, second channel — number increments within the source');
  Assert.IsTrue(M3U.Contains(',B 1 HBO'), 'provider B channel, number resets to 1');
  // intent: Plex sorts these names alphabetically, so provider A precedes provider B
  Assert.IsTrue('A 1 NPO 1' < 'B 1 HBO', 'the A/B prefixes sort provider A before B');

  // XMLTV display-name matches the M3U (single source of truth)
  Xml := BuildXmltv(Store, ListId, 0, TDummyEpgOptions.Off, nil, TNameOptions.Make(False, True, True));
  Assert.IsTrue(Xml.Contains('<display-name>A 1 NPO 1</display-name>'), 'XMLTV name matches the M3U');
  Assert.IsTrue(Xml.Contains('<display-name>B 1 HBO</display-name>'), 'XMLTV B channel matches');
  // the channel id / tvg-id is NOT touched
  Assert.IsTrue(Xml.Contains('<channel id="nl1">'), 'tvg-id id untouched by the source letter');
end;

// With IdSort, the published channel-id (M3U tvg-id AND XMLTV channel/programme id)
// is prefixed with a zero-padded sort number in output order — so a consumer that
// sorts by id (Plex) follows the bouquet. The real upstream EPG must still couple
// (channel + programme re-keyed together), and the plain box output stays untouched.
procedure TOutputBuilderTests.IdSortPrefixReordersAndKeepsEpg;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  ListId: Integer;
  M3U, Xml, PlainM3U: string;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  // canonical order: group News/Alpha (1), then Sport/Bravo (2)
  Snap.Streams.Add(MakeStreamG(ctLive, 'a', 'Alpha', 'a.nl', 'News', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStreamG(ctLive, 'b', 'Bravo', 'b.nl', 'Sport', 'http://p/b.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // real EPG stored under the upstream tvg-id 'a.nl'
  Progs := TEpgProgrammeList.Create(True);
  P := TEpgProgramme.Create; P.ChannelTvgId := 'a.nl';
  P.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  P.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0); P.Title := 'Alpha News'; Progs.Add(P);
  Store.ReplaceEpg(1, Progs);
  Progs.Free;

  ListId := SeedListAll(Store);

  // plain box output keeps the real tvg-id (no prefix)
  PlainM3U := BuildM3U(Store, ListId);
  Assert.IsTrue(PlainM3U.Contains('tvg-id="a.nl"'), 'box output keeps the real tvg-id');
  Assert.IsFalse(PlainM3U.Contains('tvg-id="1 Alpha"'), 'box output is NOT id-prefixed');

  // Plex M3U: id = sort number (width 1 for 2 channels) + readable channel name,
  // because Plex shows the id as the tile title: "1 Alpha", "2 Bravo"
  M3U := BuildM3U(Store, ListId, '', False, nil, TNameOptions.Make(False, False, False, True));
  Assert.IsTrue(M3U.Contains('tvg-id="1 Alpha"'), 'Plex M3U tvg-id = sort number + name');
  Assert.IsTrue(M3U.Contains('tvg-id="2 Bravo"'), 'second channel prefixed 2');
  Assert.IsFalse(M3U.Contains('tvg-id="1_a.nl"'), 'no raw tvg-id in the Plex id');

  // XMLTV: channel id AND programme channel both use the prefixed id (so EPG couples),
  // and the real programme is present (re-keyed from a.nl → "1 Alpha")
  Xml := BuildXmltv(Store, ListId, 0, TDummyEpgOptions.Off, nil, TNameOptions.Make(False, False, False, True));
  Assert.IsTrue(Xml.Contains('<channel id="1 Alpha">'), 'XMLTV channel id is the prefixed id');
  Assert.IsTrue(Xml.Contains('channel="1 Alpha">'), 'programme is re-keyed to the prefixed id');
  Assert.IsTrue(Xml.Contains('Alpha News'), 'the real EPG programme still appears (coupling kept)');
  // sort intent: "1 Alpha" < "2 Bravo" so an id-sort yields bouquet order
  Assert.IsTrue('1 Alpha' < '2 Bravo', 'prefixed ids sort in bouquet order');
end;

// catch-up: archive_days survives the merge, reaches the output channel and
// the M3U (box only, not Plex); the timeshift URL uses the source's creds,
// the provider's stream id and its clock offset.
procedure TOutputBuilderTests.CatchupFlowsFromCatalogToOutput;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  S: TStreamItem;
  ListId: Integer;
  Chans: TOutputChannelList;
  M3U: string;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://prov.tv/';
    Src.Username := 'pu'; Src.Password := 'pp'; Src.Enabled := True;
    Src.TzOffsetMin := 60;
    Store.SaveSource(Src);
    Assert.AreEqual(1, Src.Id, 'first source gets id 1 (MakeStream uses source 1)');
  finally
    Src.Free;
  end;
  var L := Store.LoadSources;
  try
    Assert.AreEqual(60, L[0].TzOffsetMin, 'tz offset persisted');
  finally
    L.Free;
  end;

  Snap := TSourceSnapshot.Create(1);
  S := MakeStream(ctLive, '4711', 'NPO 1', 'nl1', 'http://prov.tv/live/pu/pp/4711.ts');
  S.ArchiveDays := 3;
  Snap.Streams.Add(S);
  Snap.Streams.Add(MakeStream(ctLive, '4712', 'NPO 4K', 'nl1', 'http://prov.tv/live/pu/pp/4712.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  ListId := SeedListAll(Store);

  Chans := Store.LoadOutputChannels(ListId);
  try
    Assert.AreEqual(2, Chans.Count);
    for var C in Chans do
      if C.Name = 'NPO 1' then
      begin
        Assert.AreEqual(3, C.ArchiveDays);
        Assert.AreEqual('4711', C.UpstreamId);
      end
      else
        Assert.AreEqual(0, C.ArchiveDays);
    M3U := BuildM3UChannels(Chans, '', False);
    Assert.AreEqual(1, CountSubstr(M3U, 'catchup="xc" catchup-days="3"'), 'only the archived channel');
    Assert.IsFalse(BuildM3UChannels(Chans, '', True).Contains('catchup='), 'not on the Plex M3U');
  finally
    Chans.Free;
  end;

  // a re-merge without archive clears it again
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(ctLive, '4711', 'NPO 1', 'nl1', 'http://prov.tv/live/pu/pp/4711.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  var LS := Store.LoadStreams(Default(TCatalogFilter));
  try
    for var X in LS do
      if X.UpstreamId = '4711' then
      begin
        Assert.AreEqual(0, X.ArchiveDays, 'archive dropped upstream');
        Assert.AreEqual('http://prov.tv/timeshift/pu/pp/60/2026-11-12:21-00/4711.ts',
          TimeshiftUpstreamUrl(Store, X, 60, EncodeDateTime(2026, 11, 12, 20, 0, 0, 0), ''));
      end;
  finally
    LS.Free;
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TOutputBuilderTests);

end.
