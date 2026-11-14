unit IPTV.Storage.Locking;

{ Thread-safe IStore decorator with READ/WRITE connection separation.

  A single FireDAC TFDConnection is NOT safe for concurrent use, so each call
  must be serialised. But serialising EVERYTHING behind one lock means a long
  write (the daily 65k-stream MergeSnapshot, held in one transaction) blocks
  every UI read for its whole duration — the admin UI freezes during a refresh.

  Fix (SQLite WAL): use TWO inner stores on the SAME database file — a WRITER
  and a READER connection. WAL allows one writer + concurrent readers, so:
    * writes go to the writer store under FWriteLock,
    * reads go to the reader store under FReadLock,
    * the two locks are independent → a read no longer waits on a long write.
  Reads still serialise among themselves (one reader connection), but those are
  fast; the point is they proceed WHILE a refresh is writing. After a write
  commits, the next read (a fresh WAL read transaction) sees it.

  Sources are additionally CACHED in memory: the list is tiny and changes only
  through SaveSource/DeleteSource/Init, but the admin UI needs it first on every
  page load — and on a single connection (DB on a FUSE share, no WAL) it used to
  queue behind the heavy catalog queries the UI fires at the same moment.

  ZAP cache: every channel switch on a box resolves the list by its login and
  the stream on that list (FindListByCredentials + LoadListStreamById). Both are
  answered from memory after the first hit, so a zap never waits on the database
  - notably not on the nightly refresh holding the (single, FUSE) connection.
  Cleared AFTER every write that can change lists, items, streams, sources or a
  mirror bouquet's credentials
  (not for EPG / seen / state writes); entries loaded while a write was running
  are not stored (generation check), so a stale answer can't stick. }

interface

uses
  // RTL
  System.SysUtils,
  System.SyncObjs,
  System.Generics.Collections,
  // own units
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList,
  IPTV.Storage.Intf;

type
  /// Thread-safe IStore decorator: separate reader/writer stores and locks, plus
  /// in-memory source and zap caches (see the unit header).
  TLockingStore = class(TInterfacedObject, IStore)
  private
    FWrite: IStore;            // writer connection (also runs Init/migrations)
    FRead: IStore;             // reader connection on the same DB file (WAL)
    FWriteLock: TCriticalSection;
    FReadLock: TCriticalSection;
    // sources cache — FCacheLock is never held while waiting on another lock
    FCacheLock: TCriticalSection;
    FSourceCache: TObjectList<TSourceConfig>; // nil = not loaded / invalidated
    FSourceGen: Integer;                      // bumped on every invalidation
    // zap cache (see header) — guarded by FCacheLock too
    FZapLists: TObjectDictionary<string, TCustomList>;   // user#0pass -> list
    FZapStreams: TObjectDictionary<string, TStreamItem>; // listId:streamId -> stream
    FZapGen: Integer;
    procedure InvalidateSources;
    procedure InvalidateZap;
  public
    /// AWrite must be created first (it creates the DB file); ARead opens the same file.
    constructor Create(const AWrite, ARead: IStore);
    /// Frees the locks and caches and releases both inner stores.
    destructor Destroy; override;

    /// IStore implementation (see IPTV.Storage.Intf): writes go to the writer store
    /// under the write lock, reads to the reader store under the read lock.
    procedure Init;
    function LoadSources: TObjectList<TSourceConfig>;
    function SaveSource(const ASource: TSourceConfig): Integer;
    procedure DeleteSource(AId: Integer);
    procedure MergeSnapshot(const ASnapshot: TSourceSnapshot);
    function LoadCategories(const AFilter: TCatalogFilter): TCategoryList;
    function LoadStreams(const AFilter: TCatalogFilter): TStreamItemList;
    function CountStreams(const AFilter: TCatalogFilter): Integer;
    procedure MarkCategoriesSeen(const AIds: TArray<Integer>);
    function CountNew(const AFilter: TCatalogFilter): TNewCounts;
    function MarkAllSeen(const AFilter: TCatalogFilter): TNewCounts;
    procedure MarkStreamsSeen(const AIds: TArray<Integer>);
    function LoadStreamById(AId: Integer): TStreamItem;
    function LoadListStreamById(AListId, AStreamItemId: Integer): TStreamItem;
    function EnsureEpisodeIds(ASeriesStreamId: Integer; const AUpstreamIds,
      AExts: TArray<string>): TArray<Integer>;
    function FindEpisodeIds(ASeriesStreamId: Integer; const AUpstreamIds,
      AExts: TArray<string>): TArray<Integer>;
    function LoadStreamSiblings(AStreamItemId: Integer): TArray<string>;
    function LoadStreamSiblingsForList(AListId, AStreamItemId: Integer): TArray<string>;
    function DiscoverPrefixes(ASourceId: Integer): TArray<TPrefixCount>;
    function LoadKnownTvgIds: TArray<TTvgIdInfo>;
    function FindQualityVariants(AListId, ASourceGroupId: Integer;
      const ATargetQuality: string): TArray<TVariantMatch>;
    function FindProviderVariants(AListId, ASourceGroupId,
      ATargetSourceId: Integer): TArray<TVariantMatch>;
    function FindStreamVariants(AStreamId: Integer; AAllSources: Boolean;
      AListId: Integer): TArray<TStreamVariant>;
    function GetState(const AKey: string): string;
    procedure SetState(const AKey, AValue: string);
    procedure ReplaceEpg(ASourceId: Integer; const AProgrammes: TEpgProgrammeList);
    procedure ReplaceExtraEpg(ASourceId: Integer; const AChannels: TArray<TEpgChannelInfo>;
      const AProgrammes: TEpgProgrammeList);
    procedure ClearExtraEpgBelow(AMinSourceId: Integer);
    function LoadEpgForTvgIds(const ATvgIds: TArray<string>; AMaxDays: Integer = 0): TEpgProgrammeList;
    function LoadListTvgIds: TArray<string>;
    function LoadLists: TObjectList<TCustomList>;
    function SaveList(const AList: TCustomList): Integer;
    procedure DeleteList(AId: Integer);
    function LoadMirrorCredentials(AListId: Integer): TArray<TMirrorCredential>;
    procedure SaveMirrorCredentials(AListId: Integer; const ACredentials: TArray<TMirrorCredential>);
    procedure RunInTransaction(const AProc: TProc<IStore>);
    function FindListByCredentials(const AUser, APass: string): TCustomList;
    function LoadGroups(AListId: Integer): TCustomGroupList;
    function SaveGroup(const AGroup: TCustomGroup): Integer;
    function ReorderGroups(AListId: Integer; const AGroupIds: TArray<Integer>): Integer;
    procedure DeleteGroup(AId: Integer);
    function LoadItems(AListId: Integer): TCustomItemList;
    function LoadOutputChannels(AListId: Integer): TOutputChannelList;
    function SaveItem(const AItem: TCustomItem): Integer;
    function AddItems(AListId, ACustomGroupId: Integer; const AStreamItemIds: TArray<Integer>): Integer;
    function RestripSourceItems(ASourceId: Integer;
      const AOldPrefixes, AOldSuffixes, ANewPrefixes, ANewSuffixes: TArray<string>): Integer;
    function RestripAllItems: Integer;
    function ReplaceItemStreams(AListId: Integer; const AReplacements: TArray<TItemStreamReplace>): Integer;
    function RestripGroupItems(AListId, AGroupId: Integer;
      const AExtraPrefixes, AExtraSuffixes: TArray<string>; ADryRun: Boolean): TArray<TNameChange>;
    procedure DeleteItem(AId: Integer);
    function ClearGroupItems(AListId, ACustomGroupId: Integer): Integer;
    function DedupeListItems(AListId: Integer): Integer;
    function SortGroupAlphabetically(AListId, ACustomGroupId: Integer): Integer;
    function ReorderGroupItems(AListId, ACustomGroupId: Integer; const AItemIds: TArray<Integer>): Integer;
    function SetItemNumbers(AListId: Integer; const ANumbers: TArray<TItemNumber>): Integer;
  end;

implementation

const
  // zap-cache keys: 'listId:streamId' and 'user#0pass' (#0 can't occur in a login)
  cZapStreamKeySep = ':';
  cZapCredKeySep = #0;

constructor TLockingStore.Create(const AWrite, ARead: IStore);
begin
  inherited Create;
  FWrite := AWrite;
  FRead := ARead;
  FWriteLock := TCriticalSection.Create;
  FCacheLock := TCriticalSection.Create;
  // Same instance passed for both (the single-connection fallback when WAL isn't
  // available — see TAppContext.Start): one FireDAC connection is NOT thread-safe,
  // so reads and writes MUST serialise against each other. Share one lock. With
  // two real connections (WAL), the locks are independent so reads don't wait on
  // a long write.
  if ARead = AWrite then
    FReadLock := FWriteLock
  else
    FReadLock := TCriticalSection.Create;
  FZapLists := TObjectDictionary<string, TCustomList>.Create([doOwnsValues]);
  FZapStreams := TObjectDictionary<string, TStreamItem>.Create([doOwnsValues]);
end;

destructor TLockingStore.Destroy;
begin
  if FReadLock <> FWriteLock then
    FreeAndNil(FReadLock);
  FreeAndNil(FWriteLock);
  FreeAndNil(FSourceCache);
  FreeAndNil(FZapStreams);
  FreeAndNil(FZapLists);
  FreeAndNil(FCacheLock);
  FWrite := nil;
  FRead := nil;
  inherited;
end;

function CloneSources(const AList: TObjectList<TSourceConfig>): TObjectList<TSourceConfig>;
var
  lSource: TSourceConfig;
  lCopy: TSourceConfig;
begin
  Result := TObjectList<TSourceConfig>.Create(True);
  for lSource in AList do
  begin
    lCopy := TSourceConfig.Create;
    Result.Add(lCopy);
    lCopy.Assign(lSource);
  end;
end;

procedure TLockingStore.InvalidateSources;
begin
  FCacheLock.Acquire;
  try
    Inc(FSourceGen);
    FreeAndNil(FSourceCache);
  finally
    FCacheLock.Release;
  end;
end;

procedure TLockingStore.InvalidateZap;
begin
  FCacheLock.Acquire;
  try
    Inc(FZapGen);
    FZapLists.Clear;
    FZapStreams.Clear;
  finally
    FCacheLock.Release;
  end;
end;

function CloneList(const AList: TCustomList): TCustomList;
begin
  Result := TCustomList.Create;
  Result.Id := AList.Id;
  Result.Name := AList.Name;
  Result.OutputUsername := AList.OutputUsername;
  Result.OutputPassword := AList.OutputPassword;
  Result.Enabled := AList.Enabled;
  Result.MirrorOfListId := AList.MirrorOfListId;
end;

function CloneStream(const AStream: TStreamItem): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.Id := AStream.Id;
  Result.SourceId := AStream.SourceId;
  Result.UpstreamId := AStream.UpstreamId;
  Result.ContentType := AStream.ContentType;
  Result.Name := AStream.Name;
  Result.Logo := AStream.Logo;
  Result.GroupTitle := AStream.GroupTitle;
  Result.CategoryUpstreamId := AStream.CategoryUpstreamId;
  Result.TvgId := AStream.TvgId;
  Result.TvgName := AStream.TvgName;
  Result.UpstreamUrl := AStream.UpstreamUrl;
  Result.ContentHash := AStream.ContentHash;
  Result.ArchiveDays := AStream.ArchiveDays;
  Result.IsNew := AStream.IsNew;
  Result.SeenAtUtc := AStream.SeenAtUtc;
  Result.FirstSeenUtc := AStream.FirstSeenUtc;
  Result.LastSeenUtc := AStream.LastSeenUtc;
end;

// ── writes: writer connection, write lock ──────────────────────────────────

procedure TLockingStore.Init;
begin
  FWriteLock.Acquire;
  try
    FWrite.Init;
  finally
    FWriteLock.Release;
    InvalidateSources;
    InvalidateZap;
  end;
end;

function TLockingStore.SaveSource(const ASource: TSourceConfig): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.SaveSource(ASource);
  finally
    FWriteLock.Release;
    InvalidateSources; // also after a failed write: the row may be half-changed
    InvalidateZap;
  end;
end;

procedure TLockingStore.DeleteSource(AId: Integer);
begin
  FWriteLock.Acquire;
  try
    FWrite.DeleteSource(AId);
  finally
    FWriteLock.Release;
    InvalidateSources;
    InvalidateZap;
  end;
end;

procedure TLockingStore.MergeSnapshot(const ASnapshot: TSourceSnapshot);
begin
  FWriteLock.Acquire;
  try
    FWrite.MergeSnapshot(ASnapshot);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

procedure TLockingStore.MarkCategoriesSeen(const AIds: TArray<Integer>);
begin
  FWriteLock.Acquire;
  try
    FWrite.MarkCategoriesSeen(AIds);
  finally
    FWriteLock.Release;
  end;
end;

function TLockingStore.CountNew(const AFilter: TCatalogFilter): TNewCounts;
begin
  FReadLock.Acquire;
  try
    Result := FRead.CountNew(AFilter);
  finally
    FReadLock.Release;
  end;
end;

// "new" flags only: no list/item/stream URL changes, so the zap cache stays valid
function TLockingStore.MarkAllSeen(const AFilter: TCatalogFilter): TNewCounts;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.MarkAllSeen(AFilter);
  finally
    FWriteLock.Release;
  end;
end;

procedure TLockingStore.MarkStreamsSeen(const AIds: TArray<Integer>);
begin
  FWriteLock.Acquire;
  try
    FWrite.MarkStreamsSeen(AIds);
  finally
    FWriteLock.Release;
  end;
end;

procedure TLockingStore.SetState(const AKey, AValue: string);
begin
  FWriteLock.Acquire;
  try
    FWrite.SetState(AKey, AValue);
  finally
    FWriteLock.Release;
  end;
end;

procedure TLockingStore.ReplaceEpg(ASourceId: Integer; const AProgrammes: TEpgProgrammeList);
begin
  FWriteLock.Acquire;
  try
    FWrite.ReplaceEpg(ASourceId, AProgrammes);
  finally
    FWriteLock.Release;
  end;
end;

procedure TLockingStore.ReplaceExtraEpg(ASourceId: Integer;
  const AChannels: TArray<TEpgChannelInfo>; const AProgrammes: TEpgProgrammeList);
begin
  FWriteLock.Acquire;
  try
    FWrite.ReplaceExtraEpg(ASourceId, AChannels, AProgrammes);
  finally
    FWriteLock.Release;
  end;
end;

procedure TLockingStore.ClearExtraEpgBelow(AMinSourceId: Integer);
begin
  FWriteLock.Acquire;
  try
    FWrite.ClearExtraEpgBelow(AMinSourceId);
  finally
    FWriteLock.Release;
  end;
end;

function TLockingStore.SaveList(const AList: TCustomList): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.SaveList(AList);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

procedure TLockingStore.RunInTransaction(const AProc: TProc<IStore>);
begin
  // the whole transaction under the write lock. AProc gets the UNDERLYING store,
  // so its calls don't take the (not necessarily re-entrant) lock a second time.
  FWriteLock.Acquire;
  try
    FWrite.RunInTransaction(AProc);
  finally
    FWriteLock.Release;
    InvalidateSources; // also after a rollback
    InvalidateZap;
  end;
end;

procedure TLockingStore.DeleteList(AId: Integer);
begin
  FWriteLock.Acquire;
  try
    FWrite.DeleteList(AId);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

procedure TLockingStore.SaveMirrorCredentials(AListId: Integer; const ACredentials: TArray<TMirrorCredential>);
begin
  FWriteLock.Acquire;
  try
    FWrite.SaveMirrorCredentials(AListId, ACredentials);
  finally // also after a failed write: a mirror's zap answers carry its account
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.SaveGroup(const AGroup: TCustomGroup): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.SaveGroup(AGroup);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.ReorderGroups(AListId: Integer; const AGroupIds: TArray<Integer>): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.ReorderGroups(AListId, AGroupIds);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

procedure TLockingStore.DeleteGroup(AId: Integer);
begin
  FWriteLock.Acquire;
  try
    FWrite.DeleteGroup(AId);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.SaveItem(const AItem: TCustomItem): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.SaveItem(AItem);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.AddItems(AListId, ACustomGroupId: Integer; const AStreamItemIds: TArray<Integer>): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.AddItems(AListId, ACustomGroupId, AStreamItemIds);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.RestripSourceItems(ASourceId: Integer;
  const AOldPrefixes, AOldSuffixes, ANewPrefixes, ANewSuffixes: TArray<string>): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.RestripSourceItems(ASourceId, AOldPrefixes, AOldSuffixes, ANewPrefixes, ANewSuffixes);
  finally
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.ReplaceItemStreams(AListId: Integer;
  const AReplacements: TArray<TItemStreamReplace>): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.ReplaceItemStreams(AListId, AReplacements);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.RestripGroupItems(AListId, AGroupId: Integer;
  const AExtraPrefixes, AExtraSuffixes: TArray<string>; ADryRun: Boolean): TArray<TNameChange>;
begin
  // always the write side: a preview must see the same rows the apply will change
  FWriteLock.Acquire;
  try
    Result := FWrite.RestripGroupItems(AListId, AGroupId, AExtraPrefixes, AExtraSuffixes, ADryRun);
  finally
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.RestripAllItems: Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.RestripAllItems;
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

procedure TLockingStore.DeleteItem(AId: Integer);
begin
  FWriteLock.Acquire;
  try
    FWrite.DeleteItem(AId);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.ClearGroupItems(AListId, ACustomGroupId: Integer): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.ClearGroupItems(AListId, ACustomGroupId);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.DedupeListItems(AListId: Integer): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.DedupeListItems(AListId);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.SortGroupAlphabetically(AListId, ACustomGroupId: Integer): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.SortGroupAlphabetically(AListId, ACustomGroupId);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.SetItemNumbers(AListId: Integer; const ANumbers: TArray<TItemNumber>): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.SetItemNumbers(AListId, ANumbers);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

function TLockingStore.ReorderGroupItems(AListId, ACustomGroupId: Integer; const AItemIds: TArray<Integer>): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.ReorderGroupItems(AListId, ACustomGroupId, AItemIds);
  finally // also after a failed write
    FWriteLock.Release;
    InvalidateZap;
  end;
end;

// ── reads: reader connection, read lock (independent of writes) ─────────────

function TLockingStore.LoadSources: TObjectList<TSourceConfig>;
var
  lGen: Integer;
begin
  // served from memory when cached (callers own + free the returned copy)
  FCacheLock.Acquire;
  try
    if FSourceCache <> nil then
      Exit(CloneSources(FSourceCache));
    lGen := FSourceGen;
  finally
    FCacheLock.Release;
  end;

  FReadLock.Acquire;
  try
    Result := FRead.LoadSources;
  finally
    FReadLock.Release;
  end;

  // cache it unless a write invalidated meanwhile (then this read may be stale
  // for the cache — still a correct answer for this caller)
  FCacheLock.Acquire;
  try
    if (lGen = FSourceGen) and (FSourceCache = nil) then
      FSourceCache := CloneSources(Result);
  finally
    FCacheLock.Release;
  end;
end;

function TLockingStore.LoadCategories(const AFilter: TCatalogFilter): TCategoryList;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadCategories(AFilter);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadStreams(const AFilter: TCatalogFilter): TStreamItemList;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadStreams(AFilter);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.CountStreams(const AFilter: TCatalogFilter): Integer;
begin
  FReadLock.Acquire;
  try
    Result := FRead.CountStreams(AFilter);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadStreamById(AId: Integer): TStreamItem;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadStreamById(AId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadListStreamById(AListId, AStreamItemId: Integer): TStreamItem;
var
  lKey: string;
  lHit: TStreamItem;
  lGen: Integer;
begin
  lKey := AListId.ToString + cZapStreamKeySep + AStreamItemId.ToString;
  FCacheLock.Acquire;
  try
    if FZapStreams.TryGetValue(lKey, lHit) then
      Exit(CloneStream(lHit));
    lGen := FZapGen;
  finally
    FCacheLock.Release;
  end;
  FReadLock.Acquire;
  try
    Result := FRead.LoadListStreamById(AListId, AStreamItemId);
  finally
    FReadLock.Release;
  end;
  if Result <> nil then
  begin
    FCacheLock.Acquire;
    try
      if lGen = FZapGen then // no write in between: safe to remember
        FZapStreams.AddOrSetValue(lKey, CloneStream(Result));
    finally
      FCacheLock.Release;
    end;
  end;
end;

function TLockingStore.EnsureEpisodeIds(ASeriesStreamId: Integer; const AUpstreamIds,
  AExts: TArray<string>): TArray<Integer>;
var
  i: Integer;
  lAllKnown: Boolean;
begin
  // usually every episode is known already: answer from the read side, so opening a
  // series doesn't wait for the write lock a nightly refresh holds for minutes
  FReadLock.Acquire;
  try
    Result := FRead.FindEpisodeIds(ASeriesStreamId, AUpstreamIds, AExts);
  finally
    FReadLock.Release;
  end;
  lAllKnown := True;
  for i := 0 to High(Result) do
    if Result[i] = 0 then
      lAllKnown := False;
  if lAllKnown then
    Exit;
  FWriteLock.Acquire;
  try
    Result := FWrite.EnsureEpisodeIds(ASeriesStreamId, AUpstreamIds, AExts);
  finally
    FWriteLock.Release;
    // a changed container extension changes the cached episode URL
    InvalidateZap;
  end;
end;

function TLockingStore.FindEpisodeIds(ASeriesStreamId: Integer; const AUpstreamIds,
  AExts: TArray<string>): TArray<Integer>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.FindEpisodeIds(ASeriesStreamId, AUpstreamIds, AExts);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadStreamSiblings(AStreamItemId: Integer): TArray<string>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadStreamSiblings(AStreamItemId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadStreamSiblingsForList(AListId, AStreamItemId: Integer): TArray<string>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadStreamSiblingsForList(AListId, AStreamItemId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.DiscoverPrefixes(ASourceId: Integer): TArray<TPrefixCount>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.DiscoverPrefixes(ASourceId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadKnownTvgIds: TArray<TTvgIdInfo>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadKnownTvgIds;
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.FindQualityVariants(AListId, ASourceGroupId: Integer;
  const ATargetQuality: string): TArray<TVariantMatch>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.FindQualityVariants(AListId, ASourceGroupId, ATargetQuality);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.FindStreamVariants(AStreamId: Integer; AAllSources: Boolean;
  AListId: Integer): TArray<TStreamVariant>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.FindStreamVariants(AStreamId, AAllSources, AListId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.FindProviderVariants(AListId, ASourceGroupId,
  ATargetSourceId: Integer): TArray<TVariantMatch>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.FindProviderVariants(AListId, ASourceGroupId, ATargetSourceId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.GetState(const AKey: string): string;
begin
  FReadLock.Acquire;
  try
    Result := FRead.GetState(AKey);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadEpgForTvgIds(const ATvgIds: TArray<string>; AMaxDays: Integer): TEpgProgrammeList;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadEpgForTvgIds(ATvgIds, AMaxDays);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadListTvgIds: TArray<string>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadListTvgIds;
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadLists: TObjectList<TCustomList>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadLists;
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadMirrorCredentials(AListId: Integer): TArray<TMirrorCredential>;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadMirrorCredentials(AListId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.FindListByCredentials(const AUser, APass: string): TCustomList;
var
  lKey: string;
  lHit: TCustomList;
  lGen: Integer;
begin
  // an empty username ignores the password (login-free bouquet): one cache entry,
  // not one per random password a client tries
  if AUser = '' then
    lKey := cZapCredKeySep
  else
    lKey := AUser + cZapCredKeySep + APass;
  FCacheLock.Acquire;
  try
    if FZapLists.TryGetValue(lKey, lHit) then
      Exit(CloneList(lHit));
    lGen := FZapGen;
  finally
    FCacheLock.Release;
  end;
  FReadLock.Acquire;
  try
    Result := FRead.FindListByCredentials(AUser, APass);
  finally
    FReadLock.Release;
  end;
  if Result <> nil then // unknown logins are not cached (no memory for guessers)
  begin
    FCacheLock.Acquire;
    try
      if lGen = FZapGen then
        FZapLists.AddOrSetValue(lKey, CloneList(Result));
    finally
      FCacheLock.Release;
    end;
  end;
end;

function TLockingStore.LoadGroups(AListId: Integer): TCustomGroupList;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadGroups(AListId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadItems(AListId: Integer): TCustomItemList;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadItems(AListId);
  finally
    FReadLock.Release;
  end;
end;

function TLockingStore.LoadOutputChannels(AListId: Integer): TOutputChannelList;
begin
  FReadLock.Acquire;
  try
    Result := FRead.LoadOutputChannels(AListId);
  finally
    FReadLock.Release;
  end;
end;

end.
