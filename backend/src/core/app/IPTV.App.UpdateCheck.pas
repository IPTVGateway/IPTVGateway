unit IPTV.App.UpdateCheck;

{ Daily "is there a newer version?" check.

  Once a day the service downloads a tiny version.json asset of the LATEST GitHub
  release (a JSON object with one field, version: "1.2.42") and compares it with APP_VERSION; the web app shows
  a notice when a newer version exists. Nothing about this install is sent: it is a
  plain anonymous GET (GitHub only sees the IP address, as with a docker pull).

  The time of the last successful check is kept in the store's app state, so a
  restart (or a restart loop) does not check again within the interval. Can be
  switched off (config.json "updateCheck": false, or Settings). }

interface

uses
  // RTL
  System.Classes,
  System.SysUtils,
  System.SyncObjs;

const
  /// <summary>The asset every release carries (written by deploy\docker\build.ps1).</summary>
  cUpdateManifestUrl = 'https://github.com/IPTVGateway/IPTVGateway/releases/latest/download/version.json';
  /// <summary>Release page of a version: this prefix + the version.</summary>
  cUpdateReleaseTagUrl = 'https://github.com/IPTVGateway/IPTVGateway/releases/tag/v';
  /// <summary>Hours between two successful checks.</summary>
  cUpdateCheckIntervalHours = 24;
  /// <summary>Hours until a failed check is retried.</summary>
  cUpdateRetryHours = 1;
  /// <summary>App state: UTC time (ISO 8601) of the last successful check.</summary>
  cStateUpdateCheckedUtc = 'update.checked_utc';
  /// <summary>App state: the latest version that check found.</summary>
  cStateUpdateLatest = 'update.latest_version';

type
  /// <summary>GETs a URL as text; raises on a transport or HTTP error.</summary>
  TUpdateFetch = reference to function(const AUrl: string): string;
  /// <summary>Reads an app-state value ('' = none).</summary>
  TUpdateStateLoad = reference to function(const AKey: string): string;
  /// <summary>Writes an app-state value.</summary>
  TUpdateStateSave = reference to procedure(const AKey, AValue: string);
  /// <summary>A log line.</summary>
  TUpdateLog = reference to procedure(const AText: string);

  /// <summary>What the last check found (a snapshot).</summary>
  TUpdateInfo = record
    Enabled: Boolean;
    Current: string;
    Latest: string;        // '' = not known (yet)
    CheckedUtc: TDateTime; // 0 = never
    LastError: string;     // '' = the last attempt worked
    /// <summary>True when Latest is a newer version than Current.</summary>
    function Available: Boolean;
    /// <summary>The release page of Latest ('' when not known).</summary>
    function ReleaseUrl: string;
  end;

  /// <summary>Background thread that runs the check (see the unit comment).</summary>
  TUpdateChecker = class(TThread)
  private
    FLock: TObject;
    FWake: TEvent;
    FInfo: TUpdateInfo;
    FNextTryUtc: TDateTime; // after a failure: not before this time
    FFailureLogged: Boolean;
    FFetch: TUpdateFetch;
    FLoad: TUpdateStateLoad;
    FSave: TUpdateStateSave;
    FLog: TUpdateLog;
    FStartDelayMs: Cardinal;
    procedure LoadState;
    procedure CheckNow;
    function IsDue: Boolean;
    procedure DoLog(const AText: string);
  protected
    procedure Execute; override;
    procedure TerminatedSet; override;
  public
    /// <summary>Starts the thread. AFetch / ALoad / ASave / ALog run on it; ALoad and
    /// ASave may be nil (no persistence). The first check waits AStartDelayMs.</summary>
    constructor Create(AEnabled: Boolean; const ACurrentVersion: string; const AFetch: TUpdateFetch;
      const ALoad: TUpdateStateLoad; const ASave: TUpdateStateSave; const ALog: TUpdateLog;
      AStartDelayMs: Cardinal);
    destructor Destroy; override;
    /// <summary>Switch the check on/off (on: checks soon when it is due).</summary>
    procedure SetEnabled(AEnabled: Boolean);
    /// <summary>A thread-safe copy of the current state.</summary>
    function Info: TUpdateInfo;
  end;

/// <summary>Compares two dotted versions numerically ('1.2.10' > '1.2.9'); a missing
/// part counts as 0. Result &lt; 0, 0 or &gt; 0.</summary>
function CompareAppVersions(const A, B: string): Integer;
/// <summary>A version as we accept it from the manifest: 1 to 4 numeric parts.</summary>
function IsValidAppVersion(const AVersion: string): Boolean;
/// <summary>Reads {"version": "x.y.z"}; False when it is not that shape.</summary>
function ParseVersionManifest(const AJson: string; out AVersion: string): Boolean;
/// <summary>Is a check due? Never checked, the interval passed, or the clock went back.</summary>
function UpdateCheckDue(ALastUtc, ANowUtc: TDateTime): Boolean;

implementation

uses
  // RTL
  System.JSON,
  System.DateUtils,
  // own units
  IPTV.Core.Utils;

const
  cManifestVersionField = 'version';
  cVersionSeparator = '.';
  cMaxVersionParts = 4;
  cMaxVersionPartLength = 6;
  // the thread re-checks at least this often (and wakes at once on Terminate/SetEnabled)
  cWakeSliceMs = 60000;
  cAutoReset = False;
  cInitiallyNonSignaled = False;
  cCreateSuspended = False;

{ helpers }

function IsValidAppVersion(const AVersion: string): Boolean;
var
  lParts: TArray<string>;
  lPart: string;
  lChar: Char;
begin
  Result := False;
  if AVersion = '' then
    Exit;
  lParts := AVersion.Split([cVersionSeparator]);
  if Length(lParts) > cMaxVersionParts then
    Exit;
  for lPart in lParts do
  begin
    if (lPart = '') or (Length(lPart) > cMaxVersionPartLength) then
      Exit;
    for lChar in lPart do
      if not CharInSet(lChar, ['0'..'9']) then
        Exit;
  end;
  Result := True;
end;

function CompareAppVersions(const A, B: string): Integer;
var
  lA, lB: TArray<string>;
  i, lCount, lValueA, lValueB: Integer;
begin
  lA := A.Split([cVersionSeparator]);
  lB := B.Split([cVersionSeparator]);
  lCount := Length(lA);
  if Length(lB) > lCount then
    lCount := Length(lB);
  for i := 0 to lCount - 1 do
  begin
    lValueA := 0;
    lValueB := 0;
    if i <= High(lA) then
      lValueA := StrToIntDef(lA[i], 0);
    if i <= High(lB) then
      lValueB := StrToIntDef(lB[i], 0);
    if lValueA <> lValueB then
      Exit(lValueA - lValueB);
  end;
  Result := 0;
end;

function ParseVersionManifest(const AJson: string; out AVersion: string): Boolean;
var
  lValue, lField: TJSONValue;
begin
  AVersion := '';
  Result := False;
  lValue := TJSONObject.ParseJSONValue(AJson.Trim);
  try
    if not (lValue is TJSONObject) then
      Exit;
    lField := TJSONObject(lValue).GetValue(cManifestVersionField);
    if not (lField is TJSONString) then
      Exit;
    AVersion := TJSONString(lField).Value.Trim;
    Result := IsValidAppVersion(AVersion);
    if not Result then
      AVersion := '';
  finally
    FreeAndNil(lValue);
  end;
end;

function UpdateCheckDue(ALastUtc, ANowUtc: TDateTime): Boolean;
begin
  Result := (ALastUtc <= 0) or (ANowUtc < ALastUtc) or
    (HoursBetween(ANowUtc, ALastUtc) >= cUpdateCheckIntervalHours);
end;

{ TUpdateInfo }

function TUpdateInfo.Available: Boolean;
begin
  Result := Enabled and (Latest <> '') and (CompareAppVersions(Latest, Current) > 0);
end;

function TUpdateInfo.ReleaseUrl: string;
begin
  if Latest = '' then
    Result := ''
  else
    Result := cUpdateReleaseTagUrl + Latest;
end;

{ TUpdateChecker }

constructor TUpdateChecker.Create(AEnabled: Boolean; const ACurrentVersion: string;
  const AFetch: TUpdateFetch; const ALoad: TUpdateStateLoad; const ASave: TUpdateStateSave;
  const ALog: TUpdateLog; AStartDelayMs: Cardinal);
begin
  FLock := TObject.Create;
  FWake := TEvent.Create(nil, cAutoReset, cInitiallyNonSignaled, '');
  FInfo := Default(TUpdateInfo);
  FInfo.Enabled := AEnabled;
  FInfo.Current := ACurrentVersion;
  FFetch := AFetch;
  FLoad := ALoad;
  FSave := ASave;
  FLog := ALog;
  FStartDelayMs := AStartDelayMs;
  inherited Create(cCreateSuspended);
  FreeOnTerminate := False;
end;

destructor TUpdateChecker.Destroy;
begin
  inherited; // joins the thread before the event and lock it uses are freed
  FreeAndNil(FWake);
  FreeAndNil(FLock);
end;

procedure TUpdateChecker.TerminatedSet;
begin
  FWake.SetEvent;
  inherited;
end;

procedure TUpdateChecker.DoLog(const AText: string);
begin
  if Assigned(FLog) then
    try
      FLog(AText);
    except
      // a log failure must not stop the checker
    end;
end;

procedure TUpdateChecker.SetEnabled(AEnabled: Boolean);
begin
  TMonitor.Enter(FLock);
  try
    FInfo.Enabled := AEnabled;
  finally
    TMonitor.Exit(FLock);
  end;
  FWake.SetEvent;
end;

function TUpdateChecker.Info: TUpdateInfo;
begin
  TMonitor.Enter(FLock);
  try
    Result := FInfo;
  finally
    TMonitor.Exit(FLock);
  end;
end;

// the previous check (a restart within the interval does not check again)
procedure TUpdateChecker.LoadState;
var
  lChecked: TDateTime;
  lLatest: string;
begin
  if not Assigned(FLoad) then
    Exit;
  try
    lChecked := IsoUtcToDateTime(FLoad(cStateUpdateCheckedUtc));
    lLatest := FLoad(cStateUpdateLatest);
  except
    Exit; // a failing store: run from memory
  end;
  if not IsValidAppVersion(lLatest) then
    lLatest := '';
  TMonitor.Enter(FLock);
  try
    FInfo.CheckedUtc := lChecked;
    FInfo.Latest := lLatest;
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TUpdateChecker.IsDue: Boolean;
var
  lInfo: TUpdateInfo;
  lNow: TDateTime;
begin
  lInfo := Info;
  lNow := NowUtc;
  Result := lInfo.Enabled and UpdateCheckDue(lInfo.CheckedUtc, lNow) and (lNow >= FNextTryUtc);
end;

procedure TUpdateChecker.CheckNow;
var
  lText, lVersion, lPrevious: string;
  lNow: TDateTime;
begin
  lNow := NowUtc;
  try
    lText := FFetch(cUpdateManifestUrl);
    if not ParseVersionManifest(lText, lVersion) then
      raise Exception.Create('version.json has an unexpected format');
  except
    on E: Exception do
    begin
      FNextTryUtc := IncHour(lNow, cUpdateRetryHours);
      TMonitor.Enter(FLock);
      try
        FInfo.LastError := E.Message;
      finally
        TMonitor.Exit(FLock);
      end;
      // once per run of failures: an install without internet must not fill the log
      if not FFailureLogged then
        DoLog('Update check failed (retried hourly): ' + E.Message);
      FFailureLogged := True;
      Exit;
    end;
  end;
  FFailureLogged := False;
  FNextTryUtc := 0;
  TMonitor.Enter(FLock);
  try
    lPrevious := FInfo.Latest;
    FInfo.Latest := lVersion;
    FInfo.CheckedUtc := lNow;
    FInfo.LastError := '';
  finally
    TMonitor.Exit(FLock);
  end;
  if Assigned(FSave) then
    try
      FSave(cStateUpdateCheckedUtc, DateTimeToIsoUtc(lNow));
      FSave(cStateUpdateLatest, lVersion);
    except
      // not persisted: the next start simply checks again
    end;
  if (lVersion <> lPrevious) and (CompareAppVersions(lVersion, FInfo.Current) > 0) then
    DoLog(Format('Update available: version %s (running %s) - %s%s',
      [lVersion, FInfo.Current, cUpdateReleaseTagUrl, lVersion]));
end;

procedure TUpdateChecker.Execute;
begin
  LoadState;
  // not during startup (warm-up, first box requests); Terminate wakes this at once
  FWake.WaitFor(FStartDelayMs);
  while not Terminated do
  begin
    if IsDue then
      CheckNow;
    FWake.WaitFor(cWakeSliceMs);
  end;
end;

end.
