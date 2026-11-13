unit Test.Config;

{ TAppConfig save/load round-trip — focus on the Plex Live TV fields (each tuner
  surface on/off + its own proxy choice + tuner count + device id). }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>TAppConfig save/load round-trip and daemon config-path tests.</summary>
  [TestFixture]
  TConfigTests = class
  private
    FPath: string;
  public
    /// <summary>Picks a fresh temp config path.</summary>
    [Setup] procedure Setup;
    /// <summary>Deletes the temp config file.</summary>
    [TearDown] procedure TearDown;
    /// <summary>The Plex fields survive a save/load.</summary>
    [Test] procedure PlexFieldsRoundtrip;
    /// <summary>The Plex surfaces are off by default.</summary>
    [Test] procedure PlexDefaultsAreOff;
    /// <summary>The media/dummy-EPG fields survive a save/load.</summary>
    [Test] procedure MediaFieldsRoundtrip;
    /// <summary>The media/dummy-EPG defaults.</summary>
    [Test] procedure MediaDefaults;
    /// <summary>IPTV_CONFIG moves config.json into the data folder.</summary>
    [Test] procedure DaemonConfigPathInDataFolder;
    /// <summary>An ADMIN_PASSWORD from the environment is never saved.</summary>
    [Test] procedure EnvAdminPasswordIsNotSaved;
    /// <summary>An unparsable config is kept as a backup.</summary>
    [Test] procedure CorruptConfigIsKeptAsBackup;
    /// <summary>A leftover config.json.tmp is recovered.</summary>
    [Test] procedure InterruptedSaveIsRecovered;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.IOUtils,
  Winapi.Windows,
  // own units
  IPTV.App.Config;

procedure TConfigTests.Setup;
begin
  FPath := TPath.Combine(TPath.GetTempPath, 'iptvcfg_' + TGUID.NewGuid.ToString + '.json');
end;

procedure TConfigTests.TearDown;
begin
  if TFile.Exists(FPath) then
    TFile.Delete(FPath);
end;

procedure TConfigTests.PlexDefaultsAreOff;
var
  lConfig: TAppConfig;
begin
  lConfig := TAppConfig.Default;
  Assert.IsFalse(lConfig.PlexM3uEnabled, 'M3U tuner off by default');
  Assert.IsFalse(lConfig.PlexHdhrEnabled, 'HDHomeRun off by default');
  Assert.AreEqual<Integer>(4, lConfig.PlexTunerCount, 'default tuner count');
  Assert.AreEqual<Integer>(7, lConfig.EpgMaxDays, 'default EPG cap is 7 days');
end;

procedure TConfigTests.PlexFieldsRoundtrip;
var
  lConfig: TAppConfig;
  lLoaded: TAppConfig;
begin
  lConfig := TAppConfig.Default;
  lConfig.PlexM3uEnabled := True;
  lConfig.PlexM3uProxy := False;
  lConfig.PlexHdhrEnabled := True;
  lConfig.PlexHdhrProxy := True;
  lConfig.PlexTunerCount := 6;
  lConfig.PlexDeviceId := 'ABCD1234';
  lConfig.PlexServerUrl := 'http://192.168.1.10:32400';
  lConfig.PlexToken := 'tok-xyz';
  lConfig.EpgMaxDays := 3;
  lConfig.Save(FPath);

  lLoaded := TAppConfig.Load(FPath);
  Assert.IsTrue(lLoaded.PlexM3uEnabled, 'M3U enabled round-trips');
  Assert.IsFalse(lLoaded.PlexM3uProxy, 'M3U proxy off round-trips');
  Assert.IsTrue(lLoaded.PlexHdhrEnabled, 'HDHR enabled round-trips');
  Assert.IsTrue(lLoaded.PlexHdhrProxy, 'HDHR proxy on round-trips');
  Assert.AreEqual<Integer>(6, lLoaded.PlexTunerCount, 'tuner count round-trips');
  Assert.AreEqual('ABCD1234', lLoaded.PlexDeviceId, 'device id round-trips');
  Assert.AreEqual('http://192.168.1.10:32400', lLoaded.PlexServerUrl, 'plex server url round-trips');
  Assert.AreEqual('tok-xyz', lLoaded.PlexToken, 'plex token round-trips');
  Assert.AreEqual<Integer>(3, lLoaded.EpgMaxDays, 'EPG max days round-trips');
end;

procedure TConfigTests.MediaDefaults;
var
  lConfig: TAppConfig;
begin
  lConfig := TAppConfig.Default;
  Assert.AreEqual<Integer>(0, Length(lConfig.VisibleGroups), 'no group filter by default (all published)');
  Assert.IsFalse(lConfig.NameShowGroup, 'group-in-name off by default');
  Assert.IsFalse(lConfig.NameShowNumber, 'number-in-name off by default');
  Assert.IsTrue(lConfig.DummyEpgEnabled, 'dummy EPG on by default');
  Assert.AreEqual<Integer>(120, lConfig.DummyEpgBlockMinutes, 'default dummy block length');
  Assert.AreEqual<Integer>(12, lConfig.DummyEpgHoursBack, 'default dummy window back');
  Assert.AreEqual<Integer>(48, lConfig.DummyEpgHoursAhead, 'default dummy window ahead');
end;

procedure TConfigTests.MediaFieldsRoundtrip;
var
  lConfig: TAppConfig;
  lLoaded: TAppConfig;
begin
  lConfig := TAppConfig.Default;
  lConfig.VisibleGroups := ['Sport', 'Nederland', 'News HD'];
  lConfig.PublicBaseUrl := 'http://192.168.1.50:7777';
  lConfig.DummyEpgEnabled := False;
  lConfig.DummyEpgBlockMinutes := 60;
  lConfig.DummyEpgHoursBack := 6;
  lConfig.DummyEpgHoursAhead := 24;
  lConfig.NameShowGroup := True;
  lConfig.NameShowNumber := True;
  lConfig.Save(FPath);

  lLoaded := TAppConfig.Load(FPath);
  Assert.IsTrue(lLoaded.NameShowGroup, 'name-show-group round-trips');
  Assert.IsTrue(lLoaded.NameShowNumber, 'name-show-number round-trips');
  Assert.AreEqual<Integer>(3, Length(lLoaded.VisibleGroups), 'group filter count round-trips');
  Assert.AreEqual('Sport', lLoaded.VisibleGroups[0], 'first group round-trips');
  Assert.AreEqual('News HD', lLoaded.VisibleGroups[2], 'group with a space round-trips');
  Assert.AreEqual('http://192.168.1.50:7777', lLoaded.PublicBaseUrl, 'base URL round-trips');
  Assert.IsFalse(lLoaded.DummyEpgEnabled, 'dummy toggle round-trips');
  Assert.AreEqual<Integer>(60, lLoaded.DummyEpgBlockMinutes, 'dummy block round-trips');
  Assert.AreEqual<Integer>(6, lLoaded.DummyEpgHoursBack, 'dummy back round-trips');
  Assert.AreEqual<Integer>(24, lLoaded.DummyEpgHoursAhead, 'dummy ahead round-trips');
end;

// IPTV_CONFIG (set by the Docker image) moves config.json into the data folder:
// created from an older config.json next to the exe (migration), else defaults;
// an existing file is left alone; without the variable nothing changes.
procedure TConfigTests.DaemonConfigPathInDataFolder;
var
  lRoot: string;
  lExeDir: string;
  lDataCfg: string;
  lNote: string;
  lPath: string;
  lConfig: TAppConfig;
begin
  lRoot := TPath.Combine(TPath.GetTempPath, 'iptvcfg_' + TGUID.NewGuid.ToString);
  lExeDir := TPath.Combine(lRoot, 'exe');
  lDataCfg := TPath.Combine(TPath.Combine(lRoot, 'data'), 'config.json');
  ForceDirectories(lExeDir);
  try
    // no variable -> next to the exe, as before
    SetEnvironmentVariable('IPTV_CONFIG', nil);
    Assert.AreEqual(TPath.Combine(lExeDir, 'config.json'), ResolveDaemonConfigPath(lExeDir, lNote));
    Assert.AreEqual('', lNote);

    SetEnvironmentVariable('IPTV_CONFIG', PChar(lDataCfg));
    // older install: a real config.json next to the exe is migrated (copied)
    lConfig := TAppConfig.Default;
    lConfig.HttpPort := 9000;
    lConfig.Save(TPath.Combine(lExeDir, 'config.json'));
    lPath := ResolveDaemonConfigPath(lExeDir, lNote);
    Assert.AreEqual(lDataCfg, lPath);
    Assert.IsTrue(TFile.Exists(lDataCfg), 'created in the data folder (folder made too)');
    Assert.Contains(lNote, 'created');
    Assert.AreEqual(9000, TAppConfig.Load(lPath).HttpPort, 'migrated, not defaults');

    // an existing data-folder config is never overwritten
    lConfig.HttpPort := 7777;
    lConfig.Save(TPath.Combine(lExeDir, 'config.json'));
    ResolveDaemonConfigPath(lExeDir, lNote);
    Assert.AreEqual('', lNote);
    Assert.AreEqual(9000, TAppConfig.Load(lDataCfg).HttpPort);

    // fresh install where Docker made 'config.json' a DIRECTORY -> defaults
    TFile.Delete(lDataCfg);
    TFile.Delete(TPath.Combine(lExeDir, 'config.json'));
    ForceDirectories(TPath.Combine(lExeDir, 'config.json'));
    ResolveDaemonConfigPath(lExeDir, lNote);
    Assert.Contains(lNote, 'defaults');
    Assert.AreEqual(TAppConfig.Default.HttpPort, TAppConfig.Load(lDataCfg).HttpPort);
  finally
    SetEnvironmentVariable('IPTV_CONFIG', nil);
    TDirectory.Delete(lRoot, True);
  end;
end;

// ADMIN_PASSWORD from the environment overrides the file's password at runtime,
// but a settings save must write the FILE's value, never the env secret.
procedure TConfigTests.EnvAdminPasswordIsNotSaved;
var
  lPath: string;
  lConfig: TAppConfig;
begin
  lPath := TPath.Combine(TPath.GetTempPath, 'iptvcfg_' + TGUID.NewGuid.ToString + '.json');
  try
    lConfig := TAppConfig.Default;
    lConfig.AdminPasswordFile := 'filepw';
    lConfig.Save(lPath);
    SetEnvironmentVariable('ADMIN_PASSWORD', 'envpw');
    try
      lConfig := TAppConfig.Load(lPath);
      Assert.AreEqual('envpw', lConfig.AdminPassword, 'env wins at runtime');
      Assert.AreEqual('filepw', lConfig.AdminPasswordFile);
      lConfig.Save(lPath);
    finally
      SetEnvironmentVariable('ADMIN_PASSWORD', nil);
    end;
    lConfig := TAppConfig.Load(lPath);
    Assert.AreEqual('filepw', lConfig.AdminPassword, 'the env secret was not written to the file');
    Assert.IsFalse(TFile.Exists(lPath + '.tmp'), 'no temp file left behind');
  finally
    if TFile.Exists(lPath) then
      TFile.Delete(lPath);
  end;
end;

// A config.json that doesn't parse is kept as a backup and reported, instead of
// being silently replaced by defaults on the next save.
procedure TConfigTests.CorruptConfigIsKeptAsBackup;
var
  lDir: string;
  lPath: string;
  lConfig: TAppConfig;
begin
  lDir := TPath.Combine(TPath.GetTempPath, 'iptvcfgc_' + TGUID.NewGuid.ToString);
  ForceDirectories(lDir);
  lPath := TPath.Combine(lDir, 'config.json');
  try
    TFile.WriteAllText(lPath, '{"httpPort": 9000, "adminPassword": "x"');  // truncated
    lConfig := TAppConfig.Load(lPath);
    Assert.AreNotEqual('', lConfig.LoadWarning, 'reported');
    Assert.AreEqual(TAppConfig.Default.HttpPort, lConfig.HttpPort, 'runs with defaults');
    Assert.AreEqual<Integer>(1, Length(TDirectory.GetFiles(lDir, 'config.json.corrupt-*')), 'backup made');
  finally
    TDirectory.Delete(lDir, True);
  end;
end;

// only config.json.tmp left (a save cut off between delete and move in older
// versions): Load takes it instead of starting on defaults
procedure TConfigTests.InterruptedSaveIsRecovered;
var
  lDir: string;
  lPath: string;
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
