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
    /// <summary>A config.json with bad types/ranges loads with defaults/clamps.</summary>
    [Test] procedure ConfigLoadToleratesBadTypesAndRanges;
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

initialization
  TDUnitX.RegisterTestFixture(TSettingsIOTests);

end.
