unit Svc.IPTVService;

{ Production host #2: a native Windows Service (Win32).

  Like the console daemon (host_service), this host runs NONE of the real work
  itself. It owns a TAppRunner (a dedicated worker thread) and only *controls*
  it: ServiceStart creates the runner (worker starts the app), ServiceStop
  signals it and blocks until the app has wound down. All behaviour stays in the
  core; this unit is a thin SCM adapter.

  Install / manage from an elevated prompt:
    IPTVGateway_svc.exe /install       (register with the SCM)
    IPTVGateway_svc.exe /uninstall     (remove it)
    sc start  IPTVGatewayService
    sc stop   IPTVGatewayService

  All writable state lives under C:\ProgramData\IPTVGateway (a machine-wide,
  writable location — NEVER next to the exe, which is typically read-only under
  Program Files, and the service runs as LocalSystem):
    - config.json          (settings; seeded from a config.json next to the exe
                            on first run if present, then persisted here)
    - Data\iptvplay.sqlite (the catalog/EPG DB, unless config sets databasePath)
    - Logs\iptvgateway-svc.log (per-line runner log; best-effort)
  Lifecycle events and errors also go to the Windows Event Log. }

interface

uses
  // RTL
  Winapi.Windows,
  Winapi.ShlObj,
  System.SysUtils,
  System.Classes,
  System.IOUtils,
  System.SyncObjs,
  Vcl.SvcMgr,
  // Own units
  IPTV.App.Config,
  IPTV.App.Runner;

type
  /// Thin SCM adapter: owns a TAppRunner and only controls it.
  TIPTVGatewayService = class(TService)
    procedure ServiceCreate(Sender: TObject);
    procedure ServiceDestroy(Sender: TObject);
    procedure ServiceStart(Sender: TService; var Started: Boolean);
    procedure ServiceStop(Sender: TService; var Stopped: Boolean);
    procedure ServiceShutdown(Sender: TService);
  private
    FRunner: TAppRunner;        // the worker thread that owns the app
    FLogLock: TCriticalSection; // serialise file writes (worker thread logs here)
    FLogPath: string;
    /// Best-effort, thread-safe append of one line to the service log file.
    procedure SvcLog(const AMsg: string);
  public
    /// The SCM control callback for this service.
    function GetServiceController: TServiceController; override;
  end;

var
  IPTVGatewayService: TIPTVGatewayService;

implementation

{$R *.dfm}

const
  // writable state under ProgramData (see the unit header)
  cAppDataFolderName = 'IPTVGateway';
  cFallbackAppDataRoot = 'C:\ProgramData\' + cAppDataFolderName; // when SHGetFolderPath fails
  cLogDirName = 'Logs';
  cLogFileName = 'iptvgateway-svc.log';
  cSvcDataDirName = 'Data';       // the service's DB folder (the exe default is cDataDirName)

  // below the SCM's default 30 s start timeout
  cStartWaitMs = 25000;

function ExeDir: string;
begin
  Result := IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0)));
end;

// Machine-wide, writable data root: C:\ProgramData\IPTVGateway. A service runs
// as LocalSystem and its exe dir is typically read-only (Program Files), so ALL
// writable state — config.json, the SQLite DB and logs — lives here, NOT next to
// the exe. CSIDL_COMMON_APPDATA resolves ProgramData.
function AppDataRoot: string;
var
  lBuf: array[0..MAX_PATH] of Char;
begin
  if Succeeded(SHGetFolderPath(0, CSIDL_COMMON_APPDATA, 0, SHGFP_TYPE_CURRENT, @lBuf[0])) then
    Result := IncludeTrailingPathDelimiter(lBuf) + cAppDataFolderName
  else
    Result := cFallbackAppDataRoot;
end;

function LogDir: string;
begin
  Result := TPath.Combine(AppDataRoot, cLogDirName);
end;

function SvcConfigPath: string;
begin
  Result := TPath.Combine(AppDataRoot, cConfigFileName);
end;

// The exe-relative DB default that TAppConfig.Default computes. If config.json
// still carries this (i.e. the operator hasn't set an explicit databasePath), we
// redirect the DB under ProgramData so it isn't written next to the (read-only) exe.
function ExeDefaultDbPath: string;
begin
  Result := TPath.Combine(TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), cDataDirName), cDatabaseFileName);
end;

function SvcDefaultDbPath: string;
begin
  Result := TPath.Combine(AppDataRoot, cSvcDataDirName + PathDelim + cDatabaseFileName);
end;

procedure ServiceController(ACtrlCode: DWord); stdcall;
begin
  IPTVGatewayService.Controller(ACtrlCode);
end;

function TIPTVGatewayService.GetServiceController: TServiceController;
begin
  Result := ServiceController;
end;

procedure TIPTVGatewayService.ServiceCreate(Sender: TObject);
begin
  FLogLock := TCriticalSection.Create;
  FLogPath := IncludeTrailingPathDelimiter(LogDir) + cLogFileName;
  try
    TDirectory.CreateDirectory(LogDir); // no-op if it already exists
  except
    // best-effort: if we can't create the log dir, SvcLog just swallows writes
  end;
end;

procedure TIPTVGatewayService.ServiceDestroy(Sender: TObject);
begin
  // defensive: the SCM should have called ServiceStop first, but never leak the
  // worker (which owns the DB/HTTP) if we are torn down without a clean stop.
  if Assigned(FRunner) then
  begin
    FRunner.StopAndWait;
    FreeAndNil(FRunner);
  end;
  FreeAndNil(FLogLock);
end;

// Best-effort append to the service log (ProgramData\IPTVGateway\Logs). Called from the worker
// thread (runner log callback), so it must be thread-safe; a failure to write
// must never take the service down.
procedure TIPTVGatewayService.SvcLog(const AMsg: string);
var
  lFile: TextFile;
  lLine: string;
begin
  lLine := Format('%s  %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), AMsg]);
  FLogLock.Enter;
  try
    try
      AssignFile(lFile, FLogPath);
      if FileExists(FLogPath) then
        Append(lFile)
      else
        Rewrite(lFile);
      try
        Writeln(lFile, lLine);
      finally
        CloseFile(lFile);
      end;
    except
      // swallow: logging is best-effort (e.g. exe dir not writable)
    end;
  finally
    FLogLock.Leave;
  end;
end;

procedure TIPTVGatewayService.ServiceStart(Sender: TService; var Started: Boolean);
var
  lConfig: TAppConfig;
begin
  try
    // Load settings from the writable ProgramData copy. On first run that file
    // doesn't exist yet — seed from a config.json next to the exe (an installer
    // template) if present, else fall back to built-in defaults. Either way the
    // app persists future changes to the ProgramData copy (passed to the runner).
    if FileExists(SvcConfigPath) then
      lConfig := TAppConfig.Load(SvcConfigPath)
    else
      lConfig := TAppConfig.Load(ExeDir + cConfigFileName); // template or defaults
    // Keep the DB off the (read-only) exe dir unless the operator set an explicit path.
    if SameText(lConfig.DatabasePath, ExeDefaultDbPath) or (lConfig.DatabasePath = '') then
      lConfig.DatabasePath := SvcDefaultDbPath
    else if TPath.IsRelativePath(lConfig.DatabasePath) then
      // a relative path would land in the service's working dir (System32)
      lConfig.DatabasePath := TPath.Combine(AppDataRoot, lConfig.DatabasePath);
    FRunner := TAppRunner.Create(lConfig, SvcLog, SvcConfigPath); // worker thread starts the app
    SvcLog(Format('IPTV Gateway service starting on port %d (HTTPS=%s). Data root: %s',
      [lConfig.HttpPort, BoolToStr(lConfig.UseHttps, True), AppDataRoot]));
    LogMessage(Format('IPTV Gateway starting on port %d.', [lConfig.HttpPort]),
      EVENTLOG_INFORMATION_TYPE);
    // the app starts on the runner's thread: wait (within the SCM's start timeout)
    // for the outcome, so a bind failure shows as a failed start in services.msc
    // and the Event Log instead of "Running" while nothing listens
    if not FRunner.WaitStartDone(cStartWaitMs) then
      // still starting (slow disk / DB migration): report Running, the outcome is
      // logged by the runner when it comes
      SvcLog('Start still in progress after the SCM wait - reporting Running')
    else if FRunner.StartError <> '' then
      raise Exception.Create(FRunner.StartError);
    Started := True;
  except
    on E: Exception do
    begin
      SvcLog(Format('START FAILED: %s: %s', [E.ClassName, E.Message]));
      LogMessage(Format('IPTV Gateway start failed: %s: %s',
        [E.ClassName, E.Message]), EVENTLOG_ERROR_TYPE);
      FreeAndNil(FRunner);
      Started := False;
    end;
  end;
end;

procedure TIPTVGatewayService.ServiceStop(Sender: TService; var Stopped: Boolean);
begin
  if Assigned(FRunner) then
  begin
    FRunner.StopAndWait; // signal + block until the worker has wound the app down
    FreeAndNil(FRunner);
  end;
  SvcLog('Stopped.');
  LogMessage('IPTV Gateway stopped.', EVENTLOG_INFORMATION_TYPE);
  Stopped := True;
end;

procedure TIPTVGatewayService.ServiceShutdown(Sender: TService);
begin
  // OS is shutting down: ask the worker to wind down (non-blocking).
  if Assigned(FRunner) then
    FRunner.SignalStop;
end;

end.
