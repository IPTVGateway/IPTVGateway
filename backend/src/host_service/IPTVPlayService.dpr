program IPTVPlayService;

{ Production host: a cross-platform CONSOLE DAEMON. It does NOT run any of the
  real work itself — it owns a TAppRunner (a dedicated worker thread) and only
  controls it. The same binary concept runs on Windows and on Linux
  (Ubuntu/Debian) under systemd.

  "Started/controlled in different ways":
    - Linux: run under systemd (Type=simple); SIGTERM stops it cleanly.
    - foreground: just run it; Ctrl+C stops it.
    - Windows: run as a console app, or wrap with a service shim (nssm/sc).

  Control flow: create the runner (worker thread starts the app), then block on
  the worker. An OS stop signal just calls Runner.SignalStop; the worker winds
  the app down and Execute returns, releasing WaitFor. Config is read from
  config.json next to the executable. See deploy/iptvplay.service. }

{$APPTYPE CONSOLE}

uses
  // RTL
  System.SysUtils,
{$IFDEF MSWINDOWS}
  Winapi.Windows,
  System.SyncObjs,
{$ENDIF}
{$IFDEF POSIX}
  Posix.Signal,
{$ENDIF}
  // ── core: model ──────────────────────────────────────────────────────
  IPTV.Model.Types in '..\core\model\IPTV.Model.Types.pas',
  IPTV.Model.Source in '..\core\model\IPTV.Model.Source.pas',
  IPTV.Model.Catalog in '..\core\model\IPTV.Model.Catalog.pas',
  IPTV.Model.Epg in '..\core\model\IPTV.Model.Epg.pas',
  IPTV.Model.CustomList in '..\core\model\IPTV.Model.CustomList.pas',
  // ── core: sources ────────────────────────────────────────────────────
  IPTV.Source.Intf in '..\core\sources\IPTV.Source.Intf.pas',
  IPTV.Source.Http in '..\core\sources\IPTV.Source.Http.pas',
  IPTV.Source.M3U in '..\core\sources\IPTV.Source.M3U.pas',
  IPTV.Source.Xtream in '..\core\sources\IPTV.Source.Xtream.pas',
  IPTV.Source.Stalker in '..\core\sources\IPTV.Source.Stalker.pas',
  IPTV.Source.Epg in '..\core\sources\IPTV.Source.Epg.pas',
  IPTV.Source.Probe in '..\core\sources\IPTV.Source.Probe.pas',
  IPTV.Source.Factory in '..\core\sources\IPTV.Source.Factory.pas',
  // ── core: storage ────────────────────────────────────────────────────
  IPTV.Storage.Intf in '..\core\storage\IPTV.Storage.Intf.pas',
  IPTV.Storage.SQLite in '..\core\storage\IPTV.Storage.SQLite.pas',
  IPTV.Storage.Locking in '..\core\storage\IPTV.Storage.Locking.pas',
  // ── core: ingest + scheduler ─────────────────────────────────────────
  IPTV.Ingest.Service in '..\core\ingest\IPTV.Ingest.Service.pas',
  IPTV.Scheduler in '..\core\scheduler\IPTV.Scheduler.pas',
  // ── core: api ────────────────────────────────────────────────────────
  IPTV.Api.Serializers in '..\core\api\IPTV.Api.Serializers.pas',
  IPTV.Output.Builder in '..\core\api\IPTV.Output.Builder.pas',
  IPTV.Api.ProxyServer in '..\core\api\IPTV.Api.ProxyServer.pas',
  IPTV.Api.Server in '..\core\api\IPTV.Api.Server.pas',
  IPTV.Api.Mars.Admin in '..\core\api\IPTV.Api.Mars.Admin.pas',
  IPTV.Api.Mars.Xtream in '..\core\api\IPTV.Api.Mars.Xtream.pas',
  // ── core: app (composition root + worker thread) ─────────────────────
  IPTV.Core.Utils in '..\core\app\IPTV.Core.Utils.pas',
  IPTV.App.Config in '..\core\app\IPTV.App.Config.pas',
  IPTV.App.Context in '..\core\app\IPTV.App.Context.pas',
  IPTV.App.Runner in '..\core\app\IPTV.App.Runner.pas';

const
  cStopPollMs = 200;              // main loop: how often a stop signal is checked
  cExitCodeStartFailed = 1;       // non-zero: systemd / Docker restart policies retry
{$IFDEF MSWINDOWS}
  cAddCtrlHandler = True;         // SetConsoleCtrlHandler: add (not remove) the handler
  // close / logoff / shutdown: Windows ends the process as soon as the handler
  // returns (and anyway after ~5 s), so the handler waits this long for a clean stop
  cCtrlCloseWaitMs = 5000;
  // TEvent.Create arguments
  cManualReset = True;            // GStopDone stays set once signalled
  cInitiallyNonSignaled = False;
{$ENDIF}

var
  GRunner: TAppRunner;
  // set by the signal handler, acted on by the main loop: a signal handler may only
  // do async-signal-safe things (a plain store), not take locks like TEvent.SetEvent
  GStopRequested: Integer = 0;
  GLogLock: TObject; // Writeln from many threads (Indy workers, ingest, relay) garbles lines
{$IFDEF MSWINDOWS}
  // set by the main thread once the runner has stopped; never freed (a console
  // handler thread may still be waiting on it while the process exits)
  GStopDone: TEvent;
{$ENDIF}

{$IFDEF MSWINDOWS}
function ConsoleCtrlHandler(ACtrlType: DWORD): BOOL; stdcall;
begin
  // never touch GRunner here: the main thread creates and frees it; it polls
  // this flag (also covers a signal that arrives before the runner exists)
  GStopRequested := 1;
  // for these Windows terminates the process as soon as we return: wait (bounded)
  // until the main thread has stopped the runner, so the stop is a clean one
  if (ACtrlType = CTRL_CLOSE_EVENT) or (ACtrlType = CTRL_LOGOFF_EVENT) or
    (ACtrlType = CTRL_SHUTDOWN_EVENT) then
    GStopDone.WaitFor(cCtrlCloseWaitMs);
  Result := True;
end;
{$ENDIF}

{$IFDEF POSIX}
procedure PosixSignalHandler(ASigNum: Integer); cdecl;
begin
  GStopRequested := 1;   // SIGTERM (systemd stop) / SIGINT (Ctrl+C); see the main loop
end;
{$ENDIF}

procedure StdLog(const AMsg: string);
var
  lLine: string;
begin
  lLine := Format('%s  %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), AMsg]);
  TMonitor.Enter(GLogLock);
  try
    Writeln(lLine);
    Flush(Output); // unbuffered so journald/console shows lines immediately
  finally
    TMonitor.Exit(GLogLock);
  end;
end;

procedure InstallSignalHandlers;
begin
{$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, cAddCtrlHandler);
{$ENDIF}
{$IFDEF POSIX}
  signal(SIGTERM, @PosixSignalHandler);
  signal(SIGINT, @PosixSignalHandler);
{$ENDIF}
end;

var
  Cfg: TAppConfig;
  CfgPath, CfgNote: string;
begin
  // config.json next to the exe, or in the data folder when IPTV_CONFIG is set
  // (Docker) - created there on first start, see ResolveDaemonConfigPath
  GLogLock := TObject.Create;
{$IFDEF MSWINDOWS}
  GStopDone := TEvent.Create(nil, cManualReset, cInitiallyNonSignaled, '');
{$ENDIF}
  // BEFORE the runner exists: a SIGTERM in between was ignored (PID 1 in Docker has
  // no default action); a stop requested this early is acted on by the main loop
  InstallSignalHandlers;
  CfgPath := ResolveDaemonConfigPath(ExtractFilePath(ParamStr(0)), CfgNote);
  Cfg := TAppConfig.Load(CfgPath);

  GRunner := TAppRunner.Create(Cfg, StdLog, CfgPath);  // worker thread starts the app
  try
    if CfgNote <> '' then
      StdLog(CfgNote);
    StdLog('config: ' + CfgPath);
    StdLog(Format('IPTVPlay service starting on port %d (HTTPS=%s). Ctrl+C / SIGTERM to stop.',
      [Cfg.HttpPort, BoolToStr(Cfg.UseHttps, True)]));
    // until the worker ends by itself (failed start) or a stop signal arrives
    while not GRunner.Finished do
    begin
      if GStopRequested <> 0 then
        GRunner.SignalStop;
      Sleep(cStopPollMs);
    end;
    GRunner.WaitFor;
    if GRunner.StartError <> '' then
    begin
      // non-zero so systemd (Restart=on-failure) / Docker restart policies retry
      StdLog('Exiting: the service did not start.');
      ExitCode := cExitCodeStartFailed;
    end
    else
      StdLog('Stopped.');
  finally
    FreeAndNil(GRunner);
{$IFDEF MSWINDOWS}
    GStopDone.SetEvent; // releases a waiting close/logoff/shutdown handler
{$ENDIF}
  end;
end.
