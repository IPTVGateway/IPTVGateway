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
  // RTL
  System.SysUtils,
  System.Classes,
  System.SyncObjs,
  System.Generics.Collections,
  // Own units
  IPTV.Storage.Intf;

type
  /// Log sink every core component writes its lines to.
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

  /// Refreshes sources (catalog + EPG) into the store; used by the admin API and the scheduler.
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
    /// Writes a line to the log sink (when one is set).
    procedure Log(const AMsg: string);
    /// Run a DB write serialised against other refreshes (the slow network reads
    /// stay outside this so sources can refresh concurrently).
    procedure WriteLocked(const AProc: TProc);
    /// Mark a source as refreshing. Returns False (atomically) when it is ALREADY
    /// refreshing — so a manual single-source refresh and the daily RefreshAll can't
    /// both refresh the same source at once (wasted work + double the parse memory).
    function StatusBegin(ASourceId: Integer): Boolean;
    /// Records the merged stream/category counts of a running source.
    procedure StatusSetCounts(ASourceId, AStreams, ACategories: Integer);
    /// Records the stored programme count of a running source.
    procedure StatusSetProgrammes(ASourceId, ACount: Integer);
    /// Marks a source as finished ('' = success, else the error).
    procedure StatusDone(ASourceId: Integer; const AError: string);
  private
    FCancelled: Integer; // <> 0 once Cancel was called (shutdown)
    /// True once Cancel was called.
    function IsCancelled: Boolean;
  public
    /// Creates the service on AStore; ALog receives progress lines.
    constructor Create(const AStore: IStore; const ALog: TLogProc = nil);
    destructor Destroy; override;
    /// Shutdown: refresh loops stop before their next source / guide (the one in
    /// progress finishes), so a stop during the daily refresh doesn't wait minutes.
    procedure Cancel;
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
  // RTL
  System.DateUtils,
  // Own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList,
  IPTV.Source.Intf,
  IPTV.Source.Factory,
  IPTV.Source.Epg,
  IPTV.Core.Utils;

const
  // RSS log line after a refresh is in MiB
  cBytesPerMiB = 1024 * 1024;

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
  FreeAndNil(FStatus);
  FreeAndNil(FStatusLock);
  FreeAndNil(FEpgLock);
  FreeAndNil(FLock);
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
  lStatus, lExisting: TIngestStatus;
begin
  FStatusLock.Acquire;
  try
    // already refreshing this source (another thread) -> caller should skip
    if FStatus.TryGetValue(ASourceId, lExisting) and lExisting.Running then
      Exit(False);
    lStatus := Default(TIngestStatus);
    lStatus.SourceId := ASourceId;
    lStatus.Running := True;
    lStatus.StartedUtc := NowUtc;
    FStatus.AddOrSetValue(ASourceId, lStatus);
    Result := True;
  finally
    FStatusLock.Release;
  end;
end;

procedure TIngestService.StatusSetCounts(ASourceId, AStreams, ACategories: Integer);
var
  lStatus: TIngestStatus;
begin
  FStatusLock.Acquire;
  try
    if FStatus.TryGetValue(ASourceId, lStatus) then
    begin
      lStatus.Streams := AStreams;
      lStatus.Categories := ACategories;
      FStatus.AddOrSetValue(ASourceId, lStatus);
    end;
  finally
    FStatusLock.Release;
  end;
end;

procedure TIngestService.StatusSetProgrammes(ASourceId, ACount: Integer);
var
  lStatus: TIngestStatus;
begin
  FStatusLock.Acquire;
  try
    if FStatus.TryGetValue(ASourceId, lStatus) then
    begin
      lStatus.Programmes := ACount;
      FStatus.AddOrSetValue(ASourceId, lStatus);
    end;
  finally
    FStatusLock.Release;
  end;
end;

procedure TIngestService.StatusDone(ASourceId: Integer; const AError: string);
var
  lStatus: TIngestStatus;
begin
  FStatusLock.Acquire;
  try
    if FStatus.TryGetValue(ASourceId, lStatus) then
    begin
      lStatus.Running := False;
      lStatus.FinishedUtc := NowUtc;
      lStatus.Error := AError;
      FStatus.AddOrSetValue(ASourceId, lStatus);
    end;
  finally
    FStatusLock.Release;
  end;
end;

function TIngestService.GetStatus: TArray<TIngestStatus>;
begin
  FStatusLock.Acquire;
  try
    Result := FStatus.Values.ToArray;
  finally
    FStatusLock.Release;
  end;
end;

procedure TIngestService.RefreshSource(ASourceId: Integer);
var
  lSources: TObjectList<TSourceConfig>;
  lSrc, lFound: TSourceConfig;
  lReader: ISourceReader;
  lEpgReader: IEpgReader;
  lSnapshot: TSourceSnapshot;
  lEpg: TEpgProgrammeList;
  i: Integer;
  lKeepTvgIds: TArray<string>;
  lAdoptedEpgUrl: string; // url-tvg found in the M3U header, saved with the bookkeeping
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
    lFound := nil;
    lSources := FStore.LoadSources;
    try
      for lSrc in lSources do
        if lSrc.Id = ASourceId then
          lFound := lSrc;
      if lFound = nil then
      begin
        StatusDone(ASourceId, 'source not found');
        Exit;
      end;

      Log(Format('Refreshing source "%s"...', [lFound.Name]));
      lReader := CreateSourceReader(lFound.Kind);
      lSnapshot := lReader.Read(lFound); // SLOW network read — outside the lock
      try
        // Only the content-type toggle gates ingest (also covers M3U, where the
        // reader can't pre-skip). The name include/exclude filters are NOT applied
        // here on purpose: filtered items stay ingested so they reappear the moment
        // you drop a filter — the filtering happens live in the catalog view instead.
        for i := lSnapshot.Streams.Count - 1 downto 0 do
          if not (lSnapshot.Streams[i].ContentType in lFound.ContentTypes) then
            lSnapshot.Streams.Delete(i);
        // categories too (Xtream reads the live categories for radio as well)
        for i := lSnapshot.Categories.Count - 1 downto 0 do
          if not (lSnapshot.Categories[i].ContentType in lFound.ContentTypes) then
            lSnapshot.Categories.Delete(i);

        WriteLocked(
          procedure
          begin
            FStore.MergeSnapshot(lSnapshot);
          end);
        // provider account info (expiry etc.) is persisted with LastRefreshUtc below
        if lSnapshot.HasAccountInfo then
        begin
          lFound.AccountStatus := lSnapshot.AccountStatus;
          lFound.ExpiresUtc := lSnapshot.ExpiresUtc;
          lFound.MaxConnections := lSnapshot.MaxConnections;
        end;
        if lSnapshot.HasTzOffset then
          lFound.TzOffsetMin := lSnapshot.TzOffsetMin;
        StatusSetCounts(ASourceId, lSnapshot.Streams.Count, lSnapshot.Categories.Count);
        Log(Format('  %d streams, %d categories merged',
          [lSnapshot.Streams.Count, lSnapshot.Categories.Count]));
        // adopt an XMLTV url discovered in an M3U header so the EPG fetch below
        // (and future refreshes) can use it
        // (saved with the bookkeeping below, onto the CURRENT row - saving lFound
        // here would undo edits made to the source during the download)
        if (lFound.EpgUrl = '') and (lSnapshot.EpgUrl <> '') then
        begin
          lFound.EpgUrl := lSnapshot.EpgUrl;
          lAdoptedEpgUrl := lSnapshot.EpgUrl;
        end;
      finally
        FreeAndNil(lSnapshot);
      end;

      // only fetch EPG for channels actually on a list (provider guides are huge)
      lKeepTvgIds := FStore.LoadListTvgIds;
      if Length(lKeepTvgIds) > 0 then
      begin
        // ONE source parses its (multi-hundred-MB) XMLTV at a time — see FEpgLock.
        // Held across read+write+free so the big string is gone before the next
        // source enters; the catalog merge above already ran concurrently.
        FEpgLock.Acquire;
        try
          // the catalog merge already succeeded: an EPG problem must not skip the
          // source bookkeeping below (last refresh, account info, clock offset)
          try
            lEpgReader := CreateEpgReader;
            lEpg := lEpgReader.Read(lFound, lKeepTvgIds); // SLOW network read — outside FLock
            try
              if lEpg.Count = 0 then
                // an overloaded panel often answers 200 with an empty/garbage body:
                // keep the stored guide instead of wiping it
                Log('  EPG empty - kept the previous guide')
              else
              begin
                WriteLocked(
                  procedure
                  begin
                    FStore.ReplaceEpg(lFound.Id, lEpg);
                  end);
                StatusSetProgrammes(ASourceId, lEpg.Count);
                Log(Format('  %d EPG programmes (for %d listed channels)', [lEpg.Count, Length(lKeepTvgIds)]));
              end;
            finally
              FreeAndNil(lEpg);
            end;
          except
            on E: Exception do
              Log('  EPG failed (catalog kept): ' + E.Message);
          end;
        finally
          FEpgLock.Release;
        end;
      end
      else
        Log('  no channels on a list yet - EPG skipped');

      lFound.LastRefreshUtc := NowUtc;
      // Patch only the refresh fields onto the CURRENT row: a refresh takes
      // minutes, and saving the copy loaded at the start would undo any edit the
      // user made to this source meanwhile (filters, credentials, …).
      WriteLocked(
        procedure
        var
          lList: TObjectList<TSourceConfig>;
          lItem: TSourceConfig;
        begin
          lList := FStore.LoadSources;
          try
            for lItem in lList do
              if lItem.Id = lFound.Id then
              begin
                lItem.LastRefreshUtc := lFound.LastRefreshUtc;
                lItem.AccountStatus := lFound.AccountStatus;
                lItem.ExpiresUtc := lFound.ExpiresUtc;
                lItem.MaxConnections := lFound.MaxConnections;
                lItem.TzOffsetMin := lFound.TzOffsetMin;
                if (lItem.EpgUrl = '') and (lAdoptedEpgUrl <> '') then
                  lItem.EpgUrl := lAdoptedEpgUrl;
                FStore.SaveSource(lItem);
                Break;
              end;
          finally
            FreeAndNil(lList);
          end;
        end);
    finally
      FreeAndNil(lSources);
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

procedure TIngestService.Cancel;
begin
  TInterlocked.Exchange(FCancelled, 1);
end;

function TIngestService.IsCancelled: Boolean;
begin
  Result := TInterlocked.CompareExchange(FCancelled, 0, 0) <> 0;
end;

procedure TIngestService.RefreshAll;
var
  lSources: TObjectList<TSourceConfig>;
  lSrc: TSourceConfig;
  lIds: TArray<Integer>;
  lNames: TArray<string>;
  i: Integer;
begin
  // Refresh enabled sources SEQUENTIALLY (one at a time). Concurrency multiplied
  // the memory peak — each source holds its whole decoded XMLTV guide (~2x its
  // byte size) in memory, so N at once meant N x that peak (the container sat at
  // 450+ MiB). One-at-a-time caps it to a single guide. A per-source failure is
  // logged and does not stop the others. (Re-parallelise later if needed.)
  lIds := [];
  lNames := [];
  lSources := FStore.LoadSources;
  try
    for lSrc in lSources do
      if lSrc.Enabled then
      begin
        lIds := lIds + [lSrc.Id];
        lNames := lNames + [lSrc.Name];
      end;
  finally
    FreeAndNil(lSources);
  end;
  // (no Exit when no source is enabled: the extra guides below still refresh, and
  // the slots of removed extra URLs are still cleared)

  for i := 0 to High(lIds) do
  try
    if IsCancelled then
    begin
      Log('Refresh cancelled (shutdown)');
      Exit;
    end;
    RefreshSource(lIds[i]);
    TrimProcessMemory; // hand each source's freed parse memory back before the next
  except
    on E: Exception do
      Log(Format('Source "%s" failed: %s', [lNames[i], E.Message]));
  end;
  // Report the actual resident memory (the figure the operator watches) so its
  // trend is visible in the log after each refresh.
  RefreshExtraEpg; // the extra guides last: their matching uses the fresh catalog
  Log(Format('Refresh done — process RSS: %d MB', [ProcessResidentBytes div cBytesPerMiB]));
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
  lUrls: TArray<string>;
  lLists: TObjectList<TCustomList>;
  lList: TCustomList;
  lChans: TOutputChannelList;
  lChan: TOutputChannel;
  lListKeys, lKeepIds: TDictionary<string, Byte>;
  lGuide: TArray<TEpgChannelInfo>;
  lKept: TArray<TEpgChannelInfo>;
  lInfo: TEpgChannelInfo;
  lProgs: TEpgProgrammeList;
  i, j, lSlot: Integer;

  procedure AddKey(const AKey: string);
  begin
    if AKey <> '' then
      lListKeys.AddOrSetValue(AKey, 0);
  end;

begin
  FStatusLock.Acquire;
  try
    lUrls := Copy(FExtraEpgUrls);
  finally
    FStatusLock.Release;
  end;
  // slots of removed URLs go away (also when the list is now empty)
  WriteLocked(
    procedure
    begin
      FStore.ClearExtraEpgBelow(-Length(lUrls));
    end);
  if Length(lUrls) = 0 then
    Exit;

  lListKeys := nil;
  lKeepIds := nil;
  try
    lListKeys := TDictionary<string, Byte>.Create;
    lKeepIds := TDictionary<string, Byte>.Create;
    lLists := FStore.LoadLists;
    try
      for lList in lLists do
      begin
        lChans := FStore.LoadOutputChannels(lList.Id);
        try
          for lChan in lChans do
            if lChan.ContentType = ctLive then
            begin
              AddKey(EpgNameKey(lChan.Name));
              AddKey(EpgIdKey(lChan.TvgId));
              AddKey(EpgIdKey(lChan.UpstreamTvgId));
            end;
        finally
          FreeAndNil(lChans);
        end;
      end;
    finally
      FreeAndNil(lLists);
    end;

    for i := 0 to High(lUrls) do
    begin
      if IsCancelled then
        Break;
      lSlot := -(i + 1);
      FEpgLock.Acquire; // one guide parse at a time (memory)
      try
        try
          Log(Format('Extra EPG %d: %s', [i + 1, MaskUrlSecrets(lUrls[i])]));
          // keep only channels some list channel matches, already while parsing
          lProgs := ReadExtraXmltv(lUrls[i], lSlot, lGuide,
            function(AInfo: TEpgChannelInfo): Boolean
            begin
              Result := lListKeys.ContainsKey(EpgIdKey(AInfo.Id)) or
                lListKeys.ContainsKey(EpgNameKey(AInfo.Name));
            end);
          try
            lKeepIds.Clear;
            lKept := nil;
            for lInfo in lGuide do
              if lListKeys.ContainsKey(EpgIdKey(lInfo.Id)) or lListKeys.ContainsKey(EpgNameKey(lInfo.Name)) then
              begin
                lKept := lKept + [lInfo];
                lKeepIds.AddOrSetValue(EXTRA_EPG_PREFIX + lInfo.Id, 0);
              end;
            for j := lProgs.Count - 1 downto 0 do
              if not lKeepIds.ContainsKey(lProgs[j].ChannelTvgId) then
                lProgs.Delete(j);
            if lProgs.Count = 0 then
            begin
              // empty/garbage download: keep what we have
              Log(Format('  extra EPG %d: nothing usable - kept the previous guide', [i + 1]));
              Continue;
            end;
            WriteLocked(
              procedure
              begin
                FStore.ReplaceExtraEpg(lSlot, lKept, lProgs);
              end);
            Log(Format('  %d guide channels, %d match a list channel, %d programmes stored',
              [Length(lGuide), Length(lKept), lProgs.Count]));
          finally
            FreeAndNil(lProgs);
          end;
        except
          on E: Exception do
            Log(Format('Extra EPG %d failed: %s', [i + 1, E.Message]));
        end;
      finally
        FEpgLock.Release;
      end;
    end;
  finally
    FreeAndNil(lKeepIds);
    FreeAndNil(lListKeys);
  end;
  TrimProcessMemory;
end;

procedure TIngestService.RefreshEpgAll;
var
  lSources: TObjectList<TSourceConfig>;
  lSrc: TSourceConfig;
  lEpgReader: IEpgReader;
  lEpg: TEpgProgrammeList;
  lKeepTvgIds: TArray<string>;
begin
  lKeepTvgIds := FStore.LoadListTvgIds;
  if Length(lKeepTvgIds) = 0 then
  begin
    Log('EPG update: no channels on a list yet - nothing to do');
    Exit;
  end;
  lSources := FStore.LoadSources;
  try
    for lSrc in lSources do
      if lSrc.Enabled and not IsCancelled then
      try
        Log(Format('Updating EPG for "%s"...', [lSrc.Name]));
        lEpgReader := CreateEpgReader;
        // one guide parse at a time (memory), also against a running daily refresh
        FEpgLock.Acquire;
        try
          lEpg := lEpgReader.Read(lSrc, lKeepTvgIds); // slow network read OUTSIDE the lock
          try
            if lEpg.Count = 0 then
              Log('  EPG empty - kept the previous guide')
            else
            begin
              FLock.Acquire; // serialise only the DB write
              try
                FStore.ReplaceEpg(lSrc.Id, lEpg);
              finally
                FLock.Release;
              end;
              Log(Format('  %d EPG programmes (for %d listed channels)', [lEpg.Count, Length(lKeepTvgIds)]));
            end;
          finally
            FreeAndNil(lEpg);
          end;
        finally
          FEpgLock.Release;
        end;
      except
        on E: Exception do
          Log(Format('EPG "%s" failed: %s', [lSrc.Name, E.Message]));
      end;
  finally
    FreeAndNil(lSources);
  end;
  RefreshExtraEpg;
  TrimProcessMemory; // release the EPG parse memory back to the OS
end;

end.
