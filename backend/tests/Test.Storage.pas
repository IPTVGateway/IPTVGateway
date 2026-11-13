unit Test.Storage;

{ Integration tests for the SQLite store against a fresh temp database per test.
  Exercises CRUD, the MergeSnapshot diff/is_new logic, filters, lists/groups/
  items, bulk add, credential resolution and the resolved output ordering. }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TStorageTests = class
  private
    FDbPath: string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;

    [Test] procedure SourceCrudRoundtrips;
    [Test] procedure SaveSourceUpdateRoundtrips;
    [Test] procedure DeleteSourceCascades;
    [Test] procedure SaveListUpdateRoundtrips;
    [Test] procedure MarkCategoriesSeenClearsNew;
    [Test] procedure LoadStreamByIdFoundAndMissing;
    [Test] procedure LoadKnownTvgIdsDistinctSortedByName;
    [Test] procedure AppStateGetSetRoundtrips;
    [Test] procedure LoadListTvgIdsDistinctNonEmpty;
    [Test] procedure DeleteItemRemovesIt;
    [Test] procedure MergeFlagsNewThenStaysStable;
    [Test] procedure MarkStreamsSeenClearsNew;
    [Test] procedure FilterByPrefixAndSearch;
    [Test] procedure MultiWordSearchIsAnd;
    [Test] procedure DiscoverPrefixesCountsAndOrders;
    [Test] procedure FilterOnlyNew;
    [Test] procedure ListGroupItemCrud;
    [Test] procedure SaveGroupUpdateRenamesAndKeepsList;
    [Test] procedure SaveItemUpdateKeepsListAndStream;
    [Test] procedure AddItemsBulkDedupes;
    [Test] procedure LoadListStreamByIdScopesToList;
    [Test] procedure LoadStreamSiblingsMatchesByTvgIdAndName;
    // audit-driven gap fills (round 8): core invariants not previously covered
    [Test] procedure MergeFlagsNewItemAmongSeenOnes;
    [Test] procedure OutputChannelNumberOrderingWithinGroup;
    [Test] procedure FindListByCredentialsRespectsEnabledAndUser;
    [Test] procedure EpgKeepsCurrentlyAiringProgramme;
    [Test] procedure DiscoverPrefixesFindsUnicodeBarPrefix;
    [Test] procedure PrefixFilterEscapesLikeWildcards;
    // strip-prefix matrix: none / single / multiple configured prefixes
    [Test] procedure AddItemsNoPrefixesKeepsUpstreamName;
    [Test] procedure AddItemsStripsConfiguredPrefix;
    [Test] procedure AddItemsStripsOneOfMultipleSemicolonPrefixes;
    [Test] procedure RestripUpdatesAutoNamesKeepsManualRenames;
    [Test] procedure RestripAllItemsAppliesCurrentPrefixes;
    [Test] procedure RestripAllItemsHandlesMultipleSemicolonPrefixes;
    [Test] procedure AddItemsStripsConfiguredSuffix;
    [Test] procedure RawGroupReplacedInPlaceBy4KPlus;
    [Test] procedure StreamVariantsFindsAllQualitiesOfOneChannel;
    [Test] procedure RestripGroupItemsCleansExistingGroup;
    [Test] procedure DedupeListItemsByUrl;
    [Test] procedure SortGroupAlphabeticallyNumbersByName;
    [Test] procedure ReorderGroupItemsNumbersByGivenOrder;
    [Test] procedure BouquetRenumberSurvivesGroupReorder;
    [Test] procedure StoresUnicodeNamesIntact;
    [Test] procedure ClearGroupItemsRemovesOnlyThatGroup;
    [Test] procedure DeleteListCascades;
    [Test] procedure NameFilterHidesStreamsAndCategories;
    [Test] procedure OversizedFilterTokenIsIgnored;
    [Test] procedure HiddenFlagFollowsSourceFilters;
    [Test] procedure GroupWithVisibleChannelStaysVisible;
    [Test] procedure NameFilterIsSeparatorAware;
    [Test] procedure NameFilterHandlesUnicodeBars;
    [Test] procedure LockingStoreSeparateReadWriteConnections;
    [Test] procedure LockingStoreSingleConnectionFallback;
    [Test] procedure LockingStoreCachesSourcesAndInvalidatesOnWrite;
    [Test] procedure FilterTokensWithQuotesDoNotGrowAndAreRepaired;
    [Test] procedure LoadItemsExposesUpstreamName;
    [Test] procedure ManyExcludeTokensDoNotBreakQuery;
    [Test] procedure PerSourceFiltersApplyInAllSourcesView;
    [Test] procedure FindListByCredentials_DefaultAndNamed;
    [Test] procedure DisabledSourceOrTypeIsNotOffered;
    [Test] procedure SeriesEpisodesResolveOnlyOnTheirList;
    [Test] procedure PathCredentials_DashAndEncoding;
    [Test] procedure ReclassifiedStreamKeepsIdAndListItem;
    [Test] procedure PathCredentials_DashPerField;
    [Test] procedure OutputChannelsOrderAndOverrides;
    [Test] procedure GroupReorderControlsOutputOrder;
    [Test] procedure EpgReplaceAndLoadByTvgId;
    [Test] procedure EpgMaxDaysCapsFutureProgrammes;
    [Test] procedure IngestStatusRecordsUnknownSource;
    [Test] procedure ZapCacheServesAndInvalidates;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.DateUtils, System.Generics.Collections,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.Epg,
  IPTV.Model.CustomList, IPTV.Storage.Intf, IPTV.Storage.SQLite, IPTV.Storage.Locking,
  IPTV.Core.Utils, IPTV.Ingest.Service, IPTV.Output.Builder;

{ helpers }

function NewStore(const APath: string): IStore;
begin
  Result := TSQLiteStore.Create(APath);
  Result.Init;
end;

function MakeStream(ASourceId: Integer; ACt: TContentType;
  const AUpstreamId, AName, AGroup, ATvgId, AUrl: string): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.SourceId := ASourceId;
  Result.ContentType := ACt;
  Result.UpstreamId := AUpstreamId;
  Result.Name := AName;
  Result.GroupTitle := AGroup;
  Result.TvgId := ATvgId;
  Result.UpstreamUrl := AUrl;
end;

procedure TStorageTests.Setup;
begin
  FDbPath := TPath.Combine(TPath.GetTempPath, 'iptvtest_' + TGUID.NewGuid.ToString + '.sqlite');
end;

procedure TStorageTests.TearDown;

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

procedure TStorageTests.SourceCrudRoundtrips;
var
  Store: IStore;
  Src: TSourceConfig;
  Id: Integer;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'Provider A';
    Src.Kind := skXtream;
    Src.Url := 'http://host:8080';
    Src.Username := 'u';
    Src.Password := 'p';
    Src.ContentTypes := [ctLive, ctMovie];
    Id := Store.SaveSource(Src);
    Assert.IsTrue(Id > 0);
  finally
    Src.Free;
  end;

  var L := Store.LoadSources;
  try
    Assert.AreEqual<Integer>(1, L.Count);
    Assert.AreEqual('Provider A', L[0].Name);
    Assert.AreEqual(skXtream, L[0].Kind);
    Assert.IsTrue([ctLive, ctMovie] = L[0].ContentTypes);
  finally
    L.Free;
  end;
end;

procedure TStorageTests.SaveSourceUpdateRoundtrips;
var
  Store: IStore;
  Src: TSourceConfig;
  Id: Integer;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'Orig';
    Src.Kind := skM3U;
    Src.Url := 'http://a';
    Src.ContentTypes := [ctLive];
    Id := Store.SaveSource(Src);
    // update existing
    Src.Name := 'Renamed';
    Src.Url := 'http://b';
    Src.ContentTypes := [ctLive, ctMovie];
    Src.IncludeFilters := ['NL|'];
    Src.StripPrefixes := ['NL', 'UK'];
    Src.UserAgent := 'VLC/3.0.20 LibVLC/3.0.20';
    Src.Referer := 'http://provider.example/c/';
    Src.ForceHls := True;
    Src.AccountStatus := 'Active';
    Src.ExpiresUtc := EncodeDateTime(2027, 3, 1, 12, 0, 0, 0);
    Src.MaxConnections := 2;
    Store.SaveSource(Src);
  finally
    Src.Free;
  end;
  var L := Store.LoadSources;
  try
    Assert.AreEqual<Integer>(1, L.Count, 'update must not insert a second row');
    Assert.AreEqual<Integer>(Id, L[0].Id);
    Assert.AreEqual('Renamed', L[0].Name);
    Assert.AreEqual('http://b', L[0].Url);
    Assert.IsTrue([ctLive, ctMovie] = L[0].ContentTypes);
    Assert.AreEqual<Integer>(1, Length(L[0].IncludeFilters));
    Assert.AreEqual<Integer>(2, Length(L[0].StripPrefixes), 'strip prefixes round-trip');
    Assert.AreEqual('NL', L[0].StripPrefixes[0]);
    Assert.AreEqual('VLC/3.0.20 LibVLC/3.0.20', L[0].UserAgent, 'per-provider UA round-trips');
    Assert.AreEqual('http://provider.example/c/', L[0].Referer, 'per-provider Referer round-trips');
    Assert.IsTrue(L[0].ForceHls, 'per-provider force-HLS round-trips');
    Assert.AreEqual('Active', L[0].AccountStatus, 'account status round-trips');
    Assert.AreEqual(EncodeDateTime(2027, 3, 1, 12, 0, 0, 0), L[0].ExpiresUtc, 1 / SecsPerDay, 'expiry round-trips');
    Assert.AreEqual<Integer>(2, L[0].MaxConnections, 'max connections round-trips');
  finally
    L.Free;
  end;
end;

procedure TStorageTests.DeleteSourceCascades;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  Id: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try Src.Name := 'S'; Src.Kind := skXtream; Src.Url := 'http://h'; Id := Store.SaveSource(Src); finally Src.Free; end;

  Snap := TSourceSnapshot.Create(Id);
  Snap.Streams.Add(MakeStream(Id, ctLive, 'a', 'A', '', 'tv1', 'http://p/a.ts'));
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'c'; Cat.Name := 'Cat';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Progs := TEpgProgrammeList.Create(True);
  P := TEpgProgramme.Create; P.ChannelTvgId := 'tv1'; P.Title := 'X';
  P.StartUtc := EncodeDateTime(2026, 6, 14, 10, 0, 0, 0); P.StopUtc := EncodeDateTime(2026, 6, 14, 11, 0, 0, 0);
  Progs.Add(P);
  Store.ReplaceEpg(Id, Progs);
  Progs.Free;

  Store.DeleteSource(Id);

  Assert.AreEqual<Integer>(0, Store.LoadSources.Count, 'source row gone');
  F := Default(TCatalogFilter); F.SourceId := Id;
  var S := Store.LoadStreams(F);
  try Assert.AreEqual<Integer>(0, S.Count, 'streams cascaded'); finally S.Free; end;
  var C := Store.LoadCategories(F);
  try Assert.AreEqual<Integer>(0, C.Count, 'categories cascaded'); finally C.Free; end;
  var E := Store.LoadEpgForTvgIds(['tv1']);
  try Assert.AreEqual<Integer>(0, E.Count, 'epg cascaded'); finally E.Free; end;
end;

procedure TStorageTests.SaveListUpdateRoundtrips;
var
  Store: IStore;
  Lst: TCustomList;
  Id: Integer;
begin
  Store := NewStore(FDbPath);
  Lst := TCustomList.Create;
  try
    Lst.Name := 'L1'; Lst.OutputUsername := 'u'; Lst.OutputPassword := 'p'; Lst.Enabled := True;
    Id := Store.SaveList(Lst);
    Lst.Name := 'L2'; Lst.OutputUsername := 'u2'; Lst.Enabled := False;
    Store.SaveList(Lst);
  finally
    Lst.Free;
  end;
  var L := Store.LoadLists;
  try
    Assert.AreEqual<Integer>(1, L.Count);
    Assert.AreEqual<Integer>(Id, L[0].Id);
    Assert.AreEqual('L2', L[0].Name);
    Assert.AreEqual('u2', L[0].OutputUsername);
    Assert.IsFalse(L[0].Enabled);
  finally
    L.Free;
  end;
end;

procedure TStorageTests.MarkCategoriesSeenClearsNew;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  F: TCatalogFilter;
  CatId: Integer;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'g'; Cat.Name := 'Group';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter); F.OnlyNew := True;
  var L := Store.LoadCategories(F);
  try
    Assert.AreEqual<Integer>(1, L.Count, 'new category present');
    CatId := L[0].Id;
  finally
    L.Free;
  end;

  Store.MarkCategoriesSeen([CatId]);
  L := Store.LoadCategories(F);
  try
    Assert.AreEqual<Integer>(0, L.Count, 'no longer flagged new after mark-seen');
  finally
    L.Free;
  end;
end;

procedure TStorageTests.LoadStreamByIdFoundAndMissing;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
  Id: Integer;
  S: TStreamItem;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u', 'The Channel', '', '', 'http://p/u.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  F := Default(TCatalogFilter);
  var L := Store.LoadStreams(F);
  try Id := L[0].Id; finally L.Free; end;

  S := Store.LoadStreamById(Id);
  try
    Assert.IsNotNull(S);
    Assert.AreEqual('The Channel', S.Name);
    Assert.AreEqual('http://p/u.ts', S.UpstreamUrl);
  finally
    S.Free;
  end;
  Assert.IsNull(Store.LoadStreamById(999999), 'missing id => nil');
end;

procedure TStorageTests.LoadKnownTvgIdsDistinctSortedByName;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Ids: TArray<TTvgIdInfo>;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'Zeta', '', 'z.tv', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'b', 'Alpha', '', 'a.tv', 'http://p/b.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'c', 'NoGuide', '', '', 'http://p/c.ts')); // no tvg-id
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Ids := Store.LoadKnownTvgIds;
  Assert.AreEqual<Integer>(2, Length(Ids), 'only non-empty tvg-ids, distinct');
  // sorted by sample channel name (case-insensitive): Alpha (a.tv) before Zeta (z.tv)
  Assert.AreEqual('a.tv', Ids[0].TvgId);
  Assert.AreEqual('Alpha', Ids[0].Name);
  Assert.AreEqual('z.tv', Ids[1].TvgId);
end;

procedure TStorageTests.AppStateGetSetRoundtrips;
var
  Store: IStore;
begin
  Store := NewStore(FDbPath);
  Assert.AreEqual('', Store.GetState('missing'), 'unknown key => empty');
  Store.SetState('k', 'v1');
  Assert.AreEqual('v1', Store.GetState('k'), 'value stored');
  Store.SetState('k', 'v2'); // upsert
  Assert.AreEqual('v2', Store.GetState('k'), 'value updated, not duplicated');
end;

procedure TStorageTests.LoadListTvgIdsDistinctNonEmpty;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId: Integer;
  F: TCatalogFilter;
  Ids: TArray<string>;
  Tvgs: TArray<string>;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, '1', 'A', '', 'aa', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '2', 'B', '', 'bb', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '3', 'C', '', '', 'http://p/3.ts')); // no tvg-id
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    SetLength(Ids, Streams.Count);
    for var I := 0 to Streams.Count - 1 do Ids[I] := IntToStr(Streams[I].Id);
  finally
    Streams.Free;
  end;
  // add all three to the list
  var IntIds: TArray<Integer>;
  SetLength(IntIds, Length(Ids));
  for var I := 0 to High(Ids) do IntIds[I] := StrToInt(Ids[I]);
  Store.AddItems(ListId, 0, IntIds);

  Tvgs := Store.LoadListTvgIds;
  Assert.AreEqual<Integer>(2, Length(Tvgs), 'only non-empty, distinct tvg-ids');
  Assert.IsTrue((Tvgs[0] = 'aa') or (Tvgs[1] = 'aa'));
  Assert.IsTrue((Tvgs[0] = 'bb') or (Tvgs[1] = 'bb'));
end;

procedure TStorageTests.DeleteItemRemovesIt;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try Store.AddItems(ListId, 0, [Streams[0].Id]); finally Streams.Free; end;

  var Items := Store.LoadItems(ListId);
  var ItemId: Integer;
  try
    Assert.AreEqual<Integer>(1, Items.Count);
    ItemId := Items[0].Id;
  finally
    Items.Free;
  end;
  Store.DeleteItem(ItemId);
  Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual<Integer>(0, Items.Count, 'item removed');
  finally
    Items.Free;
  end;
end;

procedure TStorageTests.MergeFlagsNewThenStaysStable;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);

  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'x1', 'Channel 1', 'NL', 'nl1', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  var L := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, L.Count);
    Assert.IsTrue(L[0].IsNew, 'first appearance must be flagged new');
  finally
    L.Free;
  end;

  // mark seen, then re-merge the same upstream item: must NOT be re-flagged new
  Store.MarkStreamsSeen([Store.LoadStreams(F)[0].Id]);

  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'x1', 'Channel 1 renamed upstream', 'NL', 'nl1', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  L := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, L.Count, 'same upstream id must not duplicate');
    Assert.IsFalse(L[0].IsNew, 'a seen item must stay seen across refreshes');
    Assert.AreEqual('Channel 1 renamed upstream', L[0].Name, 'metadata refreshes');
  finally
    L.Free;
  end;
end;

procedure TStorageTests.MarkStreamsSeenClearsNew;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  var Id := Store.LoadStreams(F)[0].Id;
  Store.MarkStreamsSeen([Id]);

  F.OnlyNew := True;
  var L := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(0, L.Count, 'no items remain new after mark-seen');
  finally
    L.Free;
  end;
end;

procedure TStorageTests.FilterByPrefixAndSearch;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, '1', 'NL: One', 'NL', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '2', 'NL: Two', 'NL', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '3', 'UK Three', 'UK', '', 'http://p/3.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  F.Prefix := 'NL:';
  var L := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(2, L.Count, 'prefix NL: matches two');
  finally
    L.Free;
  end;

  F := Default(TCatalogFilter);
  F.Search := 'three';
  L := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, L.Count, 'search is case-insensitive contains');
    Assert.AreEqual('UK Three', L[0].Name);
  finally
    L.Free;
  end;
end;

procedure TStorageTests.MultiWordSearchIsAnd;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, '1', 'NL| NPO 1 UHD', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '2', 'NL| NPO 2 HD', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '3', 'UK| BBC UHD', '', '', 'http://p/3.ts'));
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'g1'; Cat.Name := 'NL UHD Sport';
  Snap.Categories.Add(Cat);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'g2'; Cat.Name := 'NL HD News';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // "NL UHD" => AND: only the NL channel that is also UHD
  F := Default(TCatalogFilter);
  F.Search := 'NL UHD';
  var S := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, S.Count, 'AND of both terms');
    Assert.AreEqual('NL| NPO 1 UHD', S[0].Name);
  finally S.Free; end;

  // comma works as a separator too, and applies to categories as well
  var C := Store.LoadCategories(F);
  try
    Assert.AreEqual<Integer>(1, C.Count, 'category AND search');
    Assert.AreEqual('NL UHD Sport', C[0].Name);
  finally C.Free; end;

  // single term still behaves as plain contains
  F := Default(TCatalogFilter);
  F.Search := 'NL';
  S := Store.LoadStreams(F);
  try Assert.AreEqual<Integer>(2, S.Count, 'one term = contains'); finally S.Free; end;
end;

procedure TStorageTests.DiscoverPrefixesCountsAndOrders;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Prefixes: TArray<TPrefixCount>;

  function CountFor(const APrefix: string): Integer;
  var
    P: TPrefixCount;
  begin
    Result := -1; // -1 => prefix not present at all
    for P in Prefixes do
      if P.Prefix = APrefix then
        Exit(P.Count);
  end;

begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, '1', 'NL| One', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '2', 'NL| Two', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '3', 'UK| Three', '', '', 'http://p/3.ts'));
  Snap.Streams.Add(MakeStream(1, ctMovie, '4', 'The Big Movie', '', '', 'http://p/4.ts')); // no delimiter, not a code
  // a group/category whose prefix does NOT appear in any channel name — must
  // still be discovered (groups are filtered by their own names)
  var Cat := TCategory.Create;
  Cat.ContentType := ctLive; Cat.UpstreamId := 'asia'; Cat.Name := 'ASIA | India';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Prefixes := Store.DiscoverPrefixes(1);

  Assert.AreEqual<Integer>(2, CountFor('NL|'), 'NL| occurs twice');
  Assert.AreEqual<Integer>(1, CountFor('UK|'), 'UK| occurs once');
  Assert.AreEqual<Integer>(1, CountFor('ASIA |'), 'a group-only prefix is discovered from category names');
  Assert.AreEqual<Integer>(-1, CountFor('The'), 'an ordinary first word is not a prefix');
  // ordering: most common first
  Assert.IsTrue(Length(Prefixes) >= 2);
  Assert.AreEqual('NL|', Prefixes[0].Prefix, 'most common prefix sorts first');
end;

procedure TStorageTests.FilterOnlyNew;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctMovie, 'm1', 'Movie', 'VOD', '', 'http://p/m.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  F.HasContentType := True;
  F.ContentType := ctLive;
  var L := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(0, L.Count, 'content-type filter excludes movies');
  finally
    L.Free;
  end;
end;

procedure TStorageTests.ListGroupItemCrud;
var
  Store: IStore;
  Lst: TCustomList;
  Grp: TCustomGroup;
  ListId, GroupId: Integer;
begin
  Store := NewStore(FDbPath);
  Lst := TCustomList.Create;
  try
    Lst.Name := 'My List';
    ListId := Store.SaveList(Lst);
  finally
    Lst.Free;
  end;
  Assert.IsTrue(ListId > 0);

  Grp := TCustomGroup.Create;
  try
    Grp.ListId := ListId;
    Grp.Name := 'Favorites';
    Grp.IsFavorite := True;
    GroupId := Store.SaveGroup(Grp);
  finally
    Grp.Free;
  end;

  var G := Store.LoadGroups(ListId);
  try
    Assert.AreEqual<Integer>(1, G.Count);
    Assert.IsTrue(G[0].IsFavorite);
  finally
    G.Free;
  end;

  Store.DeleteGroup(GroupId);
  G := Store.LoadGroups(ListId);
  try
    Assert.AreEqual<Integer>(0, G.Count);
  finally
    G.Free;
  end;
end;

procedure TStorageTests.SaveGroupUpdateRenamesAndKeepsList;
// Regression: updating (renaming) a group must not bind the INSERT-only :l param.
var
  Store: IStore;
  Lst: TCustomList;
  Grp: TCustomGroup;
  ListId: Integer;
begin
  Store := NewStore(FDbPath);
  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  Grp := TCustomGroup.Create;
  try
    Grp.ListId := ListId;
    Grp.Name := 'Old';
    Grp.ContentType := ctLive;
    Grp.IsFavorite := False;
    Store.SaveGroup(Grp);            // INSERT
    Grp.Name := 'New';
    Grp.IsFavorite := True;
    Store.SaveGroup(Grp);            // UPDATE — must NOT raise 'Parameter l not found'
  finally
    Grp.Free;
  end;

  var L := Store.LoadGroups(ListId);
  try
    Assert.AreEqual<Integer>(1, L.Count);
    Assert.AreEqual('New', L[0].Name, 'rename persisted');
    Assert.IsTrue(L[0].IsFavorite, 'favorite persisted');
    Assert.AreEqual<Integer>(ListId, L[0].ListId, 'list_id preserved on update');
  finally
    L.Free;
  end;
end;

procedure TStorageTests.SaveItemUpdateKeepsListAndStream;
// Regression: updating a list item must not bind the INSERT-only :l/:sid params,
// and must preserve list_id + stream_item_id.
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  It: TCustomItem;
  ListId, Sid: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 's', 'Chan', '', '', 'http://p/s.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try Sid := Streams[0].Id; finally Streams.Free; end;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  It := TCustomItem.Create;
  try
    It.ListId := ListId;
    It.StreamItemId := Sid;
    It.CustomGroupId := 0;
    It.ContentType := ctLive;
    It.DisplayName := '';
    Store.SaveItem(It);              // INSERT
    It.DisplayName := 'Renamed';
    It.ChannelNumber := 5;
    Store.SaveItem(It);              // UPDATE — must NOT raise
  finally
    It.Free;
  end;

  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual<Integer>(1, Items.Count);
    Assert.AreEqual('Renamed', Items[0].DisplayName, 'rename persisted');
    Assert.AreEqual<Integer>(5, Items[0].ChannelNumber);
    Assert.AreEqual<Integer>(Sid, Items[0].StreamItemId, 'stream link preserved on update');
    Assert.AreEqual<Integer>(ListId, Items[0].ListId, 'list link preserved on update');
  finally
    Items.Free;
  end;
end;

procedure TStorageTests.AddItemsBulkDedupes;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId, Added: Integer;
  Ids: TArray<Integer>;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'b', 'B', '', '', 'http://p/b.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try
    Lst.Name := 'L';
    ListId := Store.SaveList(Lst);
  finally
    Lst.Free;
  end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    Ids := [Streams[0].Id, Streams[1].Id];
  finally
    Streams.Free;
  end;

  Added := Store.AddItems(ListId, 0, Ids);
  Assert.AreEqual<Integer>(2, Added);

  // adding the same ids again must add nothing (UNIQUE list_id+stream_item_id)
  Added := Store.AddItems(ListId, 0, Ids);
  Assert.AreEqual<Integer>(0, Added, 'bulk add must dedupe already-present items');

  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual<Integer>(2, Items.Count);
  finally
    Items.Free;
  end;
end;

// When a stream is added to a list, the per-source strip prefixes clean the
// display name ("NL| NPO 1 HD" -> "NPO 1 HD"); a name without a configured
// prefix is left as-is (display_name empty => follows the upstream name).
// Stream failover: siblings = the SAME channel from OTHER sources, matched by
// tvg-id when present, else by exact (case-insensitive) name — never a different
// channel (e.g. NPO 2).
procedure TStorageTests.LoadStreamSiblingsMatchesByTvgIdAndName;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
  NpoA, BbcA: Integer;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u1', 'NPO 1', '', 'npo1', 'http://a/npo1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u2', 'BBC One', '', '', 'http://a/bbc.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Snap := TSourceSnapshot.Create(2);
  Snap.Streams.Add(MakeStream(2, ctLive, 'u1', 'NPO 1 HD', '', 'npo1', 'http://b/npo1.ts')); // same tvg-id
  Snap.Streams.Add(MakeStream(2, ctLive, 'u2', 'BBC One', '', '', 'http://b/bbc.ts'));        // same exact name
  Snap.Streams.Add(MakeStream(2, ctLive, 'u3', 'NPO 2', '', 'npo2', 'http://b/npo2.ts'));     // decoy
  Store.MergeSnapshot(Snap);
  Snap.Free;

  NpoA := -1; BbcA := -1;
  F := Default(TCatalogFilter);
  F.SourceId := 1;
  var Streams := Store.LoadStreams(F);
  try
    for var I := 0 to Streams.Count - 1 do
      if Streams[I].Name = 'NPO 1' then NpoA := Streams[I].Id
      else if Streams[I].Name = 'BBC One' then BbcA := Streams[I].Id;
  finally
    Streams.Free;
  end;

  var SibsNpo := Store.LoadStreamSiblings(NpoA);
  Assert.AreEqual<Integer>(1, Length(SibsNpo), 'NPO 1 → one sibling (same tvg-id), NOT NPO 2');
  Assert.AreEqual('http://b/npo1.ts', SibsNpo[0]);

  var SibsBbc := Store.LoadStreamSiblings(BbcA);
  Assert.AreEqual<Integer>(1, Length(SibsBbc), 'BBC One → one sibling (same exact name, no tvg-id)');
  Assert.AreEqual('http://b/bbc.ts', SibsBbc[0]);
end;

// The credential-scoped output (302 redirect / proxy relay) must only serve a
// stream that is actually on the authenticated list — LoadListStreamById returns
// the stream for an on-list id, but nil for a catalog stream NOT on that list.
procedure TStorageTests.LoadListStreamByIdScopesToList;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId, OnId, OffId: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u1', 'On List', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u2', 'Off List', '', '', 'http://p/2.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'Box'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  OnId := -1; OffId := -1;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    for var I := 0 to Streams.Count - 1 do
      if Streams[I].Name = 'On List' then OnId := Streams[I].Id else OffId := Streams[I].Id;
  finally
    Streams.Free;
  end;
  Store.AddItems(ListId, 0, [OnId]); // only the first stream is on the list

  var OnStream := Store.LoadListStreamById(ListId, OnId);
  try
    Assert.IsNotNull(OnStream, 'an on-list stream resolves');
    Assert.AreEqual('http://p/1.ts', OnStream.UpstreamUrl);
  finally
    OnStream.Free;
  end;
  Assert.IsNull(Store.LoadListStreamById(ListId, OffId),
    'a catalog stream NOT on the list does not resolve (no cross-list / off-list access)');
end;

// is_new diff invariant: on a LATER refresh that brings a brand-new item alongside
// an already-SEEN one, only the new item is flagged. (Earlier tests only ever had a
// single item, so they couldn't prove the mixed-population diff — the exact shape of
// the historical "tests green but broken" class of bug.)
procedure TStorageTests.MergeFlagsNewItemAmongSeenOnes;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  // refresh #1: one stream + one category
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'Alpha', '', '', 'http://p/a.ts'));
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'ca'; Cat.Name := 'CatA';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // mark everything from refresh #1 seen (clears their "new" badge)
  F := Default(TCatalogFilter);
  var S1 := Store.LoadStreams(F);
  try Store.MarkStreamsSeen([S1[0].Id]); finally S1.Free; end;
  var C1 := Store.LoadCategories(F);
  try Store.MarkCategoriesSeen([C1[0].Id]); finally C1.Free; end;

  // refresh #2: the old item PLUS a brand-new one
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'Alpha', '', '', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'b', 'Bravo', '', '', 'http://p/b.ts'));
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'ca'; Cat.Name := 'CatA';
  Snap.Categories.Add(Cat);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'cb'; Cat.Name := 'CatB';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  F.OnlyNew := True;
  var NewS := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, NewS.Count, 'only the brand-new stream is flagged new');
    Assert.AreEqual('Bravo', NewS[0].Name);
  finally NewS.Free; end;
  var NewC := Store.LoadCategories(F);
  try
    Assert.AreEqual<Integer>(1, NewC.Count, 'only the brand-new category is flagged new');
    Assert.AreEqual('CatB', NewC[0].Name);
  finally NewC.Free; end;
end;

// canonical channel ordering WITHIN a group: numbered channels first in NUMERIC
// order (so 2 precedes 10 — not text order), then unnumbered A→Z. Earlier ordering
// tests put one channel per group with no numbers, so this clause was unproven.
procedure TStorageTests.OutputChannelNumberOrderingWithinGroup;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId, OneId, TwoId, TenId, AlphaId, BravoId: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u1', 'Ten', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u2', 'Two', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u3', 'One', '', '', 'http://p/3.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u4', 'Bravo', '', '', 'http://p/4.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u5', 'Alpha', '', '', 'http://p/5.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  OneId := -1; TwoId := -1; TenId := -1; AlphaId := -1; BravoId := -1;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    for var I := 0 to Streams.Count - 1 do
      if Streams[I].Name = 'One' then OneId := Streams[I].Id
      else if Streams[I].Name = 'Two' then TwoId := Streams[I].Id
      else if Streams[I].Name = 'Ten' then TenId := Streams[I].Id
      else if Streams[I].Name = 'Alpha' then AlphaId := Streams[I].Id
      else if Streams[I].Name = 'Bravo' then BravoId := Streams[I].Id;
  finally Streams.Free; end;
  Store.AddItems(ListId, 0, [OneId, TwoId, TenId, AlphaId, BravoId]);

  // number One=1, Two=2, Ten=10; leave Alpha/Bravo unnumbered (0)
  var Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
    begin
      if Items[I].StreamItemId = OneId then Items[I].ChannelNumber := 1
      else if Items[I].StreamItemId = TwoId then Items[I].ChannelNumber := 2
      else if Items[I].StreamItemId = TenId then Items[I].ChannelNumber := 10
      else Continue;
      Store.SaveItem(Items[I]);
    end;
  finally Items.Free; end;

  var Ch := Store.LoadOutputChannels(ListId);
  try
    Assert.AreEqual<Integer>(5, Ch.Count);
    Assert.AreEqual('One', Ch[0].Name, 'number 1 first');
    Assert.AreEqual('Two', Ch[1].Name, 'number 2 next');
    Assert.AreEqual('Ten', Ch[2].Name, 'number 10 after 2 (numeric order, not text)');
    Assert.AreEqual('Alpha', Ch[3].Name, 'unnumbered come after numbered, A→Z');
    Assert.AreEqual('Bravo', Ch[4].Name);
  finally Ch.Free; end;
end;

// credential resolution: a DISABLED list is never resolved (enabled=1), a wrong
// username yields nil (-> 401), and empty creds resolve to the enabled default even
// when a disabled list exists. Earlier test had only one enabled list.
procedure TStorageTests.FindListByCredentialsRespectsEnabledAndUser;
var
  Store: IStore;
  Lst: TCustomList;
begin
  Store := NewStore(FDbPath);
  Lst := TCustomList.Create;
  try
    Lst.Name := 'Disabled'; Lst.OutputUsername := 'x'; Lst.OutputPassword := 'y'; Lst.Enabled := False;
    Store.SaveList(Lst);
  finally Lst.Free; end;
  Lst := TCustomList.Create;
  try Lst.Name := 'Default'; Lst.Enabled := True; Store.SaveList(Lst); finally Lst.Free; end;

  Assert.IsNull(Store.FindListByCredentials('nobody', 'z'), 'unknown username -> nil (401)');
  Assert.IsNull(Store.FindListByCredentials('x', 'y'), 'a disabled list is never resolved');
  var L := Store.FindListByCredentials('', '');
  try
    Assert.IsNotNull(L, 'empty creds resolve to the enabled default');
    Assert.AreEqual('Default', L.Name);
  finally L.Free; end;
end;

// EpgMaxDays caps the FUTURE, but a programme that started in the past and is still
// airing (the "now" programme) must NOT be dropped from the served guide.
procedure TStorageTests.EpgKeepsCurrentlyAiringProgramme;
var
  Store: IStore;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
begin
  Store := NewStore(FDbPath);
  Progs := TEpgProgrammeList.Create(True);
  try
    P := TEpgProgramme.Create; P.ChannelTvgId := 'nl1';
    P.StartUtc := IncHour(NowUtc, -1); P.StopUtc := IncHour(NowUtc, 1); P.Title := 'Now';
    Progs.Add(P);
    P := TEpgProgramme.Create; P.ChannelTvgId := 'nl1';
    P.StartUtc := IncHour(NowUtc, 2); P.StopUtc := IncHour(NowUtc, 3); P.Title := 'Next';
    Progs.Add(P);
    Store.ReplaceEpg(1, Progs);
  finally Progs.Free; end;

  var L := Store.LoadEpgForTvgIds(['nl1'], 7);
  try
    Assert.AreEqual<Integer>(2, L.Count, 'the currently-airing (past-started) programme is still served');
  finally L.Free; end;
end;

// The prefix picker (DiscoverPrefixes) must surface the Unicode-bar prefixes
// providers like ProviderA use (┃NL┃), not just ASCII pipes — else the operator can't
// tick them. ExtractNamePrefix treats the heavy vertical bar (U+2503) as a delimiter.
procedure TStorageTests.DiscoverPrefixesFindsUnicodeBarPrefix;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Prefixes: TArray<TPrefixCount>;
  P: TPrefixCount;
  FoundNl: Integer;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u1', #$2503 + 'NL' + #$2503 + ' NPO 1', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u2', #$2503 + 'NL' + #$2503 + ' NPO 2', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u3', #$2503 + 'F1 TV' + #$2503 + ' Race', '', '', 'http://p/3.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Prefixes := Store.DiscoverPrefixes(1);
  FoundNl := -1;
  for P in Prefixes do
    if P.Prefix = #$2503 + 'NL' + #$2503 then
      FoundNl := P.Count;
  Assert.AreEqual<Integer>(2, FoundNl, 'the ┃NL┃ Unicode-bar prefix is discovered with its count');
end;

// A discovered/typed prefix can legitimately contain a LIKE wildcard ('_' or '%').
// The prefix filter must escape it, else 'S_T' would also match 'SAT' (any char).
procedure TStorageTests.PrefixFilterEscapesLikeWildcards;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u1', 'S_T News', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'u2', 'SAT News', '', '', 'http://p/2.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  F.Prefix := 'S_T';
  var Streams := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, Streams.Count, 'underscore is matched literally, not as a wildcard');
    Assert.AreEqual('S_T News', Streams[0].Name);
  finally
    Streams.Free;
  end;
end;

// strip-prefix matrix #1 — NONE: a source with no strip prefixes leaves
// display_name '' so the channel keeps following its upstream name verbatim.
procedure TStorageTests.AddItemsNoPrefixesKeepsUpstreamName;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  SrcId, ListId, Sid: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://h';
    // StripPrefixes left empty
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u1',
    #$2503 + 'NL' + #$2503 + ' ESPN 1 HD', '', '', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try Sid := Streams[0].Id; finally Streams.Free; end;
  Store.AddItems(ListId, 0, [Sid]);

  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual('', Items[0].DisplayName,
      'no strip prefixes configured -> display_name stays empty (follows upstream)');
  finally
    Items.Free;
  end;
end;

// strip-prefix matrix #2 — SINGLE configured prefix (and a non-matching channel).
procedure TStorageTests.AddItemsStripsConfiguredPrefix;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  SrcId, ListId, PrefixedId, PlainId: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://h';
    Src.StripPrefixes := ['NL'];
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u1', 'NL| NPO 1 HD', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u2', 'BBC One', '', '', 'http://p/2.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  PrefixedId := -1; PlainId := -1;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    for var I := 0 to Streams.Count - 1 do
      if Streams[I].Name.StartsWith('NL') then PrefixedId := Streams[I].Id
      else PlainId := Streams[I].Id;
  finally
    Streams.Free;
  end;
  Store.AddItems(ListId, 0, [PrefixedId, PlainId]);

  var Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
      if Items[I].StreamItemId = PrefixedId then
        Assert.AreEqual('NPO 1 HD', Items[I].DisplayName, 'prefix stripped + trimmed into display name')
      else
        Assert.AreEqual('', Items[I].DisplayName, 'unprefixed name keeps following the upstream name');
  finally
    Items.Free;
  end;
end;

// strip-prefix matrix #3 — MULTIPLE prefixes. Regression: prefixes are stored
// ';'-delimited (a token may itself contain spaces/commas/pipes, e.g. "┃F1 TV┃").
// AddItems must split with ';' — splitting with ',' treats the whole "a;b;c"
// string as one token and strips nothing. (Single-prefix sources hid this bug;
// multi-prefix broke — exactly the "┃NL┃ ESPN" the operator reported.)
procedure TStorageTests.AddItemsStripsOneOfMultipleSemicolonPrefixes;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  SrcId, ListId, EspnId: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://h';
    // three tokens; the Unicode heavy bar (U+2503) and an embedded space ("F1 TV")
    Src.StripPrefixes := [#$2503 + 'F1 TV' + #$2503, #$2503 + 'NL' + #$2503];
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u1',
    #$2503 + 'NL' + #$2503 + ' ESPN 1 HD', '', '', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    EspnId := Streams[0].Id;
  finally
    Streams.Free;
  end;
  Store.AddItems(ListId, 0, [EspnId]);

  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual('ESPN 1 HD', Items[0].DisplayName,
      'the matching ┃NL┃ prefix is stripped even with several ;-delimited tokens');
  finally
    Items.Free;
  end;
end;

// The global "Strip prefixes (all)" button applies each source's CURRENT prefixes
// to all channels added BEFORE the prefix was configured (display_name was ''),
// while leaving manual renames alone.
procedure TStorageTests.RestripAllItemsAppliesCurrentPrefixes;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  SrcId, ListId, NpoId, RenId, Updated: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  // source starts with NO strip prefixes
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://h';
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u1', 'NL| NPO 1 HD', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u2', 'NL| Sport', '', '', 'http://p/2.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  NpoId := -1; RenId := -1;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    for var I := 0 to Streams.Count - 1 do
      if Streams[I].Name.Contains('NPO') then NpoId := Streams[I].Id
      else RenId := Streams[I].Id;
  finally
    Streams.Free;
  end;
  // added while the source had no prefixes -> display_name '' (follows upstream)
  Store.AddItems(ListId, 0, [NpoId, RenId]);
  // manually rename the Sport channel
  var Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
      if Items[I].StreamItemId = RenId then
      begin
        Items[I].DisplayName := 'My Sport';
        Store.SaveItem(Items[I]);
      end;
  finally
    Items.Free;
  end;

  // now configure the strip prefix and apply to all
  var Srcs := Store.LoadSources;
  try
    for var I := 0 to Srcs.Count - 1 do
      if Srcs[I].Id = SrcId then
      begin
        Srcs[I].StripPrefixes := ['NL'];
        Store.SaveSource(Srcs[I]);
      end;
  finally
    Srcs.Free;
  end;
  Updated := Store.RestripAllItems;
  Assert.AreEqual<Integer>(1, Updated, 'only the auto-named NPO channel is restripped');

  Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
      if Items[I].StreamItemId = NpoId then
        Assert.AreEqual('NPO 1 HD', Items[I].DisplayName, 'auto channel got the prefix stripped')
      else
        Assert.AreEqual('My Sport', Items[I].DisplayName, 'manual rename is preserved');
  finally
    Items.Free;
  end;
end;

// Regression for the same ';'-vs-',' delimiter bug, via the "Strip prefixes (all)"
// path: a multi-prefix source must restrip a channel added before the prefixes
// existed. (Was broken: the whole "┃F1 TV┃;┃NL┃" string parsed as one token.)
procedure TStorageTests.RestripAllItemsHandlesMultipleSemicolonPrefixes;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  SrcId, ListId, EspnId, Updated: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  // source starts with NO strip prefixes -> channel added with display_name ''
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://h';
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u1',
    #$2503 + 'NL' + #$2503 + ' ESPN 1 HD', '', '', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try EspnId := Streams[0].Id; finally Streams.Free; end;
  Store.AddItems(ListId, 0, [EspnId]); // display_name '' (no prefixes yet)

  // now configure SEVERAL strip prefixes and apply to all
  var Srcs := Store.LoadSources;
  try
    for var I := 0 to Srcs.Count - 1 do
      if Srcs[I].Id = SrcId then
      begin
        Srcs[I].StripPrefixes := [#$2503 + 'F1 TV' + #$2503, #$2503 + 'NL' + #$2503];
        Store.SaveSource(Srcs[I]);
      end;
  finally
    Srcs.Free;
  end;
  Updated := Store.RestripAllItems;
  Assert.AreEqual<Integer>(1, Updated, 'the ┃NL┃ ESPN channel is restripped');

  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual('ESPN 1 HD', Items[0].DisplayName,
      'restrip-all splits ;-delimited prefixes and strips the matching one');
  finally
    Items.Free;
  end;
end;

// Changing a source's strip-prefix rule re-cleans its already-added channels:
// auto-named items follow the new rule, but a manual rename is left untouched.
procedure TStorageTests.RestripUpdatesAutoNamesKeepsManualRenames;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  SrcId, ListId, NpoStream, SportStream, Updated: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://h';
    Src.StripPrefixes := ['NL'];
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u1', 'NL| NPO 1 HD', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u2', 'NL| Sport', '', '', 'http://p/2.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  NpoStream := -1; SportStream := -1;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    for var I := 0 to Streams.Count - 1 do
      if Streams[I].Name.Contains('NPO') then NpoStream := Streams[I].Id
      else SportStream := Streams[I].Id;
  finally
    Streams.Free;
  end;
  // added with NL configured -> both display names stripped ("NPO 1 HD", "Sport")
  Store.AddItems(ListId, 0, [NpoStream, SportStream]);

  // operator manually renames the Sport channel
  var Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
      if Items[I].StreamItemId = SportStream then
      begin
        Items[I].DisplayName := 'Mijn Sport';
        Store.SaveItem(Items[I]);
      end;
  finally
    Items.Free;
  end;

  // drop the NL rule: the auto-named NPO reverts to upstream, the manual stays
  Updated := Store.RestripSourceItems(SrcId, ['NL'], [], [], []);
  Assert.AreEqual<Integer>(1, Updated, 'only the auto-named item is rewritten');

  Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
      if Items[I].StreamItemId = NpoStream then
        Assert.AreEqual('', Items[I].DisplayName, 'auto name follows the new (empty) rule')
      else
        Assert.AreEqual('Mijn Sport', Items[I].DisplayName, 'manual rename preserved');
  finally
    Items.Free;
  end;
end;

procedure TStorageTests.AddItemsStripsConfiguredSuffix;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  SrcId, ListId: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://h';
    Src.StripPrefixes := ['NL |'];
    Src.StripSuffixes := ['(S)'];
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;
  var Srcs := Store.LoadSources;
  try
    Assert.AreEqual<Integer>(1, Length(Srcs[0].StripSuffixes), 'strip suffixes round-trip');
    Assert.AreEqual('(S)', Srcs[0].StripSuffixes[0]);
  finally
    Srcs.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, 'u1', 'NL | HISTORY HD (S)', '', '', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    Store.AddItems(ListId, 0, [Streams[0].Id]);
  finally
    Streams.Free;
  end;
  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual('HISTORY HD', Items[0].DisplayName, 'prefix and suffix stripped');
    Assert.AreEqual('NL | HISTORY HD (S)', Items[0].StreamName, 'original name still available');
  finally
    Items.Free;
  end;
end;

// Quality probe: "measure NPO 1 in all qualities" must find every variant of
// ONE channel in its own source (RAW small caps, 4K+, UHD, HD, and a variant
// that only shares the tvg-id), never NPO 1 EXTRA / NPO 2; other providers only
// when asked, and ordered own source -> quality ladder.
procedure TStorageTests.StreamVariantsFindsAllQualitiesOfOneChannel;
const
  RAW_SC = #$0280#$1D00#$1D21;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  SrcId, Src2: Integer;
  Ids: TDictionary<string, Integer>;
  F: TCatalogFilter;
  V: TArray<TStreamVariant>;
  Names: string;
  X: TStreamVariant;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'ProviderB'; Src.Kind := skXtream; Src.Url := 'http://h';
    Src.StripPrefixes := ['NL |'];
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;
  Src := TSourceConfig.Create;
  try
    Src.Name := 'OTHER'; Src.Kind := skXtream; Src.Url := 'http://o';
    Src.StripPrefixes := ['NL:'];
    Src2 := Store.SaveSource(Src);
  finally
    Src.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '1', 'NL | NPO 1 ' + RAW_SC, '', 'npo1.nl', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '2', 'NL | NPO 1 4K+', '', 'npo1.nl', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '3', 'NL | NPO 1 HD', '', 'npo1.nl', 'http://p/3.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '4', 'NL | NPO 1 UHD', '', '', 'http://p/4.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '5', 'NL | NPO 1 EXTRA ' + RAW_SC, '', 'npo1extra.nl', 'http://p/5.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '6', 'NL | NPO 2 HD', '', 'npo2.nl', 'http://p/6.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '7', 'NL | NPO1 FHD', '', 'npo1.nl', 'http://p/7.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Snap := TSourceSnapshot.Create(Src2);
  Snap.Streams.Add(MakeStream(Src2, ctLive, '1', 'NL: NPO 1 HD', '', '', 'http://o/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Ids := TDictionary<string, Integer>.Create;
  try
    F := Default(TCatalogFilter);
    F.SourceId := SrcId;
    var Streams := Store.LoadStreams(F);
    try
      for var I := 0 to Streams.Count - 1 do
        Ids.Add(Streams[I].UpstreamId, Streams[I].Id);
    finally
      Streams.Free;
    end;

    // started from the RAW channel, own source only
    V := Store.FindStreamVariants(Ids['1'], False, 0);
    Names := '';
    for X in V do
      Names := Names + X.Quality + '/' + X.MatchedBy + ' ';
    Assert.AreEqual('4K+/name UHD/name FHD/tvg RAW/self HD/name ', Names, 'own-source variants');

    // all sources: the other provider's NPO 1 HD comes last
    V := Store.FindStreamVariants(Ids['4'], True, 0);
    Assert.AreEqual(6, Length(V), 'all sources');
    Assert.AreEqual(Src2, V[High(V)].SourceId, 'other source last');
    Assert.AreEqual('UHD', V[1].Quality, 'self (UHD) in the ladder');
    Assert.IsTrue(V[1].IsSelf);
  finally
    Ids.Free;
  end;
end;

// The user's case: a group of ProviderB "RAW" channels (small-caps, some with a
// trailing "(S)") placed with the "NL |" prefix stripped, swapped IN PLACE for
// their 4K+ variants - channel number / tvg-id override kept, the auto display
// name follows the new channel, no-variant channels are left alone, and
// "NPO 1 EXTRA" must not be mistaken for "NPO 1".
procedure TStorageTests.RawGroupReplacedInPlaceBy4KPlus;
const
  RAW_SC = #$0280#$1D00#$1D21;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Grp: TCustomGroup;
  SrcId, ListId, GroupId: Integer;
  Ids: TDictionary<string, Integer>;
  F: TCatalogFilter;
  Reps: TArray<TItemStreamReplace>;
  R: TItemStreamReplace;
  Npo1Item: Integer;
  Items: TCustomItemList;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'ProviderB'; Src.Kind := skXtream; Src.Url := 'http://h';
    Src.StripPrefixes := ['NL |'];
    SrcId := Store.SaveSource(Src);
  finally
    Src.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '1', 'NL | NPO 1 ' + RAW_SC, '', 'npo1', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '2', 'NL | NPO 1 4K+', '', 'npo1', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '3', 'NL | HISTORY ' + RAW_SC + ' (S)', '', '', 'http://p/3.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '4', 'NL | HISTORY 4K+', '', '', 'http://p/4.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '5', 'NL | BBC NL ' + RAW_SC, '', '', 'http://p/5.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '6', 'NL | NPO 1 EXTRA ' + RAW_SC, '', '', 'http://p/6.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '7', 'NL | NPO 1 UHD', '', '', 'http://p/7.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  Grp := TCustomGroup.Create;
  try
    Grp.ListId := ListId; Grp.Name := 'Standaard';
    GroupId := Store.SaveGroup(Grp);
  finally
    Grp.Free;
  end;

  Ids := TDictionary<string, Integer>.Create;
  try
    F := Default(TCatalogFilter);
    var Streams := Store.LoadStreams(F);
    try
      for var I := 0 to Streams.Count - 1 do
        Ids.Add(Streams[I].UpstreamId, Streams[I].Id);
    finally
      Streams.Free;
    end;
    Store.AddItems(ListId, GroupId, [Ids['1'], Ids['3'], Ids['5'], Ids['6']]);

    // give NPO 1 a channel number + tvg-id override that must survive the swap
    Npo1Item := 0;
    Items := Store.LoadItems(ListId);
    try
      for var I := 0 to Items.Count - 1 do
        if Items[I].StreamItemId = Ids['1'] then
        begin
          Assert.AreEqual('NPO 1 ' + RAW_SC, Items[I].DisplayName, 'prefix stripped on the list');
          Npo1Item := Items[I].Id;
          Items[I].ChannelNumber := 5;
          Items[I].TvgIdOverride := 'npo1.nl';
          Store.SaveItem(Items[I]);
        end;
    finally
      Items.Free;
    end;

    var Matches := Store.FindQualityVariants(ListId, GroupId, '4K+');
    Assert.AreEqual<Integer>(4, Length(Matches));
    Reps := [];
    for var M in Matches do
    begin
      if M.StreamId = Ids['1'] then
      begin
        Assert.AreEqual(Ids['2'], M.CandidateStreamId, 'NPO 1 RAW -> NPO 1 4K+ despite the stripped prefix');
        Assert.AreEqual('RAW', M.Quality);
      end
      else if M.StreamId = Ids['3'] then
        Assert.AreEqual(Ids['4'], M.CandidateStreamId, 'HISTORY RAW (S) -> HISTORY 4K+ (tag after quality)')
      else if M.StreamId = Ids['5'] then
        Assert.AreEqual(0, M.CandidateStreamId, 'BBC NL has no 4K+')
      else if M.StreamId = Ids['6'] then
        Assert.AreEqual(0, M.CandidateStreamId, 'NPO 1 EXTRA is not NPO 1');
      if M.CandidateStreamId > 0 then
      begin
        R.ItemId := M.ItemId;
        R.StreamId := M.CandidateStreamId;
        Reps := Reps + [R];
      end;
    end;

    Assert.AreEqual<Integer>(2, Store.ReplaceItemStreams(ListId, Reps), 'two channels swapped');
    // replacing again is a no-op (the 4K+ streams are on the list now)
    Assert.AreEqual<Integer>(0, Store.ReplaceItemStreams(ListId, Reps), 'already on the list -> skipped');

    Items := Store.LoadItems(ListId);
    try
      Assert.AreEqual<Integer>(4, Items.Count, 'replaced in place, nothing added');
      for var I := 0 to Items.Count - 1 do
      begin
        Assert.AreEqual(GroupId, Items[I].CustomGroupId, 'stays in its group');
        if Items[I].Id = Npo1Item then
        begin
          Assert.AreEqual(Ids['2'], Items[I].StreamItemId);
          Assert.AreEqual(5, Items[I].ChannelNumber, 'channel number kept');
          Assert.AreEqual('npo1.nl', Items[I].TvgIdOverride, 'tvg-id override kept');
          Assert.AreEqual('NPO 1 4K+', Items[I].DisplayName, 'auto name follows the new channel');
          Assert.AreEqual('NL | NPO 1 4K+', Items[I].StreamName);
        end
        else if Items[I].StreamItemId = Ids['4'] then
          Assert.AreEqual('HISTORY 4K+', Items[I].DisplayName);
      end;
    finally
      Items.Free;
    end;
  finally
    Ids.Free;
  end;
end;

// "Clean the names of an EXISTING group": channels placed before a strip rule
// existed (or with tokens nobody configured) get the source rules + one-off extra
// tokens applied; dry run only previews; a manual rename without such a token is
// untouched; a result equal to the upstream name is stored as ''.
procedure TStorageTests.RestripGroupItemsCleansExistingGroup;
var
  Store: IStore;
  Src: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Grp: TCustomGroup;
  SrcId, ListId, GroupId: Integer;
  F: TCatalogFilter;
  Ids: TArray<Integer>;
  Changes: TArray<TNameChange>;
  Items: TCustomItemList;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Kind := skXtream; Src.Url := 'http://h';
    SrcId := Store.SaveSource(Src); // no strip rules yet
  finally
    Src.Free;
  end;
  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '1', 'NL | HISTORY HD (S)', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '2', 'NL | NPO 1 HD', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '3', 'NL | SPORT', '', '', 'http://p/3.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'G'; GroupId := Store.SaveGroup(Grp); finally Grp.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    Ids := [];
    for var I := 0 to Streams.Count - 1 do
      Ids := Ids + [Streams[I].Id];
  finally
    Streams.Free;
  end;
  Store.AddItems(ListId, GroupId, Ids); // added unstripped (no rules at the time)

  // a manual rename without any of the tokens must survive
  Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
      if Items[I].StreamName = 'NL | SPORT' then
      begin
        Items[I].DisplayName := 'Mijn Sport';
        Store.SaveItem(Items[I]);
      end;
  finally
    Items.Free;
  end;

  // preview with one-off tokens: nothing written yet
  Changes := Store.RestripGroupItems(ListId, GroupId, ['NL |'], ['(S)'], True);
  Assert.AreEqual<Integer>(2, Length(Changes), 'HISTORY + NPO 1 change, Mijn Sport not');
  Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
      if Items[I].StreamName <> 'NL | SPORT' then
        Assert.AreEqual('', Items[I].DisplayName, 'dry run writes nothing');
  finally
    Items.Free;
  end;

  // apply
  Changes := Store.RestripGroupItems(ListId, GroupId, ['NL |'], ['(S)'], False);
  Assert.AreEqual<Integer>(2, Length(Changes));
  Items := Store.LoadItems(ListId);
  try
    for var I := 0 to Items.Count - 1 do
      if Items[I].StreamName = 'NL | HISTORY HD (S)' then
        Assert.AreEqual('HISTORY HD', Items[I].DisplayName)
      else if Items[I].StreamName = 'NL | NPO 1 HD' then
        Assert.AreEqual('NPO 1 HD', Items[I].DisplayName)
      else
        Assert.AreEqual('Mijn Sport', Items[I].DisplayName, 'manual rename kept');
  finally
    Items.Free;
  end;

  // running again changes nothing (idempotent)
  Assert.AreEqual<Integer>(0, Length(Store.RestripGroupItems(ListId, GroupId, ['NL |'], ['(S)'], False)));
end;

procedure TStorageTests.ClearGroupItemsRemovesOnlyThatGroup;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Grp: TCustomGroup;
  ListId, GroupId, Removed: Integer;
  Ids: TArray<Integer>;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'b', 'B', '', '', 'http://p/b.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'c', 'C', '', '', 'http://p/c.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'G'; GroupId := Store.SaveGroup(Grp); finally Grp.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try Ids := [Streams[0].Id, Streams[1].Id, Streams[2].Id]; finally Streams.Free; end;

  Store.AddItems(ListId, GroupId, [Ids[0], Ids[1]]); // two into the custom group
  Store.AddItems(ListId, 0, [Ids[2]]);               // one into the upstream group

  Removed := Store.ClearGroupItems(ListId, GroupId);
  Assert.AreEqual<Integer>(2, Removed, 'only the two in the group are removed');

  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual<Integer>(1, Items.Count, 'the upstream-group item survives');
    Assert.AreEqual<Integer>(0, Items[0].CustomGroupId);
  finally
    Items.Free;
  end;
end;

procedure TStorageTests.DeleteListCascades;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Grp: TCustomGroup;
  ListId: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'Doomed'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'G'; Store.SaveGroup(Grp); finally Grp.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try Store.AddItems(ListId, 0, [Streams[0].Id]); finally Streams.Free; end;

  Store.DeleteList(ListId);

  var Lists := Store.LoadLists;
  try Assert.AreEqual<Integer>(0, Lists.Count, 'list gone'); finally Lists.Free; end;
  var Groups := Store.LoadGroups(ListId);
  try Assert.AreEqual<Integer>(0, Groups.Count, 'groups gone'); finally Groups.Free; end;
  var Items := Store.LoadItems(ListId);
  try Assert.AreEqual<Integer>(0, Items.Count, 'items gone'); finally Items.Free; end;
end;

procedure TStorageTests.NameFilterHidesStreamsAndCategories;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, '1', 'NL| One', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '2', 'NL| Two', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '3', 'UK| Three', '', '', 'http://p/3.ts'));
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'nl'; Cat.Name := 'NL| General';
  Snap.Categories.Add(Cat);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'uk'; Cat.Name := 'UK| Sport';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // exclude NL| -> only UK remains, in streams AND categories
  F := Default(TCatalogFilter);
  F.ExcludeFilters := ['NL|'];
  var S1 := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, S1.Count, 'exclude hides the two NL streams');
    Assert.AreEqual('UK| Three', S1[0].Name);
  finally S1.Free; end;
  var C1 := Store.LoadCategories(F);
  try Assert.AreEqual<Integer>(1, C1.Count, 'exclude hides the NL group'); finally C1.Free; end;

  // include NL| -> only the two NL streams
  F := Default(TCatalogFilter);
  F.IncludeFilters := ['NL|'];
  var S2 := Store.LoadStreams(F);
  try Assert.AreEqual<Integer>(2, S2.Count, 'include keeps only NL'); finally S2.Free; end;

  // nothing filtered -> all still present (filters never delete)
  F := Default(TCatalogFilter);
  var S3 := Store.LoadStreams(F);
  try Assert.AreEqual<Integer>(3, S3.Count, 'no filter => everything still there'); finally S3.Free; end;
end;

procedure TStorageTests.HiddenFlagFollowsSourceFilters;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  F: TCatalogFilter;
  Src: TSourceConfig;
  SrcId: Integer;
  function CountCats: Integer;
  var L: TCategoryList;
  begin
    L := Store.LoadCategories(F);
    try Result := L.Count; finally L.Free; end;
  end;
begin
  // The catalog uses the precomputed `hidden` flag; it must match the source's
  // filters after ingest AND after the filters are edited (and back).
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Url := 'http://x'; Src.ExcludeFilters := ['NL|'];
    SrcId := Store.SaveSource(Src);
  finally Src.Free; end;
  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '1', 'NL| One', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(SrcId, ctLive, '2', 'UK| Two', '', '', 'http://p/2.ts'));
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'nl'; Cat.Name := 'NL| General';
  Snap.Categories.Add(Cat);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'uk'; Cat.Name := 'UK| Sport';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  F.UseHiddenFlag := True;
  Assert.AreEqual<Integer>(1, Store.CountStreams(F), 'ingest applies the exclude filter');
  Assert.AreEqual<Integer>(1, CountCats, 'group hidden too');

  // edit the filters: exclude UK instead (plus a pasted giant item, ignored)
  var L := Store.LoadSources;
  try
    L[0].ExcludeFilters := ['UK|', StringOfChar('X', 60000)];
    Store.SaveSource(L[0]);
  finally L.Free; end;
  var S := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, S.Count, 'filter change recomputes the flag');
    Assert.AreEqual('NL| One', S[0].Name);
  finally S.Free; end;

  // clear the filters: everything visible again; includeHidden ignores the flag
  L := Store.LoadSources;
  try
    L[0].ExcludeFilters := [];
    Store.SaveSource(L[0]);
  finally L.Free; end;
  Assert.AreEqual<Integer>(2, Store.CountStreams(F), 'no filter => nothing hidden');
  Assert.AreEqual<Integer>(2, CountCats);
end;

// Include "UFC" keeps the UFC channels; their group ("WORLD SPORTS") must stay
// visible although its NAME doesn't match — unless an exclude token names it.
procedure TStorageTests.GroupWithVisibleChannelStaysVisible;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  F: TCatalogFilter;
  Src: TSourceConfig;
  SrcId: Integer;
  St: TStreamItem;
  function CatNames: string;
  var
    L: TCategoryList;
    C: TCategory;
  begin
    Result := '';
    L := Store.LoadCategories(F);
    try
      for C in L do Result := Result + C.Name + ';';
    finally L.Free; end;
  end;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'P'; Src.Url := 'http://x'; Src.IncludeFilters := ['NL |', 'UFC'];
    SrcId := Store.SaveSource(Src);
  finally Src.Free; end;
  Snap := TSourceSnapshot.Create(SrcId);
  St := MakeStream(SrcId, ctLive, '1', 'NL | NPO 1', '', '', 'http://p/1.ts'); St.CategoryUpstreamId := 'nl'; Snap.Streams.Add(St);
  St := MakeStream(SrcId, ctLive, '2', 'UFC 1', '', '', 'http://p/2.ts'); St.CategoryUpstreamId := 'ws'; Snap.Streams.Add(St);
  St := MakeStream(SrcId, ctLive, '3', 'NBA 1', '', '', 'http://p/3.ts'); St.CategoryUpstreamId := 'ws'; Snap.Streams.Add(St);
  St := MakeStream(SrcId, ctLive, '4', 'DE | ARD', '', '', 'http://p/4.ts'); St.CategoryUpstreamId := 'de'; Snap.Streams.Add(St);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'nl'; Cat.Name := 'NL | NEDERLAND'; Snap.Categories.Add(Cat);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'ws'; Cat.Name := 'WORLD SPORTS'; Snap.Categories.Add(Cat);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'de'; Cat.Name := 'DE | GERMANY'; Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  F.UseHiddenFlag := True;
  Assert.AreEqual<Integer>(2, Store.CountStreams(F), 'NPO 1 + UFC 1');
  Assert.AreEqual('NL | NEDERLAND;WORLD SPORTS;', CatNames, 'group of a visible channel stays');

  // an exclude token naming the group hides it even with visible channels
  var L := Store.LoadSources;
  try
    L[0].ExcludeFilters := ['WORLD SPORTS'];
    Store.SaveSource(L[0]);
  finally L.Free; end;
  Assert.AreEqual('NL | NEDERLAND;', CatNames, 'excluded group name wins');
end;

procedure TStorageTests.OversizedFilterTokenIsIgnored;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  F: TCatalogFilter;
  SF: TSourceFilter;
  Huge: string;
begin
  // a whole list pasted as ONE filter item (60k chars) used to become a single
  // LIKE pattern -> SQLite "LIKE or GLOB pattern too complex" on every catalog
  // query. It must be ignored; the normal and line-split tokens still work.
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, '1', 'NL| One', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '2', 'UK| Two', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '3', 'DE| Three', '', '', 'http://p/3.ts'));
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'nl'; Cat.Name := 'NL| General';
  Snap.Categories.Add(Cat);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'uk'; Cat.Name := 'UK| Sport';
  Snap.Categories.Add(Cat);
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'de'; Cat.Name := 'DE| Film';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Huge := StringOfChar('X', 60000);
  // exclude: the huge token is dropped, 'UK|' and the second line 'DE|' apply
  F := Default(TCatalogFilter);
  F.ExcludeFilters := [Huge, 'UK|'#10'DE|'];
  var S1 := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, S1.Count, 'only NL survives; no SQLite pattern error');
    Assert.AreEqual('NL| One', S1[0].Name);
  finally S1.Free; end;
  var C1 := Store.LoadCategories(F);
  try
    Assert.AreEqual<Integer>(1, C1.Count, 'groups filtered in memory the same way');
    Assert.AreEqual('NL| General', C1[0].Name);
  finally C1.Free; end;

  // per-source ("all sources" view): include NL| next to the huge token
  F := Default(TCatalogFilter);
  SF.SourceId := 1; SF.IncludeFilters := [Huge, 'NL|']; SF.ExcludeFilters := [];
  F.SourceFilters := [SF];
  var C2 := Store.LoadCategories(F);
  try Assert.AreEqual<Integer>(1, C2.Count, 'per-source include keeps only the NL group'); finally C2.Free; end;
  var S2 := Store.LoadStreams(F);
  try Assert.AreEqual<Integer>(1, S2.Count, 'per-source include keeps only the NL stream'); finally S2.Free; end;

  // only a huge token as include => no usable include => nothing hidden
  F := Default(TCatalogFilter);
  F.IncludeFilters := [Huge];
  var C3 := Store.LoadCategories(F);
  try Assert.AreEqual<Integer>(3, C3.Count, 'unusable include filter hides nothing'); finally C3.Free; end;
end;

procedure TStorageTests.NameFilterIsSeparatorAware;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  // leading separators/spaces around the country tag — the case that used to slip
  // through a raw 'NL%' LIKE because the name starts with " | " not "NL"
  Snap.Streams.Add(MakeStream(1, ctLive, '1', ' | NL | NPO 1', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '2', '|NL| NPO 2', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '3', 'NL - NPO 3', '', '', 'http://p/3.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '4', 'BBC One | NL', '', '', 'http://p/4.ts')); // tag as suffix
  Snap.Streams.Add(MakeStream(1, ctLive, '5', 'Netherlands 1', '', '', 'http://p/5.ts')); // must NOT match
  Snap.Streams.Add(MakeStream(1, ctLive, '6', 'NLD Sport', '', '', 'http://p/6.ts'));      // must NOT match
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // bare token "NL" (no punctuation) must catch every separator variant, prefix
  // OR suffix, but never "Netherlands"/"NLD"
  F := Default(TCatalogFilter);
  F.ExcludeFilters := ['NL'];
  var S1 := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(2, S1.Count, 'only the two non-NL names survive');
    for var It in S1 do
      Assert.IsTrue((It.Name = 'Netherlands 1') or (It.Name = 'NLD Sport'), 'survivor: ' + It.Name);
  finally S1.Free; end;

  // include "NL" keeps exactly the four tagged channels
  F := Default(TCatalogFilter);
  F.IncludeFilters := ['NL'];
  var S2 := Store.LoadStreams(F);
  try Assert.AreEqual<Integer>(4, S2.Count, 'include keeps the four NL-tagged channels'); finally S2.Free; end;
end;

// Providers decorate names with Unicode vertical bars (┃ U+2503), not the ASCII
// pipe — the filter must treat those as separators too.
procedure TStorageTests.NameFilterHandlesUnicodeBars;
const
  HB = #$2503; // ┃ heavy vertical bar
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, '1', HB + 'F1 TV' + HB + ' Race 1', '', '', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '2', HB + 'F1 TV' + HB + ' Race 2', '', '', 'http://p/2.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, '3', 'NPO 1', '', '', 'http://p/3.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // exclude the "F1 TV" tag (wrapped in ┃) -> only NPO 1 remains
  F := Default(TCatalogFilter);
  F.ExcludeFilters := ['F1 TV'];
  var S1 := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, S1.Count, 'the two ┃F1 TV┃ channels are excluded');
    Assert.AreEqual('NPO 1', S1[0].Name);
  finally S1.Free; end;

  // include "F1 TV" -> only the two tagged channels
  F := Default(TCatalogFilter);
  F.IncludeFilters := ['F1 TV'];
  var S2 := Store.LoadStreams(F);
  try Assert.AreEqual<Integer>(2, S2.Count, 'include keeps the ┃F1 TV┃ channels'); finally S2.Free; end;
end;

// TLockingStore uses TWO connections (writer + reader, WAL) on the same DB.
// A write on the writer connection must be visible to a read on the reader
// connection — proves the read/write split is wired and stays consistent.
procedure TStorageTests.LockingStoreSeparateReadWriteConnections;
var
  Store: IStore;
  Lst: TCustomList;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  // writer created first (makes the file), then reader on the same path — both in
  // WAL mode (the opt-in separate-read-connection setup; temp file is a real FS)
  Store := TLockingStore.Create(
    TSQLiteStore.Create(FDbPath, True),
    TSQLiteStore.Create(FDbPath, True));
  Store.Init;

  // write through the writer connection
  Lst := TCustomList.Create;
  try Lst.Name := 'Box'; Store.SaveList(Lst); finally Lst.Free; end;
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 's1', 'NPO 1', '', '', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // read through the reader connection — must see the just-committed writes
  var Lists := Store.LoadLists;
  try Assert.AreEqual<Integer>(1, Lists.Count, 'reader sees the list written by the writer'); finally Lists.Free; end;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, Streams.Count, 'reader sees the merged stream');
    Assert.AreEqual('NPO 1', Streams[0].Name);
  finally Streams.Free; end;
end;

// When WAL isn't available (Unraid FUSE share) the composition root passes the
// SAME store as writer AND reader. TLockingStore must then share one lock so the
// single FireDAC connection is never used concurrently — and it must not deadlock
// or double-free. Read-after-write still works through the one connection.
procedure TStorageTests.LockingStoreSingleConnectionFallback;
var
  Store: IStore;
  Inner: IStore;
  Lst: TCustomList;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
begin
  Inner := TSQLiteStore.Create(FDbPath);
  Store := TLockingStore.Create(Inner, Inner); // same connection for read + write
  Store.Init;

  Lst := TCustomList.Create;
  try Lst.Name := 'Box'; Store.SaveList(Lst); finally Lst.Free; end;
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 's1', 'NPO 1', '', '', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, Streams.Count, 'single-connection read sees the write');
    Assert.AreEqual('NPO 1', Streams[0].Name);
  finally Streams.Free; end;
end;

// Old StrArrayToCsv quoted an item containing '"' and doubled its quotes on every
// save (never unquoted on read) — 6 items grew to ~50M quotes each. Saving must be
// stable now, and Init must strip quotes already stored.
procedure TStorageTests.FilterTokensWithQuotesDoNotGrowAndAreRepaired;
var
  Store: IStore;
  Src: TSourceConfig;
  I: Integer;
begin
  Store := NewStore(FDbPath);
  Src := TSourceConfig.Create;
  try
    Src.Name := 'Q'; Src.Kind := skM3U; Src.Url := 'http://q';
    Src.ExcludeFilters := ['Sonay @ Oct 18 12:"', 'Plain'];
    Store.SaveSource(Src);
  finally Src.Free; end;
  for I := 1 to 5 do // load -> save round trips
  begin
    var L := Store.LoadSources;
    try Store.SaveSource(L[0]); finally L.Free; end;
  end;
  var L1 := Store.LoadSources;
  try
    Assert.AreEqual<Integer>(2, Length(L1[0].ExcludeFilters));
    Assert.IsTrue(Length(L1[0].ExcludeFilters[0]) < 30, 'token must not grow on save');
  finally L1.Free; end;

  Store := nil;
  Store := NewStore(FDbPath); // Init runs RepairSourceTokens
  var L2 := Store.LoadSources;
  try
    Assert.AreEqual('Sonay @ Oct 18 12:', L2[0].ExcludeFilters[0], 'stored quotes stripped on Init');
    Assert.AreEqual('Plain', L2[0].ExcludeFilters[1]);
  finally L2.Free; end;
end;

// Sources are served from memory by TLockingStore; every write path must
// invalidate, and callers get their own copy (freeing/mutating it is safe).
procedure TStorageTests.LockingStoreCachesSourcesAndInvalidatesOnWrite;
var
  Store: IStore;
  Inner: IStore;
  Src: TSourceConfig;
  Id: Integer;
begin
  Inner := TSQLiteStore.Create(FDbPath);
  Store := TLockingStore.Create(Inner, Inner);
  Store.Init;
  Src := TSourceConfig.Create;
  try
    Src.Name := 'A'; Src.Kind := skM3U; Src.Url := 'http://a';
    Id := Store.SaveSource(Src);
  finally Src.Free; end;

  var L1 := Store.LoadSources; // fills the cache
  try
    Assert.AreEqual<Integer>(1, L1.Count);
    L1[0].Name := 'mutated copy'; // must not leak into the cache
  finally L1.Free; end;

  var L2 := Store.LoadSources;
  try
    Assert.AreEqual('A', L2[0].Name, 'cache hands out copies');
    L2[0].Name := 'B';
    Store.SaveSource(L2[0]); // write -> invalidate
  finally L2.Free; end;

  var L3 := Store.LoadSources;
  try Assert.AreEqual('B', L3[0].Name, 'save invalidates the cache'); finally L3.Free; end;

  Store.DeleteSource(Id);
  var L4 := Store.LoadSources;
  try Assert.AreEqual<Integer>(0, L4.Count, 'delete invalidates the cache'); finally L4.Free; end;
end;

procedure TStorageTests.LoadItemsExposesUpstreamName;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId: Integer;
  F: TCatalogFilter;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'x', 'NPO 1 HD', '', 'npo1', 'http://p/x.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try Store.AddItems(ListId, 0, [Streams[0].Id]); finally Streams.Free; end;

  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual<Integer>(1, Items.Count);
    Assert.AreEqual('', Items[0].DisplayName, 'no override set');
    Assert.AreEqual('NPO 1 HD', Items[0].StreamName, 'upstream name resolved for the UI');
    Assert.AreEqual('npo1', Items[0].StreamTvgId);
    Assert.AreEqual<Integer>(1, Items[0].StreamSourceId, 'source of the upstream stream exposed');
  finally
    Items.Free;
  end;
end;

procedure TStorageTests.ManyExcludeTokensDoNotBreakQuery;
// Regression: a source with hundreds of filter tokens must not blow SQLite's
// expression-tree depth limit (the balanced-OR builder keeps depth at O(log n)).
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Cat: TCategory;
  F: TCatalogFilter;
  I: Integer;
  Tokens: TArray<string>;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'k', 'KEEP Me', '', '', 'http://p/k.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'd', 'AAA0 Drop', '', '', 'http://p/d.ts'));
  Cat := TCategory.Create; Cat.ContentType := ctLive; Cat.UpstreamId := 'c'; Cat.Name := 'KEEP Cat';
  Snap.Categories.Add(Cat);
  Store.MergeSnapshot(Snap);
  Snap.Free;

  // 800 distinct exclude tokens (more than SQLite's 1000 expr-depth at 2 LIKEs each)
  SetLength(Tokens, 800);
  for I := 0 to High(Tokens) do
    Tokens[I] := Format('AAA%d', [I]);

  F := Default(TCatalogFilter);
  F.ExcludeFilters := Tokens;
  // must execute without raising, and still hide the 'AAA0 Drop' stream
  var S := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, S.Count, 'only KEEP Me survives 800 exclude tokens');
    Assert.AreEqual('KEEP Me', S[0].Name);
  finally
    S.Free;
  end;
  var C := Store.LoadCategories(F);
  try
    Assert.AreEqual<Integer>(1, C.Count, 'category query also survives many tokens');
  finally
    C.Free;
  end;
end;

procedure TStorageTests.PerSourceFiltersApplyInAllSourcesView;
// In the "all sources" view each row is judged against ITS source's filters:
// source 1 excludes 'NL|', source 2 has no filter, so only source 1's NL row hides.
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
  SFs: TArray<TSourceFilter>;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'NL| A', '', '', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'b', 'UK| B', '', '', 'http://p/b.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Snap := TSourceSnapshot.Create(2);
  Snap.Streams.Add(MakeStream(2, ctLive, 'c', 'NL| C', '', '', 'http://p/c.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  SetLength(SFs, 1);
  SFs[0].SourceId := 1;
  SFs[0].ExcludeFilters := ['NL|'];

  F := Default(TCatalogFilter);
  F.SourceFilters := SFs; // SourceId stays 0 => all sources
  var S := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(2, S.Count, 'only source 1''s NL row is hidden');
    var Names := '';
    for var I := 0 to S.Count - 1 do Names := Names + S[I].Name + ';';
    Assert.IsFalse(Names.Contains('NL| A'), 'source 1 NL hidden');
    Assert.IsTrue(Names.Contains('NL| C'), 'source 2 NL kept (no filter on src 2)');
    Assert.IsTrue(Names.Contains('UK| B'), 'source 1 UK kept');
  finally
    S.Free;
  end;
end;

procedure TStorageTests.DedupeListItemsByUrl;
// Two catalog entries with the SAME upstream URL (different names/ids) are
// duplicates: dedupe keeps one, plus the genuinely different channel.
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId, Removed: Integer;
  F: TCatalogFilter;
  Ids: TArray<Integer>;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'Chan A', '', '', 'http://p/same.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'b', 'Chan B (dup url)', '', '', 'http://p/same.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'c', 'Chan C', '', '', 'http://p/other.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    SetLength(Ids, Streams.Count);
    for var I := 0 to Streams.Count - 1 do Ids[I] := Streams[I].Id;
  finally Streams.Free; end;
  Store.AddItems(ListId, 0, Ids); // all three on the list

  Removed := Store.DedupeListItems(ListId);
  Assert.AreEqual<Integer>(1, Removed, 'one duplicate URL removed');

  var Items := Store.LoadItems(ListId);
  try
    Assert.AreEqual<Integer>(2, Items.Count, 'distinct-URL channels remain');
  finally Items.Free; end;

  // running again is a no-op
  Assert.AreEqual<Integer>(0, Store.DedupeListItems(ListId), 'idempotent');
end;

procedure TStorageTests.SortGroupAlphabeticallyNumbersByName;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Grp: TCustomGroup;
  ListId, GroupId: Integer;
  F: TCatalogFilter;
  It: TCustomItem;
  Nums: TDictionary<string, Integer>;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'z', 'Zebra', '', '', 'http://p/z.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'Apple', '', '', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'm', 'Mango', '', '', 'http://p/m.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'G'; GroupId := Store.SaveGroup(Grp); finally Grp.Free; end;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    var Ids: TArray<Integer>;
    SetLength(Ids, Streams.Count);
    for var I := 0 to Streams.Count - 1 do Ids[I] := Streams[I].Id;
    Store.AddItems(ListId, GroupId, Ids);
  finally Streams.Free; end;

  Assert.AreEqual<Integer>(3, Store.SortGroupAlphabetically(ListId, GroupId));

  Nums := TDictionary<string, Integer>.Create;
  var Items := Store.LoadItems(ListId);
  try
    for It in Items do Nums.AddOrSetValue(It.StreamName, It.ChannelNumber);
    Assert.AreEqual<Integer>(1, Nums['Apple'], 'Apple first');
    Assert.AreEqual<Integer>(2, Nums['Mango'], 'Mango second');
    Assert.AreEqual<Integer>(3, Nums['Zebra'], 'Zebra third');
  finally
    Items.Free;
    Nums.Free;
  end;
end;

procedure TStorageTests.ReorderGroupItemsNumbersByGivenOrder;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Grp: TCustomGroup;
  ListId, GroupId, Numbered: Integer;
  ByName, Nums: TDictionary<string, Integer>;
  Order: TArray<Integer>;
  It: TCustomItem;
begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'z', 'Zebra', '', '', 'http://p/z.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'Apple', '', '', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'm', 'Mango', '', '', 'http://p/m.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'G'; GroupId := Store.SaveGroup(Grp); finally Grp.Free; end;

  var F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    var Ids: TArray<Integer>;
    SetLength(Ids, Streams.Count);
    for var I := 0 to Streams.Count - 1 do Ids[I] := Streams[I].Id;
    Store.AddItems(ListId, GroupId, Ids);
  finally Streams.Free; end;

  // map upstream stream name -> list_item id
  ByName := TDictionary<string, Integer>.Create;
  var ItemsA := Store.LoadItems(ListId);
  try
    for It in ItemsA do ByName.AddOrSetValue(It.StreamName, It.Id);
  finally ItemsA.Free; end;

  // explicit display order Zebra, Apple, Mango; the trailing bogus id must be ignored
  Order := [ByName['Zebra'], ByName['Apple'], ByName['Mango'], 999999];
  Numbered := Store.ReorderGroupItems(ListId, GroupId, Order);
  Assert.AreEqual<Integer>(3, Numbered, 'only the 3 real items are numbered (bogus id skipped)');

  Nums := TDictionary<string, Integer>.Create;
  var ItemsB := Store.LoadItems(ListId);
  try
    for It in ItemsB do Nums.AddOrSetValue(It.StreamName, It.ChannelNumber);
    Assert.AreEqual<Integer>(1, Nums['Zebra'], 'Zebra first');
    Assert.AreEqual<Integer>(2, Nums['Apple'], 'Apple second');
    Assert.AreEqual<Integer>(3, Nums['Mango'], 'Mango third');
  finally
    ItemsB.Free;
    Nums.Free;
  end;
  ByName.Free;
end;

// Bouquet-wide renumber: explicit numbers for many items in one call (foreign ids
// skipped); a later drag-reorder or A->Z sort of that group keeps its block
// (starts at the group's lowest number, not back at 1).
procedure TStorageTests.BouquetRenumberSurvivesGroupReorder;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Grp: TCustomGroup;
  ListId, GroupId: Integer;
  ByName, Nums: TDictionary<string, Integer>;
  It: TCustomItem;
  Plan: TArray<TItemNumber>;

  function Num(AItem, ANumber: Integer): TItemNumber;
  begin
    Result.ItemId := AItem;
    Result.ChannelNumber := ANumber;
  end;

  procedure ReadNums;
  begin
    Nums.Clear;
    var Items := Store.LoadItems(ListId);
    try
      for var X in Items do Nums.AddOrSetValue(X.StreamName, X.ChannelNumber);
    finally Items.Free; end;
  end;

begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'z', 'Zebra', '', '', 'http://p/z.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'a', 'Apple', '', '', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 'm', 'Mango', '', '', 'http://p/m.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'G'; GroupId := Store.SaveGroup(Grp); finally Grp.Free; end;
  var F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    var Ids: TArray<Integer>;
    SetLength(Ids, Streams.Count);
    for var I := 0 to Streams.Count - 1 do Ids[I] := Streams[I].Id;
    Store.AddItems(ListId, GroupId, Ids);
  finally Streams.Free; end;
  ByName := TDictionary<string, Integer>.Create;
  Nums := TDictionary<string, Integer>.Create;
  try
    var Items := Store.LoadItems(ListId);
    try
      for It in Items do ByName.AddOrSetValue(It.StreamName, It.Id);
    finally Items.Free; end;

    Plan := [Num(ByName['Zebra'], 101), Num(ByName['Apple'], 102), Num(ByName['Mango'], 103),
             Num(999999, 1)];
    Assert.AreEqual<Integer>(3, Store.SetItemNumbers(ListId, Plan), 'foreign id skipped');
    Assert.AreEqual<Integer>(0, Store.SetItemNumbers(ListId + 1, Plan), 'other list untouched');
    ReadNums;
    Assert.AreEqual<Integer>(101, Nums['Zebra']);
    Assert.AreEqual<Integer>(103, Nums['Mango']);

    Store.ReorderGroupItems(ListId, GroupId, [ByName['Mango'], ByName['Zebra'], ByName['Apple']]);
    ReadNums;
    Assert.AreEqual<Integer>(101, Nums['Mango'], 'drag keeps the block start');
    Assert.AreEqual<Integer>(103, Nums['Apple']);

    Store.SortGroupAlphabetically(ListId, GroupId);
    ReadNums;
    Assert.AreEqual<Integer>(101, Nums['Apple'], 'A-Z keeps the block start');
    Assert.AreEqual<Integer>(103, Nums['Zebra']);
  finally
    Nums.Free;
    ByName.Free;
  end;
end;

procedure TStorageTests.StoresUnicodeNamesIntact;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  F: TCatalogFilter;
  UniName: string;
begin
  UniName := 'A' + #$26BD + 'B'; // A⚽B (U+26BD)
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u1', UniName, '', '', 'http://p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  var L := Store.LoadStreams(F);
  try
    Assert.AreEqual<Integer>(1, L.Count);
    Assert.AreEqual<Integer>(3, Length(L[0].Name), 'length intact');
    // Full UTF-8 round-trip on every platform (incl. static-SQLite Win32): the
    // store binds text via AsWideString with no ANSI<->Wide MapRules, so the
    // emoji is preserved on write and decoded back on read. See the constructor.
    Assert.AreEqual<Integer>($26BD, Ord(L[0].Name[2]), 'emoji survives store+reload');
  finally
    L.Free;
  end;
end;

procedure TStorageTests.FindListByCredentials_DefaultAndNamed;
var
  Store: IStore;
  Lst: TCustomList;
  Found: TCustomList;
begin
  Store := NewStore(FDbPath);
  Lst := TCustomList.Create;
  try
    Lst.Name := 'Default';
    Lst.OutputUsername := 'box1';
    Lst.OutputPassword := 'secret';
    Store.SaveList(Lst);
  finally
    Lst.Free;
  end;

  // SECURITY: empty credentials must NOT open a bouquet that has a login
  Found := Store.FindListByCredentials('', '');
  Assert.IsNull(Found, 'empty login never reaches a protected bouquet');
  Found := Store.FindListByCredentials('', 'secret');
  Assert.IsNull(Found, 'not with only the password either');

  // ...but a bouquet WITHOUT a login is the default for boxes without one
  Lst := TCustomList.Create;
  try
    Lst.Name := 'Open'; Lst.Enabled := True;
    Store.SaveList(Lst);
  finally
    Lst.Free;
  end;
  Found := Store.FindListByCredentials('', '');
  try
    Assert.IsNotNull(Found);
    Assert.AreEqual('Open', Found.Name, 'the login-free bouquet, not the protected one');
  finally
    Found.Free;
  end;

  // named credentials match
  Found := Store.FindListByCredentials('box1', 'secret');
  try
    Assert.IsNotNull(Found);
  finally
    Found.Free;
  end;

  // wrong password -> nil
  Found := Store.FindListByCredentials('box1', 'wrong');
  Assert.IsNull(Found);
end;

procedure TStorageTests.OutputChannelsOrderAndOverrides;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  FavGrp, NormGrp: TCustomGroup;
  ListId: Integer;
  F: TCatalogFilter;
  StreamIds: TArray<Integer>;

  procedure AddItem(AStreamId, AGroupId: Integer; const ADisplay: string);
  var
    It: TCustomItem;
  begin
    It := TCustomItem.Create;
    try
      It.ListId := ListId;
      It.StreamItemId := AStreamId;
      It.CustomGroupId := AGroupId;
      It.ContentType := ctLive;
      It.DisplayName := ADisplay;
      Store.SaveItem(It);
    finally
      It.Free;
    end;
  end;

begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 's1', 'Zebra', 'X', '', 'http://p/z.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 's2', 'Apple', 'X', '', 'http://p/a.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try
    // LoadStreams is ordered by name: [0]=Apple(s2), [1]=Zebra(s1)
    StreamIds := [Streams[0].Id, Streams[1].Id];
  finally
    Streams.Free;
  end;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  NormGrp := TCustomGroup.Create;
  try NormGrp.ListId := ListId; NormGrp.Name := 'News'; var NormId := Store.SaveGroup(NormGrp);
    FavGrp := TCustomGroup.Create;
    try FavGrp.ListId := ListId; FavGrp.Name := 'Sports'; FavGrp.IsFavorite := True;
      var FavId := Store.SaveGroup(FavGrp);
      // put "Apple" in News (normal), "Zebra" renamed to "AAA" in Sports (favorite)
      AddItem(StreamIds[0], NormId, '');       // Apple -> News
      AddItem(StreamIds[1], FavId, 'AAA Top'); // Zebra -> Sports(fav), renamed
    finally FavGrp.Free; end;
  finally NormGrp.Free; end;

  var Out := Store.LoadOutputChannels(ListId);
  try
    Assert.AreEqual<Integer>(2, Out.Count);
    // favorite group first regardless of alphabetical group name (Sports > News)
    Assert.IsTrue(Out[0].IsFavoriteGroup, 'favorite group must sort first');
    Assert.AreEqual('Sports', Out[0].GroupName);
    Assert.AreEqual('AAA Top', Out[0].Name, 'display-name override applied');
    Assert.AreEqual('http://p/z.ts', Out[0].UpstreamUrl, 'raw upstream url preserved');
    Assert.AreEqual('News', Out[1].GroupName);
    Assert.AreEqual('Apple', Out[1].Name, 'empty override falls back to upstream name');
  finally
    Out.Free;
  end;
end;

// Manual group drag-order (ReorderGroups) overrides the default A→Z; favorites
// still sort first.
procedure TStorageTests.GroupReorderControlsOutputOrder;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  ListId, AId, BId: Integer;
  F: TCatalogFilter;
  StreamIds: TArray<Integer>;

  procedure AddItem(AStreamId, AGroupId: Integer);
  var It: TCustomItem;
  begin
    It := TCustomItem.Create;
    try
      It.ListId := ListId; It.StreamItemId := AStreamId;
      It.CustomGroupId := AGroupId; It.ContentType := ctLive;
      Store.SaveItem(It);
    finally It.Free; end;
  end;

begin
  Store := NewStore(FDbPath);
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 's1', 'ChA', 'X', '', 'http://p/a.ts'));
  Snap.Streams.Add(MakeStream(1, ctLive, 's2', 'ChB', 'X', '', 'http://p/b.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;

  F := Default(TCatalogFilter);
  var Streams := Store.LoadStreams(F);
  try StreamIds := [Streams[0].Id, Streams[1].Id]; finally Streams.Free; end;

  Lst := TCustomList.Create;
  try Lst.Name := 'L'; ListId := Store.SaveList(Lst); finally Lst.Free; end;

  // two non-favorite groups "Alpha" and "Beta" (A→Z would put Alpha first)
  var GA := TCustomGroup.Create;
  try GA.ListId := ListId; GA.Name := 'Alpha'; AId := Store.SaveGroup(GA); finally GA.Free; end;
  var GB := TCustomGroup.Create;
  try GB.ListId := ListId; GB.Name := 'Beta'; BId := Store.SaveGroup(GB); finally GB.Free; end;
  AddItem(StreamIds[0], AId);
  AddItem(StreamIds[1], BId);

  // default order: Alpha before Beta (A→Z)
  var Out1 := Store.LoadOutputChannels(ListId);
  try Assert.AreEqual('Alpha', Out1[0].GroupName, 'default A→Z puts Alpha first'); finally Out1.Free; end;

  // drag Beta before Alpha
  Store.ReorderGroups(ListId, [BId, AId]);
  var Out2 := Store.LoadOutputChannels(ListId);
  try
    Assert.AreEqual('Beta', Out2[0].GroupName, 'manual order puts Beta first');
    Assert.AreEqual('Alpha', Out2[1].GroupName);
  finally Out2.Free; end;
end;

procedure TStorageTests.EpgReplaceAndLoadByTvgId;
var
  Store: IStore;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
begin
  Store := NewStore(FDbPath);
  Progs := TEpgProgrammeList.Create(True);
  try
    P := TEpgProgramme.Create;
    P.ChannelTvgId := 'nl1';
    P.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
    P.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0);
    P.Title := 'News';
    Progs.Add(P);
    Store.ReplaceEpg(1, Progs);
  finally
    Progs.Free;
  end;

  var L := Store.LoadEpgForTvgIds(['nl1']);
  try
    Assert.AreEqual<Integer>(1, L.Count);
    Assert.AreEqual('News', L[0].Title);
  finally
    L.Free;
  end;

  // empty id set returns empty (no SQL error)
  L := Store.LoadEpgForTvgIds([]);
  try
    Assert.AreEqual<Integer>(0, L.Count);
  finally
    L.Free;
  end;

  // chunk-boundary: a huge id list (well over the 800-per-batch chunk AND over the
  // historical 999 bound-parameter limit) must still find the programme — proves
  // the chunk loop accumulates across batches and doesn't blow the param limit.
  var Many: TArray<string>;
  SetLength(Many, 1700);
  for var I := 0 to High(Many) do Many[I] := Format('x%d', [I]);
  Many[1500] := 'nl1'; // place the real id beyond the first chunk
  L := Store.LoadEpgForTvgIds(Many);
  try
    Assert.AreEqual<Integer>(1, L.Count, 'programme found across chunk boundary');
    Assert.AreEqual('News', L[0].Title);
  finally
    L.Free;
  end;
end;

// The AMaxDays cap drops programmes starting beyond now + N days; 0 = no cap.
procedure TStorageTests.EpgMaxDaysCapsFutureProgrammes;
var
  Store: IStore;
  Progs: TEpgProgrammeList;

  procedure AddProg(ADaysAhead: Integer; const ATitle: string);
  var P: TEpgProgramme;
  begin
    P := TEpgProgramme.Create;
    P.ChannelTvgId := 'nl1';
    P.StartUtc := IncDay(NowUtc, ADaysAhead);
    P.StopUtc := IncHour(P.StartUtc, 1);
    P.Title := ATitle;
    Progs.Add(P);
  end;

begin
  Store := NewStore(FDbPath);
  Progs := TEpgProgrammeList.Create(True);
  try
    AddProg(1, 'Tomorrow');
    AddProg(5, 'In 5 days');
    AddProg(10, 'In 10 days');
    Store.ReplaceEpg(1, Progs);
  finally
    Progs.Free;
  end;

  // cap to 7 days -> the 10-day one is dropped
  var L := Store.LoadEpgForTvgIds(['nl1'], 7);
  try
    Assert.AreEqual<Integer>(2, L.Count, '7-day cap keeps only programmes within a week');
  finally L.Free; end;

  // no cap -> all three
  L := Store.LoadEpgForTvgIds(['nl1'], 0);
  try
    Assert.AreEqual<Integer>(3, L.Count, '0 = no cap, everything returned');
  finally L.Free; end;
end;

procedure TStorageTests.IngestStatusRecordsUnknownSource;
// Exercises the ingest status lifecycle without any network: refreshing a
// non-existent source must record a finished status with an error.
var
  Store: IStore;
  Ingest: TIngestService;
  Statuses: TArray<TIngestStatus>;
  S: TIngestStatus;
  Found: Boolean;
begin
  Store := NewStore(FDbPath);
  Ingest := TIngestService.Create(Store);
  try
    Assert.AreEqual<Integer>(0, Length(Ingest.GetStatus), 'no status before any refresh');
    Ingest.RefreshSource(999); // unknown id → resolves immediately with an error
    Statuses := Ingest.GetStatus;
    Found := False;
    for S in Statuses do
      if S.SourceId = 999 then
      begin
        Found := True;
        Assert.IsFalse(S.Running, 'finished');
        Assert.AreEqual('source not found', S.Error);
      end;
    Assert.IsTrue(Found, 'status recorded for the requested source');
  finally
    Ingest.Free;
  end;
end;

// The locking store answers the zap path (list by login + stream on that list)
// from memory, and forgets it after any write that can change the answer.
procedure TStorageTests.ZapCacheServesAndInvalidates;
var
  Inner, Store: IStore;
  Snap: TSourceSnapshot;
  Lst, Found: TCustomList;
  It: TCustomItem;
  S: TStreamItem;
  ListId, StreamId, ItemId: Integer;
begin
  Inner := NewStore(FDbPath);
  Store := TLockingStore.Create(Inner, Inner); // single connection, as on Unraid
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u1', 'NPO 1', 'NL', 'npo1.nl', 'http://p/live/u/p/1.ts'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  var L := Store.LoadStreams(Default(TCatalogFilter));
  try StreamId := L[0].Id; finally L.Free; end;

  Lst := TCustomList.Create;
  try
    Lst.Name := 'Box'; Lst.OutputUsername := 'box'; Lst.OutputPassword := 'pw'; Lst.Enabled := True;
    ListId := Store.SaveList(Lst);
  finally
    Lst.Free;
  end;
  It := TCustomItem.Create;
  try
    It.ListId := ListId; It.StreamItemId := StreamId; It.ContentType := ctLive;
    ItemId := Store.SaveItem(It);
  finally
    It.Free;
  end;

  // first call fills the cache, second is served from it (both owned copies)
  for var Round := 1 to 2 do
  begin
    Found := Store.FindListByCredentials('box', 'pw');
    try
      Assert.IsNotNull(Found);
      Assert.AreEqual(ListId, Found.Id);
    finally
      Found.Free;
    end;
    S := Store.LoadListStreamById(ListId, StreamId);
    try
      Assert.IsNotNull(S);
      Assert.AreEqual('http://p/live/u/p/1.ts', S.UpstreamUrl);
    finally
      S.Free;
    end;
  end;

  // the provider URL changes on a refresh -> the next zap sees the new one
  Snap := TSourceSnapshot.Create(1);
  Snap.Streams.Add(MakeStream(1, ctLive, 'u1', 'NPO 1', 'NL', 'npo1.nl', 'http://p/live/u/p/1.m3u8'));
  Store.MergeSnapshot(Snap);
  Snap.Free;
  S := Store.LoadListStreamById(ListId, StreamId);
  try
    Assert.AreEqual('http://p/live/u/p/1.m3u8', S.UpstreamUrl, 'refresh invalidates');
  finally
    S.Free;
  end;

  // removed from the list -> no longer playable with this login
  Store.DeleteItem(ItemId);
  S := Store.LoadListStreamById(ListId, StreamId);
  Assert.IsNull(S, 'item removed');

  // login changed -> old credentials no longer resolve
  Found := Store.FindListByCredentials('box', 'pw');
  try
    Found.OutputPassword := 'new';
    Store.SaveList(Found);
  finally
    Found.Free;
  end;
  Found := Store.FindListByCredentials('box', 'pw');
  Assert.IsNull(Found, 'old password rejected');
  Found := Store.FindListByCredentials('box', 'new');
  try
    Assert.IsNotNull(Found, 'new password accepted');
  finally
    Found.Free;
  end;
end;

function SaveTestSource(const AStore: IStore; ATypes: TContentTypes; AEnabled: Boolean;
  AId: Integer = 0): Integer;
var
  Src: TSourceConfig;
begin
  Src := TSourceConfig.Create;
  try
    Src.Id := AId;
    Src.Name := 'P';
    Src.Kind := skXtream;
    Src.Url := 'http://prov:8080/';
    Src.Username := 'u';
    Src.Password := 'p';
    Src.Enabled := AEnabled;
    Src.ContentTypes := ATypes;
    Result := AStore.SaveSource(Src);
  finally
    Src.Free;
  end;
end;

function AddTestItem(const AStore: IStore; AListId, AStreamId: Integer; ACt: TContentType): Integer;
var
  It: TCustomItem;
begin
  It := TCustomItem.Create;
  try
    It.ListId := AListId;
    It.StreamItemId := AStreamId;
    It.ContentType := ACt;
    Result := AStore.SaveItem(It);
  finally
    It.Free;
  end;
end;

function StreamIdByUpstream(const AStore: IStore; const AUpstreamId: string): Integer;
var
  L: TStreamItemList;
  S: TStreamItem;
begin
  Result := 0;
  L := AStore.LoadStreams(Default(TCatalogFilter));
  try
    for S in L do
      if S.UpstreamId = AUpstreamId then
        Exit(S.Id);
  finally
    L.Free;
  end;
end;

function NewTestList(const AStore: IStore; const AName: string): Integer;
var
  Lst: TCustomList;
begin
  Lst := TCustomList.Create;
  try
    Lst.Name := AName;
    Lst.Enabled := True;
    Result := AStore.SaveList(Lst);
  finally
    Lst.Free;
  end;
end;

// a source that is switched off, or a content type switched off on it, is never
// offered to a box (output list, redirect lookup) - its items stay on the list
procedure TStorageTests.DisabledSourceOrTypeIsNotOffered;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  SrcId, ListId, LiveId, MovieId: Integer;
  Out: TOutputChannelList;
  S: TStreamItem;
begin
  Store := NewStore(FDbPath);
  SrcId := SaveTestSource(Store, [ctLive, ctMovie], True);
  Snap := TSourceSnapshot.Create(SrcId);
  try
    Snap.Streams.Add(MakeStream(SrcId, ctLive, 'l1', 'Live One', 'G', '', 'http://prov/live/u/p/l1.ts'));
    Snap.Streams.Add(MakeStream(SrcId, ctMovie, 'm1', 'Movie One', 'G', '', 'http://prov/movie/u/p/m1.mkv'));
    Store.MergeSnapshot(Snap);
  finally
    Snap.Free;
  end;
  LiveId := StreamIdByUpstream(Store, 'l1');
  MovieId := StreamIdByUpstream(Store, 'm1');
  ListId := NewTestList(Store, 'L');
  AddTestItem(Store, ListId, LiveId, ctLive);
  AddTestItem(Store, ListId, MovieId, ctMovie);

  Out := Store.LoadOutputChannels(ListId);
  try Assert.AreEqual<Integer>(2, Out.Count, 'both offered'); finally Out.Free; end;

  // movies switched off on the source
  SaveTestSource(Store, [ctLive], True, SrcId);
  Out := Store.LoadOutputChannels(ListId);
  try
    Assert.AreEqual<Integer>(1, Out.Count, 'movie no longer offered');
    Assert.AreEqual('Live One', Out[0].Name);
  finally
    Out.Free;
  end;
  Assert.IsNull(Store.LoadListStreamById(ListId, MovieId), 'no redirect to a switched-off type');
  S := Store.LoadListStreamById(ListId, LiveId);
  try Assert.IsNotNull(S); finally S.Free; end;

  // whole source switched off
  SaveTestSource(Store, [ctLive], False, SrcId);
  Out := Store.LoadOutputChannels(ListId);
  try Assert.AreEqual<Integer>(0, Out.Count, 'disabled source offers nothing'); finally Out.Free; end;
  Assert.IsNull(Store.LoadListStreamById(ListId, LiveId));
end;

// Xtream series episodes get stable ids of our own; they resolve to the provider
// episode URL, but only via a list that carries the series
procedure TStorageTests.SeriesEpisodesResolveOnlyOnTheirList;
var
  Store: IStore;
  Snap: TSourceSnapshot;
  SrcId, ListA, ListB, SerId: Integer;
  Ids, Again: TArray<Integer>;
  S: TStreamItem;
begin
  Store := NewStore(FDbPath);
  SrcId := SaveTestSource(Store, [ctSeries], True);
  Snap := TSourceSnapshot.Create(SrcId);
  try
    Snap.Streams.Add(MakeStream(SrcId, ctSeries, 'ser1', 'Some Show', 'G', '', 'http://prov/series/u/p/ser1.ts'));
    Store.MergeSnapshot(Snap);
  finally
    Snap.Free;
  end;
  SerId := StreamIdByUpstream(Store, 'ser1');
  ListA := NewTestList(Store, 'A');
  ListB := NewTestList(Store, 'B');
  AddTestItem(Store, ListA, SerId, ctSeries);

  Ids := Store.EnsureEpisodeIds(SerId, ['901', '902'], ['mkv', '']);
  Assert.AreEqual<Integer>(2, Length(Ids));
  Assert.IsTrue(Ids[0] >= cEpisodeIdBase, 'outside the catalog id range');
  Assert.AreNotEqual(Ids[0], Ids[1]);
  Again := Store.EnsureEpisodeIds(SerId, ['902', '901'], ['', 'mkv']);
  Assert.AreEqual(Ids[0], Again[1], 'stable per upstream episode');
  Assert.AreEqual(Ids[1], Again[0]);

  S := Store.LoadListStreamById(ListA, Ids[0]);
  try
    Assert.IsNotNull(S);
    Assert.AreEqual('http://prov:8080/series/u/p/901.mkv', S.UpstreamUrl);
    Assert.AreEqual(SrcId, S.SourceId);
  finally
    S.Free;
  end;
  S := Store.LoadListStreamById(ListA, Ids[1]);
  try
    Assert.AreEqual('http://prov:8080/series/u/p/902.mp4', S.UpstreamUrl, 'no extension -> mp4');
  finally
    S.Free;
  end;
  Assert.IsNull(Store.LoadListStreamById(ListB, Ids[0]), 'not via a list without the series');
end;

procedure TStorageTests.PathCredentials_DashAndEncoding;
var
  Store: IStore;
  Lst: TCustomList;
  Found: TCustomList;
begin
  Assert.AreEqual('-', PathCred(''));
  Assert.AreEqual('a%2Fb%20c%3F', PathCred('a/b c?'));
  Assert.AreEqual('box_1.x~', PathCred('box_1.x~'));

  Store := NewStore(FDbPath);
  NewTestList(Store, 'Open'); // no login
  Lst := TCustomList.Create;
  try
    Lst.Name := 'Locked'; Lst.Enabled := True;
    Lst.OutputUsername := 'me'; Lst.OutputPassword := 'p/w d';
    Store.SaveList(Lst);
  finally
    Lst.Free;
  end;
  Found := FindListForPath(Store, '-', '-');
  try
    Assert.IsNotNull(Found, '"-" is the empty login');
    Assert.AreEqual('Open', Found.Name);
  finally
    Found.Free;
  end;
  Found := FindListForPath(Store, 'me', PathCred('p/w d'));
  try
    Assert.IsNotNull(Found, 'percent-encoded password from our own URL');
    Assert.AreEqual('Locked', Found.Name);
  finally
    Found.Free;
  end;
end;

function SaveM3USource(const AStore: IStore): Integer;
var
  lSource: TSourceConfig;
begin
  lSource := TSourceConfig.Create;
  try
    lSource.Name := 'M';
    lSource.Kind := skM3U;
    lSource.Url := 'http://prov/get.php';
    lSource.Enabled := True;
    lSource.ContentTypes := [ctLive, ctMovie, ctSeries, ctRadio];
    Result := AStore.SaveSource(lSource);
  finally
    FreeAndNil(lSource);
  end;
end;

// The reader now classifies an item differently ("NL| FILM" movie -> live): the
// stored row is re-keyed in place - same id, the bouquet item follows - instead of
// a duplicate row next to a frozen old one.
procedure TStorageTests.ReclassifiedStreamKeepsIdAndListItem;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lSrcId, lListId, lOldId: Integer;
  lOut: TOutputChannelList;
  lAll: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSrcId := SaveM3USource(lStore);
  lSnap := TSourceSnapshot.Create(lSrcId);
  try
    lSnap.Streams.Add(MakeStream(lSrcId, ctMovie, 'u1', 'Film1 Action', 'NL| FILM', '', 'http://prov/live/u/p/1.ts'));
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lOldId := StreamIdByUpstream(lStore, 'u1');
  lListId := NewTestList(lStore, 'L');
  AddTestItem(lStore, lListId, lOldId, ctMovie);

  lSnap := TSourceSnapshot.Create(lSrcId);
  try
    lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u1', 'Film1 Action', 'NL| FILM', '', 'http://prov/live/u/p/1.ts'));
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;

  lAll := lStore.LoadStreams(Default(TCatalogFilter));
  try
    Assert.AreEqual<Integer>(1, lAll.Count, 'no duplicate row');
    Assert.AreEqual(lOldId, lAll[0].Id, 'same id');
    Assert.AreEqual(Ord(ctLive), Ord(lAll[0].ContentType));
  finally
    FreeAndNil(lAll);
  end;
  lOut := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual<Integer>(1, lOut.Count);
    Assert.AreEqual(Ord(ctLive), Ord(lOut[0].ContentType), 'the bouquet item follows the new type');
  finally
    FreeAndNil(lOut);
  end;
end;

// '-' stands for an empty field on its own: a bouquet with a username but no password
procedure TStorageTests.PathCredentials_DashPerField;
var
  lStore: IStore;
  lList: TCustomList;
  lFound: TCustomList;
begin
  lStore := NewStore(FDbPath);
  lList := TCustomList.Create;
  try
    lList.Name := 'UserOnly';
    lList.Enabled := True;
    lList.OutputUsername := 'bob';
    lStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;
  lFound := FindListForPath(lStore, 'bob', PathCred(''));
  try
    Assert.IsNotNull(lFound, '/live/bob/-/12 reaches the bouquet');
    Assert.AreEqual('UserOnly', lFound.Name);
  finally
    FreeAndNil(lFound);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TStorageTests);

end.
