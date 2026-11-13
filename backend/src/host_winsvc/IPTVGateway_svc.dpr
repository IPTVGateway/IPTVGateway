program IPTVGateway_svc;

{ Production host #2: a native Windows Service (Win32).

  Same concept as the console daemon (host_service/IPTVPlayService) but wrapped
  as a Windows SCM service via Vcl.SvcMgr, so it can be installed and managed
  with sc.exe / services.msc and started automatically at boot. It owns a
  TAppRunner and only controls it — all behaviour lives in the core.

  The whole core is listed below so every unit is an explicit project member
  (visible in the Project Manager); MARS is vendored and resolved via the
  .dproj search paths. }

uses
  Vcl.SvcMgr,
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
  IPTV.App.Runner in '..\core\app\IPTV.App.Runner.pas',
  // ── this host ────────────────────────────────────────────────────────
  Svc.IPTVService in 'Svc.IPTVService.pas' {IPTVGatewayService: TService};

{$R *.res}

begin
  // Windows Server requires StartServiceCtrlDispatcher to be called before
  // certain COM init; DelayInitialize / Installing guard that ordering.
  if not Application.DelayInitialize or Application.Installing then
    Application.Initialize;
  Application.CreateForm(TIPTVGatewayService, IPTVGatewayService);
  Application.Run;
end.
