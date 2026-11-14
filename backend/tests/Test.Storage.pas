unit Test.Storage;

{ Integration tests for the SQLite store against a fresh temp database per test.
  Exercises CRUD, the MergeSnapshot diff/is_new logic, filters, lists/groups/
  items, bulk add, credential resolution and the resolved output ordering. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Integration tests for TSQLiteStore / TLockingStore on a fresh temp database per test.</summary>
  [TestFixture]
  TStorageTests = class
  private
    FDbPath: string;
  public
    /// <summary>Picks a unique temp database path for the test.</summary>
    [Setup] procedure Setup;
    /// <summary>Deletes the temp database and its WAL/SHM side files.</summary>
    [TearDown] procedure TearDown;

    [Test] procedure SourceCrudRoundtrips;
    [Test] procedure SaveSourceUpdateRoundtrips;
    [Test] procedure DeleteSourceCascades;
    [Test] procedure SaveListUpdateRoundtrips;
    [Test] procedure MarkCategoriesSeenClearsNew;
    [Test] procedure OnlyNewKeepsGroupWithNewChannels;
    [Test] procedure MarkCategoriesSeenClearsItsStreams;
    [Test] procedure MarkAllSeenIsScoped;
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
    /// <summary>A transaction that raises leaves nothing behind (settings import).</summary>
    [Test] procedure RunInTransactionRollsBackOnError;
    [Test] procedure OutputChannelsOrderAndOverrides;
    [Test] procedure GroupReorderControlsOutputOrder;
    [Test] procedure EpgReplaceAndLoadByTvgId;
    [Test] procedure EpgMaxDaysCapsFutureProgrammes;
    [Test] procedure IngestStatusRecordsUnknownSource;
    [Test] procedure ZapCacheServesAndInvalidates;
    /// <summary>A refresh finishing after its source was deleted writes no orphans.</summary>
    [Test] procedure MergeForDeletedSourceWritesNothing;
    /// <summary>Re-key picks the right old type when one upstream id has two types.</summary>
    [Test] procedure ReKeyWithUpstreamIdUnderTwoTypes;
    /// <summary>Init removes rows (and list items) left under a deleted source id.</summary>
    [Test] procedure InitPurgesOrphanedSourceRows;
    /// <summary>A mirror bouquet outputs the master's channels with its own provider account.</summary>
    [Test] procedure MirrorOutputChannelsFollowMaster;
    /// <summary>Box lookups through a mirror are scoped to the master (incl. episodes, failover).</summary>
    [Test] procedure MirrorListStreamByIdScopedToMaster;
    /// <summary>Mirror rules: no self / unknown / chained mirror, empty first, master delete blocked.</summary>
    [Test] procedure MirrorValidationRules;
    /// <summary>A mirror's credentials go with the list and with the source.</summary>
    [Test] procedure MirrorCredentialsDeletedWithListAndSource;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.IOUtils,
  System.DateUtils,
  System.Generics.Collections,
  // third-party
  FireDAC.Comp.Client,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList,
  IPTV.Storage.Intf,
  IPTV.Storage.SQLite,
  IPTV.Storage.Locking,
  IPTV.Core.Utils,
  IPTV.Ingest.Service,
  IPTV.Output.Builder;

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
  lStore: IStore;
  lSrc: TSourceConfig;
  lId: Integer;
  lL: TObjectList<TSourceConfig>;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'Provider A';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://host:8080';
    lSrc.Username := 'u';
    lSrc.Password := 'p';
    lSrc.ContentTypes := [ctLive, ctMovie];
    lId := lStore.SaveSource(lSrc);
    Assert.IsTrue(lId > 0);
  finally
    FreeAndNil(lSrc);
  end;

  lL := lStore.LoadSources;
  try
    Assert.AreEqual<Integer>(1, lL.Count);
    Assert.AreEqual('Provider A', lL[0].Name);
    Assert.AreEqual(skXtream, lL[0].Kind);
    Assert.IsTrue([ctLive, ctMovie] = lL[0].ContentTypes);
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.SaveSourceUpdateRoundtrips;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lId: Integer;
  lL: TObjectList<TSourceConfig>;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'Orig';
    lSrc.Kind := skM3U;
    lSrc.Url := 'http://a';
    lSrc.ContentTypes := [ctLive];
    lId := lStore.SaveSource(lSrc);
    // update existing
    lSrc.Name := 'Renamed';
    lSrc.Url := 'http://b';
    lSrc.ContentTypes := [ctLive, ctMovie];
    lSrc.IncludeFilters := ['NL|'];
    lSrc.StripPrefixes := ['NL', 'UK'];
    lSrc.UserAgent := 'VLC/3.0.20 LibVLC/3.0.20';
    lSrc.Referer := 'http://provider.example/c/';
    lSrc.ForceHls := True;
    lSrc.AccountStatus := 'Active';
    lSrc.ExpiresUtc := EncodeDateTime(2027, 3, 1, 12, 0, 0, 0);
    lSrc.MaxConnections := 2;
    lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;
  lL := lStore.LoadSources;
  try
    Assert.AreEqual<Integer>(1, lL.Count, 'update must not insert a second row');
    Assert.AreEqual<Integer>(lId, lL[0].Id);
    Assert.AreEqual('Renamed', lL[0].Name);
    Assert.AreEqual('http://b', lL[0].Url);
    Assert.IsTrue([ctLive, ctMovie] = lL[0].ContentTypes);
    Assert.AreEqual<Integer>(1, Length(lL[0].IncludeFilters));
    Assert.AreEqual<Integer>(2, Length(lL[0].StripPrefixes), 'strip prefixes round-trip');
    Assert.AreEqual('NL', lL[0].StripPrefixes[0]);
    Assert.AreEqual('VLC/3.0.20 LibVLC/3.0.20', lL[0].UserAgent, 'per-provider UA round-trips');
    Assert.AreEqual('http://provider.example/c/', lL[0].Referer, 'per-provider Referer round-trips');
    Assert.IsTrue(lL[0].ForceHls, 'per-provider force-HLS round-trips');
    Assert.AreEqual('Active', lL[0].AccountStatus, 'account status round-trips');
    Assert.AreEqual(EncodeDateTime(2027, 3, 1, 12, 0, 0, 0), lL[0].ExpiresUtc, 1 / SecsPerDay, 'expiry round-trips');
    Assert.AreEqual<Integer>(2, lL[0].MaxConnections, 'max connections round-trips');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.DeleteSourceCascades;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lProgs: TEpgProgrammeList;
  lP: TEpgProgramme;
  lId: Integer;
  lF: TCatalogFilter;
  lS: TStreamItemList;
  lC: TCategoryList;
  lE: TEpgProgrammeList;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'S';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lId);
  lSnap.Streams.Add(MakeStream(lId, ctLive, 'a', 'A', '', 'tv1', 'http://p/a.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'c';
  lCat.Name := 'Cat';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lProgs := TEpgProgrammeList.Create(True);
  lP := TEpgProgramme.Create;
  lP.ChannelTvgId := 'tv1';
  lP.Title := 'X';
  lP.StartUtc := EncodeDateTime(2026, 6, 14, 10, 0, 0, 0);
  lP.StopUtc := EncodeDateTime(2026, 6, 14, 11, 0, 0, 0);
  lProgs.Add(lP);
  lStore.ReplaceEpg(lId, lProgs);
  FreeAndNil(lProgs);

  lStore.DeleteSource(lId);

  Assert.AreEqual<Integer>(0, lStore.LoadSources.Count, 'source row gone');
  lF := Default(TCatalogFilter);
  lF.SourceId := lId;
  lS := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(0, lS.Count, 'streams cascaded');
  finally
    FreeAndNil(lS);
  end;
  lC := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(0, lC.Count, 'categories cascaded');
  finally
    FreeAndNil(lC);
  end;
  lE := lStore.LoadEpgForTvgIds(['tv1']);
  try
    Assert.AreEqual<Integer>(0, lE.Count, 'epg cascaded');
  finally
    FreeAndNil(lE);
  end;
end;

procedure TStorageTests.SaveListUpdateRoundtrips;
var
  lStore: IStore;
  lLst: TCustomList;
  lId: Integer;
  lL: TObjectList<TCustomList>;
begin
  lStore := NewStore(FDbPath);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'L1';
    lLst.OutputUsername := 'u';
    lLst.OutputPassword := 'p';
    lLst.Enabled := True;
    lId := lStore.SaveList(lLst);
    lLst.Name := 'L2';
    lLst.OutputUsername := 'u2';
    lLst.Enabled := False;
    lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lL := lStore.LoadLists;
  try
    Assert.AreEqual<Integer>(1, lL.Count);
    Assert.AreEqual<Integer>(lId, lL[0].Id);
    Assert.AreEqual('L2', lL[0].Name);
    Assert.AreEqual('u2', lL[0].OutputUsername);
    Assert.IsFalse(lL[0].Enabled);
  finally
    FreeAndNil(lL);
  end;
end;

// a group that is not new itself but holds a new channel: newCount + "only new" view
function SnapWithGroup(ASourceId: Integer; ACt: TContentType; const AGroupId: string;
  const AStreamIds: array of string): TSourceSnapshot;
var
  lCat: TCategory;
  lStream: TStreamItem;
  lId: string;
begin
  Result := TSourceSnapshot.Create(ASourceId);
  lCat := TCategory.Create;
  lCat.ContentType := ACt;
  lCat.UpstreamId := AGroupId;
  lCat.Name := 'Group ' + AGroupId;
  Result.Categories.Add(lCat);
  for lId in AStreamIds do
  begin
    lStream := MakeStream(ASourceId, ACt, lId, 'Ch ' + lId, '', '', 'http://p/' + lId + '.ts');
    lStream.CategoryUpstreamId := AGroupId;
    Result.Streams.Add(lStream);
  end;
end;

procedure TStorageTests.OnlyNewKeepsGroupWithNewChannels;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lL: TCategoryList;
begin
  lStore := NewStore(FDbPath);
  lSnap := SnapWithGroup(1, ctLive, 'g', ['a']);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lF := Default(TCatalogFilter);
  lStore.MarkAllSeen(lF);
  // refresh #2: same group, one channel more
  lSnap := SnapWithGroup(1, ctLive, 'g', ['a', 'b']);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF.OnlyNew := True;
  lL := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lL.Count, 'a group holding a new channel stays in the only-new view');
    Assert.IsFalse(lL[0].IsNew, 'the group itself is not new');
    Assert.AreEqual<Integer>(1, lL[0].NewCount, 'one new channel in it');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.MarkCategoriesSeenClearsItsStreams;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lL: TCategoryList;
  lGroupId: Integer;
begin
  lStore := NewStore(FDbPath);
  lSnap := SnapWithGroup(1, ctLive, 'g', ['a', 'b']);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lSnap := SnapWithGroup(2, ctLive, 'h', ['c']); // own source: a refresh replaces a source's catalog
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lF.SourceId := 1;
  lL := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lL.Count, 'group g found');
    Assert.AreEqual<Integer>(2, lL[0].NewCount, 'two new channels before');
    lGroupId := lL[0].Id;
  finally
    FreeAndNil(lL);
  end;
  lStore.MarkCategoriesSeen([lGroupId]);

  lF := Default(TCatalogFilter);
  lF.OnlyNew := True;
  Assert.AreEqual<Integer>(1, lStore.CountStreams(lF), 'only the other group''s channel is still new');
  lL := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lL.Count, 'only group h left in the only-new view');
    Assert.AreEqual('h', lL[0].UpstreamId);
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.MarkAllSeenIsScoped;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lCounts: TNewCounts;
begin
  lStore := NewStore(FDbPath);
  lSnap := SnapWithGroup(1, ctLive, 'g', ['a', 'b']);
  lSnap.Streams.Add(MakeStream(1, ctMovie, 'm', 'Movie', '', '', 'http://p/m.mp4'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lSnap := SnapWithGroup(2, ctLive, 'x', ['c']);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lCounts := lStore.CountNew(lF);
  Assert.AreEqual<Integer>(2, lCounts.Categories, 'all new groups');
  Assert.AreEqual<Integer>(4, lCounts.Streams, 'all new channels');

  // only source 1, live
  lF.SourceId := 1;
  lF.HasContentType := True;
  lF.ContentType := ctLive;
  lCounts := lStore.MarkAllSeen(lF);
  Assert.AreEqual<Integer>(1, lCounts.Categories, 'cleared groups');
  Assert.AreEqual<Integer>(2, lCounts.Streams, 'cleared channels');

  lCounts := lStore.CountNew(Default(TCatalogFilter));
  Assert.AreEqual<Integer>(1, lCounts.Categories, 'source 2 group still new');
  Assert.AreEqual<Integer>(2, lCounts.Streams, 'the movie and source 2 channel still new');

  lCounts := lStore.MarkAllSeen(Default(TCatalogFilter));
  Assert.AreEqual<Integer>(2, lCounts.Streams, 'everything else cleared');
  Assert.AreEqual<Integer>(0, lStore.CountNew(Default(TCatalogFilter)).Streams, 'nothing new left');
end;

procedure TStorageTests.MarkCategoriesSeenClearsNew;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lF: TCatalogFilter;
  lCatId: Integer;
  lL: TCategoryList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'g';
  lCat.Name := 'Group';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lF.OnlyNew := True;
  lL := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lL.Count, 'new category present');
    lCatId := lL[0].Id;
  finally
    FreeAndNil(lL);
  end;

  lStore.MarkCategoriesSeen([lCatId]);
  lL := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(0, lL.Count, 'no longer flagged new after mark-seen');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.LoadStreamByIdFoundAndMissing;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lId: Integer;
  lS: TStreamItem;
  lL: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u', 'The Channel', '', '', 'http://p/u.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lF := Default(TCatalogFilter);
  lL := lStore.LoadStreams(lF);
  try
    lId := lL[0].Id;
  finally
    FreeAndNil(lL);
  end;

  lS := lStore.LoadStreamById(lId);
  try
    Assert.IsNotNull(lS);
    Assert.AreEqual('The Channel', lS.Name);
    Assert.AreEqual('http://p/u.ts', lS.UpstreamUrl);
  finally
    FreeAndNil(lS);
  end;
  Assert.IsNull(lStore.LoadStreamById(999999), 'missing id => nil');
end;

procedure TStorageTests.LoadKnownTvgIdsDistinctSortedByName;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lIds: TArray<TTvgIdInfo>;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'Zeta', '', 'z.tv', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'b', 'Alpha', '', 'a.tv', 'http://p/b.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'c', 'NoGuide', '', '', 'http://p/c.ts')); // no tvg-id
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lIds := lStore.LoadKnownTvgIds;
  Assert.AreEqual<Integer>(2, Length(lIds), 'only non-empty tvg-ids, distinct');
  // sorted by sample channel name (case-insensitive): Alpha (a.tv) before Zeta (z.tv)
  Assert.AreEqual('a.tv', lIds[0].TvgId);
  Assert.AreEqual('Alpha', lIds[0].Name);
  Assert.AreEqual('z.tv', lIds[1].TvgId);
end;

procedure TStorageTests.AppStateGetSetRoundtrips;
var
  lStore: IStore;
begin
  lStore := NewStore(FDbPath);
  Assert.AreEqual('', lStore.GetState('missing'), 'unknown key => empty');
  lStore.SetState('k', 'v1');
  Assert.AreEqual('v1', lStore.GetState('k'), 'value stored');
  lStore.SetState('k', 'v2'); // upsert
  Assert.AreEqual('v2', lStore.GetState('k'), 'value updated, not duplicated');
end;

procedure TStorageTests.LoadListTvgIdsDistinctNonEmpty;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lListId: Integer;
  lF: TCatalogFilter;
  lIds: TArray<string>;
  lTvgs: TArray<string>;
  lStreams: TStreamItemList;
  i: Integer;
  lIntIds: TArray<Integer>;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, '1', 'A', '', 'aa', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '2', 'B', '', 'bb', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '3', 'C', '', '', 'http://p/3.ts')); // no tvg-id
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    SetLength(lIds, lStreams.Count);
    for i := 0 to lStreams.Count - 1 do
      lIds[i] := IntToStr(lStreams[i].Id);
  finally
    FreeAndNil(lStreams);
  end;
  // add all three to the list
  SetLength(lIntIds, Length(lIds));
  for i := 0 to High(lIds) do
    lIntIds[i] := StrToInt(lIds[i]);
  lStore.AddItems(lListId, 0, lIntIds);

  lTvgs := lStore.LoadListTvgIds;
  Assert.AreEqual<Integer>(2, Length(lTvgs), 'only non-empty, distinct tvg-ids');
  Assert.IsTrue((lTvgs[0] = 'aa') or (lTvgs[1] = 'aa'));
  Assert.IsTrue((lTvgs[0] = 'bb') or (lTvgs[1] = 'bb'));
end;

procedure TStorageTests.DeleteItemRemovesIt;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lListId: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lItems: TCustomItemList;
  lItemId: Integer;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lStore.AddItems(lListId, 0, [lStreams[0].Id]);
  finally
    FreeAndNil(lStreams);
  end;

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(1, lItems.Count);
    lItemId := lItems[0].Id;
  finally
    FreeAndNil(lItems);
  end;
  lStore.DeleteItem(lItemId);
  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(0, lItems.Count, 'item removed');
  finally
    FreeAndNil(lItems);
  end;
end;

procedure TStorageTests.MergeFlagsNewThenStaysStable;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lL: TStreamItemList;
begin
  lStore := NewStore(FDbPath);

  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'x1', 'Channel 1', 'NL', 'nl1', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lL := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lL.Count);
    Assert.IsTrue(lL[0].IsNew, 'first appearance must be flagged new');
  finally
    FreeAndNil(lL);
  end;

  // mark seen, then re-merge the same upstream item: must NOT be re-flagged new
  lStore.MarkStreamsSeen([lStore.LoadStreams(lF)[0].Id]);

  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'x1', 'Channel 1 renamed upstream', 'NL', 'nl1', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lL := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lL.Count, 'same upstream id must not duplicate');
    Assert.IsFalse(lL[0].IsNew, 'a seen item must stay seen across refreshes');
    Assert.AreEqual('Channel 1 renamed upstream', lL[0].Name, 'metadata refreshes');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.MarkStreamsSeenClearsNew;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lId: Integer;
  lL: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lId := lStore.LoadStreams(lF)[0].Id;
  lStore.MarkStreamsSeen([lId]);

  lF.OnlyNew := True;
  lL := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(0, lL.Count, 'no items remain new after mark-seen');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.FilterByPrefixAndSearch;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lL: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, '1', 'NL: One', 'NL', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '2', 'NL: Two', 'NL', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '3', 'UK Three', 'UK', '', 'http://p/3.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lF.Prefix := 'NL:';
  lL := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(2, lL.Count, 'prefix NL: matches two');
  finally
    FreeAndNil(lL);
  end;

  lF := Default(TCatalogFilter);
  lF.Search := 'three';
  lL := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lL.Count, 'search is case-insensitive contains');
    Assert.AreEqual('UK Three', lL[0].Name);
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.MultiWordSearchIsAnd;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lF: TCatalogFilter;
  lS: TStreamItemList;
  lC: TCategoryList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, '1', 'NL| NPO 1 UHD', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '2', 'NL| NPO 2 HD', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '3', 'UK| BBC UHD', '', '', 'http://p/3.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'g1';
  lCat.Name := 'NL UHD Sport';
  lSnap.Categories.Add(lCat);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'g2';
  lCat.Name := 'NL HD News';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // "NL UHD" => AND: only the NL channel that is also UHD
  lF := Default(TCatalogFilter);
  lF.Search := 'NL UHD';
  lS := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lS.Count, 'AND of both terms');
    Assert.AreEqual('NL| NPO 1 UHD', lS[0].Name);
  finally
    FreeAndNil(lS);
  end;

  // comma works as a separator too, and applies to categories as well
  lC := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lC.Count, 'category AND search');
    Assert.AreEqual('NL UHD Sport', lC[0].Name);
  finally
    FreeAndNil(lC);
  end;

  // single term still behaves as plain contains
  lF := Default(TCatalogFilter);
  lF.Search := 'NL';
  lS := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(2, lS.Count, 'one term = contains');
  finally
    FreeAndNil(lS);
  end;
end;

procedure TStorageTests.DiscoverPrefixesCountsAndOrders;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lPrefixes: TArray<TPrefixCount>;
  lCat: TCategory;

  function CountFor(const APrefix: string): Integer;
  var
    lP: TPrefixCount;
  begin
    Result := -1; // -1 => prefix not present at all
    for lP in lPrefixes do
      if lP.Prefix = APrefix then
        Exit(lP.Count);
  end;

begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, '1', 'NL| One', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '2', 'NL| Two', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '3', 'UK| Three', '', '', 'http://p/3.ts'));
  lSnap.Streams.Add(MakeStream(1, ctMovie, '4', 'The Big Movie', '', '', 'http://p/4.ts')); // no delimiter, not a code
  // a group/category whose prefix does NOT appear in any channel name — must
  // still be discovered (groups are filtered by their own names)
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'asia';
  lCat.Name := 'ASIA | India';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lPrefixes := lStore.DiscoverPrefixes(1);

  Assert.AreEqual<Integer>(2, CountFor('NL|'), 'NL| occurs twice');
  Assert.AreEqual<Integer>(1, CountFor('UK|'), 'UK| occurs once');
  Assert.AreEqual<Integer>(1, CountFor('ASIA |'), 'a group-only prefix is discovered from category names');
  Assert.AreEqual<Integer>(-1, CountFor('The'), 'an ordinary first word is not a prefix');
  // ordering: most common first
  Assert.IsTrue(Length(lPrefixes) >= 2);
  Assert.AreEqual('NL|', lPrefixes[0].Prefix, 'most common prefix sorts first');
end;

procedure TStorageTests.FilterOnlyNew;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lL: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctMovie, 'm1', 'Movie', 'VOD', '', 'http://p/m.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lF.HasContentType := True;
  lF.ContentType := ctLive;
  lL := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(0, lL.Count, 'content-type filter excludes movies');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.ListGroupItemCrud;
var
  lStore: IStore;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lListId, lGroupId: Integer;
  lG: TCustomGroupList;
begin
  lStore := NewStore(FDbPath);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'My List';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  Assert.IsTrue(lListId > 0);

  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'Favorites';
    lGrp.IsFavorite := True;
    lGroupId := lStore.SaveGroup(lGrp);
  finally
    FreeAndNil(lGrp);
  end;

  lG := lStore.LoadGroups(lListId);
  try
    Assert.AreEqual<Integer>(1, lG.Count);
    Assert.IsTrue(lG[0].IsFavorite);
  finally
    FreeAndNil(lG);
  end;

  lStore.DeleteGroup(lGroupId);
  lG := lStore.LoadGroups(lListId);
  try
    Assert.AreEqual<Integer>(0, lG.Count);
  finally
    FreeAndNil(lG);
  end;
end;

procedure TStorageTests.SaveGroupUpdateRenamesAndKeepsList;
// Regression: updating (renaming) a group must not bind the INSERT-only :l param.
var
  lStore: IStore;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lListId: Integer;
  lL: TCustomGroupList;
begin
  lStore := NewStore(FDbPath);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'Old';
    lGrp.ContentType := ctLive;
    lGrp.IsFavorite := False;
    lStore.SaveGroup(lGrp);            // INSERT
    lGrp.Name := 'New';
    lGrp.IsFavorite := True;
    lStore.SaveGroup(lGrp);            // UPDATE — must NOT raise 'Parameter l not found'
  finally
    FreeAndNil(lGrp);
  end;

  lL := lStore.LoadGroups(lListId);
  try
    Assert.AreEqual<Integer>(1, lL.Count);
    Assert.AreEqual('New', lL[0].Name, 'rename persisted');
    Assert.IsTrue(lL[0].IsFavorite, 'favorite persisted');
    Assert.AreEqual<Integer>(lListId, lL[0].ListId, 'list_id preserved on update');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.SaveItemUpdateKeepsListAndStream;
// Regression: updating a list item must not bind the INSERT-only :l/:sid params,
// and must preserve list_id + stream_item_id.
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lIt: TCustomItem;
  lListId, lSid: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 's', 'Chan', '', '', 'http://p/s.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lSid := lStreams[0].Id;
  finally
    FreeAndNil(lStreams);
  end;

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lIt := TCustomItem.Create;
  try
    lIt.ListId := lListId;
    lIt.StreamItemId := lSid;
    lIt.CustomGroupId := 0;
    lIt.ContentType := ctLive;
    lIt.DisplayName := '';
    lStore.SaveItem(lIt);              // INSERT
    lIt.DisplayName := 'Renamed';
    lIt.ChannelNumber := 5;
    lStore.SaveItem(lIt);              // UPDATE — must NOT raise
  finally
    FreeAndNil(lIt);
  end;

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(1, lItems.Count);
    Assert.AreEqual('Renamed', lItems[0].DisplayName, 'rename persisted');
    Assert.AreEqual<Integer>(5, lItems[0].ChannelNumber);
    Assert.AreEqual<Integer>(lSid, lItems[0].StreamItemId, 'stream link preserved on update');
    Assert.AreEqual<Integer>(lListId, lItems[0].ListId, 'list link preserved on update');
  finally
    FreeAndNil(lItems);
  end;
end;

procedure TStorageTests.AddItemsBulkDedupes;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lListId, lAdded: Integer;
  lIds: TArray<Integer>;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'b', 'B', '', '', 'http://p/b.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lIds := [lStreams[0].Id, lStreams[1].Id];
  finally
    FreeAndNil(lStreams);
  end;

  lAdded := lStore.AddItems(lListId, 0, lIds);
  Assert.AreEqual<Integer>(2, lAdded);

  // adding the same ids again must add nothing (UNIQUE list_id+stream_item_id)
  lAdded := lStore.AddItems(lListId, 0, lIds);
  Assert.AreEqual<Integer>(0, lAdded, 'bulk add must dedupe already-present items');

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(2, lItems.Count);
  finally
    FreeAndNil(lItems);
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
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lNpoA, lBbcA: Integer;
  lStreams: TStreamItemList;
  i: Integer;
  lSibsNpo: TArray<string>;
  lSibsBbc: TArray<string>;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u1', 'NPO 1', '', 'npo1', 'http://a/npo1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u2', 'BBC One', '', '', 'http://a/bbc.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lSnap := TSourceSnapshot.Create(2);
  lSnap.Streams.Add(MakeStream(2, ctLive, 'u1', 'NPO 1 HD', '', 'npo1', 'http://b/npo1.ts')); // same tvg-id
  lSnap.Streams.Add(MakeStream(2, ctLive, 'u2', 'BBC One', '', '', 'http://b/bbc.ts'));        // same exact name
  lSnap.Streams.Add(MakeStream(2, ctLive, 'u3', 'NPO 2', '', 'npo2', 'http://b/npo2.ts'));     // decoy
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lNpoA := -1;
  lBbcA := -1;
  lF := Default(TCatalogFilter);
  lF.SourceId := 1;
  lStreams := lStore.LoadStreams(lF);
  try
    for i := 0 to lStreams.Count - 1 do
      if lStreams[i].Name = 'NPO 1' then
        lNpoA := lStreams[i].Id
      else if lStreams[i].Name = 'BBC One' then
        lBbcA := lStreams[i].Id;
  finally
    FreeAndNil(lStreams);
  end;

  lSibsNpo := lStore.LoadStreamSiblings(lNpoA);
  Assert.AreEqual<Integer>(1, Length(lSibsNpo), 'NPO 1 → one sibling (same tvg-id), NOT NPO 2');
  Assert.AreEqual('http://b/npo1.ts', lSibsNpo[0]);

  lSibsBbc := lStore.LoadStreamSiblings(lBbcA);
  Assert.AreEqual<Integer>(1, Length(lSibsBbc), 'BBC One → one sibling (same exact name, no tvg-id)');
  Assert.AreEqual('http://b/bbc.ts', lSibsBbc[0]);
end;

// The credential-scoped output (302 redirect / proxy relay) must only serve a
// stream that is actually on the authenticated list — LoadListStreamById returns
// the stream for an on-list id, but nil for a catalog stream NOT on that list.
procedure TStorageTests.LoadListStreamByIdScopesToList;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lListId, lOnId, lOffId: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  i: Integer;
  lOnStream: TStreamItem;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u1', 'On List', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u2', 'Off List', '', '', 'http://p/2.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'Box';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lOnId := -1;
  lOffId := -1;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    for i := 0 to lStreams.Count - 1 do
      if lStreams[i].Name = 'On List' then
        lOnId := lStreams[i].Id
      else
        lOffId := lStreams[i].Id;
  finally
    FreeAndNil(lStreams);
  end;
  lStore.AddItems(lListId, 0, [lOnId]); // only the first stream is on the list

  lOnStream := lStore.LoadListStreamById(lListId, lOnId);
  try
    Assert.IsNotNull(lOnStream, 'an on-list stream resolves');
    Assert.AreEqual('http://p/1.ts', lOnStream.UpstreamUrl);
  finally
    FreeAndNil(lOnStream);
  end;
  Assert.IsNull(lStore.LoadListStreamById(lListId, lOffId),
    'a catalog stream NOT on the list does not resolve (no cross-list / off-list access)');
end;

// is_new diff invariant: on a LATER refresh that brings a brand-new item alongside
// an already-SEEN one, only the new item is flagged. (Earlier tests only ever had a
// single item, so they couldn't prove the mixed-population diff — the exact shape of
// the historical "tests green but broken" class of bug.)
procedure TStorageTests.MergeFlagsNewItemAmongSeenOnes;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lF: TCatalogFilter;
  lS1: TStreamItemList;
  lC1: TCategoryList;
  lNewS: TStreamItemList;
  lNewC: TCategoryList;
begin
  lStore := NewStore(FDbPath);
  // refresh #1: one stream + one category
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'Alpha', '', '', 'http://p/a.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'ca';
  lCat.Name := 'CatA';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // mark everything from refresh #1 seen (clears their "new" badge)
  lF := Default(TCatalogFilter);
  lS1 := lStore.LoadStreams(lF);
  try
    lStore.MarkStreamsSeen([lS1[0].Id]);
  finally
    FreeAndNil(lS1);
  end;
  lC1 := lStore.LoadCategories(lF);
  try
    lStore.MarkCategoriesSeen([lC1[0].Id]);
  finally
    FreeAndNil(lC1);
  end;

  // refresh #2: the old item PLUS a brand-new one
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'Alpha', '', '', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'b', 'Bravo', '', '', 'http://p/b.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'ca';
  lCat.Name := 'CatA';
  lSnap.Categories.Add(lCat);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'cb';
  lCat.Name := 'CatB';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lF.OnlyNew := True;
  lNewS := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lNewS.Count, 'only the brand-new stream is flagged new');
    Assert.AreEqual('Bravo', lNewS[0].Name);
  finally
    FreeAndNil(lNewS);
  end;
  lNewC := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lNewC.Count, 'only the brand-new category is flagged new');
    Assert.AreEqual('CatB', lNewC[0].Name);
  finally
    FreeAndNil(lNewC);
  end;
end;

// canonical channel ordering WITHIN a group: numbered channels first in NUMERIC
// order (so 2 precedes 10 — not text order), then unnumbered A→Z. Earlier ordering
// tests put one channel per group with no numbers, so this clause was unproven.
procedure TStorageTests.OutputChannelNumberOrderingWithinGroup;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lListId, lOneId, lTwoId, lTenId, lAlphaId, lBravoId: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  i: Integer;
  lItems: TCustomItemList;
  lCh: TOutputChannelList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u1', 'Ten', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u2', 'Two', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u3', 'One', '', '', 'http://p/3.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u4', 'Bravo', '', '', 'http://p/4.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u5', 'Alpha', '', '', 'http://p/5.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lOneId := -1;
  lTwoId := -1;
  lTenId := -1;
  lAlphaId := -1;
  lBravoId := -1;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    for i := 0 to lStreams.Count - 1 do
      if lStreams[i].Name = 'One' then
        lOneId := lStreams[i].Id
      else if lStreams[i].Name = 'Two' then
        lTwoId := lStreams[i].Id
      else if lStreams[i].Name = 'Ten' then
        lTenId := lStreams[i].Id
      else if lStreams[i].Name = 'Alpha' then
        lAlphaId := lStreams[i].Id
      else if lStreams[i].Name = 'Bravo' then
        lBravoId := lStreams[i].Id;
  finally
    FreeAndNil(lStreams);
  end;
  lStore.AddItems(lListId, 0, [lOneId, lTwoId, lTenId, lAlphaId, lBravoId]);

  // number One=1, Two=2, Ten=10; leave Alpha/Bravo unnumbered (0)
  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
    begin
      if lItems[i].StreamItemId = lOneId then
        lItems[i].ChannelNumber := 1
      else if lItems[i].StreamItemId = lTwoId then
        lItems[i].ChannelNumber := 2
      else if lItems[i].StreamItemId = lTenId then
        lItems[i].ChannelNumber := 10
      else
        Continue;
      lStore.SaveItem(lItems[i]);
    end;
  finally
    FreeAndNil(lItems);
  end;

  lCh := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual<Integer>(5, lCh.Count);
    Assert.AreEqual('One', lCh[0].Name, 'number 1 first');
    Assert.AreEqual('Two', lCh[1].Name, 'number 2 next');
    Assert.AreEqual('Ten', lCh[2].Name, 'number 10 after 2 (numeric order, not text)');
    Assert.AreEqual('Alpha', lCh[3].Name, 'unnumbered come after numbered, A→Z');
    Assert.AreEqual('Bravo', lCh[4].Name);
  finally
    FreeAndNil(lCh);
  end;
end;

// credential resolution: a DISABLED list is never resolved (enabled=1), a wrong
// username yields nil (-> 401), and empty creds resolve to the enabled default even
// when a disabled list exists. Earlier test had only one enabled list.
procedure TStorageTests.FindListByCredentialsRespectsEnabledAndUser;
var
  lStore: IStore;
  lLst: TCustomList;
  lL: TCustomList;
begin
  lStore := NewStore(FDbPath);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'Disabled';
    lLst.OutputUsername := 'x';
    lLst.OutputPassword := 'y';
    lLst.Enabled := False;
    lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lLst := TCustomList.Create;
  try
    lLst.Name := 'Default';
    lLst.Enabled := True;
    lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  Assert.IsNull(lStore.FindListByCredentials('nobody', 'z'), 'unknown username -> nil (401)');
  Assert.IsNull(lStore.FindListByCredentials('x', 'y'), 'a disabled list is never resolved');
  lL := lStore.FindListByCredentials('', '');
  try
    Assert.IsNotNull(lL, 'empty creds resolve to the enabled default');
    Assert.AreEqual('Default', lL.Name);
  finally
    FreeAndNil(lL);
  end;
end;

// EpgMaxDays caps the FUTURE, but a programme that started in the past and is still
// airing (the "now" programme) must NOT be dropped from the served guide.
procedure TStorageTests.EpgKeepsCurrentlyAiringProgramme;
var
  lStore: IStore;
  lProgs: TEpgProgrammeList;
  lP: TEpgProgramme;
  lL: TEpgProgrammeList;
begin
  lStore := NewStore(FDbPath);
  lProgs := TEpgProgrammeList.Create(True);
  try
    lP := TEpgProgramme.Create;
    lP.ChannelTvgId := 'nl1';
    lP.StartUtc := IncHour(NowUtc, -1);
    lP.StopUtc := IncHour(NowUtc, 1);
    lP.Title := 'Now';
    lProgs.Add(lP);
    lP := TEpgProgramme.Create;
    lP.ChannelTvgId := 'nl1';
    lP.StartUtc := IncHour(NowUtc, 2);
    lP.StopUtc := IncHour(NowUtc, 3);
    lP.Title := 'Next';
    lProgs.Add(lP);
    lStore.ReplaceEpg(1, lProgs);
  finally
    FreeAndNil(lProgs);
  end;

  lL := lStore.LoadEpgForTvgIds(['nl1'], 7);
  try
    Assert.AreEqual<Integer>(2, lL.Count, 'the currently-airing (past-started) programme is still served');
  finally
    FreeAndNil(lL);
  end;
end;

// The prefix picker (DiscoverPrefixes) must surface the Unicode-bar prefixes
// providers like ProviderA use (┃NL┃), not just ASCII pipes — else the operator can't
// tick them. ExtractNamePrefix treats the heavy vertical bar (U+2503) as a delimiter.
procedure TStorageTests.DiscoverPrefixesFindsUnicodeBarPrefix;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lPrefixes: TArray<TPrefixCount>;
  lP: TPrefixCount;
  lFoundNl: Integer;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u1', #$2503 + 'NL' + #$2503 + ' NPO 1', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u2', #$2503 + 'NL' + #$2503 + ' NPO 2', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u3', #$2503 + 'F1 TV' + #$2503 + ' Race', '', '', 'http://p/3.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lPrefixes := lStore.DiscoverPrefixes(1);
  lFoundNl := -1;
  for lP in lPrefixes do
    if lP.Prefix = #$2503 + 'NL' + #$2503 then
      lFoundNl := lP.Count;
  Assert.AreEqual<Integer>(2, lFoundNl, 'the ┃NL┃ Unicode-bar prefix is discovered with its count');
end;

// A discovered/typed prefix can legitimately contain a LIKE wildcard ('_' or '%').
// The prefix filter must escape it, else 'S_T' would also match 'SAT' (any char).
procedure TStorageTests.PrefixFilterEscapesLikeWildcards;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u1', 'S_T News', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u2', 'SAT News', '', '', 'http://p/2.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lF.Prefix := 'S_T';
  lStreams := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lStreams.Count, 'underscore is matched literally, not as a wildcard');
    Assert.AreEqual('S_T News', lStreams[0].Name);
  finally
    FreeAndNil(lStreams);
  end;
end;

// strip-prefix matrix #1 — NONE: a source with no strip prefixes leaves
// display_name '' so the channel keeps following its upstream name verbatim.
procedure TStorageTests.AddItemsNoPrefixesKeepsUpstreamName;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lSrcId, lListId, lSid: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    // StripPrefixes left empty
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u1',
    #$2503 + 'NL' + #$2503 + ' ESPN 1 HD', '', '', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lSid := lStreams[0].Id;
  finally
    FreeAndNil(lStreams);
  end;
  lStore.AddItems(lListId, 0, [lSid]);

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual('', lItems[0].DisplayName,
      'no strip prefixes configured -> display_name stays empty (follows upstream)');
  finally
    FreeAndNil(lItems);
  end;
end;

// strip-prefix matrix #2 — SINGLE configured prefix (and a non-matching channel).
procedure TStorageTests.AddItemsStripsConfiguredPrefix;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lSrcId, lListId, lPrefixedId, lPlainId: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  i: Integer;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lSrc.StripPrefixes := ['NL'];
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u1', 'NL| NPO 1 HD', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u2', 'BBC One', '', '', 'http://p/2.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lPrefixedId := -1;
  lPlainId := -1;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    for i := 0 to lStreams.Count - 1 do
      if lStreams[i].Name.StartsWith('NL') then
        lPrefixedId := lStreams[i].Id
      else
        lPlainId := lStreams[i].Id;
  finally
    FreeAndNil(lStreams);
  end;
  lStore.AddItems(lListId, 0, [lPrefixedId, lPlainId]);

  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
      if lItems[i].StreamItemId = lPrefixedId then
        Assert.AreEqual('NPO 1 HD', lItems[i].DisplayName, 'prefix stripped + trimmed into display name')
      else
        Assert.AreEqual('', lItems[i].DisplayName, 'unprefixed name keeps following the upstream name');
  finally
    FreeAndNil(lItems);
  end;
end;

// strip-prefix matrix #3 — MULTIPLE prefixes. Regression: prefixes are stored
// ';'-delimited (a token may itself contain spaces/commas/pipes, e.g. "┃F1 TV┃").
// AddItems must split with ';' — splitting with ',' treats the whole "a;b;c"
// string as one token and strips nothing. (Single-prefix sources hid this bug;
// multi-prefix broke — exactly the "┃NL┃ ESPN" the operator reported.)
procedure TStorageTests.AddItemsStripsOneOfMultipleSemicolonPrefixes;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lSrcId, lListId, lEspnId: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    // three tokens; the Unicode heavy bar (U+2503) and an embedded space ("F1 TV")
    lSrc.StripPrefixes := [#$2503 + 'F1 TV' + #$2503, #$2503 + 'NL' + #$2503];
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u1',
    #$2503 + 'NL' + #$2503 + ' ESPN 1 HD', '', '', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lEspnId := lStreams[0].Id;
  finally
    FreeAndNil(lStreams);
  end;
  lStore.AddItems(lListId, 0, [lEspnId]);

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual('ESPN 1 HD', lItems[0].DisplayName,
      'the matching ┃NL┃ prefix is stripped even with several ;-delimited tokens');
  finally
    FreeAndNil(lItems);
  end;
end;

// The global "Strip prefixes (all)" button applies each source's CURRENT prefixes
// to all channels added BEFORE the prefix was configured (display_name was ''),
// while leaving manual renames alone.
procedure TStorageTests.RestripAllItemsAppliesCurrentPrefixes;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lSrcId, lListId, lNpoId, lRenId, lUpdated: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  i: Integer;
  lItems: TCustomItemList;
  lSrcs: TObjectList<TSourceConfig>;
begin
  lStore := NewStore(FDbPath);
  // source starts with NO strip prefixes
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u1', 'NL| NPO 1 HD', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u2', 'NL| Sport', '', '', 'http://p/2.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lNpoId := -1;
  lRenId := -1;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    for i := 0 to lStreams.Count - 1 do
      if lStreams[i].Name.Contains('NPO') then
        lNpoId := lStreams[i].Id
      else
        lRenId := lStreams[i].Id;
  finally
    FreeAndNil(lStreams);
  end;
  // added while the source had no prefixes -> display_name '' (follows upstream)
  lStore.AddItems(lListId, 0, [lNpoId, lRenId]);
  // manually rename the Sport channel
  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
      if lItems[i].StreamItemId = lRenId then
      begin
        lItems[i].DisplayName := 'My Sport';
        lStore.SaveItem(lItems[i]);
      end;
  finally
    FreeAndNil(lItems);
  end;

  // now configure the strip prefix and apply to all
  lSrcs := lStore.LoadSources;
  try
    for i := 0 to lSrcs.Count - 1 do
      if lSrcs[i].Id = lSrcId then
      begin
        lSrcs[i].StripPrefixes := ['NL'];
        lStore.SaveSource(lSrcs[i]);
      end;
  finally
    FreeAndNil(lSrcs);
  end;
  lUpdated := lStore.RestripAllItems;
  Assert.AreEqual<Integer>(1, lUpdated, 'only the auto-named NPO channel is restripped');

  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
      if lItems[i].StreamItemId = lNpoId then
        Assert.AreEqual('NPO 1 HD', lItems[i].DisplayName, 'auto channel got the prefix stripped')
      else
        Assert.AreEqual('My Sport', lItems[i].DisplayName, 'manual rename is preserved');
  finally
    FreeAndNil(lItems);
  end;
end;

// Regression for the same ';'-vs-',' delimiter bug, via the "Strip prefixes (all)"
// path: a multi-prefix source must restrip a channel added before the prefixes
// existed. (Was broken: the whole "┃F1 TV┃;┃NL┃" string parsed as one token.)
procedure TStorageTests.RestripAllItemsHandlesMultipleSemicolonPrefixes;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lSrcId, lListId, lEspnId, lUpdated: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lSrcs: TObjectList<TSourceConfig>;
  i: Integer;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  // source starts with NO strip prefixes -> channel added with display_name ''
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u1',
    #$2503 + 'NL' + #$2503 + ' ESPN 1 HD', '', '', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lEspnId := lStreams[0].Id;
  finally
    FreeAndNil(lStreams);
  end;
  lStore.AddItems(lListId, 0, [lEspnId]); // display_name '' (no prefixes yet)

  // now configure SEVERAL strip prefixes and apply to all
  lSrcs := lStore.LoadSources;
  try
    for i := 0 to lSrcs.Count - 1 do
      if lSrcs[i].Id = lSrcId then
      begin
        lSrcs[i].StripPrefixes := [#$2503 + 'F1 TV' + #$2503, #$2503 + 'NL' + #$2503];
        lStore.SaveSource(lSrcs[i]);
      end;
  finally
    FreeAndNil(lSrcs);
  end;
  lUpdated := lStore.RestripAllItems;
  Assert.AreEqual<Integer>(1, lUpdated, 'the ┃NL┃ ESPN channel is restripped');

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual('ESPN 1 HD', lItems[0].DisplayName,
      'restrip-all splits ;-delimited prefixes and strips the matching one');
  finally
    FreeAndNil(lItems);
  end;
end;

// Changing a source's strip-prefix rule re-cleans its already-added channels:
// auto-named items follow the new rule, but a manual rename is left untouched.
procedure TStorageTests.RestripUpdatesAutoNamesKeepsManualRenames;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lSrcId, lListId, lNpoStream, lSportStream, lUpdated: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  i: Integer;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lSrc.StripPrefixes := ['NL'];
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u1', 'NL| NPO 1 HD', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u2', 'NL| Sport', '', '', 'http://p/2.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lNpoStream := -1;
  lSportStream := -1;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    for i := 0 to lStreams.Count - 1 do
      if lStreams[i].Name.Contains('NPO') then
        lNpoStream := lStreams[i].Id
      else
        lSportStream := lStreams[i].Id;
  finally
    FreeAndNil(lStreams);
  end;
  // added with NL configured -> both display names stripped ("NPO 1 HD", "Sport")
  lStore.AddItems(lListId, 0, [lNpoStream, lSportStream]);

  // operator manually renames the Sport channel
  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
      if lItems[i].StreamItemId = lSportStream then
      begin
        lItems[i].DisplayName := 'Mijn Sport';
        lStore.SaveItem(lItems[i]);
      end;
  finally
    FreeAndNil(lItems);
  end;

  // drop the NL rule: the auto-named NPO reverts to upstream, the manual stays
  lUpdated := lStore.RestripSourceItems(lSrcId, ['NL'], [], [], []);
  Assert.AreEqual<Integer>(1, lUpdated, 'only the auto-named item is rewritten');

  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
      if lItems[i].StreamItemId = lNpoStream then
        Assert.AreEqual('', lItems[i].DisplayName, 'auto name follows the new (empty) rule')
      else
        Assert.AreEqual('Mijn Sport', lItems[i].DisplayName, 'manual rename preserved');
  finally
    FreeAndNil(lItems);
  end;
end;

procedure TStorageTests.AddItemsStripsConfiguredSuffix;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lSrcId, lListId: Integer;
  lF: TCatalogFilter;
  lSrcs: TObjectList<TSourceConfig>;
  lStreams: TStreamItemList;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lSrc.StripPrefixes := ['NL |'];
    lSrc.StripSuffixes := ['(S)'];
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;
  lSrcs := lStore.LoadSources;
  try
    Assert.AreEqual<Integer>(1, Length(lSrcs[0].StripSuffixes), 'strip suffixes round-trip');
    Assert.AreEqual('(S)', lSrcs[0].StripSuffixes[0]);
  finally
    FreeAndNil(lSrcs);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'u1', 'NL | HISTORY HD (S)', '', '', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lStore.AddItems(lListId, 0, [lStreams[0].Id]);
  finally
    FreeAndNil(lStreams);
  end;
  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual('HISTORY HD', lItems[0].DisplayName, 'prefix and suffix stripped');
    Assert.AreEqual('NL | HISTORY HD (S)', lItems[0].StreamName, 'original name still available');
  finally
    FreeAndNil(lItems);
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
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lSrcId, lSrc2: Integer;
  lIds: TDictionary<string, Integer>;
  lF: TCatalogFilter;
  lV: TArray<TStreamVariant>;
  lNames: string;
  lX: TStreamVariant;
  lStreams: TStreamItemList;
  i: Integer;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'ProviderB';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lSrc.StripPrefixes := ['NL |'];
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'OTHER';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://o';
    lSrc.StripPrefixes := ['NL:'];
    lSrc2 := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '1', 'NL | NPO 1 ' + RAW_SC, '', 'npo1.nl', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '2', 'NL | NPO 1 4K+', '', 'npo1.nl', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '3', 'NL | NPO 1 HD', '', 'npo1.nl', 'http://p/3.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '4', 'NL | NPO 1 UHD', '', '', 'http://p/4.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '5', 'NL | NPO 1 EXTRA ' + RAW_SC, '', 'npo1extra.nl', 'http://p/5.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '6', 'NL | NPO 2 HD', '', 'npo2.nl', 'http://p/6.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '7', 'NL | NPO1 FHD', '', 'npo1.nl', 'http://p/7.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lSnap := TSourceSnapshot.Create(lSrc2);
  lSnap.Streams.Add(MakeStream(lSrc2, ctLive, '1', 'NL: NPO 1 HD', '', '', 'http://o/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lIds := TDictionary<string, Integer>.Create;
  try
    lF := Default(TCatalogFilter);
    lF.SourceId := lSrcId;
    lStreams := lStore.LoadStreams(lF);
    try
      for i := 0 to lStreams.Count - 1 do
        lIds.Add(lStreams[i].UpstreamId, lStreams[i].Id);
    finally
      FreeAndNil(lStreams);
    end;

    // started from the RAW channel, own source only
    lV := lStore.FindStreamVariants(lIds['1'], False, 0);
    lNames := '';
    for lX in lV do
      lNames := lNames + lX.Quality + '/' + lX.MatchedBy + ' ';
    Assert.AreEqual('4K+/name UHD/name FHD/tvg RAW/self HD/name ', lNames, 'own-source variants');

    // all sources: the other provider's NPO 1 HD comes last
    lV := lStore.FindStreamVariants(lIds['4'], True, 0);
    Assert.AreEqual(6, Length(lV), 'all sources');
    Assert.AreEqual(lSrc2, lV[High(lV)].SourceId, 'other source last');
    Assert.AreEqual('UHD', lV[1].Quality, 'self (UHD) in the ladder');
    Assert.IsTrue(lV[1].IsSelf);
  finally
    FreeAndNil(lIds);
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
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lSrcId, lListId, lGroupId: Integer;
  lIds: TDictionary<string, Integer>;
  lF: TCatalogFilter;
  lReps: TArray<TItemStreamReplace>;
  lR: TItemStreamReplace;
  lNpo1Item: Integer;
  lItems: TCustomItemList;
  lStreams: TStreamItemList;
  i: Integer;
  lMatches: TArray<TVariantMatch>;
  lM: TVariantMatch;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'ProviderB';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lSrc.StripPrefixes := ['NL |'];
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '1', 'NL | NPO 1 ' + RAW_SC, '', 'npo1', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '2', 'NL | NPO 1 4K+', '', 'npo1', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '3', 'NL | HISTORY ' + RAW_SC + ' (S)', '', '', 'http://p/3.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '4', 'NL | HISTORY 4K+', '', '', 'http://p/4.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '5', 'NL | BBC NL ' + RAW_SC, '', '', 'http://p/5.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '6', 'NL | NPO 1 EXTRA ' + RAW_SC, '', '', 'http://p/6.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '7', 'NL | NPO 1 UHD', '', '', 'http://p/7.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'Standaard';
    lGroupId := lStore.SaveGroup(lGrp);
  finally
    FreeAndNil(lGrp);
  end;

  lIds := TDictionary<string, Integer>.Create;
  try
    lF := Default(TCatalogFilter);
    lStreams := lStore.LoadStreams(lF);
    try
      for i := 0 to lStreams.Count - 1 do
        lIds.Add(lStreams[i].UpstreamId, lStreams[i].Id);
    finally
      FreeAndNil(lStreams);
    end;
    lStore.AddItems(lListId, lGroupId, [lIds['1'], lIds['3'], lIds['5'], lIds['6']]);

    // give NPO 1 a channel number + tvg-id override that must survive the swap
    lNpo1Item := 0;
    lItems := lStore.LoadItems(lListId);
    try
      for i := 0 to lItems.Count - 1 do
        if lItems[i].StreamItemId = lIds['1'] then
        begin
          Assert.AreEqual('NPO 1 ' + RAW_SC, lItems[i].DisplayName, 'prefix stripped on the list');
          lNpo1Item := lItems[i].Id;
          lItems[i].ChannelNumber := 5;
          lItems[i].TvgIdOverride := 'npo1.nl';
          lStore.SaveItem(lItems[i]);
        end;
    finally
      FreeAndNil(lItems);
    end;

    lMatches := lStore.FindQualityVariants(lListId, lGroupId, '4K+');
    Assert.AreEqual<Integer>(4, Length(lMatches));
    lReps := [];
    for lM in lMatches do
    begin
      if lM.StreamId = lIds['1'] then
      begin
        Assert.AreEqual(lIds['2'], lM.CandidateStreamId, 'NPO 1 RAW -> NPO 1 4K+ despite the stripped prefix');
        Assert.AreEqual('RAW', lM.Quality);
      end
      else if lM.StreamId = lIds['3'] then
        Assert.AreEqual(lIds['4'], lM.CandidateStreamId, 'HISTORY RAW (S) -> HISTORY 4K+ (tag after quality)')
      else if lM.StreamId = lIds['5'] then
        Assert.AreEqual(0, lM.CandidateStreamId, 'BBC NL has no 4K+')
      else if lM.StreamId = lIds['6'] then
        Assert.AreEqual(0, lM.CandidateStreamId, 'NPO 1 EXTRA is not NPO 1');
      if lM.CandidateStreamId > 0 then
      begin
        lR.ItemId := lM.ItemId;
        lR.StreamId := lM.CandidateStreamId;
        lReps := lReps + [lR];
      end;
    end;

    Assert.AreEqual<Integer>(2, lStore.ReplaceItemStreams(lListId, lReps), 'two channels swapped');
    // replacing again is a no-op (the 4K+ streams are on the list now)
    Assert.AreEqual<Integer>(0, lStore.ReplaceItemStreams(lListId, lReps), 'already on the list -> skipped');

    lItems := lStore.LoadItems(lListId);
    try
      Assert.AreEqual<Integer>(4, lItems.Count, 'replaced in place, nothing added');
      for i := 0 to lItems.Count - 1 do
      begin
        Assert.AreEqual(lGroupId, lItems[i].CustomGroupId, 'stays in its group');
        if lItems[i].Id = lNpo1Item then
        begin
          Assert.AreEqual(lIds['2'], lItems[i].StreamItemId);
          Assert.AreEqual(5, lItems[i].ChannelNumber, 'channel number kept');
          Assert.AreEqual('npo1.nl', lItems[i].TvgIdOverride, 'tvg-id override kept');
          Assert.AreEqual('NPO 1 4K+', lItems[i].DisplayName, 'auto name follows the new channel');
          Assert.AreEqual('NL | NPO 1 4K+', lItems[i].StreamName);
        end
        else if lItems[i].StreamItemId = lIds['4'] then
          Assert.AreEqual('HISTORY 4K+', lItems[i].DisplayName);
      end;
    finally
      FreeAndNil(lItems);
    end;
  finally
    FreeAndNil(lIds);
  end;
end;

// "Clean the names of an EXISTING group": channels placed before a strip rule
// existed (or with tokens nobody configured) get the source rules + one-off extra
// tokens applied; dry run only previews; a manual rename without such a token is
// untouched; a result equal to the upstream name is stored as ''.
procedure TStorageTests.RestripGroupItemsCleansExistingGroup;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lSrcId, lListId, lGroupId: Integer;
  lF: TCatalogFilter;
  lIds: TArray<Integer>;
  lChanges: TArray<TNameChange>;
  lItems: TCustomItemList;
  lStreams: TStreamItemList;
  i: Integer;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://h';
    lSrcId := lStore.SaveSource(lSrc); // no strip rules yet
  finally
    FreeAndNil(lSrc);
  end;
  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '1', 'NL | HISTORY HD (S)', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '2', 'NL | NPO 1 HD', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '3', 'NL | SPORT', '', '', 'http://p/3.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'G';
    lGroupId := lStore.SaveGroup(lGrp);
  finally
    FreeAndNil(lGrp);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lIds := [];
    for i := 0 to lStreams.Count - 1 do
      lIds := lIds + [lStreams[i].Id];
  finally
    FreeAndNil(lStreams);
  end;
  lStore.AddItems(lListId, lGroupId, lIds); // added unstripped (no rules at the time)

  // a manual rename without any of the tokens must survive
  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
      if lItems[i].StreamName = 'NL | SPORT' then
      begin
        lItems[i].DisplayName := 'Mijn Sport';
        lStore.SaveItem(lItems[i]);
      end;
  finally
    FreeAndNil(lItems);
  end;

  // preview with one-off tokens: nothing written yet
  lChanges := lStore.RestripGroupItems(lListId, lGroupId, ['NL |'], ['(S)'], True);
  Assert.AreEqual<Integer>(2, Length(lChanges), 'HISTORY + NPO 1 change, Mijn Sport not');
  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
      if lItems[i].StreamName <> 'NL | SPORT' then
        Assert.AreEqual('', lItems[i].DisplayName, 'dry run writes nothing');
  finally
    FreeAndNil(lItems);
  end;

  // apply
  lChanges := lStore.RestripGroupItems(lListId, lGroupId, ['NL |'], ['(S)'], False);
  Assert.AreEqual<Integer>(2, Length(lChanges));
  lItems := lStore.LoadItems(lListId);
  try
    for i := 0 to lItems.Count - 1 do
      if lItems[i].StreamName = 'NL | HISTORY HD (S)' then
        Assert.AreEqual('HISTORY HD', lItems[i].DisplayName)
      else if lItems[i].StreamName = 'NL | NPO 1 HD' then
        Assert.AreEqual('NPO 1 HD', lItems[i].DisplayName)
      else
        Assert.AreEqual('Mijn Sport', lItems[i].DisplayName, 'manual rename kept');
  finally
    FreeAndNil(lItems);
  end;

  // running again changes nothing (idempotent)
  Assert.AreEqual<Integer>(0, Length(lStore.RestripGroupItems(lListId, lGroupId, ['NL |'], ['(S)'], False)));
end;

procedure TStorageTests.ClearGroupItemsRemovesOnlyThatGroup;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lListId, lGroupId, lRemoved: Integer;
  lIds: TArray<Integer>;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'b', 'B', '', '', 'http://p/b.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'c', 'C', '', '', 'http://p/c.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'G';
    lGroupId := lStore.SaveGroup(lGrp);
  finally
    FreeAndNil(lGrp);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lIds := [lStreams[0].Id, lStreams[1].Id, lStreams[2].Id];
  finally
    FreeAndNil(lStreams);
  end;

  lStore.AddItems(lListId, lGroupId, [lIds[0], lIds[1]]); // two into the custom group
  lStore.AddItems(lListId, 0, [lIds[2]]);               // one into the upstream group

  lRemoved := lStore.ClearGroupItems(lListId, lGroupId);
  Assert.AreEqual<Integer>(2, lRemoved, 'only the two in the group are removed');

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(1, lItems.Count, 'the upstream-group item survives');
    Assert.AreEqual<Integer>(0, lItems[0].CustomGroupId);
  finally
    FreeAndNil(lItems);
  end;
end;

procedure TStorageTests.DeleteListCascades;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lListId: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lLists: TObjectList<TCustomList>;
  lGroups: TCustomGroupList;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'A', '', '', 'http://p/a.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'Doomed';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'G';
    lStore.SaveGroup(lGrp);
  finally
    FreeAndNil(lGrp);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lStore.AddItems(lListId, 0, [lStreams[0].Id]);
  finally
    FreeAndNil(lStreams);
  end;

  lStore.DeleteList(lListId);

  lLists := lStore.LoadLists;
  try
    Assert.AreEqual<Integer>(0, lLists.Count, 'list gone');
  finally
    FreeAndNil(lLists);
  end;
  lGroups := lStore.LoadGroups(lListId);
  try
    Assert.AreEqual<Integer>(0, lGroups.Count, 'groups gone');
  finally
    FreeAndNil(lGroups);
  end;
  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(0, lItems.Count, 'items gone');
  finally
    FreeAndNil(lItems);
  end;
end;

procedure TStorageTests.NameFilterHidesStreamsAndCategories;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lF: TCatalogFilter;
  lS1: TStreamItemList;
  lC1: TCategoryList;
  lS2: TStreamItemList;
  lS3: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, '1', 'NL| One', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '2', 'NL| Two', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '3', 'UK| Three', '', '', 'http://p/3.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'nl';
  lCat.Name := 'NL| General';
  lSnap.Categories.Add(lCat);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'uk';
  lCat.Name := 'UK| Sport';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // exclude NL| -> only UK remains, in streams AND categories
  lF := Default(TCatalogFilter);
  lF.ExcludeFilters := ['NL|'];
  lS1 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lS1.Count, 'exclude hides the two NL streams');
    Assert.AreEqual('UK| Three', lS1[0].Name);
  finally
    FreeAndNil(lS1);
  end;
  lC1 := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lC1.Count, 'exclude hides the NL group');
  finally
    FreeAndNil(lC1);
  end;

  // include NL| -> only the two NL streams
  lF := Default(TCatalogFilter);
  lF.IncludeFilters := ['NL|'];
  lS2 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(2, lS2.Count, 'include keeps only NL');
  finally
    FreeAndNil(lS2);
  end;

  // nothing filtered -> all still present (filters never delete)
  lF := Default(TCatalogFilter);
  lS3 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(3, lS3.Count, 'no filter => everything still there');
  finally
    FreeAndNil(lS3);
  end;
end;

procedure TStorageTests.HiddenFlagFollowsSourceFilters;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lF: TCatalogFilter;
  lSrc: TSourceConfig;
  lSrcId: Integer;
  lSources: TObjectList<TSourceConfig>;
  lS: TStreamItemList;

  function CountCats: Integer;
  var
    lL: TCategoryList;
  begin
    lL := lStore.LoadCategories(lF);
    try
      Result := lL.Count;
    finally
      FreeAndNil(lL);
    end;
  end;

begin
  // The catalog uses the precomputed `hidden` flag; it must match the source's
  // filters after ingest AND after the filters are edited (and back).
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Url := 'http://x';
    lSrc.ExcludeFilters := ['NL|'];
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;
  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '1', 'NL| One', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, ctLive, '2', 'UK| Two', '', '', 'http://p/2.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'nl';
  lCat.Name := 'NL| General';
  lSnap.Categories.Add(lCat);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'uk';
  lCat.Name := 'UK| Sport';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lF.UseHiddenFlag := True;
  Assert.AreEqual<Integer>(1, lStore.CountStreams(lF), 'ingest applies the exclude filter');
  Assert.AreEqual<Integer>(1, CountCats, 'group hidden too');

  // edit the filters: exclude UK instead (plus a pasted giant item, ignored)
  lSources := lStore.LoadSources;
  try
    lSources[0].ExcludeFilters := ['UK|', StringOfChar('X', 60000)];
    lStore.SaveSource(lSources[0]);
  finally
    FreeAndNil(lSources);
  end;
  lS := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lS.Count, 'filter change recomputes the flag');
    Assert.AreEqual('NL| One', lS[0].Name);
  finally
    FreeAndNil(lS);
  end;

  // clear the filters: everything visible again; includeHidden ignores the flag
  lSources := lStore.LoadSources;
  try
    lSources[0].ExcludeFilters := [];
    lStore.SaveSource(lSources[0]);
  finally
    FreeAndNil(lSources);
  end;
  Assert.AreEqual<Integer>(2, lStore.CountStreams(lF), 'no filter => nothing hidden');
  Assert.AreEqual<Integer>(2, CountCats);
end;

// Include "UFC" keeps the UFC channels; their group ("WORLD SPORTS") must stay
// visible although its NAME doesn't match — unless an exclude token names it.
procedure TStorageTests.GroupWithVisibleChannelStaysVisible;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lF: TCatalogFilter;
  lSrc: TSourceConfig;
  lSrcId: Integer;
  lSt: TStreamItem;
  lSources: TObjectList<TSourceConfig>;

  function CatNames: string;
  var
    lL: TCategoryList;
    lC: TCategory;
  begin
    Result := '';
    lL := lStore.LoadCategories(lF);
    try
      for lC in lL do
        Result := Result + lC.Name + ';';
    finally
      FreeAndNil(lL);
    end;
  end;

begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'P';
    lSrc.Url := 'http://x';
    lSrc.IncludeFilters := ['NL |', 'UFC'];
    lSrcId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;
  lSnap := TSourceSnapshot.Create(lSrcId);
  lSt := MakeStream(lSrcId, ctLive, '1', 'NL | NPO 1', '', '', 'http://p/1.ts');
  lSt.CategoryUpstreamId := 'nl';
  lSnap.Streams.Add(lSt);
  lSt := MakeStream(lSrcId, ctLive, '2', 'UFC 1', '', '', 'http://p/2.ts');
  lSt.CategoryUpstreamId := 'ws';
  lSnap.Streams.Add(lSt);
  lSt := MakeStream(lSrcId, ctLive, '3', 'NBA 1', '', '', 'http://p/3.ts');
  lSt.CategoryUpstreamId := 'ws';
  lSnap.Streams.Add(lSt);
  lSt := MakeStream(lSrcId, ctLive, '4', 'DE | ARD', '', '', 'http://p/4.ts');
  lSt.CategoryUpstreamId := 'de';
  lSnap.Streams.Add(lSt);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'nl';
  lCat.Name := 'NL | NEDERLAND';
  lSnap.Categories.Add(lCat);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'ws';
  lCat.Name := 'WORLD SPORTS';
  lSnap.Categories.Add(lCat);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'de';
  lCat.Name := 'DE | GERMANY';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lF.UseHiddenFlag := True;
  Assert.AreEqual<Integer>(2, lStore.CountStreams(lF), 'NPO 1 + UFC 1');
  Assert.AreEqual('NL | NEDERLAND;WORLD SPORTS;', CatNames, 'group of a visible channel stays');

  // an exclude token naming the group hides it even with visible channels
  lSources := lStore.LoadSources;
  try
    lSources[0].ExcludeFilters := ['WORLD SPORTS'];
    lStore.SaveSource(lSources[0]);
  finally
    FreeAndNil(lSources);
  end;
  Assert.AreEqual('NL | NEDERLAND;', CatNames, 'excluded group name wins');
end;

procedure TStorageTests.OversizedFilterTokenIsIgnored;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lF: TCatalogFilter;
  lSF: TSourceFilter;
  lHuge: string;
  lS1: TStreamItemList;
  lC1: TCategoryList;
  lC2: TCategoryList;
  lS2: TStreamItemList;
  lC3: TCategoryList;
begin
  // a whole list pasted as ONE filter item (60k chars) used to become a single
  // LIKE pattern -> SQLite "LIKE or GLOB pattern too complex" on every catalog
  // query. It must be ignored; the normal and line-split tokens still work.
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, '1', 'NL| One', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '2', 'UK| Two', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '3', 'DE| Three', '', '', 'http://p/3.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'nl';
  lCat.Name := 'NL| General';
  lSnap.Categories.Add(lCat);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'uk';
  lCat.Name := 'UK| Sport';
  lSnap.Categories.Add(lCat);
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'de';
  lCat.Name := 'DE| Film';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lHuge := StringOfChar('X', 60000);
  // exclude: the huge token is dropped, 'UK|' and the second line 'DE|' apply
  lF := Default(TCatalogFilter);
  lF.ExcludeFilters := [lHuge, 'UK|'#10'DE|'];
  lS1 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lS1.Count, 'only NL survives; no SQLite pattern error');
    Assert.AreEqual('NL| One', lS1[0].Name);
  finally
    FreeAndNil(lS1);
  end;
  lC1 := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lC1.Count, 'groups filtered in memory the same way');
    Assert.AreEqual('NL| General', lC1[0].Name);
  finally
    FreeAndNil(lC1);
  end;

  // per-source ("all sources" view): include NL| next to the huge token
  lF := Default(TCatalogFilter);
  lSF.SourceId := 1;
  lSF.IncludeFilters := [lHuge, 'NL|'];
  lSF.ExcludeFilters := [];
  lF.SourceFilters := [lSF];
  lC2 := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lC2.Count, 'per-source include keeps only the NL group');
  finally
    FreeAndNil(lC2);
  end;
  lS2 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lS2.Count, 'per-source include keeps only the NL stream');
  finally
    FreeAndNil(lS2);
  end;

  // only a huge token as include => no usable include => nothing hidden
  lF := Default(TCatalogFilter);
  lF.IncludeFilters := [lHuge];
  lC3 := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(3, lC3.Count, 'unusable include filter hides nothing');
  finally
    FreeAndNil(lC3);
  end;
end;

procedure TStorageTests.NameFilterIsSeparatorAware;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lS1: TStreamItemList;
  lIt: TStreamItem;
  lS2: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  // leading separators/spaces around the country tag — the case that used to slip
  // through a raw 'NL%' LIKE because the name starts with " | " not "NL"
  lSnap.Streams.Add(MakeStream(1, ctLive, '1', ' | NL | NPO 1', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '2', '|NL| NPO 2', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '3', 'NL - NPO 3', '', '', 'http://p/3.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '4', 'BBC One | NL', '', '', 'http://p/4.ts')); // tag as suffix
  lSnap.Streams.Add(MakeStream(1, ctLive, '5', 'Netherlands 1', '', '', 'http://p/5.ts')); // must NOT match
  lSnap.Streams.Add(MakeStream(1, ctLive, '6', 'NLD Sport', '', '', 'http://p/6.ts'));      // must NOT match
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // bare token "NL" (no punctuation) must catch every separator variant, prefix
  // OR suffix, but never "Netherlands"/"NLD"
  lF := Default(TCatalogFilter);
  lF.ExcludeFilters := ['NL'];
  lS1 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(2, lS1.Count, 'only the two non-NL names survive');
    for lIt in lS1 do
      Assert.IsTrue((lIt.Name = 'Netherlands 1') or (lIt.Name = 'NLD Sport'), 'survivor: ' + lIt.Name);
  finally
    FreeAndNil(lS1);
  end;

  // include "NL" keeps exactly the four tagged channels
  lF := Default(TCatalogFilter);
  lF.IncludeFilters := ['NL'];
  lS2 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(4, lS2.Count, 'include keeps the four NL-tagged channels');
  finally
    FreeAndNil(lS2);
  end;
end;

// Providers decorate names with Unicode vertical bars (┃ U+2503), not the ASCII
// pipe — the filter must treat those as separators too.
procedure TStorageTests.NameFilterHandlesUnicodeBars;
const
  HB = #$2503; // ┃ heavy vertical bar
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lS1: TStreamItemList;
  lS2: TStreamItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, '1', HB + 'F1 TV' + HB + ' Race 1', '', '', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '2', HB + 'F1 TV' + HB + ' Race 2', '', '', 'http://p/2.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, '3', 'NPO 1', '', '', 'http://p/3.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // exclude the "F1 TV" tag (wrapped in ┃) -> only NPO 1 remains
  lF := Default(TCatalogFilter);
  lF.ExcludeFilters := ['F1 TV'];
  lS1 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lS1.Count, 'the two ┃F1 TV┃ channels are excluded');
    Assert.AreEqual('NPO 1', lS1[0].Name);
  finally
    FreeAndNil(lS1);
  end;

  // include "F1 TV" -> only the two tagged channels
  lF := Default(TCatalogFilter);
  lF.IncludeFilters := ['F1 TV'];
  lS2 := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(2, lS2.Count, 'include keeps the ┃F1 TV┃ channels');
  finally
    FreeAndNil(lS2);
  end;
end;

// TLockingStore uses TWO connections (writer + reader, WAL) on the same DB.
// A write on the writer connection must be visible to a read on the reader
// connection — proves the read/write split is wired and stays consistent.
procedure TStorageTests.LockingStoreSeparateReadWriteConnections;
var
  lStore: IStore;
  lLst: TCustomList;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lLists: TObjectList<TCustomList>;
  lStreams: TStreamItemList;
begin
  // writer created first (makes the file), then reader on the same path — both in
  // WAL mode (the opt-in separate-read-connection setup; temp file is a real FS)
  lStore := TLockingStore.Create(
    TSQLiteStore.Create(FDbPath, True),
    TSQLiteStore.Create(FDbPath, True));
  lStore.Init;

  // write through the writer connection
  lLst := TCustomList.Create;
  try
    lLst.Name := 'Box';
    lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 's1', 'NPO 1', '', '', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // read through the reader connection — must see the just-committed writes
  lLists := lStore.LoadLists;
  try
    Assert.AreEqual<Integer>(1, lLists.Count, 'reader sees the list written by the writer');
  finally
    FreeAndNil(lLists);
  end;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lStreams.Count, 'reader sees the merged stream');
    Assert.AreEqual('NPO 1', lStreams[0].Name);
  finally
    FreeAndNil(lStreams);
  end;
end;

// When WAL isn't available (Unraid FUSE share) the composition root passes the
// SAME store as writer AND reader. TLockingStore must then share one lock so the
// single FireDAC connection is never used concurrently — and it must not deadlock
// or double-free. Read-after-write still works through the one connection.
procedure TStorageTests.LockingStoreSingleConnectionFallback;
var
  lStore: IStore;
  lInner: IStore;
  lLst: TCustomList;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
begin
  lInner := TSQLiteStore.Create(FDbPath);
  lStore := TLockingStore.Create(lInner, lInner); // same connection for read + write
  lStore.Init;

  lLst := TCustomList.Create;
  try
    lLst.Name := 'Box';
    lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 's1', 'NPO 1', '', '', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lStreams.Count, 'single-connection read sees the write');
    Assert.AreEqual('NPO 1', lStreams[0].Name);
  finally
    FreeAndNil(lStreams);
  end;
end;

// Old StrArrayToCsv quoted an item containing '"' and doubled its quotes on every
// save (never unquoted on read) — 6 items grew to ~50M quotes each. Saving must be
// stable now, and Init must strip quotes already stored.
procedure TStorageTests.FilterTokensWithQuotesDoNotGrowAndAreRepaired;
var
  lStore: IStore;
  lSrc: TSourceConfig;
  i: Integer;
  lL: TObjectList<TSourceConfig>;
  lL1: TObjectList<TSourceConfig>;
  lL2: TObjectList<TSourceConfig>;
begin
  lStore := NewStore(FDbPath);
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'Q';
    lSrc.Kind := skM3U;
    lSrc.Url := 'http://q';
    lSrc.ExcludeFilters := ['Sonay @ Oct 18 12:"', 'Plain'];
    lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;
  for i := 1 to 5 do // load -> save round trips
  begin
    lL := lStore.LoadSources;
    try
      lStore.SaveSource(lL[0]);
    finally
      FreeAndNil(lL);
    end;
  end;
  lL1 := lStore.LoadSources;
  try
    Assert.AreEqual<Integer>(2, Length(lL1[0].ExcludeFilters));
    Assert.IsTrue(Length(lL1[0].ExcludeFilters[0]) < 30, 'token must not grow on save');
  finally
    FreeAndNil(lL1);
  end;

  lStore := nil;
  lStore := NewStore(FDbPath); // Init runs RepairSourceTokens
  lL2 := lStore.LoadSources;
  try
    Assert.AreEqual('Sonay @ Oct 18 12:', lL2[0].ExcludeFilters[0], 'stored quotes stripped on Init');
    Assert.AreEqual('Plain', lL2[0].ExcludeFilters[1]);
  finally
    FreeAndNil(lL2);
  end;
end;

// Sources are served from memory by TLockingStore; every write path must
// invalidate, and callers get their own copy (freeing/mutating it is safe).
procedure TStorageTests.LockingStoreCachesSourcesAndInvalidatesOnWrite;
var
  lStore: IStore;
  lInner: IStore;
  lSrc: TSourceConfig;
  lId: Integer;
  lL1: TObjectList<TSourceConfig>;
  lL2: TObjectList<TSourceConfig>;
  lL3: TObjectList<TSourceConfig>;
  lL4: TObjectList<TSourceConfig>;
begin
  lInner := TSQLiteStore.Create(FDbPath);
  lStore := TLockingStore.Create(lInner, lInner);
  lStore.Init;
  lSrc := TSourceConfig.Create;
  try
    lSrc.Name := 'A';
    lSrc.Kind := skM3U;
    lSrc.Url := 'http://a';
    lId := lStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;

  lL1 := lStore.LoadSources; // fills the cache
  try
    Assert.AreEqual<Integer>(1, lL1.Count);
    lL1[0].Name := 'mutated copy'; // must not leak into the cache
  finally
    FreeAndNil(lL1);
  end;

  lL2 := lStore.LoadSources;
  try
    Assert.AreEqual('A', lL2[0].Name, 'cache hands out copies');
    lL2[0].Name := 'B';
    lStore.SaveSource(lL2[0]); // write -> invalidate
  finally
    FreeAndNil(lL2);
  end;

  lL3 := lStore.LoadSources;
  try
    Assert.AreEqual('B', lL3[0].Name, 'save invalidates the cache');
  finally
    FreeAndNil(lL3);
  end;

  lStore.DeleteSource(lId);
  lL4 := lStore.LoadSources;
  try
    Assert.AreEqual<Integer>(0, lL4.Count, 'delete invalidates the cache');
  finally
    FreeAndNil(lL4);
  end;
end;

procedure TStorageTests.LoadItemsExposesUpstreamName;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lListId: Integer;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'x', 'NPO 1 HD', '', 'npo1', 'http://p/x.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lStore.AddItems(lListId, 0, [lStreams[0].Id]);
  finally
    FreeAndNil(lStreams);
  end;

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(1, lItems.Count);
    Assert.AreEqual('', lItems[0].DisplayName, 'no override set');
    Assert.AreEqual('NPO 1 HD', lItems[0].StreamName, 'upstream name resolved for the UI');
    Assert.AreEqual('npo1', lItems[0].StreamTvgId);
    Assert.AreEqual<Integer>(1, lItems[0].StreamSourceId, 'source of the upstream stream exposed');
  finally
    FreeAndNil(lItems);
  end;
end;

procedure TStorageTests.ManyExcludeTokensDoNotBreakQuery;
// Regression: a source with hundreds of filter tokens must not blow SQLite's
// expression-tree depth limit (the balanced-OR builder keeps depth at O(log n)).
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lCat: TCategory;
  lF: TCatalogFilter;
  i: Integer;
  lTokens: TArray<string>;
  lS: TStreamItemList;
  lC: TCategoryList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'k', 'KEEP Me', '', '', 'http://p/k.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'd', 'AAA0 Drop', '', '', 'http://p/d.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'c';
  lCat.Name := 'KEEP Cat';
  lSnap.Categories.Add(lCat);
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  // 800 distinct exclude tokens (more than SQLite's 1000 expr-depth at 2 LIKEs each)
  SetLength(lTokens, 800);
  for i := 0 to High(lTokens) do
    lTokens[i] := Format('AAA%d', [i]);

  lF := Default(TCatalogFilter);
  lF.ExcludeFilters := lTokens;
  // must execute without raising, and still hide the 'AAA0 Drop' stream
  lS := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lS.Count, 'only KEEP Me survives 800 exclude tokens');
    Assert.AreEqual('KEEP Me', lS[0].Name);
  finally
    FreeAndNil(lS);
  end;
  lC := lStore.LoadCategories(lF);
  try
    Assert.AreEqual<Integer>(1, lC.Count, 'category query also survives many tokens');
  finally
    FreeAndNil(lC);
  end;
end;

procedure TStorageTests.PerSourceFiltersApplyInAllSourcesView;
// In the "all sources" view each row is judged against ITS source's filters:
// source 1 excludes 'NL|', source 2 has no filter, so only source 1's NL row hides.
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lSFs: TArray<TSourceFilter>;
  lS: TStreamItemList;
  lNames: string;
  i: Integer;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'NL| A', '', '', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'b', 'UK| B', '', '', 'http://p/b.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lSnap := TSourceSnapshot.Create(2);
  lSnap.Streams.Add(MakeStream(2, ctLive, 'c', 'NL| C', '', '', 'http://p/c.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  SetLength(lSFs, 1);
  lSFs[0].SourceId := 1;
  lSFs[0].ExcludeFilters := ['NL|'];

  lF := Default(TCatalogFilter);
  lF.SourceFilters := lSFs; // SourceId stays 0 => all sources
  lS := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(2, lS.Count, 'only source 1''s NL row is hidden');
    lNames := '';
    for i := 0 to lS.Count - 1 do
      lNames := lNames + lS[i].Name + ';';
    Assert.IsFalse(lNames.Contains('NL| A'), 'source 1 NL hidden');
    Assert.IsTrue(lNames.Contains('NL| C'), 'source 2 NL kept (no filter on src 2)');
    Assert.IsTrue(lNames.Contains('UK| B'), 'source 1 UK kept');
  finally
    FreeAndNil(lS);
  end;
end;

procedure TStorageTests.DedupeListItemsByUrl;
// Two catalog entries with the SAME upstream URL (different names/ids) are
// duplicates: dedupe keeps one, plus the genuinely different channel.
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lListId, lRemoved: Integer;
  lF: TCatalogFilter;
  lIds: TArray<Integer>;
  lStreams: TStreamItemList;
  i: Integer;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'Chan A', '', '', 'http://p/same.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'b', 'Chan B (dup url)', '', '', 'http://p/same.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'c', 'Chan C', '', '', 'http://p/other.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    SetLength(lIds, lStreams.Count);
    for i := 0 to lStreams.Count - 1 do
      lIds[i] := lStreams[i].Id;
  finally
    FreeAndNil(lStreams);
  end;
  lStore.AddItems(lListId, 0, lIds); // all three on the list

  lRemoved := lStore.DedupeListItems(lListId);
  Assert.AreEqual<Integer>(1, lRemoved, 'one duplicate URL removed');

  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(2, lItems.Count, 'distinct-URL channels remain');
  finally
    FreeAndNil(lItems);
  end;

  // running again is a no-op
  Assert.AreEqual<Integer>(0, lStore.DedupeListItems(lListId), 'idempotent');
end;

procedure TStorageTests.SortGroupAlphabeticallyNumbersByName;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lListId, lGroupId: Integer;
  lF: TCatalogFilter;
  lIt: TCustomItem;
  lNums: TDictionary<string, Integer>;
  lStreams: TStreamItemList;
  lIds: TArray<Integer>;
  i: Integer;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'z', 'Zebra', '', '', 'http://p/z.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'Apple', '', '', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'm', 'Mango', '', '', 'http://p/m.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'G';
    lGroupId := lStore.SaveGroup(lGrp);
  finally
    FreeAndNil(lGrp);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    SetLength(lIds, lStreams.Count);
    for i := 0 to lStreams.Count - 1 do
      lIds[i] := lStreams[i].Id;
    lStore.AddItems(lListId, lGroupId, lIds);
  finally
    FreeAndNil(lStreams);
  end;

  Assert.AreEqual<Integer>(3, lStore.SortGroupAlphabetically(lListId, lGroupId));

  lNums := TDictionary<string, Integer>.Create;
  lItems := lStore.LoadItems(lListId);
  try
    for lIt in lItems do
      lNums.AddOrSetValue(lIt.StreamName, lIt.ChannelNumber);
    Assert.AreEqual<Integer>(1, lNums['Apple'], 'Apple first');
    Assert.AreEqual<Integer>(2, lNums['Mango'], 'Mango second');
    Assert.AreEqual<Integer>(3, lNums['Zebra'], 'Zebra third');
  finally
    FreeAndNil(lItems);
    FreeAndNil(lNums);
  end;
end;

procedure TStorageTests.ReorderGroupItemsNumbersByGivenOrder;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lListId, lGroupId, lNumbered: Integer;
  lByName, lNums: TDictionary<string, Integer>;
  lOrder: TArray<Integer>;
  lIt: TCustomItem;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lIds: TArray<Integer>;
  i: Integer;
  lItemsA: TCustomItemList;
  lItemsB: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'z', 'Zebra', '', '', 'http://p/z.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'Apple', '', '', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'm', 'Mango', '', '', 'http://p/m.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'G';
    lGroupId := lStore.SaveGroup(lGrp);
  finally
    FreeAndNil(lGrp);
  end;

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    SetLength(lIds, lStreams.Count);
    for i := 0 to lStreams.Count - 1 do
      lIds[i] := lStreams[i].Id;
    lStore.AddItems(lListId, lGroupId, lIds);
  finally
    FreeAndNil(lStreams);
  end;

  // map upstream stream name -> list_item id
  lByName := TDictionary<string, Integer>.Create;
  lItemsA := lStore.LoadItems(lListId);
  try
    for lIt in lItemsA do
      lByName.AddOrSetValue(lIt.StreamName, lIt.Id);
  finally
    FreeAndNil(lItemsA);
  end;

  // explicit display order Zebra, Apple, Mango; the trailing bogus id must be ignored
  lOrder := [lByName['Zebra'], lByName['Apple'], lByName['Mango'], 999999];
  lNumbered := lStore.ReorderGroupItems(lListId, lGroupId, lOrder);
  Assert.AreEqual<Integer>(3, lNumbered, 'only the 3 real items are numbered (bogus id skipped)');

  lNums := TDictionary<string, Integer>.Create;
  lItemsB := lStore.LoadItems(lListId);
  try
    for lIt in lItemsB do
      lNums.AddOrSetValue(lIt.StreamName, lIt.ChannelNumber);
    Assert.AreEqual<Integer>(1, lNums['Zebra'], 'Zebra first');
    Assert.AreEqual<Integer>(2, lNums['Apple'], 'Apple second');
    Assert.AreEqual<Integer>(3, lNums['Mango'], 'Mango third');
  finally
    FreeAndNil(lItemsB);
    FreeAndNil(lNums);
  end;
  FreeAndNil(lByName);
end;

// Bouquet-wide renumber: explicit numbers for many items in one call (foreign ids
// skipped); a later drag-reorder or A->Z sort of that group keeps its block
// (starts at the group's lowest number, not back at 1).
procedure TStorageTests.BouquetRenumberSurvivesGroupReorder;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lGrp: TCustomGroup;
  lListId, lGroupId: Integer;
  lByName, lNums: TDictionary<string, Integer>;
  lIt: TCustomItem;
  lPlan: TArray<TItemNumber>;
  lF: TCatalogFilter;
  lStreams: TStreamItemList;
  lIds: TArray<Integer>;
  i: Integer;
  lItems: TCustomItemList;

  function Num(AItem, ANumber: Integer): TItemNumber;
  begin
    Result.ItemId := AItem;
    Result.ChannelNumber := ANumber;
  end;

  procedure ReadNums;
  var
    lItems: TCustomItemList;
    lX: TCustomItem;
  begin
    lNums.Clear;
    lItems := lStore.LoadItems(lListId);
    try
      for lX in lItems do
        lNums.AddOrSetValue(lX.StreamName, lX.ChannelNumber);
    finally
      FreeAndNil(lItems);
    end;
  end;

begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'z', 'Zebra', '', '', 'http://p/z.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'a', 'Apple', '', '', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 'm', 'Mango', '', '', 'http://p/m.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lGrp := TCustomGroup.Create;
  try
    lGrp.ListId := lListId;
    lGrp.Name := 'G';
    lGroupId := lStore.SaveGroup(lGrp);
  finally
    FreeAndNil(lGrp);
  end;
  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    SetLength(lIds, lStreams.Count);
    for i := 0 to lStreams.Count - 1 do
      lIds[i] := lStreams[i].Id;
    lStore.AddItems(lListId, lGroupId, lIds);
  finally
    FreeAndNil(lStreams);
  end;
  lByName := TDictionary<string, Integer>.Create;
  lNums := TDictionary<string, Integer>.Create;
  try
    lItems := lStore.LoadItems(lListId);
    try
      for lIt in lItems do
        lByName.AddOrSetValue(lIt.StreamName, lIt.Id);
    finally
      FreeAndNil(lItems);
    end;

    lPlan := [Num(lByName['Zebra'], 101), Num(lByName['Apple'], 102), Num(lByName['Mango'], 103),
             Num(999999, 1)];
    Assert.AreEqual<Integer>(3, lStore.SetItemNumbers(lListId, lPlan), 'foreign id skipped');
    Assert.AreEqual<Integer>(0, lStore.SetItemNumbers(lListId + 1, lPlan), 'other list untouched');
    ReadNums;
    Assert.AreEqual<Integer>(101, lNums['Zebra']);
    Assert.AreEqual<Integer>(103, lNums['Mango']);

    lStore.ReorderGroupItems(lListId, lGroupId, [lByName['Mango'], lByName['Zebra'], lByName['Apple']]);
    ReadNums;
    Assert.AreEqual<Integer>(101, lNums['Mango'], 'drag keeps the block start');
    Assert.AreEqual<Integer>(103, lNums['Apple']);

    lStore.SortGroupAlphabetically(lListId, lGroupId);
    ReadNums;
    Assert.AreEqual<Integer>(101, lNums['Apple'], 'A-Z keeps the block start');
    Assert.AreEqual<Integer>(103, lNums['Zebra']);
  finally
    FreeAndNil(lNums);
    FreeAndNil(lByName);
  end;
end;

procedure TStorageTests.StoresUnicodeNamesIntact;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lF: TCatalogFilter;
  lUniName: string;
  lL: TStreamItemList;
begin
  lUniName := 'A' + #$26BD + 'B'; // A⚽B (U+26BD)
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u1', lUniName, '', '', 'http://p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lL := lStore.LoadStreams(lF);
  try
    Assert.AreEqual<Integer>(1, lL.Count);
    Assert.AreEqual<Integer>(3, Length(lL[0].Name), 'length intact');
    // Full UTF-8 round-trip on every platform (incl. static-SQLite Win32): the
    // store binds text via AsWideString with no ANSI<->Wide MapRules, so the
    // emoji is preserved on write and decoded back on read. See the constructor.
    Assert.AreEqual<Integer>($26BD, Ord(lL[0].Name[2]), 'emoji survives store+reload');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.FindListByCredentials_DefaultAndNamed;
var
  lStore: IStore;
  lLst: TCustomList;
  lFound: TCustomList;
begin
  lStore := NewStore(FDbPath);
  lLst := TCustomList.Create;
  try
    lLst.Name := 'Default';
    lLst.OutputUsername := 'box1';
    lLst.OutputPassword := 'secret';
    lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  // SECURITY: empty credentials must NOT open a bouquet that has a login
  lFound := lStore.FindListByCredentials('', '');
  Assert.IsNull(lFound, 'empty login never reaches a protected bouquet');
  lFound := lStore.FindListByCredentials('', 'secret');
  Assert.IsNull(lFound, 'not with only the password either');

  // ...but a bouquet WITHOUT a login is the default for boxes without one
  lLst := TCustomList.Create;
  try
    lLst.Name := 'Open';
    lLst.Enabled := True;
    lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lFound := lStore.FindListByCredentials('', '');
  try
    Assert.IsNotNull(lFound);
    Assert.AreEqual('Open', lFound.Name, 'the login-free bouquet, not the protected one');
  finally
    FreeAndNil(lFound);
  end;

  // named credentials match
  lFound := lStore.FindListByCredentials('box1', 'secret');
  try
    Assert.IsNotNull(lFound);
  finally
    FreeAndNil(lFound);
  end;

  // wrong password -> nil
  lFound := lStore.FindListByCredentials('box1', 'wrong');
  Assert.IsNull(lFound);
end;

procedure TStorageTests.OutputChannelsOrderAndOverrides;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lFavGrp, lNormGrp: TCustomGroup;
  lListId: Integer;
  lF: TCatalogFilter;
  lStreamIds: TArray<Integer>;
  lStreams: TStreamItemList;
  lNormId: Integer;
  lFavId: Integer;
  lOut: TOutputChannelList;

  procedure AddItem(AStreamId, AGroupId: Integer; const ADisplay: string);
  var
    lIt: TCustomItem;
  begin
    lIt := TCustomItem.Create;
    try
      lIt.ListId := lListId;
      lIt.StreamItemId := AStreamId;
      lIt.CustomGroupId := AGroupId;
      lIt.ContentType := ctLive;
      lIt.DisplayName := ADisplay;
      lStore.SaveItem(lIt);
    finally
      FreeAndNil(lIt);
    end;
  end;

begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 's1', 'Zebra', 'X', '', 'http://p/z.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 's2', 'Apple', 'X', '', 'http://p/a.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    // LoadStreams is ordered by name: [0]=Apple(s2), [1]=Zebra(s1)
    lStreamIds := [lStreams[0].Id, lStreams[1].Id];
  finally
    FreeAndNil(lStreams);
  end;

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  lNormGrp := TCustomGroup.Create;
  try
    lNormGrp.ListId := lListId;
    lNormGrp.Name := 'News';
    lNormId := lStore.SaveGroup(lNormGrp);
    lFavGrp := TCustomGroup.Create;
    try
      lFavGrp.ListId := lListId;
      lFavGrp.Name := 'Sports';
      lFavGrp.IsFavorite := True;
      lFavId := lStore.SaveGroup(lFavGrp);
      // put "Apple" in News (normal), "Zebra" renamed to "AAA" in Sports (favorite)
      AddItem(lStreamIds[0], lNormId, '');       // Apple -> News
      AddItem(lStreamIds[1], lFavId, 'AAA Top'); // Zebra -> Sports(fav), renamed
    finally
      FreeAndNil(lFavGrp);
    end;
  finally
    FreeAndNil(lNormGrp);
  end;

  lOut := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual<Integer>(2, lOut.Count);
    // favorite group first regardless of alphabetical group name (Sports > News)
    Assert.IsTrue(lOut[0].IsFavoriteGroup, 'favorite group must sort first');
    Assert.AreEqual('Sports', lOut[0].GroupName);
    Assert.AreEqual('AAA Top', lOut[0].Name, 'display-name override applied');
    Assert.AreEqual('http://p/z.ts', lOut[0].UpstreamUrl, 'raw upstream url preserved');
    Assert.AreEqual('News', lOut[1].GroupName);
    Assert.AreEqual('Apple', lOut[1].Name, 'empty override falls back to upstream name');
  finally
    FreeAndNil(lOut);
  end;
end;

// Manual group drag-order (ReorderGroups) overrides the default A→Z; favorites
// still sort first.
procedure TStorageTests.GroupReorderControlsOutputOrder;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst: TCustomList;
  lListId, lAId, lBId: Integer;
  lF: TCatalogFilter;
  lStreamIds: TArray<Integer>;
  lStreams: TStreamItemList;
  lGA: TCustomGroup;
  lGB: TCustomGroup;
  lOut1: TOutputChannelList;
  lOut2: TOutputChannelList;

  procedure AddItem(AStreamId, AGroupId: Integer);
  var
    lIt: TCustomItem;
  begin
    lIt := TCustomItem.Create;
    try
      lIt.ListId := lListId;
      lIt.StreamItemId := AStreamId;
      lIt.CustomGroupId := AGroupId;
      lIt.ContentType := ctLive;
      lStore.SaveItem(lIt);
    finally
      FreeAndNil(lIt);
    end;
  end;

begin
  lStore := NewStore(FDbPath);
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 's1', 'ChA', 'X', '', 'http://p/a.ts'));
  lSnap.Streams.Add(MakeStream(1, ctLive, 's2', 'ChB', 'X', '', 'http://p/b.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lF := Default(TCatalogFilter);
  lStreams := lStore.LoadStreams(lF);
  try
    lStreamIds := [lStreams[0].Id, lStreams[1].Id];
  finally
    FreeAndNil(lStreams);
  end;

  lLst := TCustomList.Create;
  try
    lLst.Name := 'L';
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;

  // two non-favorite groups "Alpha" and "Beta" (A→Z would put Alpha first)
  lGA := TCustomGroup.Create;
  try
    lGA.ListId := lListId;
    lGA.Name := 'Alpha';
    lAId := lStore.SaveGroup(lGA);
  finally
    FreeAndNil(lGA);
  end;
  lGB := TCustomGroup.Create;
  try
    lGB.ListId := lListId;
    lGB.Name := 'Beta';
    lBId := lStore.SaveGroup(lGB);
  finally
    FreeAndNil(lGB);
  end;
  AddItem(lStreamIds[0], lAId);
  AddItem(lStreamIds[1], lBId);

  // default order: Alpha before Beta (A→Z)
  lOut1 := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual('Alpha', lOut1[0].GroupName, 'default A→Z puts Alpha first');
  finally
    FreeAndNil(lOut1);
  end;

  // drag Beta before Alpha
  lStore.ReorderGroups(lListId, [lBId, lAId]);
  lOut2 := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual('Beta', lOut2[0].GroupName, 'manual order puts Beta first');
    Assert.AreEqual('Alpha', lOut2[1].GroupName);
  finally
    FreeAndNil(lOut2);
  end;
end;

procedure TStorageTests.EpgReplaceAndLoadByTvgId;
var
  lStore: IStore;
  lProgs: TEpgProgrammeList;
  lP: TEpgProgramme;
  lL: TEpgProgrammeList;
  lMany: TArray<string>;
  i: Integer;
begin
  lStore := NewStore(FDbPath);
  lProgs := TEpgProgrammeList.Create(True);
  try
    lP := TEpgProgramme.Create;
    lP.ChannelTvgId := 'nl1';
    lP.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
    lP.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0);
    lP.Title := 'News';
    lProgs.Add(lP);
    lStore.ReplaceEpg(1, lProgs);
  finally
    FreeAndNil(lProgs);
  end;

  lL := lStore.LoadEpgForTvgIds(['nl1']);
  try
    Assert.AreEqual<Integer>(1, lL.Count);
    Assert.AreEqual('News', lL[0].Title);
  finally
    FreeAndNil(lL);
  end;

  // empty id set returns empty (no SQL error)
  lL := lStore.LoadEpgForTvgIds([]);
  try
    Assert.AreEqual<Integer>(0, lL.Count);
  finally
    FreeAndNil(lL);
  end;

  // chunk-boundary: a huge id list (well over the 800-per-batch chunk AND over the
  // historical 999 bound-parameter limit) must still find the programme — proves
  // the chunk loop accumulates across batches and doesn't blow the param limit.
  SetLength(lMany, 1700);
  for i := 0 to High(lMany) do
    lMany[i] := Format('x%d', [i]);
  lMany[1500] := 'nl1'; // place the real id beyond the first chunk
  lL := lStore.LoadEpgForTvgIds(lMany);
  try
    Assert.AreEqual<Integer>(1, lL.Count, 'programme found across chunk boundary');
    Assert.AreEqual('News', lL[0].Title);
  finally
    FreeAndNil(lL);
  end;
end;

// The AMaxDays cap drops programmes starting beyond now + N days; 0 = no cap.
procedure TStorageTests.EpgMaxDaysCapsFutureProgrammes;
var
  lStore: IStore;
  lProgs: TEpgProgrammeList;
  lL: TEpgProgrammeList;

  procedure AddProg(ADaysAhead: Integer; const ATitle: string);
  var
    lP: TEpgProgramme;
  begin
    lP := TEpgProgramme.Create;
    lP.ChannelTvgId := 'nl1';
    lP.StartUtc := IncDay(NowUtc, ADaysAhead);
    lP.StopUtc := IncHour(lP.StartUtc, 1);
    lP.Title := ATitle;
    lProgs.Add(lP);
  end;

begin
  lStore := NewStore(FDbPath);
  lProgs := TEpgProgrammeList.Create(True);
  try
    AddProg(1, 'Tomorrow');
    AddProg(5, 'In 5 days');
    AddProg(10, 'In 10 days');
    lStore.ReplaceEpg(1, lProgs);
  finally
    FreeAndNil(lProgs);
  end;

  // cap to 7 days -> the 10-day one is dropped
  lL := lStore.LoadEpgForTvgIds(['nl1'], 7);
  try
    Assert.AreEqual<Integer>(2, lL.Count, '7-day cap keeps only programmes within a week');
  finally
    FreeAndNil(lL);
  end;

  // no cap -> all three
  lL := lStore.LoadEpgForTvgIds(['nl1'], 0);
  try
    Assert.AreEqual<Integer>(3, lL.Count, '0 = no cap, everything returned');
  finally
    FreeAndNil(lL);
  end;
end;

procedure TStorageTests.IngestStatusRecordsUnknownSource;
// Exercises the ingest status lifecycle without any network: refreshing a
// non-existent source must record a finished status with an error.
var
  lStore: IStore;
  lIngest: TIngestService;
  lStatuses: TArray<TIngestStatus>;
  lS: TIngestStatus;
  lFound: Boolean;
begin
  lStore := NewStore(FDbPath);
  lIngest := TIngestService.Create(lStore);
  try
    Assert.AreEqual<Integer>(0, Length(lIngest.GetStatus), 'no status before any refresh');
    lIngest.RefreshSource(999); // unknown id → resolves immediately with an error
    lStatuses := lIngest.GetStatus;
    lFound := False;
    for lS in lStatuses do
      if lS.SourceId = 999 then
      begin
        lFound := True;
        Assert.IsFalse(lS.Running, 'finished');
        Assert.AreEqual('source not found', lS.Error);
      end;
    Assert.IsTrue(lFound, 'status recorded for the requested source');
  finally
    FreeAndNil(lIngest);
  end;
end;

// The locking store answers the zap path (list by login + stream on that list)
// from memory, and forgets it after any write that can change the answer.
procedure TStorageTests.ZapCacheServesAndInvalidates;
var
  lInner, lStore: IStore;
  lSnap: TSourceSnapshot;
  lLst, lFound: TCustomList;
  lIt: TCustomItem;
  lS: TStreamItem;
  lListId, lStreamId, lItemId: Integer;
  lL: TStreamItemList;
  lRound: Integer;
begin
  lInner := NewStore(FDbPath);
  lStore := TLockingStore.Create(lInner, lInner); // single connection, as on Unraid
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u1', 'NPO 1', 'NL', 'npo1.nl', 'http://p/live/u/p/1.ts'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lL := lStore.LoadStreams(Default(TCatalogFilter));
  try
    lStreamId := lL[0].Id;
  finally
    FreeAndNil(lL);
  end;

  lLst := TCustomList.Create;
  try
    lLst.Name := 'Box';
    lLst.OutputUsername := 'box';
    lLst.OutputPassword := 'pw';
    lLst.Enabled := True;
    lListId := lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lIt := TCustomItem.Create;
  try
    lIt.ListId := lListId;
    lIt.StreamItemId := lStreamId;
    lIt.ContentType := ctLive;
    lItemId := lStore.SaveItem(lIt);
  finally
    FreeAndNil(lIt);
  end;

  // first call fills the cache, second is served from it (both owned copies)
  for lRound := 1 to 2 do
  begin
    lFound := lStore.FindListByCredentials('box', 'pw');
    try
      Assert.IsNotNull(lFound);
      Assert.AreEqual(lListId, lFound.Id);
    finally
      FreeAndNil(lFound);
    end;
    lS := lStore.LoadListStreamById(lListId, lStreamId);
    try
      Assert.IsNotNull(lS);
      Assert.AreEqual('http://p/live/u/p/1.ts', lS.UpstreamUrl);
    finally
      FreeAndNil(lS);
    end;
  end;

  // the provider URL changes on a refresh -> the next zap sees the new one
  lSnap := TSourceSnapshot.Create(1);
  lSnap.Streams.Add(MakeStream(1, ctLive, 'u1', 'NPO 1', 'NL', 'npo1.nl', 'http://p/live/u/p/1.m3u8'));
  lStore.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);
  lS := lStore.LoadListStreamById(lListId, lStreamId);
  try
    Assert.AreEqual('http://p/live/u/p/1.m3u8', lS.UpstreamUrl, 'refresh invalidates');
  finally
    FreeAndNil(lS);
  end;

  // removed from the list -> no longer playable with this login
  lStore.DeleteItem(lItemId);
  lS := lStore.LoadListStreamById(lListId, lStreamId);
  Assert.IsNull(lS, 'item removed');

  // login changed -> old credentials no longer resolve
  lFound := lStore.FindListByCredentials('box', 'pw');
  try
    lFound.OutputPassword := 'new';
    lStore.SaveList(lFound);
  finally
    FreeAndNil(lFound);
  end;
  lFound := lStore.FindListByCredentials('box', 'pw');
  Assert.IsNull(lFound, 'old password rejected');
  lFound := lStore.FindListByCredentials('box', 'new');
  try
    Assert.IsNotNull(lFound, 'new password accepted');
  finally
    FreeAndNil(lFound);
  end;
end;

function SaveTestSource(const AStore: IStore; ATypes: TContentTypes; AEnabled: Boolean;
  AId: Integer = 0): Integer;
var
  lSrc: TSourceConfig;
begin
  lSrc := TSourceConfig.Create;
  try
    lSrc.Id := AId;
    lSrc.Name := 'P';
    lSrc.Kind := skXtream;
    lSrc.Url := 'http://prov:8080/';
    lSrc.Username := 'u';
    lSrc.Password := 'p';
    lSrc.Enabled := AEnabled;
    lSrc.ContentTypes := ATypes;
    Result := AStore.SaveSource(lSrc);
  finally
    FreeAndNil(lSrc);
  end;
end;

function AddTestItem(const AStore: IStore; AListId, AStreamId: Integer; ACt: TContentType): Integer;
var
  lIt: TCustomItem;
begin
  lIt := TCustomItem.Create;
  try
    lIt.ListId := AListId;
    lIt.StreamItemId := AStreamId;
    lIt.ContentType := ACt;
    Result := AStore.SaveItem(lIt);
  finally
    FreeAndNil(lIt);
  end;
end;

function StreamIdByUpstream(const AStore: IStore; const AUpstreamId: string): Integer;
var
  lL: TStreamItemList;
  lS: TStreamItem;
begin
  Result := 0;
  lL := AStore.LoadStreams(Default(TCatalogFilter));
  try
    for lS in lL do
      if lS.UpstreamId = AUpstreamId then
        Exit(lS.Id);
  finally
    FreeAndNil(lL);
  end;
end;

function NewTestList(const AStore: IStore; const AName: string): Integer;
var
  lLst: TCustomList;
begin
  lLst := TCustomList.Create;
  try
    lLst.Name := AName;
    lLst.Enabled := True;
    Result := AStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
end;

// a source that is switched off, or a content type switched off on it, is never
// offered to a box (output list, redirect lookup) - its items stay on the list
procedure TStorageTests.DisabledSourceOrTypeIsNotOffered;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lSrcId, lListId, lLiveId, lMovieId: Integer;
  lOut: TOutputChannelList;
  lS: TStreamItem;
begin
  lStore := NewStore(FDbPath);
  lSrcId := SaveTestSource(lStore, [ctLive, ctMovie], True);
  lSnap := TSourceSnapshot.Create(lSrcId);
  try
    lSnap.Streams.Add(MakeStream(lSrcId, ctLive, 'l1', 'Live One', 'G', '', 'http://prov/live/u/p/l1.ts'));
    lSnap.Streams.Add(MakeStream(lSrcId, ctMovie, 'm1', 'Movie One', 'G', '', 'http://prov/movie/u/p/m1.mkv'));
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lLiveId := StreamIdByUpstream(lStore, 'l1');
  lMovieId := StreamIdByUpstream(lStore, 'm1');
  lListId := NewTestList(lStore, 'L');
  AddTestItem(lStore, lListId, lLiveId, ctLive);
  AddTestItem(lStore, lListId, lMovieId, ctMovie);

  lOut := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual<Integer>(2, lOut.Count, 'both offered');
  finally
    FreeAndNil(lOut);
  end;

  // movies switched off on the source
  SaveTestSource(lStore, [ctLive], True, lSrcId);
  lOut := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual<Integer>(1, lOut.Count, 'movie no longer offered');
    Assert.AreEqual('Live One', lOut[0].Name);
  finally
    FreeAndNil(lOut);
  end;
  Assert.IsNull(lStore.LoadListStreamById(lListId, lMovieId), 'no redirect to a switched-off type');
  lS := lStore.LoadListStreamById(lListId, lLiveId);
  try
    Assert.IsNotNull(lS);
  finally
    FreeAndNil(lS);
  end;

  // whole source switched off
  SaveTestSource(lStore, [ctLive], False, lSrcId);
  lOut := lStore.LoadOutputChannels(lListId);
  try
    Assert.AreEqual<Integer>(0, lOut.Count, 'disabled source offers nothing');
  finally
    FreeAndNil(lOut);
  end;
  Assert.IsNull(lStore.LoadListStreamById(lListId, lLiveId));
end;

// Xtream series episodes get stable ids of our own; they resolve to the provider
// episode URL, but only via a list that carries the series
procedure TStorageTests.SeriesEpisodesResolveOnlyOnTheirList;
var
  lStore: IStore;
  lSnap: TSourceSnapshot;
  lSrcId, lListA, lListB, lSerId: Integer;
  lIds, lAgain: TArray<Integer>;
  lS: TStreamItem;
begin
  lStore := NewStore(FDbPath);
  lSrcId := SaveTestSource(lStore, [ctSeries], True);
  lSnap := TSourceSnapshot.Create(lSrcId);
  try
    lSnap.Streams.Add(MakeStream(lSrcId, ctSeries, 'ser1', 'Some Show', 'G', '', 'http://prov/series/u/p/ser1.ts'));
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lSerId := StreamIdByUpstream(lStore, 'ser1');
  lListA := NewTestList(lStore, 'A');
  lListB := NewTestList(lStore, 'B');
  AddTestItem(lStore, lListA, lSerId, ctSeries);

  lIds := lStore.EnsureEpisodeIds(lSerId, ['901', '902'], ['mkv', '']);
  Assert.AreEqual<Integer>(2, Length(lIds));
  Assert.IsTrue(lIds[0] >= cEpisodeIdBase, 'outside the catalog id range');
  Assert.AreNotEqual(lIds[0], lIds[1]);
  lAgain := lStore.EnsureEpisodeIds(lSerId, ['902', '901'], ['', 'mkv']);
  Assert.AreEqual(lIds[0], lAgain[1], 'stable per upstream episode');
  Assert.AreEqual(lIds[1], lAgain[0]);

  lS := lStore.LoadListStreamById(lListA, lIds[0]);
  try
    Assert.IsNotNull(lS);
    Assert.AreEqual('http://prov:8080/series/u/p/901.mkv', lS.UpstreamUrl);
    Assert.AreEqual(lSrcId, lS.SourceId);
  finally
    FreeAndNil(lS);
  end;
  lS := lStore.LoadListStreamById(lListA, lIds[1]);
  try
    Assert.AreEqual('http://prov:8080/series/u/p/902.mp4', lS.UpstreamUrl, 'no extension -> mp4');
  finally
    FreeAndNil(lS);
  end;
  Assert.IsNull(lStore.LoadListStreamById(lListB, lIds[0]), 'not via a list without the series');
end;

procedure TStorageTests.PathCredentials_DashAndEncoding;
var
  lStore: IStore;
  lLst: TCustomList;
  lFound: TCustomList;
begin
  Assert.AreEqual('-', PathCred(''));
  Assert.AreEqual('a%2Fb%20c%3F', PathCred('a/b c?'));
  Assert.AreEqual('box_1.x~', PathCred('box_1.x~'));

  lStore := NewStore(FDbPath);
  NewTestList(lStore, 'Open'); // no login
  lLst := TCustomList.Create;
  try
    lLst.Name := 'Locked';
    lLst.Enabled := True;
    lLst.OutputUsername := 'me';
    lLst.OutputPassword := 'p/w d';
    lStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
  lFound := FindListForPath(lStore, '-', '-');
  try
    Assert.IsNotNull(lFound, '"-" is the empty login');
    Assert.AreEqual('Open', lFound.Name);
  finally
    FreeAndNil(lFound);
  end;
  lFound := FindListForPath(lStore, 'me', PathCred('p/w d'));
  try
    Assert.IsNotNull(lFound, 'percent-encoded password from our own URL');
    Assert.AreEqual('Locked', lFound.Name);
  finally
    FreeAndNil(lFound);
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

procedure TStorageTests.RunInTransactionRollsBackOnError;
var
  lInner, lStore: IStore;
  lLists: TObjectList<TCustomList>;
begin
  lInner := NewStore(FDbPath);
  lStore := TLockingStore.Create(lInner, lInner); // one connection, as on Unraid
  NewTestList(lStore, 'Keep');
  Assert.WillRaise(
    procedure
    begin
      lStore.RunInTransaction(
        procedure(AStore: IStore)
        var
          lInside: TObjectList<TCustomList>;
        begin
          lInside := AStore.LoadLists; // reads work inside the transaction
          try
            AStore.DeleteList(lInside[0].Id);
          finally
            FreeAndNil(lInside);
          end;
          NewTestList(AStore, 'Half');
          raise Exception.Create('import failed half-way');
        end);
    end, Exception);
  lLists := lStore.LoadLists;
  try
    Assert.AreEqual<Integer>(1, lLists.Count, 'rolled back');
    Assert.AreEqual('Keep', lLists[0].Name);
  finally
    FreeAndNil(lLists);
  end;
end;

function OneProgrammeList(const ATvgId: string): TEpgProgrammeList;
var
  lP: TEpgProgramme;
begin
  Result := TEpgProgrammeList.Create(True);
  lP := TEpgProgramme.Create;
  lP.ChannelTvgId := ATvgId;
  lP.Title := 'Show';
  lP.StartUtc := EncodeDateTime(2026, 6, 14, 18, 0, 0, 0);
  lP.StopUtc := EncodeDateTime(2026, 6, 14, 19, 0, 0, 0);
  Result.Add(lP);
end;

function CountAllStreams(const AStore: IStore): Integer;
var
  lL: TStreamItemList;
begin
  lL := AStore.LoadStreams(Default(TCatalogFilter));
  try
    Result := lL.Count;
  finally
    FreeAndNil(lL);
  end;
end;

function CountCategories(const AStore: IStore): Integer;
var
  lL: TCategoryList;
begin
  lL := AStore.LoadCategories(Default(TCatalogFilter));
  try
    Result := lL.Count;
  finally
    FreeAndNil(lL);
  end;
end;

function CountEpg(const AStore: IStore; const ATvgId: string): Integer;
var
  lL: TEpgProgrammeList;
begin
  lL := AStore.LoadEpgForTvgIds([ATvgId]);
  try
    Result := lL.Count;
  finally
    FreeAndNil(lL);
  end;
end;

function SnapshotWithStreamAndCategory(ASourceId: Integer; const AUpstreamId, ATvgId: string): TSourceSnapshot;
var
  lCat: TCategory;
begin
  Result := TSourceSnapshot.Create(ASourceId);
  Result.Streams.Add(MakeStream(ASourceId, ctLive, AUpstreamId, 'Chan ' + AUpstreamId, '', ATvgId,
    'http://p/' + AUpstreamId + '.ts'));
  lCat := TCategory.Create;
  lCat.ContentType := ctLive;
  lCat.UpstreamId := 'c' + AUpstreamId;
  lCat.Name := 'Cat ' + AUpstreamId;
  Result.Categories.Add(lCat);
end;

// RefreshSource reads for minutes, then merges under the id it started with: when
// the source was deleted meanwhile, nothing may be written under the dead id
procedure TStorageTests.MergeForDeletedSourceWritesNothing;
var
  lStore: IStore;
  lSrcId: Integer;
  lSnap: TSourceSnapshot;
  lProgs: TEpgProgrammeList;
begin
  lStore := NewStore(FDbPath);
  lSrcId := SaveTestSource(lStore, [ctLive], True);
  lStore.DeleteSource(lSrcId);

  lSnap := SnapshotWithStreamAndCategory(lSrcId, 'a', 'tv1');
  try
    lStore.MergeSnapshot(lSnap); // no exception, just skipped
  finally
    FreeAndNil(lSnap);
  end;
  lProgs := OneProgrammeList('tv1');
  try
    lStore.ReplaceEpg(lSrcId, lProgs);
  finally
    FreeAndNil(lProgs);
  end;

  Assert.AreEqual<Integer>(0, CountAllStreams(lStore), 'no orphaned streams');
  Assert.AreEqual<Integer>(0, CountCategories(lStore), 'no orphaned categories');
  Assert.AreEqual<Integer>(0, CountEpg(lStore, 'tv1'), 'no orphaned EPG');

  // a live source still merges normally
  lSrcId := SaveTestSource(lStore, [ctLive], True);
  lSnap := SnapshotWithStreamAndCategory(lSrcId, 'b', 'tv2');
  try
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lProgs := OneProgrammeList('tv2');
  try
    lStore.ReplaceEpg(lSrcId, lProgs);
  finally
    FreeAndNil(lProgs);
  end;
  Assert.AreEqual<Integer>(1, CountAllStreams(lStore), 'existing source merged');
  Assert.AreEqual<Integer>(1, CountEpg(lStore, 'tv2'), 'existing source EPG stored');
end;

// Xtream: live 500 and series 500 are separate id spaces. When live 500 becomes
// radio 500 (and series 500 stays), the live row must be re-keyed - whatever the
// dictionary order - instead of a duplicate radio row next to a frozen live one.
procedure TStorageTests.ReKeyWithUpstreamIdUnderTwoTypes;
const
  cUid = '500';
var
  lStore: IStore;
  lSrcId, lLiveId, lSeriesId: Integer;
  lSnap: TSourceSnapshot;
  lAll: TStreamItemList;
  lS: TStreamItem;
  lRadioId, lRadioCount, lSeriesCount: Integer;
begin
  lStore := NewStore(FDbPath);
  lSrcId := SaveTestSource(lStore, [ctLive, ctSeries, ctRadio], True);
  lSnap := TSourceSnapshot.Create(lSrcId);
  try
    lSnap.Streams.Add(MakeStream(lSrcId, ctLive, cUid, 'Radio One', '', '', 'http://p/live/500.ts'));
    lSnap.Streams.Add(MakeStream(lSrcId, ctSeries, cUid, 'Some Series', '', '', 'http://p/series/500'));
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lLiveId := 0;
  lSeriesId := 0;
  lAll := lStore.LoadStreams(Default(TCatalogFilter));
  try
    for lS in lAll do
      if lS.ContentType = ctLive then
        lLiveId := lS.Id
      else if lS.ContentType = ctSeries then
        lSeriesId := lS.Id;
  finally
    FreeAndNil(lAll);
  end;
  Assert.IsTrue((lLiveId > 0) and (lSeriesId > 0), 'both stored');

  lSnap := TSourceSnapshot.Create(lSrcId);
  try
    lSnap.Streams.Add(MakeStream(lSrcId, ctRadio, cUid, 'Radio One', '', '', 'http://p/live/500.ts'));
    lSnap.Streams.Add(MakeStream(lSrcId, ctSeries, cUid, 'Some Series', '', '', 'http://p/series/500'));
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;

  lRadioId := 0;
  lRadioCount := 0;
  lSeriesCount := 0;
  lAll := lStore.LoadStreams(Default(TCatalogFilter));
  try
    Assert.AreEqual<Integer>(2, lAll.Count, 'no duplicate row');
    for lS in lAll do
      if lS.ContentType = ctRadio then
      begin
        Inc(lRadioCount);
        lRadioId := lS.Id;
      end
      else if lS.ContentType = ctSeries then
      begin
        Inc(lSeriesCount);
        Assert.AreEqual(lSeriesId, lS.Id, 'series row untouched');
      end;
  finally
    FreeAndNil(lAll);
  end;
  Assert.AreEqual<Integer>(1, lRadioCount, 'one radio row');
  Assert.AreEqual<Integer>(1, lSeriesCount, 'one series row');
  Assert.AreEqual(lLiveId, lRadioId, 'the live row was re-keyed to radio (same id)');
end;

// rows written under a source id before the merge/EPG guard existed: Init removes
// them (and the list items of those streams); a never-issued id is left alone
procedure TStorageTests.InitPurgesOrphanedSourceRows;
const
  cDriverSQLite = 'SQLite';
  cNeverIssuedId = 99;
var
  lStore: IStore;
  lSrcId, lKeepId, lListId: Integer;
  lSnap: TSourceSnapshot;
  lProgs: TEpgProgrammeList;
  lConn: TFDConnection;
  lItems: TCustomItemList;
begin
  lStore := NewStore(FDbPath);
  lSrcId := SaveTestSource(lStore, [ctLive], True);
  lKeepId := SaveTestSource(lStore, [ctLive], True);
  lSnap := SnapshotWithStreamAndCategory(lSrcId, 'gone', 'tvgone');
  try
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lSnap := SnapshotWithStreamAndCategory(lKeepId, 'kept', 'tvkept');
  try
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lSnap := SnapshotWithStreamAndCategory(cNeverIssuedId, 'adhoc', 'tvadhoc');
  try
    lStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lProgs := OneProgrammeList('tvgone');
  try
    lStore.ReplaceEpg(lSrcId, lProgs);
  finally
    FreeAndNil(lProgs);
  end;
  lListId := NewTestList(lStore, 'L');
  AddTestItem(lStore, lListId, StreamIdByUpstream(lStore, 'gone'), ctLive);
  AddTestItem(lStore, lListId, StreamIdByUpstream(lStore, 'kept'), ctLive);
  lStore := nil; // close the connection

  // simulate the old bug: the sources row vanished, its rows stayed
  lConn := TFDConnection.Create(nil);
  try
    lConn.DriverName := cDriverSQLite;
    lConn.Params.Database := FDbPath;
    lConn.Connected := True;
    lConn.ExecSQL('DELETE FROM sources WHERE id = :id', [lSrcId]);
    lConn.Connected := False;
  finally
    FreeAndNil(lConn);
  end;

  lStore := NewStore(FDbPath); // Init purges
  Assert.AreEqual<Integer>(0, StreamIdByUpstream(lStore, 'gone'), 'orphaned stream removed');
  Assert.IsTrue(StreamIdByUpstream(lStore, 'kept') > 0, 'live source keeps its stream');
  Assert.IsTrue(StreamIdByUpstream(lStore, 'adhoc') > 0, 'never-issued id left alone');
  Assert.AreEqual<Integer>(2, CountCategories(lStore), 'orphaned category removed');
  Assert.AreEqual<Integer>(0, CountEpg(lStore, 'tvgone'), 'orphaned EPG removed');
  lItems := lStore.LoadItems(lListId);
  try
    Assert.AreEqual<Integer>(1, lItems.Count, 'list item of the orphaned stream removed');
  finally
    FreeAndNil(lItems);
  end;
end;

// ── mirror bouquets ─────────────────────────────────────────────────────────

const
  cMirrorUrl = 'http://alt:9090';
  cMirrorUser = 'u2';
  cMirrorPass = 'p2';

function MirrorCred(ASourceId: Integer; const AUrl, AUser, APass: string): TMirrorCredential;
begin
  Result.SourceId := ASourceId;
  Result.Url := AUrl;
  Result.Username := AUser;
  Result.Password := APass;
end;

function NewMirrorList(const AStore: IStore; const AName: string; AMasterId: Integer): Integer;
var
  lLst: TCustomList;
begin
  lLst := TCustomList.Create;
  try
    lLst.Name := AName;
    lLst.Enabled := True;
    lLst.OutputUsername := AName;
    lLst.OutputPassword := AName;
    lLst.MirrorOfListId := AMasterId;
    Result := AStore.SaveList(lLst);
  finally
    FreeAndNil(lLst);
  end;
end;

// set MirrorOfListId of an existing list (keeps its name)
procedure SetMirrorOf(const AStore: IStore; AListId, AMasterId: Integer);
var
  lLists: TObjectList<TCustomList>;
  lList: TCustomList;
begin
  lLists := AStore.LoadLists;
  try
    for lList in lLists do
      if lList.Id = AListId then
      begin
        lList.MirrorOfListId := AMasterId;
        AStore.SaveList(lList);
      end;
  finally
    FreeAndNil(lLists);
  end;
end;

// a source (Xtream http://prov:8080/, u/p) with two live channels and a series on
// list "Master" (one renamed + in a group), plus an empty list "Mirror" mirroring it
procedure SetupMirror(const AStore: IStore; out ASrcId, AMasterId, AMirrorId, ALiveId, AOffId,
  ASerId: Integer);
var
  lSnap: TSourceSnapshot;
  lGroup: TCustomGroup;
  lIt: TCustomItem;
begin
  ASrcId := SaveTestSource(AStore, [ctLive, ctSeries], True);
  lSnap := TSourceSnapshot.Create(ASrcId);
  try
    lSnap.Streams.Add(MakeStream(ASrcId, ctLive, 'l1', 'NL| NPO 1', 'NL', 'npo1', 'http://prov:8080/live/u/p/l1.ts'));
    lSnap.Streams.Add(MakeStream(ASrcId, ctLive, 'l2', 'NL| NPO 1 HD', 'NL', 'npo1',
      'http://prov:8080/live/u/p/l2.ts'));
    lSnap.Streams.Add(MakeStream(ASrcId, ctLive, 'off', 'Not on it', 'NL', '', 'http://prov:8080/live/u/p/off.ts'));
    lSnap.Streams.Add(MakeStream(ASrcId, ctSeries, 'ser1', 'Some Show', 'S', '', 'http://prov:8080/series/u/p/s.mp4'));
    AStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  ALiveId := StreamIdByUpstream(AStore, 'l1');
  AOffId := StreamIdByUpstream(AStore, 'off');
  ASerId := StreamIdByUpstream(AStore, 'ser1');
  AMasterId := NewTestList(AStore, 'Master');
  lGroup := TCustomGroup.Create;
  try
    lGroup.ListId := AMasterId;
    lGroup.Name := 'Dutch';
    lGroup.ContentType := ctLive;
    AStore.SaveGroup(lGroup);
    lIt := TCustomItem.Create;
    try
      lIt.ListId := AMasterId;
      lIt.StreamItemId := ALiveId;
      lIt.ContentType := ctLive;
      lIt.CustomGroupId := lGroup.Id;
      lIt.DisplayName := 'NPO 1';
      lIt.ChannelNumber := 101;
      AStore.SaveItem(lIt);
    finally
      FreeAndNil(lIt);
    end;
  finally
    FreeAndNil(lGroup);
  end;
  AddTestItem(AStore, AMasterId, StreamIdByUpstream(AStore, 'l2'), ctLive);
  AddTestItem(AStore, AMasterId, ASerId, ctSeries);
  AMirrorId := NewMirrorList(AStore, 'Mirror', AMasterId);
end;

function CountOutput(const AStore: IStore; AListId: Integer): Integer;
var
  lOut: TOutputChannelList;
begin
  lOut := AStore.LoadOutputChannels(AListId);
  try
    Result := lOut.Count;
  finally
    FreeAndNil(lOut);
  end;
end;

procedure TStorageTests.MirrorOutputChannelsFollowMaster;
var
  lStore: IStore;
  lSrcId, lMasterId, lMirrorId, lLiveId, lOffId, lSerId, i: Integer;
  lMaster, lMirror: TOutputChannelList;
  lCreds: TArray<TMirrorCredential>;
begin
  lStore := NewStore(FDbPath);
  SetupMirror(lStore, lSrcId, lMasterId, lMirrorId, lLiveId, lOffId, lSerId);
  lStore.SaveMirrorCredentials(lMirrorId, [MirrorCred(lSrcId, cMirrorUrl, cMirrorUser, cMirrorPass),
    MirrorCred(lSrcId + 1, '', 'x', 'y'), MirrorCred(0, '', 'x', 'y')]);
  lCreds := lStore.LoadMirrorCredentials(lMirrorId);
  Assert.AreEqual<Integer>(1, Length(lCreds), 'unknown sources are not stored');
  Assert.AreEqual(cMirrorUser, lCreds[0].Username);
  Assert.AreEqual(cMirrorUrl, lCreds[0].Url);

  lMaster := lStore.LoadOutputChannels(lMasterId);
  lMirror := lStore.LoadOutputChannels(lMirrorId);
  try
    Assert.AreEqual<Integer>(3, lMaster.Count);
    Assert.AreEqual<Integer>(lMaster.Count, lMirror.Count, 'the master''s channels');
    for i := 0 to lMaster.Count - 1 do
    begin
      Assert.AreEqual(lMaster[i].StreamItemId, lMirror[i].StreamItemId, 'same order');
      Assert.AreEqual(lMaster[i].Name, lMirror[i].Name, 'same names');
      Assert.AreEqual(lMaster[i].Number, lMirror[i].Number, 'same numbers');
      Assert.AreEqual(lMaster[i].GroupName, lMirror[i].GroupName, 'same groups');
      Assert.AreEqual(lMaster[i].TvgId, lMirror[i].TvgId, 'same guide ids');
      Assert.IsTrue(lMaster[i].UpstreamUrl.StartsWith('http://prov:8080/'), 'master keeps its account');
      Assert.AreEqual(lMaster[i].UpstreamUrl.Replace('http://prov:8080/', cMirrorUrl + '/')
        .Replace('/u/p/', '/u2/p2/'), lMirror[i].UpstreamUrl, 'mirror plays with its own account');
    end;
  finally
    FreeAndNil(lMaster);
    FreeAndNil(lMirror);
  end;

  // without credentials the mirror plays with the source's account
  lStore.SaveMirrorCredentials(lMirrorId, [MirrorCred(lSrcId, '', '', '')]);
  Assert.AreEqual<Integer>(0, Length(lStore.LoadMirrorCredentials(lMirrorId)), 'empty rows are not stored');
  lMirror := lStore.LoadOutputChannels(lMirrorId);
  try
    Assert.AreEqual('http://prov:8080/live/u/p/l1.ts', lMirror[0].UpstreamUrl);
  finally
    FreeAndNil(lMirror);
  end;
end;

procedure TStorageTests.MirrorListStreamByIdScopedToMaster;
var
  lInner, lStore: IStore;
  lSrcId, lMasterId, lMirrorId, lLiveId, lOffId, lSerId: Integer;
  lIds: TArray<Integer>;
  lS: TStreamItem;
  lSiblings: TArray<string>;
begin
  lInner := NewStore(FDbPath);
  lStore := TLockingStore.Create(lInner, lInner); // the zap cache must follow credential changes
  SetupMirror(lStore, lSrcId, lMasterId, lMirrorId, lLiveId, lOffId, lSerId);
  lStore.SaveMirrorCredentials(lMirrorId, [MirrorCred(lSrcId, '', cMirrorUser, cMirrorPass)]);

  lS := lStore.LoadListStreamById(lMirrorId, lLiveId);
  try
    Assert.IsNotNull(lS, 'a master channel plays through the mirror');
    Assert.AreEqual('http://prov:8080/live/u2/p2/l1.ts', lS.UpstreamUrl);
  finally
    FreeAndNil(lS);
  end;
  lS := lStore.LoadListStreamById(lMasterId, lLiveId);
  try
    Assert.AreEqual('http://prov:8080/live/u/p/l1.ts', lS.UpstreamUrl, 'the master is untouched');
  finally
    FreeAndNil(lS);
  end;
  Assert.IsNull(lStore.LoadListStreamById(lMirrorId, lOffId), 'scoped to the master''s channels');

  // series episodes of the master's series
  lIds := lStore.EnsureEpisodeIds(lSerId, ['901'], ['mkv']);
  lS := lStore.LoadListStreamById(lMirrorId, lIds[0]);
  try
    Assert.IsNotNull(lS, 'an episode of a master series');
    Assert.AreEqual('http://prov:8080/series/u2/p2/901.mkv', lS.UpstreamUrl);
  finally
    FreeAndNil(lS);
  end;

  // failover candidates are played with the mirror's account too
  lSiblings := lStore.LoadStreamSiblingsForList(lMirrorId, lLiveId);
  Assert.AreEqual<Integer>(1, Length(lSiblings));
  Assert.AreEqual('http://prov:8080/live/u2/p2/l2.ts', lSiblings[0]);
  lSiblings := lStore.LoadStreamSiblingsForList(lMasterId, lLiveId);
  Assert.AreEqual('http://prov:8080/live/u/p/l2.ts', lSiblings[0], 'a normal list: as stored');

  // new credentials: the cached zap answer goes
  lStore.SaveMirrorCredentials(lMirrorId, [MirrorCred(lSrcId, cMirrorUrl, '', '')]);
  lS := lStore.LoadListStreamById(lMirrorId, lLiveId);
  try
    Assert.AreEqual(cMirrorUrl + '/live/u/p/l1.ts', lS.UpstreamUrl, 'zap cache invalidated');
  finally
    FreeAndNil(lS);
  end;
end;

procedure TStorageTests.MirrorValidationRules;
var
  lStore: IStore;
  lSrcId, lMasterId, lMirrorId, lLiveId, lOffId, lSerId, lOther, lOwn: Integer;
begin
  lStore := NewStore(FDbPath);
  SetupMirror(lStore, lSrcId, lMasterId, lMirrorId, lLiveId, lOffId, lSerId);
  lOther := NewTestList(lStore, 'Other');
  lOwn := NewTestList(lStore, 'Own');
  AddTestItem(lStore, lOwn, lLiveId, ctLive);

  Assert.WillRaise(
    procedure
    begin
      SetMirrorOf(lStore, lOther, lOther);
    end, EStoreValidation, 'not itself');
  Assert.WillRaise(
    procedure
    begin
      NewMirrorList(lStore, 'Ghost', 9999);
    end, EStoreValidation, 'an existing master');
  Assert.WillRaise(
    procedure
    begin
      SetMirrorOf(lStore, lOther, lMirrorId);
    end, EStoreValidation, 'no mirror of a mirror');
  Assert.WillRaise(
    procedure
    begin
      SetMirrorOf(lStore, lMasterId, lOther);
    end, EStoreValidation, 'a mirrored list can''t become a mirror');
  Assert.WillRaise(
    procedure
    begin
      SetMirrorOf(lStore, lOwn, lMasterId);
    end, EStoreValidation, 'a list with channels can''t become a mirror');
  Assert.WillRaise(
    procedure
    begin
      lStore.SaveMirrorCredentials(lOther, [MirrorCred(lSrcId, '', 'x', 'y')]);
    end, EStoreValidation, 'only a mirror has credentials');
  Assert.WillRaise(
    procedure
    begin
      lStore.DeleteList(lMasterId);
    end, EStoreValidation, 'a master can''t go while mirrored');
  Assert.AreEqual<Integer>(3, CountOutput(lStore, lMasterId), 'the master survived');

  // an empty list may become a mirror; and back again (its credentials go)
  SetMirrorOf(lStore, lOther, lMasterId);
  Assert.AreEqual<Integer>(3, CountOutput(lStore, lOther), 'now mirrors the master');
  lStore.SaveMirrorCredentials(lOther, [MirrorCred(lSrcId, '', 'x', 'y')]);
  SetMirrorOf(lStore, lOther, 0);
  Assert.AreEqual<Integer>(0, CountOutput(lStore, lOther), 'own channels again (none)');
  Assert.AreEqual<Integer>(0, Length(lStore.LoadMirrorCredentials(lOther)), 'credentials dropped');

  // without its mirrors the master can go
  lStore.DeleteList(lMirrorId);
  lStore.DeleteList(lMasterId);
end;

procedure TStorageTests.MirrorCredentialsDeletedWithListAndSource;
var
  lStore: IStore;
  lSrcId, lMasterId, lMirrorId, lLiveId, lOffId, lSerId, lSecond: Integer;
begin
  lStore := NewStore(FDbPath);
  SetupMirror(lStore, lSrcId, lMasterId, lMirrorId, lLiveId, lOffId, lSerId);
  lSecond := NewMirrorList(lStore, 'Second', lMasterId);
  lStore.SaveMirrorCredentials(lMirrorId, [MirrorCred(lSrcId, '', 'x', 'y')]);
  lStore.SaveMirrorCredentials(lSecond, [MirrorCred(lSrcId, '', 'x', 'y')]);

  lStore.DeleteList(lMirrorId);
  Assert.AreEqual<Integer>(0, Length(lStore.LoadMirrorCredentials(lMirrorId)), 'gone with the list');
  Assert.AreEqual<Integer>(1, Length(lStore.LoadMirrorCredentials(lSecond)), 'the other mirror keeps its own');

  lStore.DeleteSource(lSrcId);
  Assert.AreEqual<Integer>(0, Length(lStore.LoadMirrorCredentials(lSecond)), 'gone with the source');
end;

initialization
  TDUnitX.RegisterTestFixture(TStorageTests);

end.
