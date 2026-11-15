unit Test.UpdateCheck;

{ Tests for IPTV.App.UpdateCheck: version compare / validation, the version.json
  parser, the due rule, and the checker thread with a fake fetch + state store. }

interface

uses
  // third-party
  DUnitX.TestFramework;

type
  /// <summary>Tests for IPTV.App.UpdateCheck.</summary>
  [TestFixture]
  TUpdateCheckTests = class
  public
    /// <summary>Numeric per part: 1.2.10 is newer than 1.2.9; missing parts are 0.</summary>
    [Test] procedure Compare_Numeric;
    /// <summary>Only 1-4 numeric parts are a version.</summary>
    [Test] procedure Valid_Versions;
    /// <summary>{"version": "x"} is read; anything else is refused.</summary>
    [Test] procedure Manifest_Parse;
    /// <summary>Never checked, 24 h passed or the clock went back = due.</summary>
    [Test] procedure Due_Rule;
    /// <summary>Available only when enabled and the latest is newer.</summary>
    [Test] procedure Info_Available;
    /// <summary>A check stores the version + time and logs a newer version.</summary>
    [Test] procedure Checker_ChecksAndPersists;
    /// <summary>A recent stored check is not repeated after a restart.</summary>
    [Test] procedure Checker_RecentStateSkipsFetch;
    /// <summary>A failing fetch records the error and logs it once.</summary>
    [Test] procedure Checker_FailureLoggedOnce;
    /// <summary>Disabled: nothing is fetched.</summary>
    [Test] procedure Checker_DisabledNeverFetches;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.DateUtils,
  System.Generics.Collections,
  // own units
  IPTV.Core.Utils,
  IPTV.App.UpdateCheck;

const
  cCurrent = '1.2.41';
  cManifestNewer = '{"version": "1.2.42"}';
  cNoStartDelayMs = 0;
  cWaitMs = 5000;
  cPollMs = 20;
  cSettleMs = 300;

{ fake state store shared by the checker tests }

type
  TFakeState = class
  public
    Values: TDictionary<string, string>;
    Logs: TList<string>;
    Fetches: Integer;
    constructor Create;
    destructor Destroy; override;
    function Loader: TUpdateStateLoad;
    function Saver: TUpdateStateSave;
    function Logger: TUpdateLog;
  end;

constructor TFakeState.Create;
begin
  inherited Create;
  Values := TDictionary<string, string>.Create;
  Logs := TList<string>.Create;
end;

destructor TFakeState.Destroy;
begin
  FreeAndNil(Logs);
  FreeAndNil(Values);
  inherited;
end;

function TFakeState.Loader: TUpdateStateLoad;
begin
  Result :=
    function(const AKey: string): string
    begin
      TMonitor.Enter(Self);
      try
        if not Values.TryGetValue(AKey, Result) then
          Result := '';
      finally
        TMonitor.Exit(Self);
      end;
    end;
end;

function TFakeState.Saver: TUpdateStateSave;
begin
  Result :=
    procedure(const AKey, AValue: string)
    begin
      TMonitor.Enter(Self);
      try
        Values.AddOrSetValue(AKey, AValue);
      finally
        TMonitor.Exit(Self);
      end;
    end;
end;

function TFakeState.Logger: TUpdateLog;
begin
  Result :=
    procedure(const AText: string)
    begin
      TMonitor.Enter(Self);
      try
        Logs.Add(AText);
      finally
        TMonitor.Exit(Self);
      end;
    end;
end;

// waits until ACondition holds (or the time is up)
function WaitUntil(const ACondition: TFunc<Boolean>): Boolean;
var
  lDeadline: TDateTime;
begin
  lDeadline := IncMilliSecond(Now, cWaitMs);
  while not ACondition() do
  begin
    if Now > lDeadline then
      Exit(False);
    Sleep(cPollMs);
  end;
  Result := True;
end;

{ TUpdateCheckTests }

procedure TUpdateCheckTests.Compare_Numeric;
begin
  Assert.IsTrue(CompareAppVersions('1.2.10', '1.2.9') > 0);
  Assert.IsTrue(CompareAppVersions('1.2.9', '1.2.10') < 0);
  Assert.AreEqual(0, CompareAppVersions('1.2.41', '1.2.41'));
  Assert.AreEqual(0, CompareAppVersions('1.2', '1.2.0'));
  Assert.IsTrue(CompareAppVersions('2.0', '1.99.99') > 0);
end;

procedure TUpdateCheckTests.Valid_Versions;
begin
  Assert.IsTrue(IsValidAppVersion('1.2.42'));
  Assert.IsTrue(IsValidAppVersion('2'));
  Assert.IsTrue(IsValidAppVersion('1.2.3.4'));
  Assert.IsFalse(IsValidAppVersion(''));
  Assert.IsFalse(IsValidAppVersion('v1.2.42'));
  Assert.IsFalse(IsValidAppVersion('1.2.3.4.5'));
  Assert.IsFalse(IsValidAppVersion('1..2'));
  Assert.IsFalse(IsValidAppVersion('1.2.42-beta'));
  Assert.IsFalse(IsValidAppVersion('1.2.<script>'));
  Assert.IsFalse(IsValidAppVersion('1.2.1234567'));
end;

procedure TUpdateCheckTests.Manifest_Parse;
var
  lVersion: string;
begin
  Assert.IsTrue(ParseVersionManifest(cManifestNewer, lVersion));
  Assert.AreEqual('1.2.42', lVersion);
  Assert.IsTrue(ParseVersionManifest('  {"version":" 1.3 ","extra":1}  ', lVersion));
  Assert.AreEqual('1.3', lVersion);
  Assert.IsFalse(ParseVersionManifest('', lVersion));
  Assert.IsFalse(ParseVersionManifest('<html>Not Found</html>', lVersion));
  Assert.IsFalse(ParseVersionManifest('{"version": 142}', lVersion));
  Assert.IsFalse(ParseVersionManifest('{"version": "latest"}', lVersion));
  Assert.AreEqual('', lVersion);
  Assert.IsFalse(ParseVersionManifest('["1.2.42"]', lVersion));
end;

procedure TUpdateCheckTests.Due_Rule;
var
  lNow: TDateTime;
begin
  lNow := EncodeDateTime(2026, 11, 15, 12, 0, 0, 0);
  Assert.IsTrue(UpdateCheckDue(0, lNow));
  Assert.IsFalse(UpdateCheckDue(IncHour(lNow, -23), lNow));
  Assert.IsTrue(UpdateCheckDue(IncHour(lNow, -24), lNow));
  Assert.IsTrue(UpdateCheckDue(IncHour(lNow, 2), lNow)); // the clock went back
end;

procedure TUpdateCheckTests.Info_Available;
var
  lInfo: TUpdateInfo;
begin
  lInfo := Default(TUpdateInfo);
  lInfo.Enabled := True;
  lInfo.Current := cCurrent;
  Assert.IsFalse(lInfo.Available);
  Assert.AreEqual('', lInfo.ReleaseUrl);
  lInfo.Latest := '1.2.41';
  Assert.IsFalse(lInfo.Available);
  lInfo.Latest := '1.2.40';
  Assert.IsFalse(lInfo.Available);
  lInfo.Latest := '1.2.42';
  Assert.IsTrue(lInfo.Available);
  Assert.AreEqual(cUpdateReleaseTagUrl + '1.2.42', lInfo.ReleaseUrl);
  lInfo.Enabled := False;
  Assert.IsFalse(lInfo.Available);
end;

procedure TUpdateCheckTests.Checker_ChecksAndPersists;
var
  lState: TFakeState;
  lChecker: TUpdateChecker;
  lUrl: string;
begin
  lState := TFakeState.Create;
  try
    lChecker := TUpdateChecker.Create(True, cCurrent,
      function(const AUrl: string): string
      begin
        lUrl := AUrl;
        TInterlocked.Increment(lState.Fetches);
        Result := cManifestNewer;
      end, lState.Loader(), lState.Saver(), lState.Logger(), cNoStartDelayMs);
    try
      Assert.IsTrue(WaitUntil(
        function: Boolean
        begin
          Result := lChecker.Info.CheckedUtc > 0;
        end), 'no check happened');
      Assert.AreEqual(cUpdateManifestUrl, lUrl);
      Assert.AreEqual('1.2.42', lChecker.Info.Latest);
      Assert.IsTrue(lChecker.Info.Available);
      Assert.AreEqual('1.2.42', lState.Loader()(cStateUpdateLatest));
      Assert.IsTrue(lState.Loader()(cStateUpdateCheckedUtc) <> '');
      Assert.AreEqual(1, lState.Logs.Count);
      Assert.Contains(lState.Logs[0], '1.2.42');
      Sleep(cSettleMs);
      Assert.AreEqual(1, lState.Fetches, 'checked more than once a day');
    finally
      FreeAndNil(lChecker);
    end;
  finally
    FreeAndNil(lState);
  end;
end;

procedure TUpdateCheckTests.Checker_RecentStateSkipsFetch;
var
  lState: TFakeState;
  lChecker: TUpdateChecker;
begin
  lState := TFakeState.Create;
  try
    lState.Saver()(cStateUpdateCheckedUtc, DateTimeToIsoUtc(IncHour(NowUtc, -1)));
    lState.Saver()(cStateUpdateLatest, '1.2.42');
    lChecker := TUpdateChecker.Create(True, cCurrent,
      function(const AUrl: string): string
      begin
        TInterlocked.Increment(lState.Fetches);
        Result := cManifestNewer;
      end, lState.Loader(), lState.Saver(), lState.Logger(), cNoStartDelayMs);
    try
      Assert.IsTrue(WaitUntil(
        function: Boolean
        begin
          Result := lChecker.Info.Latest <> '';
        end), 'state not loaded');
      Sleep(cSettleMs);
      Assert.AreEqual(0, lState.Fetches, 'a restart checked again within the interval');
      Assert.IsTrue(lChecker.Info.Available);
    finally
      FreeAndNil(lChecker);
    end;
  finally
    FreeAndNil(lState);
  end;
end;

procedure TUpdateCheckTests.Checker_FailureLoggedOnce;
var
  lState: TFakeState;
  lChecker: TUpdateChecker;
begin
  lState := TFakeState.Create;
  try
    lChecker := TUpdateChecker.Create(True, cCurrent,
      function(const AUrl: string): string
      begin
        TInterlocked.Increment(lState.Fetches);
        raise Exception.Create('no route to host');
      end, lState.Loader(), lState.Saver(), lState.Logger(), cNoStartDelayMs);
    try
      Assert.IsTrue(WaitUntil(
        function: Boolean
        begin
          Result := lChecker.Info.LastError <> '';
        end), 'the failure was not recorded');
      Sleep(cSettleMs);
      Assert.AreEqual(1, lState.Fetches, 'retried before the retry hour');
      Assert.AreEqual(1, lState.Logs.Count);
      Assert.Contains(lState.Logs[0], 'no route to host');
      Assert.AreEqual(Double(0), Double(lChecker.Info.CheckedUtc));
      Assert.AreEqual('', lState.Loader()(cStateUpdateCheckedUtc));
    finally
      FreeAndNil(lChecker);
    end;
  finally
    FreeAndNil(lState);
  end;
end;

procedure TUpdateCheckTests.Checker_DisabledNeverFetches;
var
  lState: TFakeState;
  lChecker: TUpdateChecker;
begin
  lState := TFakeState.Create;
  try
    lChecker := TUpdateChecker.Create(False, cCurrent,
      function(const AUrl: string): string
      begin
        TInterlocked.Increment(lState.Fetches);
        Result := cManifestNewer;
      end, lState.Loader(), lState.Saver(), lState.Logger(), cNoStartDelayMs);
    try
      Sleep(cSettleMs);
      Assert.AreEqual(0, lState.Fetches);
      Assert.IsFalse(lChecker.Info.Available);
      // switched on: checks soon
      lChecker.SetEnabled(True);
      Assert.IsTrue(WaitUntil(
        function: Boolean
        begin
          Result := lChecker.Info.CheckedUtc > 0;
        end), 'no check after switching on');
      Assert.AreEqual(1, lState.Fetches);
    finally
      FreeAndNil(lChecker);
    end;
  finally
    FreeAndNil(lState);
  end;
end;

initialization
  TDUnitX.RegisterTestFixture(TUpdateCheckTests);

end.
