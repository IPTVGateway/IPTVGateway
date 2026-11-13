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
  end;

implementation

uses
  System.SysUtils, System.IOUtils,
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

initialization
  TDUnitX.RegisterTestFixture(TConfigTests);

end.
