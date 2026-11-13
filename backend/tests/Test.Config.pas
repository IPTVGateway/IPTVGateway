unit Test.Config;

{ TAppConfig save/load round-trip — focus on the Plex Live TV fields (each tuner
  surface on/off + its own proxy choice + tuner count + device id). }

interface

uses
  DUnitX.TestFramework;

type
  [TestFixture]
  TConfigTests = class
  private
    FPath: string;
  public
    [Setup] procedure Setup;
    [TearDown] procedure TearDown;
    [Test] procedure PlexFieldsRoundtrip;
    [Test] procedure PlexDefaultsAreOff;
    [Test] procedure MediaFieldsRoundtrip;
    [Test] procedure MediaDefaults;
    [Test] procedure DaemonConfigPathInDataFolder;
    [Test] procedure EnvAdminPasswordIsNotSaved;
    [Test] procedure CorruptConfigIsKeptAsBackup;
    [Test] procedure InterruptedSaveIsRecovered;
  end;

implementation

uses
  System.SysUtils, System.IOUtils, Winapi.Windows,
  IPTV.App.Config;

procedure TConfigTests.Setup;
begin
  FPath := TPath.Combine(TPath.GetTempPath, 'iptvcfg_' + TGUID.NewGuid.ToString + '.json');
end;

procedure TConfigTests.TearDown;
begin
  if TFile.Exists(FPath) then TFile.Delete(FPath);
end;

procedure TConfigTests.PlexDefaultsAreOff;
var
  C: TAppConfig;
begin
  C := TAppConfig.Default;
  Assert.IsFalse(C.PlexM3uEnabled, 'M3U tuner off by default');
  Assert.IsFalse(C.PlexHdhrEnabled, 'HDHomeRun off by default');
  Assert.AreEqual<Integer>(4, C.PlexTunerCount, 'default tuner count');
  Assert.AreEqual<Integer>(7, C.EpgMaxDays, 'default EPG cap is 7 days');
end;

procedure TConfigTests.PlexFieldsRoundtrip;
var
  C, L: TAppConfig;
begin
  C := TAppConfig.Default;
  C.PlexM3uEnabled := True;
  C.PlexM3uProxy := False;
  C.PlexHdhrEnabled := True;
  C.PlexHdhrProxy := True;
  C.PlexTunerCount := 6;
  C.PlexDeviceId := 'ABCD1234';
  C.PlexServerUrl := 'http://192.168.1.10:32400';
  C.PlexToken := 'tok-xyz';
  C.EpgMaxDays := 3;
  C.Save(FPath);

  L := TAppConfig.Load(FPath);
  Assert.IsTrue(L.PlexM3uEnabled, 'M3U enabled round-trips');
  Assert.IsFalse(L.PlexM3uProxy, 'M3U proxy off round-trips');
  Assert.IsTrue(L.PlexHdhrEnabled, 'HDHR enabled round-trips');
  Assert.IsTrue(L.PlexHdhrProxy, 'HDHR proxy on round-trips');
  Assert.AreEqual<Integer>(6, L.PlexTunerCount, 'tuner count round-trips');
  Assert.AreEqual('ABCD1234', L.PlexDeviceId, 'device id round-trips');
  Assert.AreEqual('http://192.168.1.10:32400', L.PlexServerUrl, 'plex server url round-trips');
  Assert.AreEqual('tok-xyz', L.PlexToken, 'plex token round-trips');
  Assert.AreEqual<Integer>(3, L.EpgMaxDays, 'EPG max days round-trips');
end;

procedure TConfigTests.MediaDefaults;
var
  C: TAppConfig;
begin
  C := TAppConfig.Default;
  Assert.AreEqual<Integer>(0, Length(C.VisibleGroups), 'no group filter by default (all published)');
  Assert.IsFalse(C.NameShowGroup, 'group-in-name off by default');
  Assert.IsFalse(C.NameShowNumber, 'number-in-name off by default');
  Assert.IsTrue(C.DummyEpgEnabled, 'dummy EPG on by default');
  Assert.AreEqual<Integer>(120, C.DummyEpgBlockMinutes, 'default dummy block length');
  Assert.AreEqual<Integer>(12, C.DummyEpgHoursBack, 'default dummy window back');
  Assert.AreEqual<Integer>(48, C.DummyEpgHoursAhead, 'default dummy window ahead');
end;

procedure TConfigTests.MediaFieldsRoundtrip;
var
  C, L: TAppConfig;
begin
  C := TAppConfig.Default;
  C.VisibleGroups := ['Sport', 'Nederland', 'News HD'];
  C.PublicBaseUrl := 'http://192.168.1.50:7777';
  C.DummyEpgEnabled := False;
  C.DummyEpgBlockMinutes := 60;
  C.DummyEpgHoursBack := 6;
  C.DummyEpgHoursAhead := 24;
  C.NameShowGroup := True;
  C.NameShowNumber := True;
  C.Save(FPath);

  L := TAppConfig.Load(FPath);
  Assert.IsTrue(L.NameShowGroup, 'name-show-group round-trips');
  Assert.IsTrue(L.NameShowNumber, 'name-show-number round-trips');
  Assert.AreEqual<Integer>(3, Length(L.VisibleGroups), 'group filter count round-trips');
  Assert.AreEqual('Sport', L.VisibleGroups[0], 'first group round-trips');
  Assert.AreEqual('News HD', L.VisibleGroups[2], 'group with a space round-trips');
  Assert.AreEqual('http://192.168.1.50:7777', L.PublicBaseUrl, 'base URL round-trips');
  Assert.IsFalse(L.DummyEpgEnabled, 'dummy toggle round-trips');
  Assert.AreEqual<Integer>(60, L.DummyEpgBlockMinutes, 'dummy block round-trips');
  Assert.AreEqual<Integer>(6, L.DummyEpgHoursBack, 'dummy back round-trips');
  Assert.AreEqual<Integer>(24, L.DummyEpgHoursAhead, 'dummy ahead round-trips');
end;

// IPTV_CONFIG (set by the Docker image) moves config.json into the data folder:
// created from an older config.json next to the exe (migration), else defaults;
// an existing file is left alone; without the variable nothing changes.
procedure TConfigTests.DaemonConfigPathInDataFolder;
var
  Root, ExeDir, DataCfg, Note, P: string;
  C: TAppConfig;
begin
  Root := TPath.Combine(TPath.GetTempPath, 'iptvcfg_' + TGUID.NewGuid.ToString);
  ExeDir := TPath.Combine(Root, 'exe');
  DataCfg := TPath.Combine(TPath.Combine(Root, 'data'), 'config.json');
  ForceDirectories(ExeDir);
  try
    // no variable -> next to the exe, as before
    SetEnvironmentVariable('IPTV_CONFIG', nil);
    Assert.AreEqual(TPath.Combine(ExeDir, 'config.json'), ResolveDaemonConfigPath(ExeDir, Note));
    Assert.AreEqual('', Note);

    SetEnvironmentVariable('IPTV_CONFIG', PChar(DataCfg));
    // older install: a real config.json next to the exe is migrated (copied)
    C := TAppConfig.Default;
    C.HttpPort := 9000;
    C.Save(TPath.Combine(ExeDir, 'config.json'));
    P := ResolveDaemonConfigPath(ExeDir, Note);
    Assert.AreEqual(DataCfg, P);
    Assert.IsTrue(TFile.Exists(DataCfg), 'created in the data folder (folder made too)');
    Assert.Contains(Note, 'created');
    Assert.AreEqual(9000, TAppConfig.Load(P).HttpPort, 'migrated, not defaults');

    // an existing data-folder config is never overwritten
    C.HttpPort := 7777;
    C.Save(TPath.Combine(ExeDir, 'config.json'));
    ResolveDaemonConfigPath(ExeDir, Note);
    Assert.AreEqual('', Note);
    Assert.AreEqual(9000, TAppConfig.Load(DataCfg).HttpPort);

    // fresh install where Docker made 'config.json' a DIRECTORY -> defaults
    TFile.Delete(DataCfg);
    TFile.Delete(TPath.Combine(ExeDir, 'config.json'));
    ForceDirectories(TPath.Combine(ExeDir, 'config.json'));
    ResolveDaemonConfigPath(ExeDir, Note);
    Assert.Contains(Note, 'defaults');
    Assert.AreEqual(TAppConfig.Default.HttpPort, TAppConfig.Load(DataCfg).HttpPort);
  finally
    SetEnvironmentVariable('IPTV_CONFIG', nil);
    TDirectory.Delete(Root, True);
  end;
end;

// ADMIN_PASSWORD from the environment overrides the file's password at runtime,
// but a settings save must write the FILE's value, never the env secret.
procedure TConfigTests.EnvAdminPasswordIsNotSaved;
var
  P: string;
  C: TAppConfig;
begin
  P := TPath.Combine(TPath.GetTempPath, 'iptvcfg_' + TGUID.NewGuid.ToString + '.json');
  try
    C := TAppConfig.Default;
    C.AdminPasswordFile := 'filepw';
    C.Save(P);
    SetEnvironmentVariable('ADMIN_PASSWORD', 'envpw');
    try
      C := TAppConfig.Load(P);
      Assert.AreEqual('envpw', C.AdminPassword, 'env wins at runtime');
      Assert.AreEqual('filepw', C.AdminPasswordFile);
      C.Save(P);
    finally
      SetEnvironmentVariable('ADMIN_PASSWORD', nil);
    end;
    C := TAppConfig.Load(P);
    Assert.AreEqual('filepw', C.AdminPassword, 'the env secret was not written to the file');
    Assert.IsFalse(TFile.Exists(P + '.tmp'), 'no temp file left behind');
  finally
    if TFile.Exists(P) then TFile.Delete(P);
  end;
end;

// A config.json that doesn't parse is kept as a backup and reported, instead of
// being silently replaced by defaults on the next save.
procedure TConfigTests.CorruptConfigIsKeptAsBackup;
var
  Dir, P: string;
  C: TAppConfig;
begin
  Dir := TPath.Combine(TPath.GetTempPath, 'iptvcfgc_' + TGUID.NewGuid.ToString);
  ForceDirectories(Dir);
  P := TPath.Combine(Dir, 'config.json');
  try
    TFile.WriteAllText(P, '{"httpPort": 9000, "adminPassword": "x"');  // truncated
    C := TAppConfig.Load(P);
    Assert.AreNotEqual('', C.LoadWarning, 'reported');
    Assert.AreEqual(TAppConfig.Default.HttpPort, C.HttpPort, 'runs with defaults');
    Assert.AreEqual<Integer>(1, Length(TDirectory.GetFiles(Dir, 'config.json.corrupt-*')), 'backup made');
  finally
    TDirectory.Delete(Dir, True);
  end;
end;

// only config.json.tmp left (a save cut off between delete and move in older
// versions): Load takes it instead of starting on defaults
procedure TConfigTests.InterruptedSaveIsRecovered;
var
  lDir, lPath: string;
  lCfg: TAppConfig;
begin
  lDir := TPath.Combine(TPath.GetTempPath, 'iptvcfgr_' + TGUID.NewGuid.ToString);
  ForceDirectories(lDir);
  lPath := TPath.Combine(lDir, 'config.json');
  try
    TFile.WriteAllText(lPath + '.tmp', '{"httpPort": 9123}');
    lCfg := TAppConfig.Load(lPath);
    Assert.AreEqual(9123, lCfg.HttpPort);
    Assert.IsTrue(TFile.Exists(lPath), 'swapped into place');
    Assert.IsFalse(TFile.Exists(lPath + '.tmp'));
  finally
    TDirectory.Delete(lDir, True);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TConfigTests);

end.
