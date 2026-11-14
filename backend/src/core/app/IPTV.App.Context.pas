unit IPTV.App.Context;

{ Composition root. Wires storage + ingest + scheduler + HTTP server together
  and exposes Start/Stop. BOTH hosts (VCL dev form and the service/daemon)
  create one of these and do nothing else — all behaviour lives here and below.

  A single global instance (App) is published so the stateless Horse route
  handlers can reach the store/ingest without a per-request container. }

interface

uses
  // RTL
  System.SysUtils,
  // Own units
  IPTV.App.Config,
  IPTV.Storage.Intf,
  IPTV.Ingest.Service,
  IPTV.Model.CustomList,
  IPTV.Scheduler,
  IPTV.Api.Server;

const
  /// Lines kept by the in-memory log ring (the web app's Log tab).
  cLogRingCapacity = 2000;

type
  /// One captured log line (for the web app's Log tab).
  TLogLine = record
    Seq: Int64;          // 1, 2, 3 ... (never reused within a run)
    TimeUtc: TDateTime;
    Text: string;
  end;

  /// The last N log lines in memory (a ring buffer - nothing written to disk), so
  /// the admin can read the log in the web app instead of `docker logs`.
  TLogRing = class
  private
    FLock: TObject;
    FLines: TArray<TLogLine>;
    FCount: Integer;
    FNextSeq: Int64;
  public
    /// Creates a ring of ACapacity lines (at least cLogRingMinCapacity).
    constructor Create(ACapacity: Integer = cLogRingCapacity);
    destructor Destroy; override;
    /// Appends a line (thread-safe), overwriting the oldest when full.
    procedure Add(const AText: string);
    /// Lines with Seq > ASince, oldest first (at most the buffer).
    function Since(ASince: Int64): TArray<TLogLine>;
  end;

  /// Composition root: owns store, ingest, scheduler and HTTP server; published as App.
  TAppContext = class
  private
    FConfig: TAppConfig;
    FStore: IStore;
    FIngest: TIngestService;
    FScheduler: TDailyScheduler;
    FServer: TApiServer;
    FLog: TLogProc;      // the host's log + the in-memory ring (see TLogRing)
    FHostLog: TLogProc;  // what the host passed in (console / VCL memo / event log)
    FConfigPath: string;
    FBgOps: Integer; // count of detached background ops (admin-triggered refreshes)
    FStopped: Boolean;   // Stop ran (it is idempotent: Destroy calls it again)
    FAbandoned: Boolean; // Stop left work running on other threads (see Abandoned)
  public
    /// AConfigPath overrides where settings are loaded from AND persisted to
    /// (empty => config.json next to the executable, as the dev/daemon hosts use).
    /// The Windows Service passes a writable ProgramData path here.
    constructor Create(const AConfig: TAppConfig; const ALog: TLogProc = nil;
      const AConfigPath: string = '');
    destructor Destroy; override;
    /// Opens the store, starts ingest, the HTTP server and the scheduler, then sets App.
    procedure Start;
    /// Stops scheduler and server, waits (bounded) for the daily refresh and background
    /// ops, clears App, releases the store. Idempotent: a second call does nothing.
    procedure Stop;
    /// Route handlers can emit diagnostics.
    procedure Log(const AMsg: string);
    /// Run AWork on a detached thread, tracked so Stop waits for it before tearing
    /// down App/store/ingest. Use for fire-and-forget admin actions (refreshes).
    procedure SpawnBackground(const AWork: TProc);
    /// Apply editable settings at runtime and persist them to config.json:
    /// reschedules the daily refresh and starts/stops the stream relay live.
    procedure UpdateSettings(ARefreshHour, ARefreshMinute: Word;
      AProxyStreams: Boolean; AProxyPort: Integer; AEpgMaxDays: Integer = -1;
      AStreamFailover: Boolean = False);
    /// Apply Plex tuner settings live (gates the endpoints; starts/stops SSDP).
    procedure UpdatePlexSettings(AM3uEnabled, AM3uProxy, AHdhrEnabled,
      AHdhrProxy: Boolean; ATunerCount: Integer; const AServerUrl, AToken: string);
    /// Extra (third-party) XMLTV guide URLs; persisted. Fetched on the next refresh.
    procedure UpdateExtraEpgUrls(const AUrls: TArray<string>);
    /// Set the clients allowed on the Plex/HDHomeRun endpoints (blank entries dropped); persisted.
    procedure UpdateMediaAllowedClients(const AClients: TArray<string>);
    /// May this client IP use the Plex/HDHomeRun endpoints? (empty list = everyone)
    function IsMediaClientAllowed(const AClientIp: string): Boolean;
    /// Media-server config: the global group filter, the base URL boxes use, and the
    /// dummy-EPG settings. Persisted; read live by the output builders (no restart).
    procedure UpdateMediaConfig(const AVisibleGroups: TArray<string>;
      const ABaseUrl: string; ADummyEnabled: Boolean;
      ADummyBlockMinutes, ADummyHoursBack, ADummyHoursAhead: Integer;
      ANameShowGroup, ANameShowNumber, ANameShowSource, AIdSortPrefix: Boolean);
    /// Regenerate the HDHomeRun DeviceID so Plex treats the tuner as a brand-new
    /// device (and can't re-attach its cached channel numbers/names). Persisted;
    /// returns the new id. The operator then removes + re-adds the DVR in Plex.
    function ResetPlexDeviceId: string;
    /// Plex-sync reminder: stamp when the bouquet changed / when Plex was rescanned,
    /// and whether a rescan is due (bouquet changed since the last rescan).
    procedure MarkLineupChanged;
    procedure MarkPlexRescanned;
    function PlexSyncPending: Boolean;
    /// True when at least one Plex tuner surface is enabled (so the reminder is relevant).
    function PlexEnabled: Boolean;
    /// Choose the bouquet Plex/Jellyfin get (0 = first enabled). Persisted.
    procedure SetPlexListId(AListId: Integer);
    /// The bouquet the media-server surfaces serve: the chosen PlexListId when it
    /// exists and is enabled, else the first enabled bouquet. nil if none. Caller frees.
    function PlexList: TCustomList;
    /// The current (runtime-updated) settings.
    property Config: TAppConfig read FConfig;
    /// The shared, serialised store.
    property Store: IStore read FStore;
    /// The ingest service (refreshes).
    property Ingest: TIngestService read FIngest;
    /// True when Stop gave up waiting while a refresh (daily or background) still ran
    /// on another thread. That work still uses this context (its ingest, store, log
    /// and op counter), so the owner must NOT free it: it is left to the process exit.
    property Abandoned: Boolean read FAbandoned;
  end;

var
  App: TAppContext = nil; // set by the host on Start, cleared on Stop
  /// Process-wide log ring (outlives App so start/stop lines are kept too).
  LogRing: TLogRing = nil;
  /// The admin password as soon as the context exists (before App is set), so
  /// /api/logs can be protected even while the service is still starting.
  AdminPasswordEarly: string = '';

implementation

uses
  // RTL
  System.IOUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  System.Diagnostics,
  // Own units
  IPTV.Storage.SQLite,
  IPTV.Storage.Locking,
  IPTV.Core.Utils;

const
  // host part of the image's config.json template value (http://your-unraid-host:7777)
  cPublicUrlPlaceholder = 'your-unraid-host';

  // smallest log ring a caller may ask for
  cLogRingMinCapacity = 10;

  // TSQLiteStore AUseWal argument (separateReadConnection mode)
  cUseWal = True;

  // HDHomeRun DeviceID: the first 8 hex digits of a fresh GUID
  cPlexDeviceIdLength = 8;

  // Stop: how long to wait in total for the daily refresh (scheduler thread) and the
  // detached background ops, polled in slices. Below the 35 s stop grace of
  // docker / systemd / the SCM, leaving room for draining the HTTP server.
  cStopMaxWaitMs = 25000;
  cStopPollMs = 50;

{ TLogRing }

constructor TLogRing.Create(ACapacity: Integer);
begin
  inherited Create;
  FLock := TObject.Create;
  if ACapacity < cLogRingMinCapacity then
    ACapacity := cLogRingMinCapacity;
  SetLength(FLines, ACapacity);
end;

destructor TLogRing.Destroy;
begin
  FreeAndNil(FLock);
  inherited;
end;

procedure TLogRing.Add(const AText: string);
var
  lLine: TLogLine;
begin
  TMonitor.Enter(FLock);
  try
    Inc(FNextSeq);
    lLine.Seq := FNextSeq;
    lLine.TimeUtc := NowUtc;
    lLine.Text := AText;
    FLines[(FNextSeq - 1) mod Length(FLines)] := lLine;
    if FCount < Length(FLines) then
      Inc(FCount);
  finally
    TMonitor.Exit(FLock);
  end;
end;

function TLogRing.Since(ASince: Int64): TArray<TLogLine>;
var
  lFirst, lSeq: Int64;
begin
  Result := nil;
  TMonitor.Enter(FLock);
  try
    // a client ahead of us = we restarted (numbering began again): send everything
    if ASince > FNextSeq then
      ASince := 0;
    lFirst := FNextSeq - FCount + 1; // oldest seq still in the buffer
    if ASince + 1 > lFirst then
      lFirst := ASince + 1;
    if lFirst > FNextSeq then
      Exit;
    SetLength(Result, FNextSeq - lFirst + 1);
    for lSeq := lFirst to FNextSeq do
      Result[lSeq - lFirst] := FLines[(lSeq - 1) mod Length(FLines)];
  finally
    TMonitor.Exit(FLock);
  end;
end;

const
  STATE_PLEX_RESCAN = 'plex_rescan_utc';

constructor TAppContext.Create(const AConfig: TAppConfig; const ALog: TLogProc;
  const AConfigPath: string);
begin
  inherited Create;
  FConfig := AConfig;
  AdminPasswordEarly := AConfig.AdminPassword;
  FHostLog := ALog;
  // every component logs through FLog: keep a copy for the web app's Log tab
  FLog :=
    procedure(const AMsg: string)
    begin
      if LogRing <> nil then
        LogRing.Add(AMsg);
      if Assigned(FHostLog) then
        FHostLog(AMsg);
    end;
  // Where settings are persisted. Default: next to the executable (dev form +
  // console daemon). The Windows Service injects a writable ProgramData path,
  // since its exe dir is typically read-only (Program Files).
  if AConfigPath <> '' then
    FConfigPath := AConfigPath
  else
    FConfigPath := TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), cConfigFileName);
end;

destructor TAppContext.Destroy;
begin
  Stop;
  inherited;
end;

procedure TAppContext.Start;
var
  lStore: IStore;
begin
  if FConfig.LoadWarning <> '' then
    Log(FConfig.LoadWarning);
  // the image template's placeholder is published to boxes as server_info.url
  if FConfig.PublicBaseUrl.Contains(cPublicUrlPlaceholder) then
    Log('WARNING: publicBaseUrl is still "' + FConfig.PublicBaseUrl +
      '" - set it (Settings) to the address boxes use to reach this server');
  ForceDirectories(TPath.GetDirectoryName(FConfig.DatabasePath));
  // Storage connection model:
  //   DEFAULT  -> ONE connection (rollback journal), reads + writes serialised on a
  //               shared lock. Works on EVERY filesystem, including the Unraid
  //               /mnt/user FUSE share. A refresh may briefly pause UI reads.
  //   OPT-IN   -> separateReadConnection=true: a WAL writer + reader connection so UI
  //               reads don't wait on the daily refresh. ONLY safe on a real
  //               (non-FUSE) path — on /mnt/user WAL silently breaks and the UI hangs.
  // Default is single-connection because the two-connection path proved unreliable on
  // the FUSE share (SQLite reports 'wal' there even though WAL can't actually run).
  if FConfig.SeparateReadConnection then
  begin
    Log('storage: separate read connection (WAL) enabled — ensure the DB is on a ' +
        'non-FUSE path (e.g. /mnt/cache/...), else reads will hang.');
    FStore := TLockingStore.Create(
      TSQLiteStore.Create(FConfig.DatabasePath, cUseWal),   // writer (WAL)
      TSQLiteStore.Create(FConfig.DatabasePath, cUseWal));  // reader (WAL)
  end
  else
  begin
    Log('storage: single serialised connection (rollback journal) — robust on any ' +
        'filesystem. Set separateReadConnection=true for non-blocking reads on a real disk.');
    lStore := TSQLiteStore.Create(FConfig.DatabasePath); // no WAL
    FStore := TLockingStore.Create(lStore, lStore); // same connection, shared lock
  end;
  FStore.Init;

  FIngest := TIngestService.Create(FStore, FLog);
  FIngest.SetExtraEpgUrls(FConfig.ExtraEpgUrls);

  // a stable HDHomeRun device id for Plex (generated once, persisted)
  if FConfig.PlexDeviceId = '' then
  begin
    FConfig.PlexDeviceId := Copy(TGUID.NewGuid.ToString.Replace('{', '').Replace('-', ''), 1,
      cPlexDeviceIdLength);
    // not over a config.json that failed to load: we run on defaults then, and
    // saving would replace the operator's file (port, password, ...) with them
    if FConfig.LoadWarning = '' then
      FConfig.Save(FConfigPath);
  end;

  FServer := TApiServer.Create(FConfig, FLog);
  FServer.Start;

  FScheduler := TDailyScheduler.Create(FConfig.RefreshHour, FConfig.RefreshMinute,
    procedure
    begin
      try
        FIngest.RefreshAll;
      except
        on E: Exception do
          Log('Daily refresh failed: ' + E.Message);
      end;
    end);

  App := Self;
end;

procedure TAppContext.Log(const AMsg: string);
begin
  if Assigned(FLog) then
    FLog(AMsg);
end;

procedure TAppContext.SpawnBackground(const AWork: TProc);
begin
  // increment on the CALLER thread (before the request handler returns) so that,
  // once the server has drained, FBgOps already reflects every spawned op.
  TInterlocked.Increment(FBgOps);
  TThread.CreateAnonymousThread(
    procedure
    begin
      try
        try
          AWork();
        except
          // a detached op (e.g. a manual refresh of an unreachable provider) must
          // not raise unhandled out of the thread — log it; status already records it.
          on E: Exception do
            Log(Format('Background op failed: %s', [E.Message]));
        end;
      finally
        TInterlocked.Decrement(FBgOps);
      end;
    end).Start;
end;

procedure TAppContext.UpdateSettings(ARefreshHour, ARefreshMinute: Word;
  AProxyStreams: Boolean; AProxyPort: Integer; AEpgMaxDays: Integer;
  AStreamFailover: Boolean);
begin
  // the relay first: when it can't (re)bind this raises and NOTHING is changed -
  // before, the new values stayed in memory and a later unrelated save wrote them
  if Assigned(FServer) then
    FServer.SetProxy(AProxyStreams, AProxyPort); // start/stop/rebind the relay live
  FConfig.RefreshHour := ARefreshHour;
  FConfig.RefreshMinute := ARefreshMinute;
  FConfig.ProxyStreams := AProxyStreams;
  FConfig.ProxyPort := AProxyPort;
  FConfig.StreamFailover := AStreamFailover;
  if AEpgMaxDays >= 0 then
    FConfig.EpgMaxDays := AEpgMaxDays;
  if Assigned(FScheduler) then
  begin
    FScheduler.Hour := ARefreshHour;
    FScheduler.Minute := ARefreshMinute;
  end;
  FConfig.Save(FConfigPath);
  Log(Format('Settings updated: refresh %0.2d:%0.2d, proxy=%s (port %d)',
    [ARefreshHour, ARefreshMinute, BoolToStr(AProxyStreams, True), AProxyPort]));
end;

procedure TAppContext.UpdatePlexSettings(AM3uEnabled, AM3uProxy, AHdhrEnabled,
  AHdhrProxy: Boolean; ATunerCount: Integer; const AServerUrl, AToken: string);
begin
  FConfig.PlexM3uEnabled := AM3uEnabled;
  FConfig.PlexM3uProxy := AM3uProxy;
  FConfig.PlexHdhrEnabled := AHdhrEnabled;
  FConfig.PlexHdhrProxy := AHdhrProxy;
  FConfig.PlexServerUrl := AServerUrl;
  FConfig.PlexToken := AToken;
  if ATunerCount > 0 then
    FConfig.PlexTunerCount := ATunerCount;
  if Assigned(FServer) then
    FServer.SyncPlex(FConfig); // start/stop the SSDP responder to match
  FConfig.Save(FConfigPath);
  Log(Format('Plex updated: M3U=%s (proxy %s), HDHR=%s (proxy %s), tuners=%d',
    [BoolToStr(AM3uEnabled, True), BoolToStr(AM3uProxy, True),
     BoolToStr(AHdhrEnabled, True), BoolToStr(AHdhrProxy, True), FConfig.PlexTunerCount]));
end;

procedure TAppContext.SetPlexListId(AListId: Integer);
begin
  if AListId = FConfig.PlexListId then
    Exit;
  FConfig.PlexListId := AListId;
  FConfig.Save(FConfigPath);
  MarkLineupChanged; // Plex must re-read the (different) lineup
  Log(Format('Plex bouquet set to list %d (0 = first enabled)', [AListId]));
end;

function TAppContext.PlexList: TCustomList;
var
  lLists: TObjectList<TCustomList>;
  i: Integer;
begin
  Result := nil;
  if FConfig.PlexListId > 0 then
  begin
    lLists := FStore.LoadLists;
    try
      for i := 0 to lLists.Count - 1 do
        if (lLists[i].Id = FConfig.PlexListId) and lLists[i].Enabled then
        begin
          Result := lLists.Extract(lLists[i]);
          Exit;
        end;
    finally
      FreeAndNil(lLists);
    end;
  end;
  // no explicit choice: the first enabled bouquet (by id)
  lLists := FStore.LoadLists;
  try
    for i := 0 to lLists.Count - 1 do
      if lLists[i].Enabled then
      begin
        Result := lLists.Extract(lLists[i]);
        Exit;
      end;
  finally
    FreeAndNil(lLists);
  end;
  // (Result is still nil: no enabled bouquet)
end;

procedure TAppContext.UpdateMediaConfig(const AVisibleGroups: TArray<string>;
  const ABaseUrl: string; ADummyEnabled: Boolean;
  ADummyBlockMinutes, ADummyHoursBack, ADummyHoursAhead: Integer;
  ANameShowGroup, ANameShowNumber, ANameShowSource, AIdSortPrefix: Boolean);
begin
  FConfig.VisibleGroups := AVisibleGroups;
  FConfig.PublicBaseUrl := ABaseUrl;
  FConfig.NameShowGroup := ANameShowGroup;
  FConfig.NameShowNumber := ANameShowNumber;
  FConfig.NameShowSource := ANameShowSource;
  FConfig.IdSortPrefix := AIdSortPrefix;
  FConfig.DummyEpgEnabled := ADummyEnabled;
  if ADummyBlockMinutes > 0 then
    FConfig.DummyEpgBlockMinutes := ADummyBlockMinutes;
  if ADummyHoursBack >= 0 then
    FConfig.DummyEpgHoursBack := ADummyHoursBack;
  if ADummyHoursAhead > 0 then
    FConfig.DummyEpgHoursAhead := ADummyHoursAhead;
  if Assigned(FServer) then
    FServer.SyncPlex(FConfig); // refresh the server's config copy (SSDP location host)
  FConfig.Save(FConfigPath);
  Log(Format('Media config updated: %d visible groups, baseUrl=%s, dummyEpg=%s (%d min, -%d/+%dh)',
    [Length(AVisibleGroups), ABaseUrl, BoolToStr(ADummyEnabled, True),
     FConfig.DummyEpgBlockMinutes, FConfig.DummyEpgHoursBack, FConfig.DummyEpgHoursAhead]));
end;

procedure TAppContext.UpdateMediaAllowedClients(const AClients: TArray<string>);
var
  lClients: TArray<string>;
  lClient: string;
begin
  lClients := nil;
  for lClient in AClients do
    if lClient.Trim <> '' then
      lClients := lClients + [lClient.Trim];
  FConfig.MediaAllowedClients := lClients;
  FConfig.Save(FConfigPath);
  Log(Format('Media servers: %d allowed client entr(y/ies) (0 = everyone)', [Length(lClients)]));
end;

function TAppContext.IsMediaClientAllowed(const AClientIp: string): Boolean;
begin
  Result := IsClientInList(AClientIp, FConfig.MediaAllowedClients);
end;

procedure TAppContext.UpdateExtraEpgUrls(const AUrls: TArray<string>);
var
  lUrls: TArray<string>;
  lUrl: string;
begin
  lUrls := nil;
  for lUrl in AUrls do
    if lUrl.Trim <> '' then
      lUrls := lUrls + [lUrl.Trim];
  FConfig.ExtraEpgUrls := lUrls;
  if Assigned(FIngest) then
    FIngest.SetExtraEpgUrls(lUrls);
  FConfig.Save(FConfigPath);
  Log(Format('Extra EPG sources: %d (fetched with the next refresh / EPG update)', [Length(lUrls)]));
end;

function TAppContext.ResetPlexDeviceId: string;
begin
  // fresh 8-hex id (same shape as the one minted on first start) — a NEW device to Plex
  FConfig.PlexDeviceId := Copy(TGUID.NewGuid.ToString.Replace('{', '').Replace('-', ''), 1,
    cPlexDeviceIdLength);
  if Assigned(FServer) then
    FServer.SyncPlex(FConfig); // refresh the server's config copy (discover.json reads App.Config live)
  FConfig.Save(FConfigPath);
  Result := FConfig.PlexDeviceId;
  Log('Plex tuner DeviceID reset to ' + Result + ' — remove + re-add the DVR in Plex for a fresh import');
end;

procedure TAppContext.MarkLineupChanged;
begin
  if Assigned(FStore) then
    FStore.SetState(cStateLineupChanged, DateTimeToIsoUtc(NowUtc));
end;

procedure TAppContext.MarkPlexRescanned;
begin
  if Assigned(FStore) then
    FStore.SetState(STATE_PLEX_RESCAN, DateTimeToIsoUtc(NowUtc));
end;

function TAppContext.PlexSyncPending: Boolean;
var
  lChanged, lRescan: string;
begin
  Result := False;
  if not Assigned(FStore) then
    Exit;
  lChanged := FStore.GetState(cStateLineupChanged);
  if lChanged = '' then
    Exit; // nothing changed yet
  lRescan := FStore.GetState(STATE_PLEX_RESCAN);
  // ISO-8601 UTC strings are fixed-width, so lexicographic compare = chronological
  Result := (lRescan = '') or (lChanged > lRescan);
end;

function TAppContext.PlexEnabled: Boolean;
begin
  Result := FConfig.PlexM3uEnabled or FConfig.PlexHdhrEnabled;
end;

procedure TAppContext.Stop;
var
  lClock: TStopwatch;
  lSchedulerRunning: Boolean;
begin
  // idempotent: the runner calls Stop and Destroy calls it again - a second pass
  // would wait out the budget once more (past the docker/systemd/SCM grace)
  if FStopped then
    Exit;
  FStopped := True;
  // One budget for every wait below, so a stuck refresh can't push the whole stop
  // past the stop grace of docker / systemd / the SCM.
  lClock := TStopwatch.StartNew;
  // Order matters: stop the scheduler (no refresh fires mid-shutdown), then the
  // HTTP server (stops accepting + drains in-flight requests) BEFORE clearing the
  // global App and releasing the store — otherwise a request that just passed its
  // "if App = nil" check could use App/Store as they're torn down (use-after-check).
  // a running (daily) refresh stops before its next source, so the scheduler
  // thread that runs it can usually be joined within the stop budget
  if Assigned(FIngest) then
    FIngest.Cancel;
  lSchedulerRunning := False;
  if Assigned(FScheduler) then
  begin
    FScheduler.Terminate;
    // bounded: TThread.WaitFor has no timeout, and one source's refresh (a stuck
    // network read, a huge XMLTV) isn't interrupted by Cancel
    while (not FScheduler.Finished) and (lClock.ElapsedMilliseconds < cStopMaxWaitMs) do
      Sleep(cStopPollMs);
    lSchedulerRunning := not FScheduler.Finished;
    if lSchedulerRunning then
      Log('Stop: the daily refresh is still running - continuing the shutdown without it')
    else
      FreeAndNil(FScheduler); // finished: Destroy's join returns at once
  end;
  if Assigned(FServer) then
  begin
    FServer.Stop; // stops accepting + drains in-flight requests (no new SpawnBackground)
    FreeAndNil(FServer);
  end;

  // wait for detached admin refreshes to finish so they don't touch App/FIngest
  // after we free them. Bounded so a stuck network read can't hang shutdown forever.
  while (TInterlocked.CompareExchange(FBgOps, 0, 0) > 0) and
    (lClock.ElapsedMilliseconds < cStopMaxWaitMs) do
    Sleep(cStopPollMs);

  if App = Self then
    App := nil;

  if lSchedulerRunning or (TInterlocked.CompareExchange(FBgOps, 0, 0) > 0) then
  begin
    // A refresh is still running (stuck network read): it uses FIngest/FStore, and
    // when it ends it touches this context too (FBgOps, Log; the scheduler's
    // callback reads FIngest). So NOTHING it uses is freed - not the scheduler
    // thread, the ingest, the store, nor this context (the owner checks Abandoned
    // and leaves it to the process exit). A small leak beats a use-after-free.
    FAbandoned := True;
    Log('Stop: a refresh is still running - ingest, store and context are left to the process exit');
    Exit;
  end;
  FreeAndNil(FIngest);
  FStore := nil; // interface ref-count releases the SQLite store
end;

initialization
  LogRing := TLogRing.Create(cLogRingCapacity);

finalization
  FreeAndNil(LogRing);

end.
