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
  Cleared AFTER every write that can change lists, items, streams or sources
  (not for EPG / seen / state writes); entries loaded while a write was running
  are not stored (generation check), so a stale answer can't stick. }

interface

uses
  System.SysUtils, System.SyncObjs, System.Generics.Collections,
  IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.Epg, IPTV.Model.CustomList,
  IPTV.Storage.Intf;

type
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
    // AWrite must be created first (it creates the DB file); ARead opens the same file.
    constructor Create(const AWrite, ARead: IStore);
    destructor Destroy; override;

    procedure Init;
    function LoadSources: TObjectList<TSourceConfig>;
    function SaveSource(const ASource: TSourceConfig): Integer;
    procedure DeleteSource(AId: Integer);
    procedure MergeSnapshot(const ASnapshot: TSourceSnapshot);
    function LoadCategories(const AFilter: TCatalogFilter): TCategoryList;
    function LoadStreams(const AFilter: TCatalogFilter): TStreamItemList;
    function CountStreams(const AFilter: TCatalogFilter): Integer;
    procedure MarkCategoriesSeen(const AIds: TArray<Integer>);
    procedure MarkStreamsSeen(const AIds: TArray<Integer>);
    function LoadStreamById(AId: Integer): TStreamItem;
    function LoadListStreamById(AListId, AStreamItemId: Integer): TStreamItem;
    function LoadStreamSiblings(AStreamItemId: Integer): TArray<string>;
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
    FReadLock.Free;
  FWriteLock.Free;
  FSourceCache.Free;
  FZapStreams.Free;
  FZapLists.Free;
  FCacheLock.Free;
  FWrite := nil;
  FRead := nil;
  inherited;
end;

function CloneSources(const L: TObjectList<TSourceConfig>): TObjectList<TSourceConfig>;
var
  S, N: TSourceConfig;
begin
  Result := TObjectList<TSourceConfig>.Create(True);
  for S in L do
  begin
    N := TSourceConfig.Create;
    Result.Add(N);
    N.Assign(S);
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

function CloneList(const L: TCustomList): TCustomList;
begin
  Result := TCustomList.Create;
  Result.Id := L.Id;
  Result.Name := L.Name;
  Result.OutputUsername := L.OutputUsername;
  Result.OutputPassword := L.OutputPassword;
  Result.Enabled := L.Enabled;
end;

function CloneStream(const S: TStreamItem): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.Id := S.Id;
  Result.SourceId := S.SourceId;
  Result.UpstreamId := S.UpstreamId;
  Result.ContentType := S.ContentType;
  Result.Name := S.Name;
  Result.Logo := S.Logo;
  Result.GroupTitle := S.GroupTitle;
  Result.CategoryUpstreamId := S.CategoryUpstreamId;
  Result.TvgId := S.TvgId;
  Result.TvgName := S.TvgName;
  Result.UpstreamUrl := S.UpstreamUrl;
  Result.ContentHash := S.ContentHash;
  Result.ArchiveDays := S.ArchiveDays;
  Result.IsNew := S.IsNew;
  Result.SeenAtUtc := S.SeenAtUtc;
  Result.FirstSeenUtc := S.FirstSeenUtc;
  Result.LastSeenUtc := S.LastSeenUtc;
end;

// ── writes: writer connection, write lock ──────────────────────────────────

procedure TLockingStore.Init;
begin
  FWriteLock.Acquire;
  try FWrite.Init; finally FWriteLock.Release; end;
  InvalidateSources;
  InvalidateZap;
end;

function TLockingStore.SaveSource(const ASource: TSourceConfig): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.SaveSource(ASource);
  finally
    FWriteLock.Release;
    InvalidateSources; // also after a failed write: the row may be half-changed
  end;
  InvalidateZap;
end;

procedure TLockingStore.DeleteSource(AId: Integer);
begin
  FWriteLock.Acquire;
  try
    FWrite.DeleteSource(AId);
  finally
    FWriteLock.Release;
    InvalidateSources;
  end;
  InvalidateZap;
end;

procedure TLockingStore.MergeSnapshot(const ASnapshot: TSourceSnapshot);
begin
  FWriteLock.Acquire;
  try FWrite.MergeSnapshot(ASnapshot); finally FWriteLock.Release; end;
  InvalidateZap;
end;

procedure TLockingStore.MarkCategoriesSeen(const AIds: TArray<Integer>);
begin
  FWriteLock.Acquire;
  try FWrite.MarkCategoriesSeen(AIds); finally FWriteLock.Release; end;
end;

procedure TLockingStore.MarkStreamsSeen(const AIds: TArray<Integer>);
begin
  FWriteLock.Acquire;
  try FWrite.MarkStreamsSeen(AIds); finally FWriteLock.Release; end;
end;

procedure TLockingStore.SetState(const AKey, AValue: string);
begin
  FWriteLock.Acquire;
  try FWrite.SetState(AKey, AValue); finally FWriteLock.Release; end;
end;

procedure TLockingStore.ReplaceEpg(ASourceId: Integer; const AProgrammes: TEpgProgrammeList);
begin
  FWriteLock.Acquire;
  try FWrite.ReplaceEpg(ASourceId, AProgrammes); finally FWriteLock.Release; end;
end;

procedure TLockingStore.ReplaceExtraEpg(ASourceId: Integer;
  const AChannels: TArray<TEpgChannelInfo>; const AProgrammes: TEpgProgrammeList);
begin
  FWriteLock.Acquire;
  try FWrite.ReplaceExtraEpg(ASourceId, AChannels, AProgrammes); finally FWriteLock.Release; end;
end;

procedure TLockingStore.ClearExtraEpgBelow(AMinSourceId: Integer);
begin
  FWriteLock.Acquire;
  try FWrite.ClearExtraEpgBelow(AMinSourceId); finally FWriteLock.Release; end;
end;

function TLockingStore.SaveList(const AList: TCustomList): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.SaveList(AList); finally FWriteLock.Release; end;
  InvalidateZap;
end;

procedure TLockingStore.DeleteList(AId: Integer);
begin
  FWriteLock.Acquire;
  try FWrite.DeleteList(AId); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.SaveGroup(const AGroup: TCustomGroup): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.SaveGroup(AGroup); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.ReorderGroups(AListId: Integer; const AGroupIds: TArray<Integer>): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.ReorderGroups(AListId, AGroupIds); finally FWriteLock.Release; end;
  InvalidateZap;
end;

procedure TLockingStore.DeleteGroup(AId: Integer);
begin
  FWriteLock.Acquire;
  try FWrite.DeleteGroup(AId); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.SaveItem(const AItem: TCustomItem): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.SaveItem(AItem); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.AddItems(AListId, ACustomGroupId: Integer; const AStreamItemIds: TArray<Integer>): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.AddItems(AListId, ACustomGroupId, AStreamItemIds); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.RestripSourceItems(ASourceId: Integer;
  const AOldPrefixes, AOldSuffixes, ANewPrefixes, ANewSuffixes: TArray<string>): Integer;
begin
  FWriteLock.Acquire;
  try
    Result := FWrite.RestripSourceItems(ASourceId, AOldPrefixes, AOldSuffixes, ANewPrefixes, ANewSuffixes);
  finally
    FWriteLock.Release;
  end;
  InvalidateZap;
end;

function TLockingStore.ReplaceItemStreams(AListId: Integer;
  const AReplacements: TArray<TItemStreamReplace>): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.ReplaceItemStreams(AListId, AReplacements); finally FWriteLock.Release; end;
  InvalidateZap;
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
  end;
  InvalidateZap;
end;

function TLockingStore.RestripAllItems: Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.RestripAllItems; finally FWriteLock.Release; end;
  InvalidateZap;
end;

procedure TLockingStore.DeleteItem(AId: Integer);
begin
  FWriteLock.Acquire;
  try FWrite.DeleteItem(AId); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.ClearGroupItems(AListId, ACustomGroupId: Integer): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.ClearGroupItems(AListId, ACustomGroupId); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.DedupeListItems(AListId: Integer): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.DedupeListItems(AListId); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.SortGroupAlphabetically(AListId, ACustomGroupId: Integer): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.SortGroupAlphabetically(AListId, ACustomGroupId); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.SetItemNumbers(AListId: Integer; const ANumbers: TArray<TItemNumber>): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.SetItemNumbers(AListId, ANumbers); finally FWriteLock.Release; end;
  InvalidateZap;
end;

function TLockingStore.ReorderGroupItems(AListId, ACustomGroupId: Integer; const AItemIds: TArray<Integer>): Integer;
begin
  FWriteLock.Acquire;
  try Result := FWrite.ReorderGroupItems(AListId, ACustomGroupId, AItemIds); finally FWriteLock.Release; end;
  InvalidateZap;
end;

// ── reads: reader connection, read lock (independent of writes) ─────────────

function TLockingStore.LoadSources: TObjectList<TSourceConfig>;
var
  Gen: Integer;
begin
  // served from memory when cached (callers own + free the returned copy)
  FCacheLock.Acquire;
  try
    if FSourceCache <> nil then
      Exit(CloneSources(FSourceCache));
    Gen := FSourceGen;
  finally
    FCacheLock.Release;
  end;

  FReadLock.Acquire;
  try Result := FRead.LoadSources; finally FReadLock.Release; end;

  // cache it unless a write invalidated meanwhile (then this read may be stale
  // for the cache — still a correct answer for this caller)
  FCacheLock.Acquire;
  try
    if (Gen = FSourceGen) and (FSourceCache = nil) then
      FSourceCache := CloneSources(Result);
  finally
    FCacheLock.Release;
  end;
end;

function TLockingStore.LoadCategories(const AFilter: TCatalogFilter): TCategoryList;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadCategories(AFilter); finally FReadLock.Release; end;
end;

function TLockingStore.LoadStreams(const AFilter: TCatalogFilter): TStreamItemList;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadStreams(AFilter); finally FReadLock.Release; end;
end;

function TLockingStore.CountStreams(const AFilter: TCatalogFilter): Integer;
begin
  FReadLock.Acquire;
  try Result := FRead.CountStreams(AFilter); finally FReadLock.Release; end;
end;

function TLockingStore.LoadStreamById(AId: Integer): TStreamItem;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadStreamById(AId); finally FReadLock.Release; end;
end;

function TLockingStore.LoadListStreamById(AListId, AStreamItemId: Integer): TStreamItem;
var
  Key: string;
  Hit: TStreamItem;
  Gen: Integer;
begin
  Key := AListId.ToString + ':' + AStreamItemId.ToString;
  FCacheLock.Acquire;
  try
    if FZapStreams.TryGetValue(Key, Hit) then
      Exit(CloneStream(Hit));
    Gen := FZapGen;
  finally
    FCacheLock.Release;
  end;
  FReadLock.Acquire;
  try Result := FRead.LoadListStreamById(AListId, AStreamItemId); finally FReadLock.Release; end;
  if Result <> nil then
  begin
    FCacheLock.Acquire;
    try
      if Gen = FZapGen then // no write in between: safe to remember
        FZapStreams.AddOrSetValue(Key, CloneStream(Result));
    finally
      FCacheLock.Release;
    end;
  end;
end;

function TLockingStore.LoadStreamSiblings(AStreamItemId: Integer): TArray<string>;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadStreamSiblings(AStreamItemId); finally FReadLock.Release; end;
end;

function TLockingStore.DiscoverPrefixes(ASourceId: Integer): TArray<TPrefixCount>;
begin
  FReadLock.Acquire;
  try Result := FRead.DiscoverPrefixes(ASourceId); finally FReadLock.Release; end;
end;

function TLockingStore.LoadKnownTvgIds: TArray<TTvgIdInfo>;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadKnownTvgIds; finally FReadLock.Release; end;
end;

function TLockingStore.FindQualityVariants(AListId, ASourceGroupId: Integer;
  const ATargetQuality: string): TArray<TVariantMatch>;
begin
  FReadLock.Acquire;
  try Result := FRead.FindQualityVariants(AListId, ASourceGroupId, ATargetQuality);
  finally FReadLock.Release; end;
end;

function TLockingStore.FindStreamVariants(AStreamId: Integer; AAllSources: Boolean;
  AListId: Integer): TArray<TStreamVariant>;
begin
  FReadLock.Acquire;
  try Result := FRead.FindStreamVariants(AStreamId, AAllSources, AListId);
  finally FReadLock.Release; end;
end;

function TLockingStore.FindProviderVariants(AListId, ASourceGroupId,
  ATargetSourceId: Integer): TArray<TVariantMatch>;
begin
  FReadLock.Acquire;
  try Result := FRead.FindProviderVariants(AListId, ASourceGroupId, ATargetSourceId);
  finally FReadLock.Release; end;
end;

function TLockingStore.GetState(const AKey: string): string;
begin
  FReadLock.Acquire;
  try Result := FRead.GetState(AKey); finally FReadLock.Release; end;
end;

function TLockingStore.LoadEpgForTvgIds(const ATvgIds: TArray<string>; AMaxDays: Integer): TEpgProgrammeList;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadEpgForTvgIds(ATvgIds, AMaxDays); finally FReadLock.Release; end;
end;

function TLockingStore.LoadListTvgIds: TArray<string>;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadListTvgIds; finally FReadLock.Release; end;
end;

function TLockingStore.LoadLists: TObjectList<TCustomList>;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadLists; finally FReadLock.Release; end;
end;

function TLockingStore.FindListByCredentials(const AUser, APass: string): TCustomList;
var
  Key: string;
  Hit: TCustomList;
  Gen: Integer;
begin
  Key := AUser + #0 + APass;
  FCacheLock.Acquire;
  try
    if FZapLists.TryGetValue(Key, Hit) then
      Exit(CloneList(Hit));
    Gen := FZapGen;
  finally
    FCacheLock.Release;
  end;
  FReadLock.Acquire;
  try Result := FRead.FindListByCredentials(AUser, APass); finally FReadLock.Release; end;
  if Result <> nil then // unknown logins are not cached (no memory for guessers)
  begin
    FCacheLock.Acquire;
    try
      if Gen = FZapGen then
        FZapLists.AddOrSetValue(Key, CloneList(Result));
    finally
      FCacheLock.Release;
    end;
  end;
end;

function TLockingStore.LoadGroups(AListId: Integer): TCustomGroupList;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadGroups(AListId); finally FReadLock.Release; end;
end;

function TLockingStore.LoadItems(AListId: Integer): TCustomItemList;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadItems(AListId); finally FReadLock.Release; end;
end;

function TLockingStore.LoadOutputChannels(AListId: Integer): TOutputChannelList;
begin
  FReadLock.Acquire;
  try Result := FRead.LoadOutputChannels(AListId); finally FReadLock.Release; end;
end;

end.
