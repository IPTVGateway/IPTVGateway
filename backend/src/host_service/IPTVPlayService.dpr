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
  System.SysUtils,
{$IFDEF MSWINDOWS}
  Winapi.Windows,
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

var
  GRunner: TAppRunner;

{$IFDEF MSWINDOWS}
function ConsoleCtrlHandler(CtrlType: DWORD): BOOL; stdcall;
begin
  if Assigned(GRunner) then
    GRunner.SignalStop;   // CTRL_C / CTRL_CLOSE / shutdown
  Result := True;
end;
{$ENDIF}

{$IFDEF POSIX}
procedure PosixSignalHandler(SigNum: Integer); cdecl;
begin
  if Assigned(GRunner) then
    GRunner.SignalStop;   // SIGTERM (systemd stop) / SIGINT (Ctrl+C)
end;
{$ENDIF}

procedure StdLog(const AMsg: string);
begin
  Writeln(Format('%s  %s', [FormatDateTime('yyyy-mm-dd hh:nn:ss.zzz', Now), AMsg]));
  Flush(Output); // unbuffered so journald/console shows lines immediately
end;

procedure InstallSignalHandlers;
begin
{$IFDEF MSWINDOWS}
  SetConsoleCtrlHandler(@ConsoleCtrlHandler, True);
{$ENDIF}
{$IFDEF POSIX}
  signal(SIGTERM, @PosixSignalHandler);
  signal(SIGINT, @PosixSignalHandler);
{$ENDIF}
end;

var
  Cfg: TAppConfig;
begin
  Cfg := TAppConfig.Load(
    IncludeTrailingPathDelimiter(ExtractFilePath(ParamStr(0))) + 'config.json');

  GRunner := TAppRunner.Create(Cfg, StdLog);  // worker thread starts the app
  try
    InstallSignalHandlers;
    StdLog(Format('IPTVPlay service starting on port %d (HTTPS=%s). Ctrl+C / SIGTERM to stop.',
      [Cfg.HttpPort, BoolToStr(Cfg.UseHttps, True)]));
    GRunner.WaitFor;        // block until a stop signal winds the worker down
    StdLog('Stopped.');
  finally
    GRunner.Free;
  end;
end.
