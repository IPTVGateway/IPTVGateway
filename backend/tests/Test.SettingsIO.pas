unit Test.SettingsIO;

{ Round-trip test for the portable settings bundle (IPTV.Api.SettingsIO):
  build a curated setup in one store, export it, import into a FRESH store, and
  assert the clone is 1:1 — sources, lists, groups AND the chosen channels (with
  their renames, channel numbers and group placement) all come back, with the
  catalog rows recreated so the items resolve without a refresh. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Export/import round-trip tests for the portable settings bundle.</summary>
  [TestFixture]
  TSettingsIOTests = class
  private
    FDb1, FDb2: string;
  public
    /// <summary>Picks two fresh temp database paths.</summary>
    [Setup] procedure Setup;
    /// <summary>Deletes both temp databases (incl. -wal/-shm).</summary>
    [TearDown] procedure TearDown;
    /// <summary>Export then import into a fresh store clones the setup 1:1.</summary>
    [Test] procedure ExportImportClonesEverything;
    /// <summary>The manual group order survives export/import.</summary>
    [Test] procedure ImportPreservesManualGroupOrder;
    /// <summary>A mirror bouquet round-trips: master remapped by name, credentials by source name.</summary>
    [Test] procedure ExportImportClonesMirror;
    /// <summary>A config.json with bad types/ranges loads with defaults/clamps.</summary>
    [Test] procedure ConfigLoadToleratesBadTypesAndRanges;
    /// <summary>A Live and a Movies group with the same name stay two groups (mapped by bundle id).</summary>
    [Test] procedure ImportKeepsSameNamedGroupsApart;
    /// <summary>Two sources with the same name keep their own channels and mirror credentials.</summary>
    [Test] procedure ImportKeepsSameNamedSourcesApart;
    /// <summary>A mirror of one of two same-named masters follows ITS master.</summary>
    [Test] procedure ImportMirrorOfSameNamedMaster;
    /// <summary>An older bundle without groupId/sourceId still imports by name.</summary>
    [Test] procedure ImportOldBundleMatchesByName;
    /// <summary>The import reports every list's new id by its bundle id (same names stay apart; the Plex bouquet).</summary>
    [Test] procedure ImportReportsListIdMap;
  end;

implementation

uses
  // RTL
  System.Generics.Collections,
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.CustomList,
  IPTV.Storage.Intf,
  IPTV.Storage.SQLite,
  IPTV.Api.SettingsIO,
  IPTV.App.Config;

function NewStore(const APath: string): IStore;
begin
  Result := TSQLiteStore.Create(APath);
  Result.Init;
end;

function MakeStream(ASourceId: Integer; const AUpstreamId, AName, AGroup, ATvgId, AUrl: string): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.SourceId := ASourceId;
  Result.ContentType := ctLive;
  Result.UpstreamId := AUpstreamId;
  Result.Name := AName;
  Result.GroupTitle := AGroup;
  Result.TvgId := ATvgId;
  Result.UpstreamUrl := AUrl;
end;

procedure TSettingsIOTests.Setup;
begin
  FDb1 := TPath.Combine(TPath.GetTempPath, 'iptvio1_' + TGUID.NewGuid.ToString + '.sqlite');
  FDb2 := TPath.Combine(TPath.GetTempPath, 'iptvio2_' + TGUID.NewGuid.ToString + '.sqlite');
end;

procedure TSettingsIOTests.TearDown;

  procedure Del(const APath: string);
  begin
    if TFile.Exists(APath) then
      TFile.Delete(APath);
    if TFile.Exists(APath + '-wal') then
      TFile.Delete(APath + '-wal');
    if TFile.Exists(APath + '-shm') then
      TFile.Delete(APath + '-shm');
  end;

begin
  Del(FDb1);
  Del(FDb2);
end;

procedure TSettingsIOTests.ExportImportClonesEverything;
var
  lSrc: IStore;
  lDst: IStore;
  lCfg: TSourceConfig;
  lSnap: TSourceSnapshot;
  lList: TCustomList;
  lGroup: TCustomGroup;
  lItem: TCustomItem;
  lBundle: TJSONObject;
  lSrcId, lListId, lGroupId, lS1, lS2: Integer;
  lFilter: TCatalogFilter;
  lStreams: TStreamItemList;
  lCounts: TImportCounts;
  lNewListId: Integer;
  lChannels: TOutputChannelList;
  lFoundNpo: Boolean;
  i: Integer;
  lSources: TObjectList<TSourceConfig>;
  lLists: TObjectList<TCustomList>;
begin
  // ── build the original setup ───────────────────────────────────────────
  lSrc := NewStore(FDb1);
  lCfg := TSourceConfig.Create;
  try
    lCfg.Name := 'Prov';
    lCfg.Kind := skXtream;
    lCfg.Url := 'http://h';
    lCfg.StripPrefixes := ['NL'];
    lSrcId := lSrc.SaveSource(lCfg);
  finally
    FreeAndNil(lCfg);
  end;

  lSnap := TSourceSnapshot.Create(lSrcId);
  lSnap.Streams.Add(MakeStream(lSrcId, 'u1', 'NPO 1 HD', 'NL', 'tv1', 'http://p/1.ts'));
  lSnap.Streams.Add(MakeStream(lSrcId, 'u2', 'BBC One', 'UK', 'tv2', 'http://p/2.ts'));
  lSrc.MergeSnapshot(lSnap);
  FreeAndNil(lSnap);

  lList := TCustomList.Create;
  try
    lList.Name := 'Box';
    lList.OutputUsername := 'u';
    lList.OutputPassword := 'p';
    lListId := lSrc.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;

  lGroup := TCustomGroup.Create;
  try
    lGroup.ListId := lListId;
    lGroup.Name := 'Sport';
    lGroup.ContentType := ctLive;
    lGroup.IsFavorite := True;
    lGroupId := lSrc.SaveGroup(lGroup);
  finally
    FreeAndNil(lGroup);
  end;

  lS1 := -1;
  lS2 := -1;
  lFilter := Default(TCatalogFilter);
  lStreams := lSrc.LoadStreams(lFilter);
  try
    for i := 0 to lStreams.Count - 1 do
      if lStreams[i].Name.Contains('NPO') then
        lS1 := lStreams[i].Id
      else
        lS2 := lStreams[i].Id;
  finally
    FreeAndNil(lStreams);
  end;

  // item 1: renamed + numbered + in the favorite group; item 2: plain
  lItem := TCustomItem.Create;
  try
    lItem.ListId := lListId;
    lItem.StreamItemId := lS1;
    lItem.CustomGroupId := lGroupId;
    lItem.ContentType := ctLive;
    lItem.DisplayName := 'NPO Een';
    lItem.ChannelNumber := 5;
    lSrc.SaveItem(lItem);
  finally
    FreeAndNil(lItem);
  end;
  lItem := TCustomItem.Create;
  try
    lItem.ListId := lListId;
    lItem.StreamItemId := lS2;
    lItem.ContentType := ctLive;
    lSrc.SaveItem(lItem);
  finally
    FreeAndNil(lItem);
  end;

  // ── export, then import into a fresh store ──────────────────────────────
  lDst := NewStore(FDb2);
  lBundle := ExportStoreSettings(lSrc);
  try
    lCounts := ImportStoreSettings(lDst, lBundle);
    Assert.AreEqual<Integer>(1, lCounts.Sources, 'source recreated');
    Assert.AreEqual<Integer>(1, lCounts.Lists, 'list recreated');
    Assert.AreEqual<Integer>(1, lCounts.Groups, 'group recreated');
    Assert.AreEqual<Integer>(2, lCounts.Items, 'both channels recreated');
  finally
    FreeAndNil(lBundle);
  end;

  // ── assert the clone is faithful ────────────────────────────────────────
  lSources := lDst.LoadSources;
  try
    Assert.AreEqual<Integer>(1, lSources.Count);
    Assert.AreEqual('Prov', lSources[0].Name);
    Assert.AreEqual<Integer>(1, Length(lSources[0].StripPrefixes), 'source config (strip prefixes) cloned');
  finally
    FreeAndNil(lSources);
  end;

  lNewListId := -1;
  lLists := lDst.LoadLists;
  try
    Assert.AreEqual<Integer>(1, lLists.Count);
    Assert.AreEqual('Box', lLists[0].Name);
    lNewListId := lLists[0].Id;
  finally
    FreeAndNil(lLists);
  end;

  // the resolved output proves: streams recreated, items linked by URL, rename,
  // channel number and favorite-group placement all survived the round-trip
  lChannels := lDst.LoadOutputChannels(lNewListId);
  try
    Assert.AreEqual<Integer>(2, lChannels.Count, 'both channels resolve in the clone');
    lFoundNpo := False;
    for i := 0 to lChannels.Count - 1 do
      if lChannels[i].UpstreamUrl = 'http://p/1.ts' then
      begin
        lFoundNpo := True;
        Assert.AreEqual('NPO Een', lChannels[i].Name, 'rename cloned');
        Assert.AreEqual<Integer>(5, lChannels[i].Number, 'channel number cloned');
        Assert.AreEqual('Sport', lChannels[i].GroupName, 'group placement cloned');
        Assert.IsTrue(lChannels[i].IsFavoriteGroup, 'favorite-group flag cloned');
      end;
    Assert.IsTrue(lFoundNpo, 'the renamed channel is present by its upstream URL');
  finally
    FreeAndNil(lChannels);
  end;
end;

// The operator's manual group drag-order (sort_order) must survive export->import.
// Groups are created with three non-alphabetical names and reordered; after a
// round-trip the clone must list them in that SAME order, not back to A->Z.
procedure TSettingsIOTests.ImportPreservesManualGroupOrder;
var
  lSrc, lDst: IStore;
  lList: TCustomList;
  lGroup: TCustomGroup;
  lListId, lAlpha, lBeta, lGamma: Integer;
  lBundle: TJSONObject;
  lNewListId: Integer;
  lGroups: TCustomGroupList;
  lLists: TObjectList<TCustomList>;
begin
  lSrc := NewStore(FDb1);
  lList := TCustomList.Create;
  try
    lList.Name := 'Box';
    lListId := lSrc.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;

  // create in alphabetical order, then reorder to Gamma, Alpha, Beta
  lGroup := TCustomGroup.Create;
  try
    lGroup.ListId := lListId;
    lGroup.Name := 'Alpha';
    lGroup.ContentType := ctLive;
    lAlpha := lSrc.SaveGroup(lGroup);
  finally
    FreeAndNil(lGroup);
  end;
  lGroup := TCustomGroup.Create;
  try
    lGroup.ListId := lListId;
    lGroup.Name := 'Beta';
    lGroup.ContentType := ctLive;
    lBeta := lSrc.SaveGroup(lGroup);
  finally
    FreeAndNil(lGroup);
  end;
  lGroup := TCustomGroup.Create;
  try
    lGroup.ListId := lListId;
    lGroup.Name := 'Gamma';
    lGroup.ContentType := ctLive;
    lGamma := lSrc.SaveGroup(lGroup);
  finally
    FreeAndNil(lGroup);
  end;
  lSrc.ReorderGroups(lListId, [lGamma, lAlpha, lBeta]);

  lDst := NewStore(FDb2);
  lBundle := ExportStoreSettings(lSrc);
  try
    ImportStoreSettings(lDst, lBundle);
  finally
    FreeAndNil(lBundle);
  end;

  lNewListId := -1;
  lLists := lDst.LoadLists;
  try
    lNewListId := lLists[0].Id;
  finally
    FreeAndNil(lLists);
  end;

  lGroups := lDst.LoadGroups(lNewListId);
  try
    Assert.AreEqual<Integer>(3, lGroups.Count, 'all groups cloned');
    Assert.AreEqual('Gamma', lGroups[0].Name, 'manual order preserved (1st)');
    Assert.AreEqual('Alpha', lGroups[1].Name, 'manual order preserved (2nd)');
    Assert.AreEqual('Beta', lGroups[2].Name, 'manual order preserved (3rd)');
  finally
    FreeAndNil(lGroups);
  end;
end;

// A hand-edited config.json with wrong-typed or out-of-range fields must NOT crash
// startup — it should fall back to defaults / clamp, per the file's documented contract.
procedure TSettingsIOTests.ConfigLoadToleratesBadTypesAndRanges;
var
  lPath: string;
  lCfg: TAppConfig;
begin
  lPath := TPath.Combine(TPath.GetTempPath, 'iptvcfg_' + TGUID.NewGuid.ToString + '.json');
  TFile.WriteAllText(lPath,
    '{"httpPort":"not-a-number","refreshHour":70000,"refreshMinute":-5,' +
    '"proxyPort":0,"useHttps":"yes","plexTunerCount":-3,"epgMaxDays":-1}');
  try
    lCfg := TAppConfig.Load(lPath); // must not raise
    Assert.AreEqual<Integer>(7777, lCfg.HttpPort, 'string httpPort -> default (no crash)');
    Assert.AreEqual<Integer>(23, lCfg.RefreshHour, 'hour 70000 clamped to 23');
    Assert.AreEqual<Integer>(0, lCfg.RefreshMinute, 'minute -5 clamped to 0');
    Assert.AreEqual<Integer>(1, lCfg.ProxyPort, 'port 0 clamped to 1');
    Assert.IsFalse(lCfg.UseHttps, 'non-bool useHttps -> default false');
    Assert.AreEqual<Integer>(1, lCfg.PlexTunerCount, 'tuner count -3 clamped to 1');
    Assert.AreEqual<Integer>(0, lCfg.EpgMaxDays, 'epgMaxDays -1 clamped to 0');
  finally
    TFile.Delete(lPath);
  end;
end;

function FindListByName(const AStore: IStore; const AName: string): TCustomList;
var
  lLists: TObjectList<TCustomList>;
  i: Integer;
begin
  Result := nil;
  lLists := AStore.LoadLists;
  try
    for i := 0 to lLists.Count - 1 do
      if lLists[i].Name = AName then
        Exit(lLists.Extract(lLists[i]));
  finally
    FreeAndNil(lLists);
  end;
end;

// builds Master (one channel) + its mirror in AStore; returns the source id
function BuildMirrorSetup(const AStore: IStore; const AMirrorName: string; out AMasterId,
  AMirrorId: Integer): Integer;
var
  lCfg: TSourceConfig;
  lSnap: TSourceSnapshot;
  lList: TCustomList;
  lItem: TCustomItem;
  lStreams: TStreamItemList;
  lCred: TMirrorCredential;
begin
  lCfg := TSourceConfig.Create;
  try
    lCfg.Name := 'Prov';
    lCfg.Kind := skXtream;
    lCfg.Url := 'http://h';
    lCfg.Username := 'a';
    lCfg.Password := 'b';
    Result := AStore.SaveSource(lCfg);
  finally
    FreeAndNil(lCfg);
  end;
  lSnap := TSourceSnapshot.Create(Result);
  try
    lSnap.Streams.Add(MakeStream(Result, 'u1', 'NPO 1', 'NL', 'tv1', 'http://h/live/a/b/1.ts'));
    AStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
  lList := TCustomList.Create;
  try
    lList.Name := 'Master';
    AMasterId := AStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;
  lStreams := AStore.LoadStreams(Default(TCatalogFilter));
  lItem := TCustomItem.Create;
  try
    lItem.ListId := AMasterId;
    lItem.StreamItemId := lStreams[0].Id;
    lItem.ContentType := ctLive;
    AStore.SaveItem(lItem);
  finally
    FreeAndNil(lItem);
    FreeAndNil(lStreams);
  end;
  lList := TCustomList.Create;
  try
    lList.Name := AMirrorName;
    lList.OutputUsername := 'mirror';
    lList.OutputPassword := 'pw';
    lList.MirrorOfListId := AMasterId;
    AMirrorId := AStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;
  lCred.SourceId := Result;
  lCred.Url := '';
  lCred.Username := 'a2';
  lCred.Password := 'b2';
  AStore.SaveMirrorCredentials(AMirrorId, [lCred]);
end;

procedure TSettingsIOTests.ExportImportClonesMirror;
var
  lSrc, lDst: IStore;
  lList: TCustomList;
  lBundle, lMirrorJson: TJSONObject;
  lValue: TJSONValue;
  lMasterId, lMirrorId, lDstSrcId, lOldMaster, lOldMirror: Integer;
  lMaster, lMirror: TCustomList;
  lCreds: TArray<TMirrorCredential>;
  lChannels: TOutputChannelList;
  lCounts: TImportCounts;
begin
  lSrc := NewStore(FDb1);
  // a throwaway list first, so the bundle's ids differ from the clone's
  lList := TCustomList.Create;
  try
    lList.Name := 'Gone';
    lSrc.SaveList(lList);
    lSrc.DeleteList(lList.Id);
  finally
    FreeAndNil(lList);
  end;
  // 'A Mirror' sorts before 'Master': the bundle lists the mirror first
  BuildMirrorSetup(lSrc, 'A Mirror', lMasterId, lMirrorId);

  // the target already has a master + mirror: the wipe must remove the mirror first
  lDst := NewStore(FDb2);
  BuildMirrorSetup(lDst, 'Old Mirror', lOldMaster, lOldMirror);

  lBundle := ExportStoreSettings(lSrc);
  try
    lMirrorJson := nil;
    for lValue in TJSONArray(lBundle.GetValue('lists')) do
      if TJSONObject(lValue).GetValue<string>('name') = 'A Mirror' then
        lMirrorJson := TJSONObject(lValue);
    Assert.IsNotNull(lMirrorJson);
    Assert.AreEqual(lMasterId, lMirrorJson.GetValue<Integer>('mirrorOfListId'), 'exported with the master id');
    // a credential for a source the bundle doesn't have is dropped on import
    TJSONArray(lMirrorJson.GetValue('mirrorCredentials')).AddElement(TJSONObject.Create
      .AddPair('sourceName', 'Nope').AddPair('url', '').AddPair('username', 'x').AddPair('password', 'y'));
    lCounts := ImportStoreSettings(lDst, lBundle);
  finally
    FreeAndNil(lBundle);
  end;
  Assert.AreEqual<Integer>(2, lCounts.Lists);

  lMaster := FindListByName(lDst, 'Master');
  lMirror := FindListByName(lDst, 'A Mirror');
  try
    Assert.IsNotNull(lMaster);
    Assert.IsNotNull(lMirror);
    Assert.IsNull(FindListByName(lDst, 'Old Mirror'), 'the old setup is gone');
    Assert.AreNotEqual(lMasterId, lMaster.Id, 'ids differ between the installs');
    Assert.AreEqual(lMaster.Id, lMirror.MirrorOfListId, 'remapped to the new master');
    Assert.AreEqual('mirror', lMirror.OutputUsername);
    lCreds := lDst.LoadMirrorCredentials(lMirror.Id);
    Assert.AreEqual<Integer>(1, Length(lCreds), 'unknown source dropped');
    lDstSrcId := lCreds[0].SourceId;
    Assert.AreEqual('a2', lCreds[0].Username);
    Assert.AreEqual('b2', lCreds[0].Password);
    lChannels := lDst.LoadOutputChannels(lMirror.Id);
    try
      Assert.AreEqual<Integer>(1, lChannels.Count, 'the master''s channel');
      Assert.AreEqual(lDstSrcId, lChannels[0].SourceId);
      Assert.AreEqual('http://h/live/a2/b2/1.ts', lChannels[0].UpstreamUrl, 'played with the mirror''s account');
    finally
      FreeAndNil(lChannels);
    end;
  finally
    FreeAndNil(lMaster);
    FreeAndNil(lMirror);
  end;
end;

// -- helpers for the id-remap tests --------------------------------------------

function AddSource(const AStore: IStore; const AName, AUrl: string): Integer;
var
  lCfg: TSourceConfig;
begin
  lCfg := TSourceConfig.Create;
  try
    lCfg.Name := AName;
    lCfg.Kind := skXtream;
    lCfg.Url := AUrl;
    lCfg.Username := 'a';
    lCfg.Password := 'b';
    Result := AStore.SaveSource(lCfg);
  finally
    FreeAndNil(lCfg);
  end;
end;

// all streams of a source in one snapshot (a snapshot replaces the source's catalog)
procedure AddSourceStreams(const AStore: IStore; ASourceId: Integer; const AStreams: array of TStreamItem);
var
  lSnap: TSourceSnapshot;
  lStream: TStreamItem;
begin
  lSnap := TSourceSnapshot.Create(ASourceId);
  try
    for lStream in AStreams do
      lSnap.Streams.Add(lStream);
    AStore.MergeSnapshot(lSnap);
  finally
    FreeAndNil(lSnap);
  end;
end;

function TypedStream(ASourceId: Integer; ACt: TContentType; const AUp, AName, AUrl: string): TStreamItem;
begin
  Result := MakeStream(ASourceId, AUp, AName, '', '', AUrl);
  Result.ContentType := ACt;
end;

function StreamIdOf(const AStore: IStore; ASourceId: Integer; const AUrl: string): Integer;
var
  lStreams: TStreamItemList;
  lStream: TStreamItem;
begin
  Result := -1;
  lStreams := AStore.LoadStreams(Default(TCatalogFilter));
  try
    for lStream in lStreams do
      if (lStream.SourceId = ASourceId) and (lStream.UpstreamUrl = AUrl) then
        Exit(lStream.Id);
  finally
    FreeAndNil(lStreams);
  end;
end;

function AddList(const AStore: IStore; const AName: string; AMirrorOf: Integer = 0): Integer;
var
  lList: TCustomList;
begin
  lList := TCustomList.Create;
  try
    lList.Name := AName;
    lList.OutputUsername := AName + IntToStr(AMirrorOf) + TGUID.NewGuid.ToString;
    lList.MirrorOfListId := AMirrorOf;
    Result := AStore.SaveList(lList);
  finally
    FreeAndNil(lList);
  end;
end;

function AddGroup(const AStore: IStore; AListId: Integer; const AName: string; ACt: TContentType): Integer;
var
  lGroup: TCustomGroup;
begin
  lGroup := TCustomGroup.Create;
  try
    lGroup.ListId := AListId;
    lGroup.Name := AName;
    lGroup.ContentType := ACt;
    Result := AStore.SaveGroup(lGroup);
  finally
    FreeAndNil(lGroup);
  end;
end;

procedure AddItem(const AStore: IStore; AListId, AStreamId, AGroupId: Integer; ACt: TContentType);
var
  lItem: TCustomItem;
begin
  lItem := TCustomItem.Create;
  try
    lItem.ListId := AListId;
    lItem.StreamItemId := AStreamId;
    lItem.CustomGroupId := AGroupId;
    lItem.ContentType := ACt;
    AStore.SaveItem(lItem);
  finally
    FreeAndNil(lItem);
  end;
end;

// export ASrc and import the bundle into ADst; AStrip: drop the reference ids an
// older bundle doesn't have (items' groupId, streams' sourceId)
procedure CloneSettings(const ASrc, ADst: IStore; AStrip: Boolean = False);
var
  lBundle, lItemObj: TJSONObject;
  lList, lItem: TJSONValue;
begin
  lBundle := ExportStoreSettings(ASrc);
  try
    if AStrip then
      for lList in TJSONArray(lBundle.GetValue('lists')) do
        for lItem in TJSONArray(TJSONObject(lList).GetValue('items')) do
        begin
          lItemObj := TJSONObject(lItem);
          lItemObj.RemovePair('groupId').Free;
          TJSONObject(lItemObj.GetValue('stream')).RemovePair('sourceId').Free;
        end;
    ImportStoreSettings(ADst, lBundle);
  finally
    FreeAndNil(lBundle);
  end;
end;

procedure TSettingsIOTests.ImportKeepsSameNamedGroupsApart;
var
  lSrc, lDst: IStore;
  lSrcId, lListId: Integer;
  lList: TCustomList;
  lGroups: TCustomGroupList;
  lItems: TCustomItemList;
  lGroup: TCustomGroup;
  lItem: TCustomItem;
  lGroupType: TDictionary<Integer, TContentType>;
  lType: TContentType;
begin
  lSrc := NewStore(FDb1);
  lSrcId := AddSource(lSrc, 'Prov', 'http://h');
  AddSourceStreams(lSrc, lSrcId, [TypedStream(lSrcId, ctLive, 'l1', 'Kids TV', 'http://h/live/a/b/1.ts'),
    TypedStream(lSrcId, ctMovie, 'm1', 'Kids Movie', 'http://h/movie/a/b/2.mkv')]);
  lListId := AddList(lSrc, 'Box');
  // the Movies group first: a name-keyed import would put both channels in the last one
  AddItem(lSrc, lListId, StreamIdOf(lSrc, lSrcId, 'http://h/movie/a/b/2.mkv'),
    AddGroup(lSrc, lListId, 'Kids', ctMovie), ctMovie);
  AddItem(lSrc, lListId, StreamIdOf(lSrc, lSrcId, 'http://h/live/a/b/1.ts'),
    AddGroup(lSrc, lListId, 'Kids', ctLive), ctLive);

  lDst := NewStore(FDb2);
  CloneSettings(lSrc, lDst);

  lList := FindListByName(lDst, 'Box');
  lGroupType := TDictionary<Integer, TContentType>.Create;
  try
    Assert.IsNotNull(lList);
    lGroups := lDst.LoadGroups(lList.Id);
    try
      Assert.AreEqual<Integer>(2, lGroups.Count, 'both groups');
      for lGroup in lGroups do
        lGroupType.Add(lGroup.Id, lGroup.ContentType);
    finally
      FreeAndNil(lGroups);
    end;
    lItems := lDst.LoadItems(lList.Id);
    try
      Assert.AreEqual<Integer>(2, lItems.Count, 'both channels');
      for lItem in lItems do
      begin
        Assert.IsTrue(lGroupType.TryGetValue(lItem.CustomGroupId, lType), 'item is in a group');
        Assert.AreEqual<Integer>(Ord(lItem.ContentType), Ord(lType), 'item in the group of its own type');
      end;
      Assert.AreNotEqual<Integer>(lItems[0].CustomGroupId, lItems[1].CustomGroupId, 'two groups, not one');
    finally
      FreeAndNil(lItems);
    end;
  finally
    FreeAndNil(lGroupType);
    FreeAndNil(lList);
  end;
end;

procedure TSettingsIOTests.ImportKeepsSameNamedSourcesApart;
var
  lSrc, lDst: IStore;
  lSrcA, lSrcB, lListId, lMirrorId: Integer;
  lCred: TMirrorCredential;
  lSources: TObjectList<TSourceConfig>;
  lSource: TSourceConfig;
  lUrlById: TDictionary<Integer, string>;
  lList, lMirror: TCustomList;
  lChannels: TOutputChannelList;
  lChannel: TOutputChannel;
  lCreds: TArray<TMirrorCredential>;
begin
  lSrc := NewStore(FDb1);
  lSrcA := AddSource(lSrc, 'Prov', 'http://a');
  lSrcB := AddSource(lSrc, 'Prov', 'http://b');
  // the very same upstream URL on both (two accounts' playlists can overlap)
  AddSourceStreams(lSrc, lSrcA, [TypedStream(lSrcA, ctLive, '1', 'From A', 'http://x/live/a/b/1.ts')]);
  AddSourceStreams(lSrc, lSrcB, [TypedStream(lSrcB, ctLive, '1', 'From B', 'http://x/live/a/b/1.ts')]);
  lListId := AddList(lSrc, 'Box');
  AddItem(lSrc, lListId, StreamIdOf(lSrc, lSrcA, 'http://x/live/a/b/1.ts'), 0, ctLive);
  AddItem(lSrc, lListId, StreamIdOf(lSrc, lSrcB, 'http://x/live/a/b/1.ts'), 0, ctLive);
  lMirrorId := AddList(lSrc, 'Copy', lListId);
  lCred.SourceId := lSrcA; // the FIRST of the two: a name-keyed import would pick the last
  lCred.Url := '';
  lCred.Username := 'a2';
  lCred.Password := 'b2';
  lSrc.SaveMirrorCredentials(lMirrorId, [lCred]);

  lDst := NewStore(FDb2);
  CloneSettings(lSrc, lDst);

  lUrlById := TDictionary<Integer, string>.Create;
  lList := FindListByName(lDst, 'Box');
  lMirror := FindListByName(lDst, 'Copy');
  try
    Assert.IsNotNull(lList);
    Assert.IsNotNull(lMirror);
    lSources := lDst.LoadSources;
    try
      Assert.AreEqual<Integer>(2, lSources.Count, 'both sources');
      for lSource in lSources do
        lUrlById.Add(lSource.Id, lSource.Url);
    finally
      FreeAndNil(lSources);
    end;
    lChannels := lDst.LoadOutputChannels(lList.Id);
    try
      Assert.AreEqual<Integer>(2, lChannels.Count, 'both channels');
      for lChannel in lChannels do
        if lChannel.Name = 'From A' then
          Assert.AreEqual('http://a', lUrlById[lChannel.SourceId], 'the channel of A on source A')
        else
          Assert.AreEqual('http://b', lUrlById[lChannel.SourceId], 'the channel of B on source B');
      Assert.AreNotEqual<Integer>(lChannels[0].SourceId, lChannels[1].SourceId);
    finally
      FreeAndNil(lChannels);
    end;
    lCreds := lDst.LoadMirrorCredentials(lMirror.Id);
    Assert.AreEqual<Integer>(1, Length(lCreds));
    Assert.AreEqual('http://a', lUrlById[lCreds[0].SourceId], 'credential on source A');
  finally
    FreeAndNil(lUrlById);
    FreeAndNil(lList);
    FreeAndNil(lMirror);
  end;
end;

procedure TSettingsIOTests.ImportMirrorOfSameNamedMaster;
var
  lSrc, lDst: IStore;
  lSrcId, lFirst, lSecond: Integer;
  lMirror: TCustomList;
  lChannels: TOutputChannelList;
begin
  lSrc := NewStore(FDb1);
  lSrcId := AddSource(lSrc, 'Prov', 'http://h');
  AddSourceStreams(lSrc, lSrcId, [TypedStream(lSrcId, ctLive, '1', 'One', 'http://h/live/a/b/1.ts'),
    TypedStream(lSrcId, ctLive, '2', 'Two', 'http://h/live/a/b/2.ts')]);
  lFirst := AddList(lSrc, 'Box');
  AddItem(lSrc, lFirst, StreamIdOf(lSrc, lSrcId, 'http://h/live/a/b/1.ts'), 0, ctLive);
  lSecond := AddList(lSrc, 'Box');
  AddItem(lSrc, lSecond, StreamIdOf(lSrc, lSrcId, 'http://h/live/a/b/2.ts'), 0, ctLive);
  // the mirror of the FIRST 'Box': a name-keyed import would pick the last one
  AddList(lSrc, 'Mirror', lFirst);

  lDst := NewStore(FDb2);
  CloneSettings(lSrc, lDst);

  lMirror := FindListByName(lDst, 'Mirror');
  try
    Assert.IsNotNull(lMirror);
    Assert.AreNotEqual<Integer>(0, lMirror.MirrorOfListId, 'still a mirror');
    lChannels := lDst.LoadOutputChannels(lMirror.Id);
    try
      Assert.AreEqual<Integer>(1, lChannels.Count);
      Assert.AreEqual('One', lChannels[0].Name, 'mirrors its own master');
    finally
      FreeAndNil(lChannels);
    end;
  finally
    FreeAndNil(lMirror);
  end;
end;

procedure TSettingsIOTests.ImportReportsListIdMap;
const
  cUnknownBundleId = 9999;
var
  lSrc, lDst: IStore;
  lSrcId, lFirst, lSecond, lMirrorId: Integer;
  lBundle: TJSONObject;
  lCounts: TImportCounts;
  lChannels: TOutputChannelList;
  lMirror: TCustomList;
begin
  lSrc := NewStore(FDb1);
  lSrcId := AddSource(lSrc, 'Prov', 'http://h');
  AddSourceStreams(lSrc, lSrcId, [TypedStream(lSrcId, ctLive, '1', 'One', 'http://h/live/a/b/1.ts'),
    TypedStream(lSrcId, ctLive, '2', 'Two', 'http://h/live/a/b/2.ts')]);
  lFirst := AddList(lSrc, 'Box');
  AddItem(lSrc, lFirst, StreamIdOf(lSrc, lSrcId, 'http://h/live/a/b/1.ts'), 0, ctLive);
  lSecond := AddList(lSrc, 'Box');
  AddItem(lSrc, lSecond, StreamIdOf(lSrc, lSrcId, 'http://h/live/a/b/2.ts'), 0, ctLive);
  lMirrorId := AddList(lSrc, 'Mirror', lFirst);

  lDst := NewStore(FDb2);
  lBundle := ExportStoreSettings(lSrc);
  try
    lCounts := ImportStoreSettings(lDst, lBundle);
  finally
    FreeAndNil(lBundle);
  end;
  Assert.AreEqual<Integer>(3, Length(lCounts.ListIds), 'every list, the mirror too');
  // the SECOND 'Box' by its bundle id (a name lookup would hit the first one)
  lChannels := lDst.LoadOutputChannels(lCounts.NewListId(lSecond));
  try
    Assert.AreEqual<Integer>(1, lChannels.Count);
    Assert.AreEqual('Two', lChannels[0].Name, 'the second Box');
  finally
    FreeAndNil(lChannels);
  end;
  lMirror := FindListByName(lDst, 'Mirror');
  try
    Assert.IsNotNull(lMirror);
    Assert.AreEqual(lMirror.Id, lCounts.NewListId(lMirrorId), 'the mirror is mapped too');
  finally
    FreeAndNil(lMirror);
  end;
  Assert.AreEqual(0, lCounts.NewListId(cUnknownBundleId), 'unknown bundle id');
  Assert.AreEqual(0, lCounts.NewListId(0), 'no bundle id');
end;

procedure TSettingsIOTests.ImportOldBundleMatchesByName;
var
  lSrc, lDst: IStore;
  lSrcId, lListId: Integer;
  lList: TCustomList;
  lChannels: TOutputChannelList;
begin
  lSrc := NewStore(FDb1);
  lSrcId := AddSource(lSrc, 'Prov', 'http://h');
  AddSourceStreams(lSrc, lSrcId, [TypedStream(lSrcId, ctLive, '1', 'One', 'http://h/live/a/b/1.ts')]);
  lListId := AddList(lSrc, 'Box');
  AddItem(lSrc, lListId, StreamIdOf(lSrc, lSrcId, 'http://h/live/a/b/1.ts'),
    AddGroup(lSrc, lListId, 'Sport', ctLive), ctLive);

  lDst := NewStore(FDb2);
  CloneSettings(lSrc, lDst, True);

  lList := FindListByName(lDst, 'Box');
  try
    Assert.IsNotNull(lList);
    lChannels := lDst.LoadOutputChannels(lList.Id);
    try
      Assert.AreEqual<Integer>(1, lChannels.Count, 'channel resolved by source name');
      Assert.AreEqual('Sport', lChannels[0].GroupName, 'group by name');
    finally
      FreeAndNil(lChannels);
    end;
  finally
    FreeAndNil(lList);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSettingsIOTests);

end.
