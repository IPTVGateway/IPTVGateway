unit Test.SettingsIO;

{ Round-trip test for the portable settings bundle (IPTV.Api.SettingsIO):
  build a curated setup in one store, export it, import into a FRESH store, and
  assert the clone is 1:1 — sources, lists, groups AND the chosen channels (with
  their renames, channel numbers and group placement) all come back, with the
  catalog rows recreated so the items resolve without a refresh. }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TSettingsIOTests = class
  private
    FDb1, FDb2: string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure ExportImportClonesEverything;
    [Test] procedure ImportPreservesManualGroupOrder;
    [Test] procedure ConfigLoadToleratesBadTypesAndRanges;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.JSON,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.CustomList,
  IPTV.Storage.Intf, IPTV.Storage.SQLite, IPTV.Api.SettingsIO, IPTV.App.Config;

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

  procedure Del(const P: string);
  begin
    if TFile.Exists(P) then TFile.Delete(P);
    if TFile.Exists(P + '-wal') then TFile.Delete(P + '-wal');
    if TFile.Exists(P + '-shm') then TFile.Delete(P + '-shm');
  end;

begin
  Del(FDb1);
  Del(FDb2);
end;

procedure TSettingsIOTests.ExportImportClonesEverything;
var
  Src: IStore;
  Dst: IStore;
  Cfg: TSourceConfig;
  Snap: TSourceSnapshot;
  Lst: TCustomList;
  Grp: TCustomGroup;
  Item: TCustomItem;
  Bundle: TJSONObject;
  SrcId, ListId, GrpId, S1, S2: Integer;
  F: TCatalogFilter;
begin
  // ── build the original setup ───────────────────────────────────────────
  Src := NewStore(FDb1);
  Cfg := TSourceConfig.Create;
  try
    Cfg.Name := 'Prov'; Cfg.Kind := skXtream; Cfg.Url := 'http://h';
    Cfg.StripPrefixes := ['NL'];
    SrcId := Src.SaveSource(Cfg);
  finally
    Cfg.Free;
  end;

  Snap := TSourceSnapshot.Create(SrcId);
  Snap.Streams.Add(MakeStream(SrcId, 'u1', 'NPO 1 HD', 'NL', 'tv1', 'http://p/1.ts'));
  Snap.Streams.Add(MakeStream(SrcId, 'u2', 'BBC One', 'UK', 'tv2', 'http://p/2.ts'));
  Src.MergeSnapshot(Snap);
  Snap.Free;

  Lst := TCustomList.Create;
  try
    Lst.Name := 'Box'; Lst.OutputUsername := 'u'; Lst.OutputPassword := 'p';
    ListId := Src.SaveList(Lst);
  finally
    Lst.Free;
  end;

  Grp := TCustomGroup.Create;
  try
    Grp.ListId := ListId; Grp.Name := 'Sport'; Grp.ContentType := ctLive; Grp.IsFavorite := True;
    GrpId := Src.SaveGroup(Grp);
  finally
    Grp.Free;
  end;

  S1 := -1; S2 := -1;
  F := Default(TCatalogFilter);
  var Streams := Src.LoadStreams(F);
  try
    for var I := 0 to Streams.Count - 1 do
      if Streams[I].Name.Contains('NPO') then S1 := Streams[I].Id else S2 := Streams[I].Id;
  finally
    Streams.Free;
  end;

  // item 1: renamed + numbered + in the favorite group; item 2: plain
  Item := TCustomItem.Create;
  try
    Item.ListId := ListId; Item.StreamItemId := S1; Item.CustomGroupId := GrpId;
    Item.ContentType := ctLive; Item.DisplayName := 'NPO Een'; Item.ChannelNumber := 5;
    Src.SaveItem(Item);
  finally
    Item.Free;
  end;
  Item := TCustomItem.Create;
  try
    Item.ListId := ListId; Item.StreamItemId := S2; Item.ContentType := ctLive;
    Src.SaveItem(Item);
  finally
    Item.Free;
  end;

  // ── export, then import into a fresh store ──────────────────────────────
  Dst := NewStore(FDb2);
  Bundle := ExportStoreSettings(Src);
  try
    var Counts := ImportStoreSettings(Dst, Bundle);
    Assert.AreEqual<Integer>(1, Counts.Sources, 'source recreated');
    Assert.AreEqual<Integer>(1, Counts.Lists, 'list recreated');
    Assert.AreEqual<Integer>(1, Counts.Groups, 'group recreated');
    Assert.AreEqual<Integer>(2, Counts.Items, 'both channels recreated');
  finally
    Bundle.Free;
  end;

  // ── assert the clone is faithful ────────────────────────────────────────
  var Srcs := Dst.LoadSources;
  try
    Assert.AreEqual<Integer>(1, Srcs.Count);
    Assert.AreEqual('Prov', Srcs[0].Name);
    Assert.AreEqual<Integer>(1, Length(Srcs[0].StripPrefixes), 'source config (strip prefixes) cloned');
  finally
    Srcs.Free;
  end;

  var NewListId := -1;
  var Lists := Dst.LoadLists;
  try
    Assert.AreEqual<Integer>(1, Lists.Count);
    Assert.AreEqual('Box', Lists[0].Name);
    NewListId := Lists[0].Id;
  finally
    Lists.Free;
  end;

  // the resolved output proves: streams recreated, items linked by URL, rename,
  // channel number and favorite-group placement all survived the round-trip
  var Channels := Dst.LoadOutputChannels(NewListId);
  try
    Assert.AreEqual<Integer>(2, Channels.Count, 'both channels resolve in the clone');
    var FoundNpo := False;
    for var I := 0 to Channels.Count - 1 do
      if Channels[I].UpstreamUrl = 'http://p/1.ts' then
      begin
        FoundNpo := True;
        Assert.AreEqual('NPO Een', Channels[I].Name, 'rename cloned');
        Assert.AreEqual<Integer>(5, Channels[I].Number, 'channel number cloned');
        Assert.AreEqual('Sport', Channels[I].GroupName, 'group placement cloned');
        Assert.IsTrue(Channels[I].IsFavoriteGroup, 'favorite-group flag cloned');
      end;
    Assert.IsTrue(FoundNpo, 'the renamed channel is present by its upstream URL');
  finally
    Channels.Free;
  end;
end;

// The operator's manual group drag-order (sort_order) must survive export->import.
// Groups are created with three non-alphabetical names and reordered; after a
// round-trip the clone must list them in that SAME order, not back to A->Z.
procedure TSettingsIOTests.ImportPreservesManualGroupOrder;
var
  Src, Dst: IStore;
  Lst: TCustomList;
  Grp: TCustomGroup;
  ListId, GAlpha, GBeta, GGamma: Integer;
  Bundle: TJSONObject;
begin
  Src := NewStore(FDb1);
  Lst := TCustomList.Create;
  try Lst.Name := 'Box'; ListId := Src.SaveList(Lst); finally Lst.Free; end;

  // create in alphabetical order, then reorder to Gamma, Alpha, Beta
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'Alpha'; Grp.ContentType := ctLive; GAlpha := Src.SaveGroup(Grp); finally Grp.Free; end;
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'Beta'; Grp.ContentType := ctLive; GBeta := Src.SaveGroup(Grp); finally Grp.Free; end;
  Grp := TCustomGroup.Create;
  try Grp.ListId := ListId; Grp.Name := 'Gamma'; Grp.ContentType := ctLive; GGamma := Src.SaveGroup(Grp); finally Grp.Free; end;
  Src.ReorderGroups(ListId, [GGamma, GAlpha, GBeta]);

  Dst := NewStore(FDb2);
  Bundle := ExportStoreSettings(Src);
  try
    ImportStoreSettings(Dst, Bundle);
  finally
    Bundle.Free;
  end;

  var NewListId := -1;
  var Lists := Dst.LoadLists;
  try NewListId := Lists[0].Id; finally Lists.Free; end;

  var Groups := Dst.LoadGroups(NewListId);
  try
    Assert.AreEqual<Integer>(3, Groups.Count, 'all groups cloned');
    Assert.AreEqual('Gamma', Groups[0].Name, 'manual order preserved (1st)');
    Assert.AreEqual('Alpha', Groups[1].Name, 'manual order preserved (2nd)');
    Assert.AreEqual('Beta',  Groups[2].Name, 'manual order preserved (3rd)');
  finally
    Groups.Free;
  end;
end;

// A hand-edited config.json with wrong-typed or out-of-range fields must NOT crash
// startup — it should fall back to defaults / clamp, per the file's documented contract.
procedure TSettingsIOTests.ConfigLoadToleratesBadTypesAndRanges;
var
  Path: string;
  Cfg: TAppConfig;
begin
  Path := TPath.Combine(TPath.GetTempPath, 'iptvcfg_' + TGUID.NewGuid.ToString + '.json');
  TFile.WriteAllText(Path,
    '{"httpPort":"not-a-number","refreshHour":70000,"refreshMinute":-5,' +
    '"proxyPort":0,"useHttps":"yes","plexTunerCount":-3,"epgMaxDays":-1}');
  try
    Cfg := TAppConfig.Load(Path); // must not raise
    Assert.AreEqual<Integer>(7777, Cfg.HttpPort, 'string httpPort -> default (no crash)');
    Assert.AreEqual<Integer>(23, Cfg.RefreshHour, 'hour 70000 clamped to 23');
    Assert.AreEqual<Integer>(0, Cfg.RefreshMinute, 'minute -5 clamped to 0');
    Assert.AreEqual<Integer>(1, Cfg.ProxyPort, 'port 0 clamped to 1');
    Assert.IsFalse(Cfg.UseHttps, 'non-bool useHttps -> default false');
    Assert.AreEqual<Integer>(1, Cfg.PlexTunerCount, 'tuner count -3 clamped to 1');
    Assert.AreEqual<Integer>(0, Cfg.EpgMaxDays, 'epgMaxDays -1 clamped to 0');
  finally
    TFile.Delete(Path);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TSettingsIOTests);

end.
