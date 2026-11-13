unit IPTV.Ingest.Service;

{ Orchestrates a refresh: for each enabled source, read its snapshot via the
  appropriate reader, merge it into the catalog (which flags genuinely new
  items), then refresh its EPG. Used by both the manual "refresh now" admin
  action and the daily scheduler.

  Thread-safety: FLock serialises the DB WRITES; FEpgLock serialises the memory-
  heavy EPG fetch+parse (one guide at a time). RefreshAll runs sources one at a
  time, and StatusBegin refuses to start a source that is already refreshing, so a
  manual single-source refresh can't run the same source concurrently with the
  daily run. }

interface

uses
  System.SysUtils, System.Classes, System.SyncObjs, System.Generics.Collections,
  IPTV.Storage.Intf;

type
  TLogProc = reference to procedure(const AMsg: string);

  /// Live progress of a per-source ingest, so the UI can show busy/done/error.
  TIngestStatus = record
    SourceId: Integer;
    Running: Boolean;
    StartedUtc: TDateTime;
    FinishedUtc: TDateTime;
    Streams: Integer;
    Categories: Integer;
    Programmes: Integer;
    Error: string;
  end;

  TIngestService = class
  private
    FStore: IStore;
    FLock: TCriticalSection;
    // Serialises the EPG fetch+decode+parse across the concurrent source threads.
    // Catalog reads still run in parallel (that's the speed-relevant part); but a
    // full XMLTV guide decodes to a multi-hundred-MB string, so letting all sources
    // parse at once multiplies the memory peak by the source count. One-at-a-time
    // caps it to a single guide while keeping the catalog refresh concurrent.
    FEpgLock: TCriticalSection;
    FLog: TLogProc;
    FStatus: TDictionary<Integer, TIngestStatus>;
    FStatusLock: TCriticalSection;
    FExtraEpgUrls: TArray<string>; // extra (third-party) XMLTV guides, guarded by FStatusLock
    procedure Log(const AMsg: string);
    /// Run a DB write serialised against other refreshes (the slow network reads
    /// stay outside this so sources can refresh concurrently).
    procedure WriteLocked(const AProc: TProc);
    /// Mark a source as refreshing. Returns False (atomically) when it is ALREADY
    /// refreshing — so a manual single-source refresh and the daily RefreshAll can't
    /// both refresh the same source at once (wasted work + double the parse memory).
    function StatusBegin(ASourceId: Integer): Boolean;
    procedure StatusSetCounts(ASourceId, AStreams, ACategories: Integer);
    procedure StatusSetProgrammes(ASourceId, ACount: Integer);
    procedure StatusDone(ASourceId: Integer; const AError: string);
  public
    constructor Create(const AStore: IStore; const ALog: TLogProc = nil);
    destructor Destroy; override;
    /// Refresh a single source (catalog + EPG).
    procedure RefreshSource(ASourceId: Integer);
    /// Refresh every enabled source. Errors per source are logged, not fatal.
    procedure RefreshAll;
    /// Re-fetch EPG only (no catalog re-read) for the channels currently on a
    /// list — use after adding channels so their guide shows up without a full refresh.
    procedure RefreshEpgAll;
    /// Re-fetch the extra (third-party) XMLTV guides; runs after RefreshAll/RefreshEpgAll.
    procedure RefreshExtraEpg;
    /// The extra guide URLs (from config.json extraEpgUrls), first = highest priority.
    procedure SetExtraEpgUrls(const AUrls: TArray<string>);
    /// Snapshot of the per-source ingest progress (for the admin status endpoint).
    function GetStatus: TArray<TIngestStatus>;
  end;

implementation

uses
  System.DateUtils,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.Epg, IPTV.Model.CustomList,
  IPTV.Source.Intf, IPTV.Source.Factory, IPTV.Source.Epg, IPTV.Core.Utils;

constructor TIngestService.Create(const AStore: IStore; const ALog: TLogProc);
begin
  inherited Create;
  FStore := AStore;
  FLock := TCriticalSection.Create;
  FEpgLock := TCriticalSection.Create;
  FStatusLock := TCriticalSection.Create;
  FStatus := TDictionary<Integer, TIngestStatus>.Create;
  FLog := ALog;
end;

destructor TIngestService.Destroy;
begin
  FStatus.Free;
  FStatusLock.Free;
  FEpgLock.Free;
  FLock.Free;
  inherited;
end;

procedure TIngestService.Log(const AMsg: string);
begin
  if Assigned(FLog) then
    FLog(AMsg);
end;

procedure TIngestService.WriteLocked(const AProc: TProc);
begin
  FLock.Acquire;
  try
    AProc();
  finally
    FLock.Release;
  end;
end;

// ── ingest status (thread-safe; read from request threads while a worker writes) ──

function TIngestService.StatusBegin(ASourceId: Integer): Boolean;
var
  S, Existing: TIngestStatus;
begin
  FStatusLock.Acquire;
  try
    // already refreshing this source (another thread) -> caller should skip
    if FStatus.TryGetValue(ASourceId, Existing) and Existing.Running then
      Exit(False);
    S := Default(TIngestStatus);
    S.SourceId := ASourceId;
    S.Running := True;
    S.StartedUtc := TTimeZone.Local.ToUniversalTime(Now);
    FStatus.AddOrSetValue(ASourceId, S);
    Result := True;
  finally
    FStatusLock.Release;
  end;
end;

procedure TIngestService.StatusSetCounts(ASourceId, AStreams, ACategories: Integer);
var
  S: TIngestStatus;
begin
  FStatusLock.Acquire;
  try
    if FStatus.TryGetValue(ASourceId, S) then
    begin
      S.Streams := AStreams;
      S.Categories := ACategories;
      FStatus.AddOrSetValue(ASourceId, S);
    end;
  finally FStatusLock.Release; end;
end;

procedure TIngestService.StatusSetProgrammes(ASourceId, ACount: Integer);
var
  S: TIngestStatus;
begin
  FStatusLock.Acquire;
  try
    if FStatus.TryGetValue(ASourceId, S) then
    begin
      S.Programmes := ACount;
      FStatus.AddOrSetValue(ASourceId, S);
    end;
  finally FStatusLock.Release; end;
end;

procedure TIngestService.StatusDone(ASourceId: Integer; const AError: string);
var
  S: TIngestStatus;
begin
  FStatusLock.Acquire;
  try
    if FStatus.TryGetValue(ASourceId, S) then
    begin
      S.Running := False;
      S.FinishedUtc := TTimeZone.Local.ToUniversalTime(Now);
      S.Error := AError;
      FStatus.AddOrSetValue(ASourceId, S);
    end;
  finally FStatusLock.Release; end;
end;

function TIngestService.GetStatus: TArray<TIngestStatus>;
begin
  FStatusLock.Acquire;
  try Result := FStatus.Values.ToArray; finally FStatusLock.Release; end;
end;

procedure TIngestService.RefreshSource(ASourceId: Integer);
var
  Sources: TObjectList<TSourceConfig>;
  Src, Found: TSourceConfig;
  Reader: ISourceReader;
  EpgReader: IEpgReader;
  Snapshot: TSourceSnapshot;
  Epg: TEpgProgrammeList;
  I: Integer;
  KeepTvgIds: TArray<string>;
begin
  if not StatusBegin(ASourceId) then
  begin
    Log(Format('Source %d already refreshing - skipped', [ASourceId]));
    Exit;
  end;
  try
    // The slow provider network reads happen OUTSIDE FLock so they don't block
    // box/admin requests and several sources can refresh in parallel; only the
    // brief DB writes are serialised (via WriteLocked). Store reads go through
    // the thread-safe TLockingStore anyway.
    Found := nil;
    Sources := FStore.LoadSources;
    try
      for Src in Sources do
        if Src.Id = ASourceId then
          Found := Src;
      if Found = nil then
      begin
        StatusDone(ASourceId, 'source not found');
        Exit;
      end;

      Log(Format('Refreshing source "%s"...', [Found.Name]));
      Reader := CreateSourceReader(Found.Kind);
      Snapshot := Reader.Read(Found); // SLOW network read — outside the lock
      try
        // Only the content-type toggle gates ingest (also covers M3U, where the
        // reader can't pre-skip). The name include/exclude filters are NOT applied
        // here on purpose: filtered items stay ingested so they reappear the moment
        // you drop a filter — the filtering happens live in the catalog view instead.
        for I := Snapshot.Streams.Count - 1 downto 0 do
          if not (Snapshot.Streams[I].ContentType in Found.ContentTypes) then
            Snapshot.Streams.Delete(I);

        WriteLocked(procedure begin FStore.MergeSnapshot(Snapshot); end);
        // provider account info (expiry etc.) is persisted with LastRefreshUtc below
        if Snapshot.HasAccountInfo then
        begin
          Found.AccountStatus := Snapshot.AccountStatus;
          Found.ExpiresUtc := Snapshot.ExpiresUtc;
          Found.MaxConnections := Snapshot.MaxConnections;
        end;
        if Snapshot.HasTzOffset then
          Found.TzOffsetMin := Snapshot.TzOffsetMin;
        StatusSetCounts(ASourceId, Snapshot.Streams.Count, Snapshot.Categories.Count);
        Log(Format('  %d streams, %d categories merged',
          [Snapshot.Streams.Count, Snapshot.Categories.Count]));
        // adopt an XMLTV url discovered in an M3U header so the EPG fetch below
        // (and future refreshes) can use it
        if (Found.EpgUrl = '') and (Snapshot.EpgUrl <> '') then
        begin
          Found.EpgUrl := Snapshot.EpgUrl;
          WriteLocked(procedure begin FStore.SaveSource(Found); end);
        end;
      finally
        Snapshot.Free;
      end;

      // only fetch EPG for channels actually on a list (provider guides are huge)
      KeepTvgIds := FStore.LoadListTvgIds;
      if Length(KeepTvgIds) > 0 then
      begin
        // ONE source parses its (multi-hundred-MB) XMLTV at a time — see FEpgLock.
        // Held across read+write+free so the big string is gone before the next
        // source enters; the catalog merge above already ran concurrently.
        FEpgLock.Acquire;
        try
          EpgReader := CreateEpgReader;
          Epg := EpgReader.Read(Found, KeepTvgIds); // SLOW network read — outside FLock
          try
            WriteLocked(procedure begin FStore.ReplaceEpg(Found.Id, Epg); end);
            StatusSetProgrammes(ASourceId, Epg.Count);
            Log(Format('  %d EPG programmes (for %d listed channels)', [Epg.Count, Length(KeepTvgIds)]));
          finally
            Epg.Free;
          end;
        finally
          FEpgLock.Release;
        end;
      end
      else
        Log('  no channels on a list yet - EPG skipped');

      Found.LastRefreshUtc := TTimeZone.Local.ToUniversalTime(Now);
      // Patch only the refresh fields onto the CURRENT row: a refresh takes
      // minutes, and saving the copy loaded at the start would undo any edit the
      // user made to this source meanwhile (filters, credentials, …).
      WriteLocked(procedure
        var
          L: TObjectList<TSourceConfig>;
          X: TSourceConfig;
        begin
          L := FStore.LoadSources;
          try
            for X in L do
              if X.Id = Found.Id then
              begin
                X.LastRefreshUtc := Found.LastRefreshUtc;
                X.AccountStatus := Found.AccountStatus;
                X.ExpiresUtc := Found.ExpiresUtc;
                X.MaxConnections := Found.MaxConnections;
                X.TzOffsetMin := Found.TzOffsetMin;
                FStore.SaveSource(X);
                Break;
              end;
          finally
            L.Free;
          end;
        end);
    finally
      Sources.Free;
    end;
    StatusDone(ASourceId, ''); // success
  except
    on E: Exception do
    begin
      StatusDone(ASourceId, E.Message);
      raise; // RefreshAll catches + logs per source; a single-refresh thread just ends
    end;
  end;
end;

procedure TIngestService.RefreshAll;
var
  Sources: TObjectList<TSourceConfig>;
  Src: TSourceConfig;
  Ids: TArray<Integer>;
  Names: TArray<string>;
  I: Integer;
begin
  // Refresh enabled sources SEQUENTIALLY (one at a time). Concurrency multiplied
  // the memory peak — each source holds its whole decoded XMLTV guide (~2x its
  // byte size) in memory, so N at once meant N x that peak (the container sat at
  // 450+ MiB). One-at-a-time caps it to a single guide. A per-source failure is
  // logged and does not stop the others. (Re-parallelise later if needed.)
  Ids := [];
  Names := [];
  Sources := FStore.LoadSources;
  try
    for Src in Sources do
      if Src.Enabled then
      begin
        Ids := Ids + [Src.Id];
        Names := Names + [Src.Name];
      end;
  finally
    Sources.Free;
  end;
  if Length(Ids) = 0 then
    Exit;

  for I := 0 to High(Ids) do
  try
    RefreshSource(Ids[I]);
    TrimProcessMemory; // hand each source's freed parse memory back before the next
  except
    on E: Exception do
      Log(Format('Source "%s" failed: %s', [Names[I], E.Message]));
  end;
  // Report the actual resident memory (the figure the operator watches) so its
  // trend is visible in the log after each refresh.
  RefreshExtraEpg; // the extra guides last: their matching uses the fresh catalog
  Log(Format('Refresh done — process RSS: %d MB', [ProcessResidentBytes div (1024 * 1024)]));
end;

procedure TIngestService.SetExtraEpgUrls(const AUrls: TArray<string>);
begin
  FStatusLock.Acquire;
  try
    FExtraEpgUrls := Copy(AUrls);
  finally
    FStatusLock.Release;
  end;
end;

// Fetch the extra (third-party) XMLTV guides from the settings. Each URL is a
// slot with a negative source id (-1 = first URL = highest priority). Only the
// guide channels that match a channel on some list (by name or id key) are
// stored; the matching itself happens per request in the store.
procedure TIngestService.RefreshExtraEpg;
var
  Urls: TArray<string>;
  Lists: TObjectList<TCustomList>;
  L: TCustomList;
  Chans: TOutputChannelList;
  C: TOutputChannel;
  ListKeys, KeepIds: TDictionary<string, Byte>;
  Guide: TArray<TEpgChannelInfo>;
  Kept: TArray<TEpgChannelInfo>;
  Info: TEpgChannelInfo;
  Progs: TEpgProgrammeList;
  I, J, Slot: Integer;

  procedure AddKey(const AKey: string);
  begin
    if AKey <> '' then
      ListKeys.AddOrSetValue(AKey, 0);
  end;

begin
  FStatusLock.Acquire;
  try
    Urls := Copy(FExtraEpgUrls);
  finally
    FStatusLock.Release;
  end;
  // slots of removed URLs go away (also when the list is now empty)
  WriteLocked(procedure begin FStore.ClearExtraEpgBelow(-Length(Urls)); end);
  if Length(Urls) = 0 then
    Exit;

  ListKeys := TDictionary<string, Byte>.Create;
  KeepIds := TDictionary<string, Byte>.Create;
  try
    Lists := FStore.LoadLists;
    try
      for L in Lists do
      begin
        Chans := FStore.LoadOutputChannels(L.Id);
        try
          for C in Chans do
            if C.ContentType = ctLive then
            begin
              AddKey(EpgNameKey(C.Name));
              AddKey(EpgIdKey(C.TvgId));
              AddKey(EpgIdKey(C.UpstreamTvgId));
            end;
        finally
          Chans.Free;
        end;
      end;
    finally
      Lists.Free;
    end;

    for I := 0 to High(Urls) do
    begin
      Slot := -(I + 1);
      FEpgLock.Acquire; // one guide parse at a time (memory)
      try
        try
          Log(Format('Extra EPG %d: %s', [I + 1, Urls[I]]));
          Progs := ReadExtraXmltv(Urls[I], Slot, Guide);
          try
            KeepIds.Clear;
            Kept := nil;
            for Info in Guide do
              if ListKeys.ContainsKey(EpgIdKey(Info.Id)) or ListKeys.ContainsKey(EpgNameKey(Info.Name)) then
              begin
                Kept := Kept + [Info];
                KeepIds.AddOrSetValue(EXTRA_EPG_PREFIX + Info.Id, 0);
              end;
            for J := Progs.Count - 1 downto 0 do
              if not KeepIds.ContainsKey(Progs[J].ChannelTvgId) then
                Progs.Delete(J);
            WriteLocked(procedure begin FStore.ReplaceExtraEpg(Slot, Kept, Progs); end);
            Log(Format('  %d guide channels, %d match a list channel, %d programmes stored',
              [Length(Guide), Length(Kept), Progs.Count]));
          finally
            Progs.Free;
          end;
        except
          on E: Exception do
            Log(Format('Extra EPG %d failed: %s', [I + 1, E.Message]));
        end;
      finally
        FEpgLock.Release;
      end;
    end;
  finally
    KeepIds.Free;
    ListKeys.Free;
  end;
  TrimProcessMemory;
end;

procedure TIngestService.RefreshEpgAll;
var
  Sources: TObjectList<TSourceConfig>;
  Src: TSourceConfig;
  EpgReader: IEpgReader;
  Epg: TEpgProgrammeList;
  KeepTvgIds: TArray<string>;
begin
  KeepTvgIds := FStore.LoadListTvgIds;
  if Length(KeepTvgIds) = 0 then
  begin
    Log('EPG update: no channels on a list yet - nothing to do');
    Exit;
  end;
  Sources := FStore.LoadSources;
  try
    for Src in Sources do
      if Src.Enabled then
      try
        Log(Format('Updating EPG for "%s"...', [Src.Name]));
        EpgReader := CreateEpgReader;
        Epg := EpgReader.Read(Src, KeepTvgIds); // slow network read OUTSIDE the lock
        try
          FLock.Acquire; // serialise only the DB write
          try
            FStore.ReplaceEpg(Src.Id, Epg);
          finally
            FLock.Release;
          end;
          Log(Format('  %d EPG programmes (for %d listed channels)', [Epg.Count, Length(KeepTvgIds)]));
        finally
          Epg.Free;
        end;
      except
        on E: Exception do
          Log(Format('EPG "%s" failed: %s', [Src.Name, E.Message]));
      end;
  finally
    Sources.Free;
  end;
  RefreshExtraEpg;
  TrimProcessMemory; // release the EPG parse memory back to the OS
end;

end.
