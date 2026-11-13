unit IPTV.Storage.SQLite;

{ FireDAC + SQLite implementation of IStore.

  WAL mode is enabled so the read-heavy admin/output side never blocks the daily
  refresh writer. All times are stored as ISO-8601 UTC text.

  Change tracking: MergeSnapshot upserts a freshly-read snapshot; rows that did
  not exist before are flagged is_new=1 (and stamped first_seen). Existing rows
  keep their is_new/seen state and just refresh metadata + last_seen. Marking an
  item seen clears is_new and stamps seen_at. }

interface

uses
  System.SysUtils, System.Classes, System.Generics.Collections,
  FireDAC.Stan.Intf, // core FireDAC types
  FireDAC.Comp.Client, FireDAC.Stan.Def, FireDAC.Stan.Async, FireDAC.Stan.Param,
  FireDAC.DApt, FireDAC.Phys.SQLite, FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat, // statically link the SQLite engine into the host
  Data.DB,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.Epg,
  IPTV.Model.CustomList, IPTV.Storage.Intf;

type
  TSQLiteStore = class(TInterfacedObject, IStore)
  private
    FConn: TFDConnection;
    function NewQuery: TFDQuery;
    procedure Exec(const ASql: string);
    procedure TouchLineup; // stamp lineup_changed_utc (Plex-rescan reminder)
    procedure MigrateM3uStreamIds; // one-time: re-key M3U streams credential-insensitively
    /// (Re)compute streams.hidden / categories.hidden for one source from its
    /// name filters. AForce=False skips it when the filters didn't change.
    procedure RecomputeHidden(ASourceId: Integer; AForce: Boolean);
    procedure RepairSourceTokens;
    function StreamHash(const AItem: TStreamItem): string;
    procedure ApplyExtraGuides(AChannels: TOutputChannelList);
    // row -> object
    function ReadSource(Q: TFDQuery): TSourceConfig;
    function ReadCategory(Q: TFDQuery): TCategory;
    function ReadStream(Q: TFDQuery): TStreamItem;
    function ReadProgramme(Q: TFDQuery): TEpgProgramme;
    function ReadList(Q: TFDQuery): TCustomList;
    function ReadGroup(Q: TFDQuery): TCustomGroup;
    function ReadItem(Q: TFDQuery): TCustomItem;
  public
    /// AUseWal turns on WAL journal mode — ONLY safe with a real filesystem and
    /// the separate read/write connection setup (opt-in). Default off: a single
    /// serialised connection on a rollback journal, which works everywhere
    /// (including the Unraid /mnt/user FUSE share, where WAL silently breaks).
    constructor Create(const ADatabasePath: string; AUseWal: Boolean = False);
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
    /// The group's lowest channel number > 0 (1 when the group has none).
    function GroupNumberBase(AListId, ACustomGroupId: Integer): Integer;
  end;

implementation

uses
  System.Hash, System.StrUtils, System.Generics.Defaults, System.DateUtils, System.Math,
  IPTV.Core.Utils;

// Strong IPTV group/name delimiters. We deliberately exclude '-' and '.' since
// VOD titles use them freely, which would explode the discovered-prefix list.
// Includes the Unicode vertical bars providers decorate names with (┃ │ ¦ ｜ …) —
// these are > #255 so a CharInSet (AnsiChar) set can't see them; test via a case.
function IsStrongDelim(C: Char): Boolean;
begin
  case C of
    '|', ':', #$203A, #$00BB,            // | : › »
    #$00A6, #$2502, #$2503, #$2506,      // ¦ │ ┃ ┆
    #$2507, #$250A, #$250B, #$FF5C:      // ┇ ┊ ┋ ｜
      Result := True;
  else
    Result := False;
  end;
end;

function ExtractNamePrefix(const AName: string): string;
var
  S, Token: string;
  I, Start: Integer;
begin
  S := AName.Trim;
  if S = '' then
    Exit('');
  // skip a leading delimiter run so "|NL| ..." / "┃NL┃ ..." yields "|NL|" / "┃NL┃"
  Start := 1;
  while (Start <= Length(S)) and IsStrongDelim(S[Start]) do
    Inc(Start);
  for I := Start to Length(S) do
    if IsStrongDelim(S[I]) then
      Exit(Copy(S, 1, I).Trim); // keep everything up to and incl. the delimiter
  // no delimiter: accept only a short all-caps leading token (a country/lang code
  // like "NL", "UK"), never an ordinary first word ("The", "Het", ...)
  I := Pos(' ', S);
  if I > 1 then
    Token := Copy(S, 1, I - 1)
  else
    Token := S;
  if (Length(Token) <= 4) and (Token = UpperCase(Token)) and (Token <> '') then
    Result := Token
  else
    Result := '';
end;

function IdsToCsv(const AIds: TArray<Integer>): string;
var
  I: Integer;
begin
  Result := '';
  for I := 0 to High(AIds) do
    Result := Result + IfThen(I > 0, ',', '') + AIds[I].ToString;
end;

const
  SCHEMA: array[0..7] of string = (
    'CREATE TABLE IF NOT EXISTS app_state (key TEXT PRIMARY KEY, value TEXT)',

    'CREATE TABLE IF NOT EXISTS sources (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL,' +
    '  url TEXT NOT NULL, username TEXT, password TEXT, epg_url TEXT, user_agent TEXT NOT NULL DEFAULT '''', referer TEXT NOT NULL DEFAULT '''',' +
    '  force_hls INTEGER NOT NULL DEFAULT 0,' +
    '  enabled INTEGER NOT NULL DEFAULT 1, content_types TEXT NOT NULL DEFAULT ''live,movie,series,radio'',' +
    '  include_filters TEXT NOT NULL DEFAULT '''', exclude_filters TEXT NOT NULL DEFAULT '''',' +
    '  strip_prefixes TEXT NOT NULL DEFAULT '''', strip_suffixes TEXT NOT NULL DEFAULT '''',' +
    '  last_refresh_utc TEXT)',

    'CREATE TABLE IF NOT EXISTS categories (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT, source_id INTEGER NOT NULL, upstream_id TEXT,' +
    '  content_type TEXT NOT NULL, name TEXT NOT NULL, is_new INTEGER NOT NULL DEFAULT 1,' +
    '  seen_at_utc TEXT,' +
    '  UNIQUE(source_id, content_type, upstream_id))',

    'CREATE TABLE IF NOT EXISTS streams (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT, source_id INTEGER NOT NULL, upstream_id TEXT NOT NULL,' +
    '  content_type TEXT NOT NULL, name TEXT, logo TEXT, group_title TEXT, category_upstream_id TEXT,' +
    '  tvg_id TEXT, tvg_name TEXT, upstream_url TEXT, content_hash TEXT,' +
    '  archive_days INTEGER NOT NULL DEFAULT 0,' +
    '  is_new INTEGER NOT NULL DEFAULT 1, seen_at_utc TEXT, first_seen_utc TEXT, last_seen_utc TEXT,' +
    '  UNIQUE(source_id, content_type, upstream_id))',

    'CREATE TABLE IF NOT EXISTS epg (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT, source_id INTEGER NOT NULL, channel_tvg_id TEXT NOT NULL,' +
    '  start_utc TEXT NOT NULL, stop_utc TEXT NOT NULL, title TEXT, description TEXT, category TEXT)',

    // output_username/password are OPTIONAL (empty => portal needs no auth).
    'CREATE TABLE IF NOT EXISTS lists (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,' +
    '  output_username TEXT NOT NULL DEFAULT '''', output_password TEXT NOT NULL DEFAULT '''',' +
    '  enabled INTEGER NOT NULL DEFAULT 1)',

    'CREATE TABLE IF NOT EXISTS list_groups (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT, list_id INTEGER NOT NULL, name TEXT NOT NULL,' +
    '  content_type TEXT NOT NULL, is_favorite INTEGER NOT NULL DEFAULT 0,' +
    '  sort_order INTEGER NOT NULL DEFAULT 0)',

    'CREATE TABLE IF NOT EXISTS list_items (' +
    '  id INTEGER PRIMARY KEY AUTOINCREMENT, list_id INTEGER NOT NULL, stream_item_id INTEGER NOT NULL,' +
    '  custom_group_id INTEGER NOT NULL DEFAULT 0, content_type TEXT NOT NULL,' +
    '  display_name TEXT, logo_override TEXT, channel_number INTEGER NOT NULL DEFAULT 0,' +
    '  tvg_id_override TEXT NOT NULL DEFAULT '''',' +
    '  UNIQUE(list_id, stream_item_id))'
  );

{ TSQLiteStore }

constructor TSQLiteStore.Create(const ADatabasePath: string; AUseWal: Boolean);
begin
  inherited Create;
  FConn := TFDConnection.Create(nil);
  FConn.DriverName := 'SQLite';
  FConn.Params.Database := ADatabasePath;
  FConn.Params.Add('LockingMode=Normal');
  FConn.Params.Add('Synchronous=Normal');
  // SQLite stores TEXT as UTF-8. Two rules make non-CP1252 text (emoji, Cyrillic,
  // "NL| ODIDO SPORT ⚽", …) round-trip losslessly on the static Win32 wrapper —
  // both verified empirically (tests\probe\Utf8Probe + Test.Storage):
  //   1. StringFormat=Unicode and NO FormatOptions.MapRules. An ANSI<->Wide map
  //      rule (the obvious-looking fix) actually re-routes even AsWideString back
  //      through CP1252 and corrupts it — leave MapRules untouched.
  //   2. Bind every text parameter with AsWideString (NOT AsString). AsString
  //      forces a CP1252 param and stores '?'; AsWideString stores real UTF-8.
  // Reads via TField.AsString are already correct (UTF-8 -> UnicodeString), so
  // only the write side needed the AsWideString switch.
  FConn.Params.Values['StringFormat'] := 'Unicode';
  FConn.Connected := True;
  // busy_timeout FIRST so any later statement waits (not errors) on a brief lock.
  Exec('PRAGMA busy_timeout=5000');
  Exec('PRAGMA foreign_keys=ON');
  // WAL is OPT-IN (the separate-read-connection mode). It needs a shared-memory
  // file (-shm, mmap'd) which an Unraid FUSE share (/mnt/user) can't provide — and
  // there SQLite reports 'wal' while WAL doesn't actually function, so a second
  // connection silently breaks (reads hang). The default (no WAL) uses a rollback
  // journal, which works on every filesystem with a single serialised connection.
  if AUseWal then
  begin
    // open (and finalise) the pragma as a query: PRAGMA journal_mode returns a row,
    // and finalising it cleanly lets a WAL checkpoint run on close (an unfinalised
    // ExecSQL statement holds a read lock and leaves the file 'in use').
    var Q := NewQuery;
    try Q.Open('PRAGMA journal_mode=WAL'); finally Q.Free; end;
  end;
end;

destructor TSQLiteStore.Destroy;
begin
  FConn.Free;
  inherited;
end;

function TSQLiteStore.NewQuery: TFDQuery;
begin
  Result := TFDQuery.Create(nil);
  Result.Connection := FConn;
end;

procedure TSQLiteStore.Exec(const ASql: string);
begin
  FConn.ExecSQL(ASql);
end;

function TSQLiteStore.StreamHash(const AItem: TStreamItem): string;
begin
  Result := THashSHA2.GetHashString(
    string.Join('|', [AItem.Name, AItem.Logo, AItem.GroupTitle,
                      AItem.CategoryUpstreamId, AItem.TvgId, AItem.UpstreamUrl]));
end;

procedure TSQLiteStore.Init;

  procedure AddColumn(const ATable, AColumnDef: string);
  begin
    try
      Exec('ALTER TABLE ' + ATable + ' ADD COLUMN ' + AColumnDef);
    except
      // column already exists — ignore (SQLite has no ADD COLUMN IF NOT EXISTS)
    end;
  end;

var
  S: string;
  Q: TFDQuery;
  Ids: TArray<Integer>;
  SrcId: Integer;
begin
  for S in SCHEMA do
    Exec(S);

  // migrate older DBs that predate the per-source filter columns
  AddColumn('sources', 'include_filters TEXT NOT NULL DEFAULT ''''');
  AddColumn('sources', 'exclude_filters TEXT NOT NULL DEFAULT ''''');
  AddColumn('sources', 'user_agent TEXT NOT NULL DEFAULT ''''');
  AddColumn('sources', 'referer TEXT NOT NULL DEFAULT ''''');
  AddColumn('sources', 'force_hls INTEGER NOT NULL DEFAULT 0');
  AddColumn('sources', 'strip_prefixes TEXT NOT NULL DEFAULT ''''');
  AddColumn('sources', 'strip_suffixes TEXT NOT NULL DEFAULT ''''');
  AddColumn('sources', 'last_refresh_utc TEXT');
  AddColumn('sources', 'account_status TEXT NOT NULL DEFAULT ''''');
  AddColumn('sources', 'expires_utc TEXT');
  AddColumn('sources', 'max_connections INTEGER NOT NULL DEFAULT 0');
  // portal clock offset for catch-up/timeshift start times (minutes, local - UTC)
  AddColumn('sources', 'tz_offset_min INTEGER NOT NULL DEFAULT 0');
  // this provider's own guide before the extra (third-party) EPG source
  AddColumn('sources', 'prefer_own_epg INTEGER NOT NULL DEFAULT 0');
  // channel list of the extra guides (negative source ids), to match channels by id/name
  Exec('CREATE TABLE IF NOT EXISTS epg_channels (source_id INTEGER NOT NULL, ' +
    'channel_id TEXT NOT NULL, display_name TEXT NOT NULL DEFAULT '''')');
  Exec('CREATE INDEX IF NOT EXISTS idx_epgch_src ON epg_channels(source_id)');
  // per-item tvg-id override (empty => use the upstream stream's tvg-id)
  AddColumn('list_items', 'tvg_id_override TEXT NOT NULL DEFAULT ''''');
  // manual group drag-order (0 => unset, falls back to A→Z; favorites still first)
  AddColumn('list_groups', 'sort_order INTEGER NOT NULL DEFAULT 0');
  // change-tracking columns: present inline in the current CREATE TABLE, but a DB
  // created by an OLDER build that predates them would lack them, and
  // CREATE TABLE IF NOT EXISTS won't add them — then every catalog read / refresh
  // would fail with "no such column". These ALTERs are no-ops (swallowed) when the
  // columns already exist; they're nullable so they ADD cleanly to a populated table.
  AddColumn('streams', 'content_hash TEXT');
  AddColumn('streams', 'seen_at_utc TEXT');
  AddColumn('streams', 'first_seen_utc TEXT');
  AddColumn('streams', 'last_seen_utc TEXT');
  // catch-up window (Xtream tv_archive_duration), 0 = no archive
  AddColumn('streams', 'archive_days INTEGER NOT NULL DEFAULT 0');
  AddColumn('categories', 'seen_at_utc TEXT');
  // precomputed name-filter result (see RecomputeHidden): catalog queries test
  // `hidden=0` instead of evaluating hundreds of LIKE patterns per row
  AddColumn('streams', 'hidden INTEGER NOT NULL DEFAULT 0');
  AddColumn('categories', 'hidden INTEGER NOT NULL DEFAULT 0');

  // indexes for the hot paths
  Exec('CREATE INDEX IF NOT EXISTS idx_streams_source ON streams(source_id, content_type)');
  // group/category drill-down (catalog "show channels in this group")
  Exec('CREATE INDEX IF NOT EXISTS idx_streams_cat ON streams(source_id, content_type, category_upstream_id)');
  // name ordering + prefix LIKE (case-insensitive)
  Exec('CREATE INDEX IF NOT EXISTS idx_streams_name ON streams(name COLLATE NOCASE)');
  Exec('CREATE INDEX IF NOT EXISTS idx_cats_source ON categories(source_id, content_type)');
  Exec('CREATE INDEX IF NOT EXISTS idx_epg_chan ON epg(channel_tvg_id, start_utc)');
  Exec('CREATE INDEX IF NOT EXISTS idx_items_list ON list_items(list_id)');
  // enforce unique credentials only when a username is actually set
  Exec('CREATE UNIQUE INDEX IF NOT EXISTS idx_lists_user ON lists(output_username) ' +
       'WHERE output_username <> ''''');

  MigrateM3uStreamIds;
  RepairSourceTokens;

  // bring every source's hidden flags up to date (no-op when unchanged)
  Q := NewQuery;
  try
    Q.Open('SELECT id FROM sources');
    Ids := [];
    while not Q.Eof do
    begin
      Ids := Ids + [Q.Fields[0].AsInteger];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  for SrcId in Ids do
    RecomputeHidden(SrcId, False);
end;

// Undo the quote-doubling of old StrArrayToCsv (see IPTV.Core.Utils) and drop
// unusable (>200 char) filter items. The '"' removal runs in SQLite (C speed on a
// multi-hundred-MB value); then VACUUM once if that freed a lot of space.
procedure TSQLiteStore.RepairSourceTokens;
const
  VacuumAboveBytes = 64 * 1024 * 1024;
var
  Q: TFDQuery;
  Ids: TArray<Integer>;
  Id: Integer;
  Inc, Exc, NewInc, NewExc: string;
  Changed: Boolean;
begin
  Changed := False;
  for var Col in TArray<string>.Create('include_filters', 'exclude_filters', 'strip_prefixes', 'strip_suffixes') do
    if FConn.ExecSQL(Format('UPDATE sources SET %0:s = replace(%0:s, ''"'', '''') ' +
      'WHERE instr(%0:s, ''"'') > 0', [Col])) > 0 then
      Changed := True;

  Ids := [];
  Q := NewQuery;
  try
    Q.Open('SELECT id FROM sources');
    while not Q.Eof do
    begin
      Ids := Ids + [Q.Fields[0].AsInteger];
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  for Id in Ids do
  begin
    Q := NewQuery;
    try
      Q.Open('SELECT include_filters, exclude_filters FROM sources WHERE id = :id', [Id]);
      Inc := Q.Fields[0].AsString;
      Exc := Q.Fields[1].AsString;
    finally
      Q.Free;
    end;
    NewInc := StrArrayToCsv(CleanFilterTokens(CsvToStrArray(Inc)));
    NewExc := StrArrayToCsv(CleanFilterTokens(CsvToStrArray(Exc)));
    if (NewInc <> Inc) or (NewExc <> Exc) then
    begin
      FConn.ExecSQL('UPDATE sources SET include_filters = :i, exclude_filters = :e WHERE id = :id',
        [NewInc, NewExc, Id]);
      Changed := True;
    end;
  end;

  if Changed then
  begin
    Q := NewQuery;
    try
      Q.Open('SELECT (SELECT freelist_count FROM pragma_freelist_count) * ' +
             '(SELECT page_size FROM pragma_page_size)');
      if Q.Fields[0].AsLargeInt > VacuumAboveBytes then
      begin
        Q.Close;
        Exec('VACUUM');
      end;
    finally
      Q.Free;
    end;
  end;
end;

procedure TSQLiteStore.RecomputeHidden(ASourceId: Integer; AForce: Boolean);
const
  Chunk = 500;
var
  Q: TFDQuery;
  Src: TSourceConfig;
  PF: TPreparedNameFilter;
  Sig, Key, Table: string;
  ToHide, ToShow: TList<Integer>;
  WithVisible: THashSet<string>; // 'contenttype|category upstream id' having a visible stream
  Passes: Boolean;

  procedure Apply(const AIds: TList<Integer>; AValue: Integer);
  var
    I, J: Integer;
    SB: TStringBuilder;
  begin
    I := 0;
    while I < AIds.Count do
    begin
      SB := TStringBuilder.Create;
      try
        for J := I to Min(I + Chunk, AIds.Count) - 1 do
        begin
          if J > I then
            SB.Append(',');
          SB.Append(AIds[J]);
        end;
        Exec(Format('UPDATE %s SET hidden=%d WHERE id IN (%s)', [Table, AValue, SB.ToString]));
      finally
        SB.Free;
      end;
      Inc(I, Chunk);
    end;
  end;

begin
  Src := nil;
  Q := NewQuery;
  try
    Q.Open('SELECT * FROM sources WHERE id=:id', [ASourceId]);
    if Q.Eof then
      Exit;
    Src := ReadSource(Q);
    Q.Close;
    // 'v2': groups with a visible channel stay visible — bumping it recomputes
    // every source once after an upgrade
    Sig := THashBobJenkins.GetHashString('v2' + #3 +
      StrArrayToCsv(Src.IncludeFilters, #1) + #2 + StrArrayToCsv(Src.ExcludeFilters, #1));
    Key := 'hidden_sig_' + ASourceId.ToString;
    if (not AForce) and (GetState(Key) = Sig) then
      Exit;
    PF := PrepareNameFilter(Src.IncludeFilters, Src.ExcludeFilters);
    ToHide := TList<Integer>.Create;
    ToShow := TList<Integer>.Create;
    WithVisible := THashSet<string>.Create;
    try
      FConn.StartTransaction;
      try
        // streams FIRST: a group stays visible when it holds a visible channel
        // (e.g. include "UFC" keeps the UFC channels AND their "WORLD SPORTS"
        // group), unless an exclude token matches the group name itself
        for Table in TArray<string>.Create('streams', 'categories') do
        begin
          ToHide.Clear;
          ToShow.Clear;
          if Table = 'categories' then
          begin
            Q.Open('SELECT DISTINCT content_type, category_upstream_id FROM streams ' +
              'WHERE source_id=:s AND hidden=0', [ASourceId]);
            while not Q.Eof do
            begin
              WithVisible.Add(Q.Fields[0].AsString + '|' + Q.Fields[1].AsString);
              Q.Next;
            end;
            Q.Close;
            Q.Open('SELECT id, name, hidden, content_type, upstream_id FROM categories WHERE source_id=:s', [ASourceId]);
          end
          else
            Q.Open('SELECT id, name, hidden FROM streams WHERE source_id=:s', [ASourceId]);
          while not Q.Eof do
          begin
            Passes := PreparedNamePasses(PF, Q.Fields[1].AsWideString);
            if (not Passes) and (Table = 'categories') and
               WithVisible.Contains(Q.Fields[3].AsString + '|' + Q.Fields[4].AsString) and
               not PreparedNameExcluded(PF, Q.Fields[1].AsWideString) then
              Passes := True;
            if Passes then
            begin
              if Q.Fields[2].AsInteger <> 0 then
                ToShow.Add(Q.Fields[0].AsInteger);
            end
            else if Q.Fields[2].AsInteger = 0 then
              ToHide.Add(Q.Fields[0].AsInteger);
            Q.Next;
          end;
          Q.Close;
          Apply(ToHide, 1);
          Apply(ToShow, 0);
        end;
        FConn.Commit;
      except
        FConn.Rollback;
        raise;
      end;
    finally
      ToHide.Free;
      ToShow.Free;
      WithVisible.Free;
    end;
    SetState(Key, Sig);
  finally
    Q.Free;
    Src.Free;
  end;
end;

procedure TSQLiteStore.MigrateM3uStreamIds;
// One-time: M3U stream ids used to be SHA(full URL), which embeds the account
// credentials, so a new subscription at the same provider re-keyed every channel
// and detached the curated list_items. Re-key existing M3U streams to the
// credential-insensitive id (M3uStreamId) so current curation survives and the
// NEXT refresh matches in place. Guarded by an app_state flag so it runs once.
const
  FLAG = 'm3u_stream_id_v2';
type
  TSrcInfo = record Id: Integer; User, Pass: string; end;
var
  Q, Upd: TFDQuery;
  Srcs: TList<TSrcInfo>;
  Si, NewSi: TSrcInfo;
  Ids: TList<Integer>;
  NewIds: TList<string>;
  K: Integer;
  Nid: string;
begin
  Q := NewQuery;
  try
    Q.Open('SELECT value FROM app_state WHERE key=:k', [FLAG]);
    if not Q.Eof then
      Exit; // already migrated
  finally
    Q.Free;
  end;

  Srcs := TList<TSrcInfo>.Create;
  Ids := TList<Integer>.Create;
  NewIds := TList<string>.Create;
  try
    // collect m3u sources first (don't keep a cursor open while updating)
    Q := NewQuery;
    try
      Q.Open('SELECT id, username, password, url FROM sources WHERE kind=''m3u''');
      while not Q.Eof do
      begin
        NewSi.Id := Q.FieldByName('id').AsInteger;
        NewSi.User := Q.FieldByName('username').AsString;
        NewSi.Pass := Q.FieldByName('password').AsString;
        if NewSi.User = '' then
          NewSi.User := UrlQueryParam(Q.FieldByName('url').AsString, 'username');
        if NewSi.Pass = '' then
          NewSi.Pass := UrlQueryParam(Q.FieldByName('url').AsString, 'password');
        Srcs.Add(NewSi);
        Q.Next;
      end;
    finally
      Q.Free;
    end;

    Upd := NewQuery;
    try
      Upd.SQL.Text := 'UPDATE streams SET upstream_id=:new WHERE id=:id';
      for Si in Srcs do
      begin
        // collect this source's re-keyed rows, then close the cursor before updating
        Ids.Clear;
        NewIds.Clear;
        Q := NewQuery;
        try
          Q.Open('SELECT id, upstream_url, upstream_id FROM streams WHERE source_id=:s', [Si.Id]);
          while not Q.Eof do
          begin
            Nid := M3uStreamId(Q.FieldByName('upstream_url').AsString, Si.User, Si.Pass);
            if Nid <> Q.FieldByName('upstream_id').AsString then
            begin
              Ids.Add(Q.FieldByName('id').AsInteger);
              NewIds.Add(Nid);
            end;
            Q.Next;
          end;
        finally
          Q.Free;
        end;

        for K := 0 to Ids.Count - 1 do
        try
          Upd.ParamByName('new').AsWideString := NewIds[K];
          Upd.ParamByName('id').AsInteger := Ids[K];
          Upd.ExecSQL;
        except
          // a UNIQUE(source_id,content_type,upstream_id) clash (two rows that differ
          // only by credentials) — leave this row's old id; harmless and very rare.
        end;
      end;
    finally
      Upd.Free;
    end;

    Exec('INSERT OR REPLACE INTO app_state(key,value) VALUES(''' + FLAG + ''',''1'')');
  finally
    Srcs.Free;
    Ids.Free;
    NewIds.Free;
  end;
end;

// ── Sources ──────────────────────────────────────────────────────────────

function TSQLiteStore.ReadSource(Q: TFDQuery): TSourceConfig;
begin
  Result := TSourceConfig.Create;
  Result.Id := Q.FieldByName('id').AsInteger;
  Result.Name := Q.FieldByName('name').AsString;
  Result.Kind := SourceKindFromString(Q.FieldByName('kind').AsString);
  Result.Url := Q.FieldByName('url').AsString;
  Result.Username := Q.FieldByName('username').AsString;
  Result.Password := Q.FieldByName('password').AsString;
  Result.EpgUrl := Q.FieldByName('epg_url').AsString;
  Result.UserAgent := Q.FieldByName('user_agent').AsString;
  Result.Referer := Q.FieldByName('referer').AsString;
  Result.ForceHls := Q.FieldByName('force_hls').AsInteger <> 0;
  Result.Enabled := Q.FieldByName('enabled').AsInteger <> 0;
  Result.ContentTypes := StrToContentTypes(Q.FieldByName('content_types').AsString);
  Result.IncludeFilters := CsvToStrArray(Q.FieldByName('include_filters').AsString);
  Result.ExcludeFilters := CsvToStrArray(Q.FieldByName('exclude_filters').AsString);
  // strip prefixes use ';' so a token may itself contain spaces/commas/pipes
  Result.StripPrefixes := CsvToStrArray(Q.FieldByName('strip_prefixes').AsString, ';');
  Result.StripSuffixes := CsvToStrArray(Q.FieldByName('strip_suffixes').AsString, ';');
  Result.LastRefreshUtc := IsoUtcToDateTime(Q.FieldByName('last_refresh_utc').AsString);
  Result.AccountStatus := Q.FieldByName('account_status').AsString;
  Result.ExpiresUtc := IsoUtcToDateTime(Q.FieldByName('expires_utc').AsString);
  Result.MaxConnections := Q.FieldByName('max_connections').AsInteger;
  Result.TzOffsetMin := Q.FieldByName('tz_offset_min').AsInteger;
  Result.PreferOwnEpg := Q.FieldByName('prefer_own_epg').AsInteger <> 0;
end;

function TSQLiteStore.LoadSources: TObjectList<TSourceConfig>;
var
  Q: TFDQuery;
begin
  Result := TObjectList<TSourceConfig>.Create(True);
  Q := NewQuery;
  try
    Q.Open('SELECT * FROM sources ORDER BY name COLLATE NOCASE');
    while not Q.Eof do
    begin
      Result.Add(ReadSource(Q));
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TSQLiteStore.SaveSource(const ASource: TSourceConfig): Integer;
var
  Q: TFDQuery;
begin
  Q := NewQuery;
  try
    if ASource.Id = 0 then
      Q.SQL.Text :=
        'INSERT INTO sources(name,kind,url,username,password,epg_url,user_agent,referer,force_hls,enabled,content_types,' +
        'include_filters,exclude_filters,strip_prefixes,strip_suffixes,last_refresh_utc,account_status,expires_utc,max_connections,tz_offset_min,prefer_own_epg) ' +
        'VALUES(:name,:kind,:url,:username,:password,:epg_url,:user_agent,:referer,:force_hls,:enabled,:content_types,' +
        ':include_filters,:exclude_filters,:strip_prefixes,:strip_suffixes,:last_refresh_utc,:account_status,:expires_utc,:max_connections,:tz_offset_min,:prefer_own_epg)'
    else
    begin
      Q.SQL.Text :=
        'UPDATE sources SET name=:name,kind=:kind,url=:url,username=:username,password=:password,' +
        'epg_url=:epg_url,user_agent=:user_agent,referer=:referer,force_hls=:force_hls,enabled=:enabled,content_types=:content_types,' +
        'include_filters=:include_filters,exclude_filters=:exclude_filters,strip_prefixes=:strip_prefixes,' +
        'strip_suffixes=:strip_suffixes,last_refresh_utc=:last_refresh_utc,account_status=:account_status,expires_utc=:expires_utc,' +
        'max_connections=:max_connections,tz_offset_min=:tz_offset_min,prefer_own_epg=:prefer_own_epg WHERE id=:id';
      Q.ParamByName('id').AsInteger := ASource.Id;
    end;
    Q.ParamByName('name').AsWideString := ASource.Name;
    Q.ParamByName('kind').AsWideString := SourceKindNames[ASource.Kind];
    Q.ParamByName('url').AsWideString := ASource.Url;
    Q.ParamByName('username').AsWideString := ASource.Username;
    Q.ParamByName('password').AsWideString := ASource.Password;
    Q.ParamByName('epg_url').AsWideString := ASource.EpgUrl;
    Q.ParamByName('user_agent').AsWideString := ASource.UserAgent;
    Q.ParamByName('referer').AsWideString := ASource.Referer;
    Q.ParamByName('force_hls').AsInteger := Ord(ASource.ForceHls);
    Q.ParamByName('enabled').AsInteger := Ord(ASource.Enabled);
    Q.ParamByName('content_types').AsWideString := ContentTypesToStr(ASource.ContentTypes);
    Q.ParamByName('include_filters').AsWideString := StrArrayToCsv(ASource.IncludeFilters);
    Q.ParamByName('exclude_filters').AsWideString := StrArrayToCsv(ASource.ExcludeFilters);
    Q.ParamByName('strip_prefixes').AsWideString := StrArrayToCsv(ASource.StripPrefixes, ';');
    Q.ParamByName('strip_suffixes').AsWideString := StrArrayToCsv(ASource.StripSuffixes, ';');
    Q.ParamByName('last_refresh_utc').AsWideString := DateTimeToIsoUtc(ASource.LastRefreshUtc);
    Q.ParamByName('account_status').AsWideString := ASource.AccountStatus;
    Q.ParamByName('expires_utc').AsWideString := DateTimeToIsoUtc(ASource.ExpiresUtc);
    Q.ParamByName('max_connections').AsInteger := ASource.MaxConnections;
    Q.ParamByName('tz_offset_min').AsInteger := ASource.TzOffsetMin;
    Q.ParamByName('prefer_own_epg').AsInteger := Ord(ASource.PreferOwnEpg);
    Q.ExecSQL;

    if ASource.Id = 0 then
      Result := FConn.GetLastAutoGenValue('')
    else
      Result := ASource.Id;
    ASource.Id := Result;
  finally
    Q.Free;
  end;
  RecomputeHidden(Result, False); // filters may have changed (no-op otherwise)
end;

procedure TSQLiteStore.DeleteSource(AId: Integer);
begin
  // there are no FK cascades, so clean dependents by hand. Remove list_items that
  // point at this source's streams FIRST, else they dangle (orphaned rows that
  // LoadOutputChannels silently drops and the UI can never repair).
  FConn.ExecSQL(
    'DELETE FROM list_items WHERE stream_item_id IN ' +
    '(SELECT id FROM streams WHERE source_id=:id)', [AId]);
  FConn.ExecSQL('DELETE FROM streams WHERE source_id=:id', [AId]);
  FConn.ExecSQL('DELETE FROM categories WHERE source_id=:id', [AId]);
  FConn.ExecSQL('DELETE FROM epg WHERE source_id=:id', [AId]);
  FConn.ExecSQL('DELETE FROM sources WHERE id=:id', [AId]);
  TouchLineup;
end;

// ── Catalog ────────────────────────────────────────────────────────────────

procedure TSQLiteStore.MergeSnapshot(const ASnapshot: TSourceSnapshot);
var
  Cat: TCategory;
  S: TStreamItem;
  Now_, Key: string;
  CatKeys, StrKeys: TDictionary<string, Boolean>;
  LoadQ, CatIns, CatUpd, StrIns, StrUpd: TFDQuery;

  function LoadKeys(const ATable: string): TDictionary<string, Boolean>;
  begin
    Result := TDictionary<string, Boolean>.Create;
    LoadQ.Close;
    LoadQ.Open('SELECT content_type, upstream_id FROM ' + ATable + ' WHERE source_id=:s',
      [ASnapshot.SourceId]);
    while not LoadQ.Eof do
    begin
      Result.AddOrSetValue(LoadQ.FieldByName('content_type').AsString + '|' +
        LoadQ.FieldByName('upstream_id').AsString, True);
      LoadQ.Next;
    end;
  end;

begin
  Now_ := DateTimeToIsoUtc(NowUtc);
  LoadQ := NewQuery; CatIns := NewQuery; CatUpd := NewQuery; StrIns := NewQuery; StrUpd := NewQuery;
  CatKeys := nil; StrKeys := nil;
  try
    // one read each instead of a SELECT per row; lets us decide insert vs update
    // (and so flag is_new) in memory.
    CatKeys := LoadKeys('categories');
    StrKeys := LoadKeys('streams');

    // prepared once, reused per row (no SQL re-parse per item)
    CatIns.SQL.Text := 'INSERT INTO categories(source_id,upstream_id,content_type,name,is_new) VALUES(:s,:u,:c,:n,1)';
    CatUpd.SQL.Text := 'UPDATE categories SET name=:n WHERE source_id=:s AND content_type=:c AND upstream_id=:u';
    StrIns.SQL.Text := 'INSERT INTO streams(source_id,upstream_id,content_type,name,logo,group_title,' +
      'category_upstream_id,tvg_id,tvg_name,upstream_url,content_hash,archive_days,is_new,first_seen_utc,last_seen_utc) ' +
      'VALUES(:s,:u,:c,:n,:logo,:grp,:cat,:tvg,:tvgn,:url,:hash,:arch,1,:now,:now)';
    StrUpd.SQL.Text := 'UPDATE streams SET name=:n,logo=:logo,group_title=:grp,category_upstream_id=:cat,' +
      'tvg_id=:tvg,tvg_name=:tvgn,upstream_url=:url,content_hash=:hash,archive_days=:arch,last_seen_utc=:now ' +
      'WHERE source_id=:s AND content_type=:c AND upstream_id=:u';

    FConn.StartTransaction;
    try
      for Cat in ASnapshot.Categories do
      begin
        Key := ContentTypeNames[Cat.ContentType] + '|' + Cat.UpstreamId;
        if CatKeys.ContainsKey(Key) then
        begin
          CatUpd.ParamByName('n').AsWideString := Cat.Name;
          CatUpd.ParamByName('s').AsInteger := ASnapshot.SourceId;
          CatUpd.ParamByName('c').AsWideString := ContentTypeNames[Cat.ContentType];
          CatUpd.ParamByName('u').AsWideString := Cat.UpstreamId;
          CatUpd.ExecSQL;
        end
        else
        begin
          CatIns.ParamByName('s').AsInteger := ASnapshot.SourceId;
          CatIns.ParamByName('u').AsWideString := Cat.UpstreamId;
          CatIns.ParamByName('c').AsWideString := ContentTypeNames[Cat.ContentType];
          CatIns.ParamByName('n').AsWideString := Cat.Name;
          CatIns.ExecSQL;
          CatKeys.AddOrSetValue(Key, True);
        end;
      end;

      for S in ASnapshot.Streams do
      begin
        Key := ContentTypeNames[S.ContentType] + '|' + S.UpstreamId;
        if StrKeys.ContainsKey(Key) then
        begin
          StrUpd.ParamByName('n').AsWideString := S.Name;
          StrUpd.ParamByName('logo').AsWideString := S.Logo;
          StrUpd.ParamByName('grp').AsWideString := S.GroupTitle;
          StrUpd.ParamByName('cat').AsWideString := S.CategoryUpstreamId;
          StrUpd.ParamByName('tvg').AsWideString := S.TvgId;
          StrUpd.ParamByName('tvgn').AsWideString := S.TvgName;
          StrUpd.ParamByName('url').AsWideString := S.UpstreamUrl;
          StrUpd.ParamByName('hash').AsWideString := StreamHash(S);
          StrUpd.ParamByName('arch').AsInteger := S.ArchiveDays;
          StrUpd.ParamByName('now').AsWideString := Now_;
          StrUpd.ParamByName('s').AsInteger := ASnapshot.SourceId;
          StrUpd.ParamByName('c').AsWideString := ContentTypeNames[S.ContentType];
          StrUpd.ParamByName('u').AsWideString := S.UpstreamId;
          StrUpd.ExecSQL;
        end
        else
        begin
          StrIns.ParamByName('s').AsInteger := ASnapshot.SourceId;
          StrIns.ParamByName('u').AsWideString := S.UpstreamId;
          StrIns.ParamByName('c').AsWideString := ContentTypeNames[S.ContentType];
          StrIns.ParamByName('n').AsWideString := S.Name;
          StrIns.ParamByName('logo').AsWideString := S.Logo;
          StrIns.ParamByName('grp').AsWideString := S.GroupTitle;
          StrIns.ParamByName('cat').AsWideString := S.CategoryUpstreamId;
          StrIns.ParamByName('tvg').AsWideString := S.TvgId;
          StrIns.ParamByName('tvgn').AsWideString := S.TvgName;
          StrIns.ParamByName('url').AsWideString := S.UpstreamUrl;
          StrIns.ParamByName('hash').AsWideString := StreamHash(S);
          StrIns.ParamByName('arch').AsInteger := S.ArchiveDays;
          StrIns.ParamByName('now').AsWideString := Now_;
          StrIns.ExecSQL;
          StrKeys.AddOrSetValue(Key, True); // guard against duplicates within one snapshot
        end;
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
  finally
    CatKeys.Free; StrKeys.Free;
    StrUpd.Free; StrIns.Free; CatUpd.Free; CatIns.Free; LoadQ.Free;
  end;
  // new rows arrive with hidden=0: re-apply this source's filters to them
  RecomputeHidden(ASnapshot.SourceId, True);
end;

function TSQLiteStore.ReadCategory(Q: TFDQuery): TCategory;
begin
  Result := TCategory.Create;
  Result.Id := Q.FieldByName('id').AsInteger;
  Result.SourceId := Q.FieldByName('source_id').AsInteger;
  Result.UpstreamId := Q.FieldByName('upstream_id').AsString;
  Result.ContentType := ContentTypeFromString(Q.FieldByName('content_type').AsString);
  Result.Name := Q.FieldByName('name').AsString;
  Result.IsNew := Q.FieldByName('is_new').AsInteger <> 0;
  Result.SeenAtUtc := IsoUtcToDateTime(Q.FieldByName('seen_at_utc').AsString);
end;

function TSQLiteStore.ReadStream(Q: TFDQuery): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.Id := Q.FieldByName('id').AsInteger;
  Result.SourceId := Q.FieldByName('source_id').AsInteger;
  Result.UpstreamId := Q.FieldByName('upstream_id').AsString;
  Result.ContentType := ContentTypeFromString(Q.FieldByName('content_type').AsString);
  Result.Name := Q.FieldByName('name').AsWideString;
  Result.Logo := Q.FieldByName('logo').AsWideString;
  Result.GroupTitle := Q.FieldByName('group_title').AsWideString;
  Result.CategoryUpstreamId := Q.FieldByName('category_upstream_id').AsString;
  Result.TvgId := Q.FieldByName('tvg_id').AsString;
  Result.TvgName := Q.FieldByName('tvg_name').AsString;
  Result.UpstreamUrl := Q.FieldByName('upstream_url').AsString;
  Result.ContentHash := Q.FieldByName('content_hash').AsString;
  // FindField: a few callers select an explicit column list
  if Q.FindField('archive_days') <> nil then
    Result.ArchiveDays := Q.FindField('archive_days').AsInteger;
  Result.IsNew := Q.FieldByName('is_new').AsInteger <> 0;
  Result.SeenAtUtc := IsoUtcToDateTime(Q.FieldByName('seen_at_utc').AsString);
  Result.FirstSeenUtc := IsoUtcToDateTime(Q.FieldByName('first_seen_utc').AsString);
  Result.LastSeenUtc := IsoUtcToDateTime(Q.FieldByName('last_seen_utc').AsString);
end;

// Build a SQL fragment that hides names not matching the source's filters.
// A token matches as a whole, separator-delimited PREFIX or SUFFIX word,
// case-insensitive (SQLite LIKE is ASCII-CI) — consistent with StripNamePrefixes.
// We first map every separator (| - : tab) to a space and trim, so a token like
// "NL" matches "NL| x", "|NL| x", " | NL | x" or "x | NL" alike, but never the
// middle of a word ("Netherlands"). Tokens come from operator config; we escape
// LIKE wildcards just in case.
function NameFilterSql(const ACol: string; const AInclude, AExclude: TArray<string>): string;

  function EscapeLike(const S: string): string;
  begin
    Result := S.Replace('\', '\\').Replace('%', '\%').Replace('_', '\_');
  end;

  // SQL that yields ACol with all separators turned into spaces and trimmed, so
  // word-boundary LIKE patterns can match against it. Covers the ASCII separators
  // AND the Unicode vertical bars providers decorate names with (┃ │ ¦ ｜ …),
  // expressed as char(codepoint) so no non-ASCII literal sits in the SQL text.
  function NormCol: string;
  const
    Seps: array[0..11] of string = (
      '''|''', '''-''', ''':''', 'char(9)', 'char(166)',
      'char(9474)', 'char(9475)', 'char(9478)', 'char(9479)',
      'char(9482)', 'char(9483)', 'char(65340)');
  var
    I: Integer;
  begin
    Result := ACol;
    for I := Low(Seps) to High(Seps) do
      Result := 'REPLACE(' + Result + ', ' + Seps[I] + ', '' '')';
    Result := 'TRIM(' + Result + ')';
  end;

  // normalise a configured token the same way (seps -> space, trim) so it lines
  // up with NormCol (e.g. "NL|", "|NL|", "┃NL┃" all become "NL").
  function NormToken(const S: string): string;
  begin
    Result := S
      .Replace('|', ' ').Replace('-', ' ').Replace(':', ' ').Replace(#9, ' ')
      .Replace(#$00A6, ' ').Replace(#$2502, ' ').Replace(#$2503, ' ')
      .Replace(#$2506, ' ').Replace(#$2507, ' ').Replace(#$250A, ' ')
      .Replace(#$250B, ' ').Replace(#$FF5C, ' ')
      .Trim;
  end;

  function Like(const APattern: string): string;
  begin
    Result := NormCol + ' LIKE ' + QuotedStr(APattern) + ' ESCAPE ' + QuotedStr('\');
  end;

  // (col LIKE 'tok%' OR col LIKE '%tok' OR ...) across all tokens, built as a
  // BALANCED OR tree. A flat 'a OR b OR c …' chain nests to depth N and blows
  // SQLite's expression-depth limit (1000) once a source has a few hundred
  // filter tokens; balancing keeps depth at O(log N).
  function BalancedOr(const ALeaves: TArray<string>; ALo, AHi: Integer): string;
  var
    Mid: Integer;
  begin
    if ALo = AHi then
      Result := ALeaves[ALo]
    else
    begin
      Mid := (ALo + AHi) div 2;
      Result := '(' + BalancedOr(ALeaves, ALo, Mid) + ' OR ' + BalancedOr(ALeaves, Mid + 1, AHi) + ')';
    end;
  end;

  function AnyMatch(const ATokens: TArray<string>): string;
  var
    T, Esc: string;
    Leaves: TList<string>;
  begin
    Leaves := TList<string>.Create;
    try
      for T in ATokens do
        if NormToken(T) <> '' then
        begin
          Esc := EscapeLike(NormToken(T));
          // whole name, or token as the first word, or token as the last word
          Leaves.Add('(' + Like(Esc) + ' OR ' + Like(Esc + ' %') + ' OR ' + Like('% ' + Esc) + ')');
        end;
      if Leaves.Count = 0 then
        Result := ''
      else
        Result := BalancedOr(Leaves.ToArray, 0, Leaves.Count - 1);
    finally
      Leaves.Free;
    end;
  end;

var
  Inc_, Exc_: string;
begin
  Result := '';
  // drop pasted-list / oversized tokens first (SQLite rejects LIKE patterns over
  // 50 000 chars and such a token can't match a real name anyway)
  Inc_ := AnyMatch(CleanFilterTokens(AInclude));
  if Inc_ <> '' then
    Result := Result + ' AND ' + Inc_;
  Exc_ := AnyMatch(CleanFilterTokens(AExclude));
  if Exc_ <> '' then
    Result := Result + ' AND NOT ' + Exc_;
end;

// Full name-filter fragment for a catalog query: the global filter (no source
// guard, for a single selected source) plus each per-source filter guarded by
// its source_id (so the "all sources" view filters every source by its own rules).
function CatalogFilterSql(const AFilter: TCatalogFilter; const ACol: string): string;
var
  SF: TSourceFilter;
  Sub: string;
begin
  Result := NameFilterSql(ACol, AFilter.IncludeFilters, AFilter.ExcludeFilters);
  for SF in AFilter.SourceFilters do
  begin
    Sub := NameFilterSql(ACol, SF.IncludeFilters, SF.ExcludeFilters);
    if Sub <> '' then
      // a row passes if it's from another source, or it satisfies this source's filter
      Result := Result + Format(' AND (source_id <> %d OR (1=1%s))', [SF.SourceId, Sub]);
  end;
end;

// Multi-word search: split on commas/whitespace and AND each term as a
// case-insensitive substring (so "NL UHD" keeps only names containing BOTH).
function SearchSql(const ACol, ASearch: string): string;

  function Esc(const S: string): string;
  begin
    Result := S.Replace('\', '\\').Replace('%', '\%').Replace('_', '\_');
  end;

var
  Terms: TArray<string>;
  T: string;
begin
  Result := '';
  Terms := ASearch.Split([',', ' ', #9], TStringSplitOptions.ExcludeEmpty);
  for T in Terms do
    Result := Result + ' AND ' + ACol + ' LIKE ' + QuotedStr('%' + Esc(T) + '%') +
      ' ESCAPE ' + QuotedStr('\');
end;

// in-memory twin of CatalogFilterSql for the categories list. Filters are
// prepared ONCE per query (cleaning/normalising hundreds of tokens per group
// name pegged the CPU in 1.2.12).
type
  TPreparedCatalogFilter = record
    Global: TPreparedNameFilter;
    SourceIds: TArray<Integer>;
    PerSource: TArray<TPreparedNameFilter>;
  end;

function PrepareCatalogFilter(const AFilter: TCatalogFilter): TPreparedCatalogFilter;
var
  I: Integer;
begin
  Result.Global := PrepareNameFilter(AFilter.IncludeFilters, AFilter.ExcludeFilters);
  SetLength(Result.SourceIds, Length(AFilter.SourceFilters));
  SetLength(Result.PerSource, Length(AFilter.SourceFilters));
  for I := 0 to High(AFilter.SourceFilters) do
  begin
    Result.SourceIds[I] := AFilter.SourceFilters[I].SourceId;
    Result.PerSource[I] := PrepareNameFilter(AFilter.SourceFilters[I].IncludeFilters,
      AFilter.SourceFilters[I].ExcludeFilters);
  end;
end;

function CategoryPassesFilter(const ACat: TCategory; const AFilter: TPreparedCatalogFilter): Boolean;
var
  I: Integer;
begin
  if not PreparedNamePasses(AFilter.Global, ACat.Name) then
    Exit(False);
  for I := 0 to High(AFilter.SourceIds) do
    if (AFilter.SourceIds[I] = ACat.SourceId) and
       not PreparedNamePasses(AFilter.PerSource[I], ACat.Name) then
      Exit(False);
  Result := True;
end;

function TSQLiteStore.LoadCategories(const AFilter: TCatalogFilter): TCategoryList;
var
  Q: TFDQuery;
  Where: string;
  Cat: TCategory;
  Prepared: TPreparedCatalogFilter;
begin
  Result := TCategoryList.Create(True);
  Prepared := PrepareCatalogFilter(AFilter);
  Q := NewQuery;
  try
    Where := ' WHERE 1=1';
    if AFilter.SourceId > 0 then
      Where := Where + ' AND source_id=' + AFilter.SourceId.ToString;
    if AFilter.HasContentType then
      Where := Where + ' AND content_type=' + QuotedStr(ContentTypeNames[AFilter.ContentType]);
    if AFilter.OnlyNew then
      Where := Where + ' AND is_new=1';
    if AFilter.UseHiddenFlag then
      Where := Where + ' AND hidden=0';
    Where := Where + SearchSql('name', AFilter.Search); // multi-word AND search
    Q.SQL.Text := 'SELECT * FROM categories' + Where + ' ORDER BY name COLLATE NOCASE';
    Q.Open;
    // hide groups whose name matches the source's filters (live view filter) —
    // done here in memory, not as SQL: with hundreds of filter tokens the nested
    // REPLACE/LIKE tree made this the slowest query in the app (~20 s on the NAS)
    // while holding the single DB connection. Groups are few; matching is cheap.
    while not Q.Eof do
    begin
      Cat := ReadCategory(Q);
      if CategoryPassesFilter(Cat, Prepared) then
        Result.Add(Cat)
      else
        Cat.Free;
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

// escape LIKE wildcards in a literal so a '%' or '_' in the value is matched
// literally (paired with an ESCAPE '\' clause) — a discovered prefix can legitimately
// contain '%'/'_' (e.g. a "100% HD" group), which would otherwise match anything.
function EscapeLikeLiteral(const S: string): string;
begin
  Result := S.Replace('\', '\\').Replace('%', '\%').Replace('_', '\_');
end;

// shared WHERE builder + param binder for stream queries
function StreamWhere(const AFilter: TCatalogFilter): string;
begin
  Result := ' WHERE 1=1';
  if AFilter.SourceId > 0 then
    Result := Result + ' AND source_id=' + AFilter.SourceId.ToString;
  if AFilter.HasContentType then
    Result := Result + ' AND content_type=' + QuotedStr(ContentTypeNames[AFilter.ContentType]);
  if AFilter.OnlyNew then
    Result := Result + ' AND is_new=1';
  Result := Result + SearchSql('name', AFilter.Search); // multi-word AND search
  if AFilter.Prefix <> '' then
    Result := Result + ' AND name LIKE :prefix ESCAPE ''\''';
  if AFilter.HasCategory then
    Result := Result + ' AND category_upstream_id = :cat';
  if AFilter.UseHiddenFlag then
    Result := Result + ' AND hidden=0';
  Result := Result + CatalogFilterSql(AFilter, 'name');
end;

procedure BindStreamFilter(Q: TFDQuery; const AFilter: TCatalogFilter);
begin
  if AFilter.Prefix <> '' then
    // escape wildcards in the literal prefix; the trailing '%' stays a wildcard
    Q.ParamByName('prefix').AsWideString := EscapeLikeLiteral(AFilter.Prefix) + '%';
  if AFilter.HasCategory then
    Q.ParamByName('cat').AsWideString := AFilter.CategoryUpstreamId;
end;

function TSQLiteStore.LoadStreams(const AFilter: TCatalogFilter): TStreamItemList;
var
  Q: TFDQuery;
  Sql: string;
begin
  Result := TStreamItemList.Create(True);
  Q := NewQuery;
  try
    Sql := 'SELECT * FROM streams' + StreamWhere(AFilter) + ' ORDER BY name COLLATE NOCASE';
    if AFilter.Limit > 0 then
      Sql := Sql + ' LIMIT :limit OFFSET :offset';
    Q.SQL.Text := Sql;
    BindStreamFilter(Q, AFilter);
    if AFilter.Limit > 0 then
    begin
      Q.ParamByName('limit').AsInteger := AFilter.Limit;
      Q.ParamByName('offset').AsInteger := AFilter.Offset;
    end;
    Q.Open;
    while not Q.Eof do
    begin
      Result.Add(ReadStream(Q));
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TSQLiteStore.CountStreams(const AFilter: TCatalogFilter): Integer;
var
  Q: TFDQuery;
begin
  Q := NewQuery;
  try
    Q.SQL.Text := 'SELECT COUNT(*) AS c FROM streams' + StreamWhere(AFilter);
    BindStreamFilter(Q, AFilter);
    Q.Open;
    Result := Q.FieldByName('c').AsInteger;
  finally
    Q.Free;
  end;
end;

procedure TSQLiteStore.MarkCategoriesSeen(const AIds: TArray<Integer>);
begin
  if Length(AIds) = 0 then
    Exit;
  FConn.ExecSQL(Format('UPDATE categories SET is_new=0, seen_at_utc=%s WHERE id IN (%s)',
    [QuotedStr(DateTimeToIsoUtc(NowUtc)), IdsToCsv(AIds)]));
end;

procedure TSQLiteStore.MarkStreamsSeen(const AIds: TArray<Integer>);
begin
  if Length(AIds) = 0 then
    Exit;
  FConn.ExecSQL(Format('UPDATE streams SET is_new=0, seen_at_utc=%s WHERE id IN (%s)',
    [QuotedStr(DateTimeToIsoUtc(NowUtc)), IdsToCsv(AIds)]));
end;

function TSQLiteStore.LoadStreamById(AId: Integer): TStreamItem;
var
  Q: TFDQuery;
begin
  Result := nil;
  Q := NewQuery;
  try
    Q.Open('SELECT * FROM streams WHERE id=:id', [AId]);
    if not Q.IsEmpty then
      Result := ReadStream(Q);
  finally
    Q.Free;
  end;
end;

function TSQLiteStore.LoadStreamSiblings(AStreamItemId: Integer): TArray<string>;
var
  Q: TFDQuery;
  Ct, Tvg, Nm: string;
  L: TList<string>;
begin
  Result := nil;
  Q := NewQuery;
  try
    Q.Open('SELECT content_type, tvg_id, name FROM streams WHERE id = :id', [AStreamItemId]);
    if Q.IsEmpty then
      Exit;
    Ct := Q.FieldByName('content_type').AsString;
    Tvg := Q.FieldByName('tvg_id').AsString;
    Nm := Q.FieldByName('name').AsString;
    Q.Close;
    L := TList<string>.Create;
    try
      // same channel from a DIFFERENT row: by tvg-id when present (reliable), else by
      // exact case-insensitive name (conservative — avoids failing over to a wrong
      // channel). Same content type; skip self and empty URLs.
      Q.SQL.Text :=
        'SELECT upstream_url FROM streams ' +
        'WHERE id <> :id AND content_type = :ct AND upstream_url <> '''' AND (' +
        '  (:tvg <> '''' AND tvg_id = :tvg) OR ' +
        '  (:tvg = '''' AND name = :nm COLLATE NOCASE)) ' +
        'ORDER BY source_id';
      Q.ParamByName('id').AsInteger := AStreamItemId;
      Q.ParamByName('ct').AsWideString := Ct;
      Q.ParamByName('tvg').AsWideString := Tvg;
      Q.ParamByName('nm').AsWideString := Nm;
      Q.Open;
      while not Q.Eof do
      begin
        L.Add(Q.FieldByName('upstream_url').AsString);
        Q.Next;
      end;
      Result := L.ToArray;
    finally
      L.Free;
    end;
  finally
    Q.Free;
  end;
end;

function TSQLiteStore.LoadListStreamById(AListId, AStreamItemId: Integer): TStreamItem;
var
  Q: TFDQuery;
begin
  // only return the stream when it is actually an item on this list, so the
  // credential-scoped output can't serve a stream off another list / not curated.
  Result := nil;
  Q := NewQuery;
  try
    Q.Open(
      'SELECT s.* FROM streams s JOIN list_items i ON i.stream_item_id = s.id ' +
      'WHERE i.list_id = :l AND s.id = :id LIMIT 1', [AListId, AStreamItemId]);
    if not Q.IsEmpty then
      Result := ReadStream(Q);
  finally
    Q.Free;
  end;
end;

function TSQLiteStore.DiscoverPrefixes(ASourceId: Integer): TArray<TPrefixCount>;
var
  Q: TFDQuery;
  Counts: TDictionary<string, Integer>;
  Prefix: string;
  N: Integer;
  Pair: TPair<string, Integer>;
  I: Integer;
begin
  Counts := TDictionary<string, Integer>.Create;
  Q := NewQuery;
  try
    // Scan BOTH channel names and category/group names: the operator filters by
    // either, and groups often use a different prefix scheme than their channels
    // (e.g. group "AL| ALBANIA" while channels are "ALB| ..."). Surfacing both
    // lets a single exclude token hide the matching groups AND channels.
    for var Tbl in ['streams', 'categories'] do
    begin
      if ASourceId > 0 then
        Q.Open(Format('SELECT name FROM %s WHERE source_id=:s', [Tbl]), [ASourceId])
      else
        Q.Open(Format('SELECT name FROM %s', [Tbl]));
      while not Q.Eof do
      begin
        Prefix := ExtractNamePrefix(Q.Fields[0].AsString);
        if Prefix <> '' then
        begin
          Counts.TryGetValue(Prefix, N);
          Counts.AddOrSetValue(Prefix, N + 1);
        end;
        Q.Next;
      end;
      Q.Close;
    end;

    SetLength(Result, Counts.Count);
    I := 0;
    for Pair in Counts do
    begin
      Result[I].Prefix := Pair.Key;
      Result[I].Count := Pair.Value;
      Inc(I);
    end;
    // most common first, then alphabetical (case-insensitive) as a tiebreaker
    TArray.Sort<TPrefixCount>(Result, TComparer<TPrefixCount>.Construct(
      function(const A, B: TPrefixCount): Integer
      begin
        Result := B.Count - A.Count;
        if Result = 0 then
          Result := CompareText(A.Prefix, B.Prefix);
      end));
  finally
    Q.Free;
    Counts.Free;
  end;
end;

function TSQLiteStore.LoadKnownTvgIds: TArray<TTvgIdInfo>;
var
  Q: TFDQuery;
  L: TList<TTvgIdInfo>;
  Info: TTvgIdInfo;
begin
  L := TList<TTvgIdInfo>.Create;
  Q := NewQuery;
  try
    // distinct tvg-ids in the catalog with one representative channel name
    Q.Open('SELECT tvg_id, MIN(name) AS nm FROM streams WHERE tvg_id <> '''' ' +
           'GROUP BY tvg_id ORDER BY nm COLLATE NOCASE');
    while not Q.Eof do
    begin
      Info.TvgId := Q.FieldByName('tvg_id').AsString;
      Info.Name := Q.FieldByName('nm').AsString;
      L.Add(Info);
      Q.Next;
    end;
    Result := L.ToArray;
  finally
    Q.Free;
    L.Free;
  end;
end;

function TSQLiteStore.FindQualityVariants(AListId, ASourceGroupId: Integer;
  const ATargetQuality: string): TArray<TVariantMatch>;
type
  TCand = record Id, SourceId: Integer; Name: string; end;
  TRules = record Prefixes, Suffixes: TArray<string>; end;
var
  Q: TFDQuery;
  Items: TList<TVariantMatch>;
  ItemSrc: TList<Integer>;  // parallel to Items: source_id (same-source preference)
  Bases: TList<string>;     // parallel to Items: quality-stripped base key
  Heads: TList<string>;     // parallel to Items: tokens before the quality word
  NeededBase, NeededHead: TDictionary<string, Boolean>;
  DictBase, DictHead: TDictionary<string, TList<TCand>>;
  InList: TDictionary<Integer, Boolean>;
  Rules: TDictionary<Integer, TRules>;
  Cts: TStringList;
  Target, Base, Head, Qual, InClause: string;
  M: TVariantMatch;
  Cand: TCand;
  Cands: TList<TCand>;
  R: TRules;
  I, Picked: Integer;

  // the match key is computed on the CLEANED name (the source's strip prefixes
  // and suffixes removed, e.g. "NL |" and "(S)"), so tags that differ between
  // variants don't break the match; decorative letters are folded by the key
  function KeyOf(const AName: string; ASourceId: Integer; out AQual, AHead: string): string;
  var
    Rr: TRules;
  begin
    if Rules.TryGetValue(ASourceId, Rr) then
      Result := QualityMatchKey(CleanChannelName(AName, Rr.Prefixes, Rr.Suffixes), AQual, AHead)
    else
      Result := QualityMatchKey(AName, AQual, AHead);
  end;

  procedure AddCand(ADict: TDictionary<string, TList<TCand>>; const AKey: string; const C: TCand);
  var
    L: TList<TCand>;
  begin
    if not ADict.TryGetValue(AKey, L) then
    begin
      L := TList<TCand>.Create;
      ADict.Add(AKey, L);
    end;
    L.Add(C);
  end;

  // prefer the SAME source, never the item's own stream; among equals the
  // shortest name (the plainest variant, e.g. "NPO 1 4K+" over "NPO 1 4K+ backup")
  function Pick(L: TList<TCand>; AOwnStream, ASrc: Integer): Integer;
  var
    K: Integer;
  begin
    Result := -1;
    for K := 0 to L.Count - 1 do
      if (L[K].Id <> AOwnStream) and (L[K].SourceId = ASrc) and
         ((Result < 0) or (Length(L[K].Name) < Length(L[Result].Name))) then
        Result := K;
    if Result < 0 then
      for K := 0 to L.Count - 1 do
        if (L[K].Id <> AOwnStream) and
           ((Result < 0) or (Length(L[K].Name) < Length(L[Result].Name))) then
          Result := K;
  end;

begin
  Target := CanonicalQuality(ATargetQuality);
  if Target = '' then
    Exit(nil); // unknown/blank target quality

  Items := TList<TVariantMatch>.Create;
  ItemSrc := TList<Integer>.Create;
  Bases := TList<string>.Create;
  Heads := TList<string>.Create;
  NeededBase := TDictionary<string, Boolean>.Create;
  NeededHead := TDictionary<string, Boolean>.Create;
  DictBase := TDictionary<string, TList<TCand>>.Create;
  DictHead := TDictionary<string, TList<TCand>>.Create;
  InList := TDictionary<Integer, Boolean>.Create;
  Rules := TDictionary<Integer, TRules>.Create;
  Cts := TStringList.Create;
  try
    Cts.Sorted := True;
    Cts.Duplicates := dupIgnore;

    // 0. every source's strip rules (few rows)
    Q := NewQuery;
    try
      Q.Open('SELECT id, strip_prefixes, strip_suffixes FROM sources');
      while not Q.Eof do
      begin
        R.Prefixes := CsvToStrArray(Q.Fields[1].AsString, ';');
        R.Suffixes := CsvToStrArray(Q.Fields[2].AsString, ';');
        Rules.AddOrSetValue(Q.Fields[0].AsInteger, R);
        Q.Next;
      end;
    finally
      Q.Free;
    end;

    // 1. the source group's items + their current (ORIGINAL upstream) stream name.
    //    Matching uses the stream's own name, never the list's stripped display
    //    name, so a prefix/suffix stripped on the list doesn't matter.
    Q := NewQuery;
    try
      Q.Open(
        'SELECT i.id AS iid, i.stream_item_id AS sid, s.name AS sname, ' +
        '  s.content_type AS ct, s.source_id AS srcid ' +
        'FROM list_items i JOIN streams s ON s.id = i.stream_item_id ' +
        'WHERE i.list_id = :l AND i.custom_group_id = :g ' +
        'ORDER BY i.channel_number, sname COLLATE NOCASE', [AListId, ASourceGroupId]);
      while not Q.Eof do
      begin
        M := Default(TVariantMatch);
        M.ItemId := Q.FieldByName('iid').AsInteger;
        M.StreamId := Q.FieldByName('sid').AsInteger;
        M.Name := Q.FieldByName('sname').AsString;
        Base := KeyOf(M.Name, Q.FieldByName('srcid').AsInteger, Qual, Head);
        M.Quality := Qual;
        Items.Add(M);
        Bases.Add(Base);
        Heads.Add(Head);
        ItemSrc.Add(Q.FieldByName('srcid').AsInteger);
        if Base <> '' then
          NeededBase.AddOrSetValue(Base, True);
        if Head <> '' then
          NeededHead.AddOrSetValue(Head, True);
        Cts.Add(Q.FieldByName('ct').AsString);
        Q.Next;
      end;
    finally
      Q.Free;
    end;
    if Items.Count = 0 then
      Exit(nil);

    // 2. stream ids already on this list (a candidate already here can't be re-added)
    Q := NewQuery;
    try
      Q.Open('SELECT stream_item_id FROM list_items WHERE list_id = :l', [AListId]);
      while not Q.Eof do
      begin
        InList.AddOrSetValue(Q.FieldByName('stream_item_id').AsInteger, True);
        Q.Next;
      end;
    finally
      Q.Free;
    end;

    // 3. candidate pool: streams of the same content type(s) that carry the TARGET
    //    quality and whose base key (or, as a fallback, head key) matches
    InClause := '';
    for I := 0 to Cts.Count - 1 do
      InClause := InClause + IfThen(I > 0, ',', '') + QuotedStr(Cts[I]);
    Q := NewQuery;
    try
      Q.Open('SELECT id, source_id, name FROM streams ' +
             'WHERE content_type IN (' + InClause + ') AND upstream_url <> ''''');
      while not Q.Eof do
      begin
        Base := KeyOf(Q.FieldByName('name').AsString, Q.FieldByName('source_id').AsInteger, Qual, Head);
        if Qual = Target then
        begin
          Cand.Id := Q.FieldByName('id').AsInteger;
          Cand.SourceId := Q.FieldByName('source_id').AsInteger;
          Cand.Name := Q.FieldByName('name').AsString;
          if (Base <> '') and NeededBase.ContainsKey(Base) then
            AddCand(DictBase, Base, Cand);
          if (Head <> '') and NeededHead.ContainsKey(Head) then
            AddCand(DictHead, Head, Cand);
        end;
        Q.Next;
      end;
    finally
      Q.Free;
    end;

    // 4. pick a candidate per item: exact base key first; else the head key
    //    (ignores tags AFTER the quality word, e.g. "NPO 1 RAW (S)" -> "NPO 1 4K+")
    for I := 0 to Items.Count - 1 do
    begin
      M := Items[I];
      Picked := -1;
      Cands := nil;
      if DictBase.TryGetValue(Bases[I], Cands) then
        Picked := Pick(Cands, M.StreamId, ItemSrc[I]);
      if (Picked < 0) and (Heads[I] <> '') and DictHead.TryGetValue(Heads[I], Cands) then
        Picked := Pick(Cands, M.StreamId, ItemSrc[I]);
      if Picked >= 0 then
      begin
        M.CandidateStreamId := Cands[Picked].Id;
        M.CandidateName := Cands[Picked].Name;
        M.AlreadyInList := InList.ContainsKey(Cands[Picked].Id);
      end;
      Items[I] := M;
    end;

    Result := Items.ToArray;
  finally
    for Cands in DictBase.Values do
      Cands.Free;
    for Cands in DictHead.Values do
      Cands.Free;
    DictBase.Free;
    DictHead.Free;
    NeededBase.Free;
    NeededHead.Free;
    InList.Free;
    Rules.Free;
    Items.Free;
    ItemSrc.Free;
    Bases.Free;
    Heads.Free;
    Cts.Free;
  end;
end;

function TSQLiteStore.FindStreamVariants(AStreamId: Integer; AAllSources: Boolean;
  AListId: Integer): TArray<TStreamVariant>;
type
  TRules = record Prefixes, Suffixes: TArray<string>; end;
var
  Q: TFDQuery;
  Rules: TDictionary<Integer, TRules>;
  InList: TDictionary<Integer, Boolean>;
  L: TList<TStreamVariant>;
  R: TRules;
  V: TStreamVariant;
  Ct, Tvg, Name, Base, Head, Qual, CBase, CHead, CQual, Sql: string;
  SrcId, Pass, K: Integer;
  ByName, ByTvg: Boolean;
  Tok, T, Extra: string;
  TvgArr: TArray<string>;
  Seen: TDictionary<Integer, Boolean>;
  Tvgs: TDictionary<string, Boolean>;

  function KeyOf(const AName: string; ASourceId: Integer; out AQual, AHead: string): string;
  var
    Rr: TRules;
  begin
    if Rules.TryGetValue(ASourceId, Rr) then
      Result := QualityMatchKey(CleanChannelName(AName, Rr.Prefixes, Rr.Suffixes), AQual, AHead)
    else
      Result := QualityMatchKey(AName, AQual, AHead);
  end;

  function IsPlainAscii(const AStr: string): Boolean;
  var
    Ch: Char;
  begin
    for Ch in AStr do
      if not CharInSet(Ch, ['a'..'z', '0'..'9']) then
        Exit(False);
    Result := True;
  end;

begin
  Result := nil;
  Rules := TDictionary<Integer, TRules>.Create;
  InList := TDictionary<Integer, Boolean>.Create;
  L := TList<TStreamVariant>.Create;
  Seen := TDictionary<Integer, Boolean>.Create;
  Tvgs := TDictionary<string, Boolean>.Create;
  try
    Q := NewQuery;
    try
      Q.Open('SELECT id, strip_prefixes, strip_suffixes FROM sources');
      while not Q.Eof do
      begin
        R.Prefixes := CsvToStrArray(Q.Fields[1].AsString, ';');
        R.Suffixes := CsvToStrArray(Q.Fields[2].AsString, ';');
        Rules.AddOrSetValue(Q.Fields[0].AsInteger, R);
        Q.Next;
      end;

      Q.Close;
      Q.Open('SELECT content_type, tvg_id, name, source_id FROM streams WHERE id = :id', [AStreamId]);
      if Q.IsEmpty then
        Exit;
      Ct := Q.FieldByName('content_type').AsString;
      Tvg := Q.FieldByName('tvg_id').AsString.Trim;
      Name := Q.FieldByName('name').AsString;
      SrcId := Q.FieldByName('source_id').AsInteger;
      Base := KeyOf(Name, SrcId, Qual, Head);

      if AListId > 0 then
      begin
        Q.Close;
        Q.Open('SELECT stream_item_id FROM list_items WHERE list_id = :l', [AListId]);
        while not Q.Eof do
        begin
          InList.AddOrSetValue(Q.Fields[0].AsInteger, True);
          Q.Next;
        end;
      end;

      // candidate pool: same content type (and source unless all sources), still
      // playable. Keys are computed in Delphi (decorative letters, strip rules).
      Sql := 'SELECT id, source_id, name, tvg_id, group_title FROM streams ' +
             'WHERE content_type = :ct AND upstream_url <> ''''';
      if Tvg <> '' then
        Tvgs.AddOrSetValue(Tvg.ToLower, True);
      // pass 1: self + name matches (collecting their tvg-ids); pass 2: rows that
      // only share one of those tvg-ids, so a variant without a tvg-id still
      // finds a differently named sibling through the others
      // SQL prefilter (68k+ rows across sources): pass 1 only rows whose name
      // contains the longest plain token of the head key (every name/head match
      // must contain it), pass 2 only rows carrying one of the collected tvg-ids
      Tok := '';
      for T in Head.Split([' ']) do
        if (Length(T) > Length(Tok)) and (Length(T) >= 2) and IsPlainAscii(T) then
          Tok := T;
      for Pass := 1 to 2 do
      begin
        if (Pass = 2) and (Tvgs.Count = 0) then
          Break;
        Q.Close;
        Extra := IfThen(AAllSources, '', ' AND source_id = :s');
        TvgArr := Tvgs.Keys.ToArray;
        if (Pass = 1) and (Tok <> '') then
          Extra := Extra + ' AND (id = :self OR name LIKE :tok)'
        else if Pass = 2 then
        begin
          Extra := Extra + ' AND tvg_id <> '''' AND lower(tvg_id) IN (';
          for K := 0 to High(TvgArr) do
            Extra := Extra + IfThen(K > 0, ',', '') + ':t' + IntToStr(K);
          Extra := Extra + ')';
        end;
        Q.SQL.Text := Sql + Extra;
        Q.ParamByName('ct').AsString := Ct;
        if not AAllSources then
          Q.ParamByName('s').AsInteger := SrcId;
        if (Pass = 1) and (Tok <> '') then
        begin
          Q.ParamByName('self').AsInteger := AStreamId;
          Q.ParamByName('tok').AsWideString := '%' + Tok + '%';
        end
        else if Pass = 2 then
          for K := 0 to High(TvgArr) do
            Q.ParamByName('t' + IntToStr(K)).AsWideString := TvgArr[K];
        Q.Open;
        while not Q.Eof do
        begin
          if Seen.ContainsKey(Q.FieldByName('id').AsInteger) then
          begin
            Q.Next;
            Continue;
          end;
          V := Default(TStreamVariant);
          V.StreamId := Q.FieldByName('id').AsInteger;
          V.SourceId := Q.FieldByName('source_id').AsInteger;
          V.Name := Q.FieldByName('name').AsString;
          V.TvgId := Q.FieldByName('tvg_id').AsString.Trim;
          V.GroupTitle := Q.FieldByName('group_title').AsString;
          CBase := KeyOf(V.Name, V.SourceId, CQual, CHead);
          V.Quality := CQual;
          V.IsSelf := V.StreamId = AStreamId;
          // same channel when the quality-stripped name matches; the head key (the
          // tokens before the quality word) catches tags after it ("RAW (S)") but
          // only when BOTH carry a quality word, so "NPO 1" never eats "NPO 1 EXTRA"
          ByName := ((Base <> '') and (CBase = Base)) or
                    ((Head <> '') and (CHead = Head) and (Qual <> '') and (CQual <> ''));
          // same tvg-id (EPG id) + a quality word: a variant named differently
          ByTvg := (Pass = 2) and (V.TvgId <> '') and Tvgs.ContainsKey(V.TvgId.ToLower) and
                   (CQual <> '');
          if Pass = 2 then
            ByName := False;
          if ((Pass = 1) and (V.IsSelf or ByName)) or ByTvg then
          begin
            Seen.AddOrSetValue(V.StreamId, True);
            if (Pass = 1) and (V.TvgId <> '') then
              Tvgs.AddOrSetValue(V.TvgId.ToLower, True);
            if V.IsSelf then
              V.MatchedBy := 'self'
            else if ByName then
              V.MatchedBy := 'name'
            else
              V.MatchedBy := 'tvg';
            V.OnList := InList.ContainsKey(V.StreamId);
            L.Add(V);
          end;
          Q.Next;
        end;
      end;
    finally
      Q.Free;
    end;

    // own source first, then the quality ladder (best tier first), then name
    L.Sort(TComparer<TStreamVariant>.Construct(
      function(const A, B: TStreamVariant): Integer
      begin
        Result := Ord(A.SourceId <> SrcId) - Ord(B.SourceId <> SrcId);
        if Result = 0 then
          Result := A.SourceId - B.SourceId;
        if Result = 0 then
          Result := QualityRank(A.Quality) - QualityRank(B.Quality);
        if Result = 0 then
          Result := CompareText(A.Name, B.Name);
      end));
    Result := L.ToArray;
  finally
    Tvgs.Free;
    Seen.Free;
    L.Free;
    InList.Free;
    Rules.Free;
  end;
end;

function TSQLiteStore.FindProviderVariants(AListId, ASourceGroupId,
  ATargetSourceId: Integer): TArray<TVariantMatch>;
type
  TRow = record M: TVariantMatch; Ct, Tvg: string; end;
var
  Q: TFDQuery;
  Rows: TList<TRow>;
  Row: TRow;
  InList: TDictionary<Integer, Boolean>;
  Res: TList<TVariantMatch>;
  M: TVariantMatch;
  I: Integer;
begin
  Rows := TList<TRow>.Create;
  InList := TDictionary<Integer, Boolean>.Create;
  Res := TList<TVariantMatch>.Create;
  try
    Q := NewQuery;
    try
      // stream ids already on this list (a candidate already here can't be re-added)
      Q.Open('SELECT stream_item_id FROM list_items WHERE list_id = :l', [AListId]);
      while not Q.Eof do
      begin
        InList.AddOrSetValue(Q.FieldByName('stream_item_id').AsInteger, True);
        Q.Next;
      end;
      Q.Close;

      // collect the source group's items, then close the cursor before per-item lookups
      Q.Open(
        'SELECT i.id AS iid, i.stream_item_id AS sid, s.name AS sname, ' +
        '  s.content_type AS ct, s.tvg_id AS tvg ' +
        'FROM list_items i JOIN streams s ON s.id = i.stream_item_id ' +
        'WHERE i.list_id = :l AND i.custom_group_id = :g ' +
        'ORDER BY i.channel_number, sname COLLATE NOCASE', [AListId, ASourceGroupId]);
      while not Q.Eof do
      begin
        Row.M := Default(TVariantMatch);
        Row.M.ItemId := Q.FieldByName('iid').AsInteger;
        Row.M.StreamId := Q.FieldByName('sid').AsInteger;
        Row.M.Name := Q.FieldByName('sname').AsString;
        Row.Ct := Q.FieldByName('ct').AsString;
        Row.Tvg := Q.FieldByName('tvg').AsString;
        Rows.Add(Row);
        Q.Next;
      end;
      Q.Close;

      // per item: the SAME channel in the chosen target source — by tvg-id when the
      // channel has one (reliable), else by exact case-insensitive name; same content
      // type; skip placeholder rows with no URL.
      Q.SQL.Text :=
        'SELECT id, name FROM streams ' +
        'WHERE source_id = :src AND content_type = :ct AND upstream_url <> '''' AND (' +
        '  (:tvg <> '''' AND tvg_id = :tvg) OR ' +
        '  (:tvg = '''' AND name = :nm COLLATE NOCASE)) ' +
        'ORDER BY id LIMIT 1';
      for I := 0 to Rows.Count - 1 do
      begin
        M := Rows[I].M;
        Q.Close;
        Q.ParamByName('src').AsInteger := ATargetSourceId;
        Q.ParamByName('ct').AsWideString := Rows[I].Ct;
        Q.ParamByName('tvg').AsWideString := Rows[I].Tvg;
        Q.ParamByName('nm').AsWideString := M.Name;
        Q.Open;
        if not Q.IsEmpty then
        begin
          M.CandidateStreamId := Q.FieldByName('id').AsInteger;
          M.CandidateName := Q.FieldByName('name').AsString;
          M.AlreadyInList := InList.ContainsKey(M.CandidateStreamId);
        end;
        Res.Add(M);
      end;
    finally
      Q.Free;
    end;
    Result := Res.ToArray;
  finally
    Rows.Free;
    InList.Free;
    Res.Free;
  end;
end;

function TSQLiteStore.GetState(const AKey: string): string;
var
  Q: TFDQuery;
begin
  Result := '';
  Q := NewQuery;
  try
    Q.Open('SELECT value FROM app_state WHERE key = :k', [AKey]);
    if not Q.IsEmpty then
      Result := Q.Fields[0].AsString;
  finally
    Q.Free;
  end;
end;

procedure TSQLiteStore.SetState(const AKey, AValue: string);
var
  Q: TFDQuery;
begin
  Q := NewQuery;
  try
    Q.SQL.Text := 'INSERT INTO app_state(key, value) VALUES(:k, :v) ' +
                  'ON CONFLICT(key) DO UPDATE SET value = :v';
    Q.ParamByName('k').AsWideString := AKey;
    Q.ParamByName('v').AsWideString := AValue;
    Q.ExecSQL;
  finally
    Q.Free;
  end;
end;

procedure TSQLiteStore.TouchLineup;
begin
  // any bouquet edit (add/remove/rename/regroup/number/tvg/group/restrip) bumps
  // this; the Plex-rescan reminder compares it to the last rescan stamp. A daily
  // catalog refresh does NOT call this (it would nag after every refresh).
  SetState('lineup_changed_utc', DateTimeToIsoUtc(NowUtc));
end;

// ── EPG ──────────────────────────────────────────────────────────────────

procedure TSQLiteStore.ReplaceEpg(ASourceId: Integer; const AProgrammes: TEpgProgrammeList);
var
  P: TEpgProgramme;
  Q: TFDQuery;
begin
  Q := NewQuery;
  try
    FConn.StartTransaction;
    try
      FConn.ExecSQL('DELETE FROM epg WHERE source_id=:s', [ASourceId]);
      // prepared once, reused per row (was re-parsing per programme = very slow)
      Q.SQL.Text :=
        'INSERT INTO epg(source_id,channel_tvg_id,start_utc,stop_utc,title,description,category) ' +
        'VALUES(:s,:ch,:start,:stop,:title,:desc,:cat)';
      for P in AProgrammes do
      begin
        Q.ParamByName('s').AsInteger := ASourceId;
        Q.ParamByName('ch').AsWideString := P.ChannelTvgId;
        Q.ParamByName('start').AsWideString := DateTimeToIsoUtc(P.StartUtc);
        Q.ParamByName('stop').AsWideString := DateTimeToIsoUtc(P.StopUtc);
        Q.ParamByName('title').AsWideString := P.Title;
        Q.ParamByName('desc').AsWideString := P.Description;
        Q.ParamByName('cat').AsWideString := P.Category;
        Q.ExecSQL;
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
  finally
    Q.Free;
  end;
end;

procedure TSQLiteStore.ReplaceExtraEpg(ASourceId: Integer;
  const AChannels: TArray<TEpgChannelInfo>; const AProgrammes: TEpgProgrammeList);
var
  Q: TFDQuery;
  C: TEpgChannelInfo;
begin
  ReplaceEpg(ASourceId, AProgrammes);
  Q := NewQuery;
  try
    FConn.StartTransaction;
    try
      FConn.ExecSQL('DELETE FROM epg_channels WHERE source_id=:s', [ASourceId]);
      Q.SQL.Text := 'INSERT INTO epg_channels(source_id,channel_id,display_name) VALUES(:s,:id,:n)';
      for C in AChannels do
      begin
        Q.ParamByName('s').AsInteger := ASourceId;
        Q.ParamByName('id').AsWideString := C.Id;
        Q.ParamByName('n').AsWideString := C.Name;
        Q.ExecSQL;
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
  finally
    Q.Free;
  end;
end;

procedure TSQLiteStore.ClearExtraEpgBelow(AMinSourceId: Integer);
begin
  // extra guides live under negative source ids -1, -2, ...; drop the slots of
  // URLs that were removed from the settings
  FConn.ExecSQL('DELETE FROM epg WHERE source_id < :m', [AMinSourceId]);
  FConn.ExecSQL('DELETE FROM epg_channels WHERE source_id < :m', [AMinSourceId]);
end;

// Point each live channel at a matching channel of an extra (third-party) guide:
// by its display name first, else by its tvg-id(s). Only extra channels that
// actually have upcoming programmes count; the first extra URL wins over later
// ones; a key that maps to two different channels within one guide is ambiguous
// and never used. A source with "prefer own EPG" keeps its own guide whenever
// that has upcoming programmes. Channel ids/numbers are NOT touched - only where
// the programmes are read from (TOutputChannel.ExtraGuideId).
procedure TSQLiteStore.ApplyExtraGuides(AChannels: TOutputChannelList);
type
  TKeyHit = record
    Id: string;   // stored id ('extra:...'); '' = ambiguous
    Slot: Integer;
  end;
var
  Q: TFDQuery;
  NowS, Cand, K, IdA, IdB: string;
  Keys: TDictionary<string, TKeyHit>;
  PreferOwn: TDictionary<Integer, Byte>;
  OwnFuture: TDictionary<string, Byte>;
  C: TOutputChannel;
  HasOwn: Boolean;

  procedure AddKey(const AKey, AId: string; ASlot: Integer);
  var
    H: TKeyHit;
  begin
    if AKey = '' then
      Exit;
    if Keys.TryGetValue(AKey, H) then
    begin
      if (H.Slot = ASlot) and (H.Id <> AId) then
      begin
        H.Id := ''; // two channels of the same guide share the key: don't guess
        Keys[AKey] := H;
      end;
      Exit; // an earlier (better) guide already owns this key
    end;
    H.Id := AId;
    H.Slot := ASlot;
    Keys.Add(AKey, H);
  end;

  function Hit(const AKey: string): string;
  var
    H: TKeyHit;
  begin
    if (AKey <> '') and Keys.TryGetValue(AKey, H) then
      Result := H.Id
    else
      Result := '';
  end;

begin
  if AChannels.Count = 0 then
    Exit;
  NowS := DateTimeToIsoUtc(NowUtc);
  Keys := TDictionary<string, TKeyHit>.Create;
  PreferOwn := TDictionary<Integer, Byte>.Create;
  OwnFuture := TDictionary<string, Byte>.Create;
  Q := NewQuery;
  try
    Q.Open(
      'SELECT c.source_id AS sid, c.channel_id AS cid, c.display_name AS dn FROM epg_channels c ' +
      'WHERE c.source_id < 0 AND EXISTS (SELECT 1 FROM epg e WHERE e.channel_tvg_id = :pfx || c.channel_id ' +
      '  AND e.source_id = c.source_id AND e.stop_utc > :now) ' +
      'ORDER BY c.source_id DESC', [EXTRA_EPG_PREFIX, NowS]);
    while not Q.Eof do
    begin
      K := EXTRA_EPG_PREFIX + Q.FieldByName('cid').AsWideString;
      AddKey(EpgIdKey(Q.FieldByName('cid').AsWideString), K, Q.FieldByName('sid').AsInteger);
      AddKey(EpgNameKey(Q.FieldByName('dn').AsWideString), K, Q.FieldByName('sid').AsInteger);
      Q.Next;
    end;
    Q.Close;
    if Keys.Count = 0 then
      Exit; // no extra guide configured / nothing upcoming in it

    Q.Open('SELECT id FROM sources WHERE prefer_own_epg <> 0');
    while not Q.Eof do
    begin
      PreferOwn.AddOrSetValue(Q.FieldByName('id').AsInteger, 0);
      Q.Next;
    end;
    Q.Close;
    if PreferOwn.Count > 0 then
    begin
      Q.Open('SELECT DISTINCT channel_tvg_id AS t FROM epg WHERE source_id > 0 AND stop_utc > :now', [NowS]);
      while not Q.Eof do
      begin
        OwnFuture.AddOrSetValue(Q.FieldByName('t').AsWideString, 0);
        Q.Next;
      end;
      Q.Close;
    end;

    for C in AChannels do
    begin
      if C.ContentType <> ctLive then
        Continue;
      // the name the operator sees decides first ...
      Cand := Hit(EpgNameKey(C.Name));
      // ... else the tvg-id(s), but only when they agree on one guide channel
      if Cand = '' then
      begin
        IdA := Hit(EpgIdKey(C.TvgId));
        IdB := Hit(EpgIdKey(C.UpstreamTvgId));
        if (IdA <> '') and ((IdB = '') or (IdB = IdA)) then
          Cand := IdA
        else if (IdA = '') and (IdB <> '') then
          Cand := IdB;
      end;
      if Cand = '' then
        Continue;
      if PreferOwn.ContainsKey(C.SourceId) then
      begin
        HasOwn := False;
        for K in C.EpgReadIds do
          if OwnFuture.ContainsKey(K) then
            HasOwn := True;
        if HasOwn then
          Continue; // this provider's own guide goes first and it has data
      end;
      C.ExtraGuideId := Cand;
    end;
  finally
    Q.Free;
    OwnFuture.Free;
    PreferOwn.Free;
    Keys.Free;
  end;
end;

function TSQLiteStore.LoadListTvgIds: TArray<string>;
var
  Q: TFDQuery;
  L: TList<string>;
begin
  L := TList<string>.Create;
  Q := NewQuery;
  try
    // Keep EPG for BOTH the upstream id AND the effective (override) id of every
    // chosen channel. The provider's XMLTV may publish under either: a pure
    // "relabel" override has its programmes under the upstream id, while a "match
    // an existing guide" override points at an id that already has its own EPG.
    // Serving (BuildXmltv / list EPG) re-keys whatever is found to the effective id.
    Q.Open('SELECT DISTINCT tvg FROM (' +
           '  SELECT s.tvg_id AS tvg FROM list_items i ' +
           '    JOIN streams s ON s.id = i.stream_item_id WHERE s.tvg_id <> '''' ' +
           '  UNION ' +
           '  SELECT COALESCE(NULLIF(i.tvg_id_override,''''), s.tvg_id) AS tvg FROM list_items i ' +
           '    JOIN streams s ON s.id = i.stream_item_id ' +
           '    WHERE COALESCE(NULLIF(i.tvg_id_override,''''), s.tvg_id) <> ''''' +
           ')');
    while not Q.Eof do
    begin
      L.Add(Q.Fields[0].AsString);
      Q.Next;
    end;
    Result := L.ToArray;
  finally
    Q.Free;
    L.Free;
  end;
end;

function TSQLiteStore.ReadProgramme(Q: TFDQuery): TEpgProgramme;
begin
  Result := TEpgProgramme.Create;
  Result.Id := Q.FieldByName('id').AsInteger;
  Result.SourceId := Q.FieldByName('source_id').AsInteger;
  Result.ChannelTvgId := Q.FieldByName('channel_tvg_id').AsString;
  Result.StartUtc := IsoUtcToDateTime(Q.FieldByName('start_utc').AsString);
  Result.StopUtc := IsoUtcToDateTime(Q.FieldByName('stop_utc').AsString);
  Result.Title := Q.FieldByName('title').AsString;
  Result.Description := Q.FieldByName('description').AsString;
  Result.Category := Q.FieldByName('category').AsString;
end;

function TSQLiteStore.LoadEpgForTvgIds(const ATvgIds: TArray<string>;
  AMaxDays: Integer): TEpgProgrammeList;
const
  // bind tvg-ids in batches so a very large list never hits SQLite's
  // SQLITE_MAX_VARIABLE_NUMBER (historically 999) on the IN(...) clause
  CHUNK = 800;
var
  Q: TFDQuery;
  Placeholders, Cutoff: string;
  Lo, Hi, I: Integer;
begin
  Result := TEpgProgrammeList.Create(True);
  if Length(ATvgIds) = 0 then
    Exit;
  if AMaxDays > 0 then
    Cutoff := DateTimeToIsoUtc(IncDay(NowUtc, AMaxDays));
  Lo := 0;
  while Lo <= High(ATvgIds) do
  begin
    Hi := Lo + CHUNK - 1;
    if Hi > High(ATvgIds) then
      Hi := High(ATvgIds);
    Q := NewQuery;
    try
      Placeholders := '';
      for I := Lo to Hi do
        Placeholders := Placeholders + IfThen(I > Lo, ',', '') + ':p' + I.ToString;
      Q.SQL.Text := 'SELECT * FROM epg WHERE channel_tvg_id IN (' + Placeholders + ')';
      // optional cap: drop programmes that start beyond now + AMaxDays (0 = no cap)
      if AMaxDays > 0 then
        Q.SQL.Text := Q.SQL.Text + ' AND start_utc < :cutoff';
      Q.SQL.Text := Q.SQL.Text + ' ORDER BY channel_tvg_id, start_utc';
      for I := Lo to Hi do
        Q.ParamByName('p' + I.ToString).AsWideString := ATvgIds[I];
      if AMaxDays > 0 then
        Q.ParamByName('cutoff').AsWideString := Cutoff;
      Q.Open;
      while not Q.Eof do
      begin
        Result.Add(ReadProgramme(Q));
        Q.Next;
      end;
    finally
      Q.Free;
    end;
    Lo := Hi + 1;
  end;
  // several providers deliver the same channel's guide: serve one, not all
  KeepOneSourcePerChannel(Result, NowUtc);
end;

// ── Lists ──────────────────────────────────────────────────────────────────

function TSQLiteStore.ReadList(Q: TFDQuery): TCustomList;
begin
  Result := TCustomList.Create;
  Result.Id := Q.FieldByName('id').AsInteger;
  Result.Name := Q.FieldByName('name').AsString;
  Result.OutputUsername := Q.FieldByName('output_username').AsString;
  Result.OutputPassword := Q.FieldByName('output_password').AsString;
  Result.Enabled := Q.FieldByName('enabled').AsInteger <> 0;
end;

function TSQLiteStore.LoadLists: TObjectList<TCustomList>;
var
  Q: TFDQuery;
begin
  Result := TObjectList<TCustomList>.Create(True);
  Q := NewQuery;
  try
    Q.Open('SELECT * FROM lists ORDER BY name COLLATE NOCASE');
    while not Q.Eof do
    begin
      Result.Add(ReadList(Q));
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TSQLiteStore.SaveList(const AList: TCustomList): Integer;
var
  Q: TFDQuery;
begin
  Q := NewQuery;
  try
    if AList.Id = 0 then
      Q.SQL.Text := 'INSERT INTO lists(name,output_username,output_password,enabled) ' +
        'VALUES(:name,:u,:p,:enabled)'
    else
    begin
      Q.SQL.Text := 'UPDATE lists SET name=:name,output_username=:u,output_password=:p,enabled=:enabled WHERE id=:id';
      Q.ParamByName('id').AsInteger := AList.Id;
    end;
    Q.ParamByName('name').AsWideString := AList.Name;
    Q.ParamByName('u').AsWideString := AList.OutputUsername;
    Q.ParamByName('p').AsWideString := AList.OutputPassword;
    Q.ParamByName('enabled').AsInteger := Ord(AList.Enabled);
    Q.ExecSQL;
    if AList.Id = 0 then
      Result := FConn.GetLastAutoGenValue('')
    else
      Result := AList.Id;
    AList.Id := Result;
  finally
    Q.Free;
  end;
end;

procedure TSQLiteStore.DeleteList(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM list_items WHERE list_id=:id', [AId]);
  FConn.ExecSQL('DELETE FROM list_groups WHERE list_id=:id', [AId]);
  FConn.ExecSQL('DELETE FROM lists WHERE id=:id', [AId]);
end;

function TSQLiteStore.FindListByCredentials(const AUser, APass: string): TCustomList;
var
  Q: TFDQuery;
begin
  Result := nil;
  Q := NewQuery;
  try
    if AUser = '' then
      // optional credentials: fall back to the single enabled default list
      Q.Open('SELECT * FROM lists WHERE enabled=1 ORDER BY id LIMIT 1')
    else
      Q.Open('SELECT * FROM lists WHERE enabled=1 AND output_username=:u AND output_password=:p LIMIT 1',
        [AUser, APass]);
    if not Q.IsEmpty then
      Result := ReadList(Q);
  finally
    Q.Free;
  end;
end;

// ── Groups ───────────────────────────────────────────────────────────────

function TSQLiteStore.ReadGroup(Q: TFDQuery): TCustomGroup;
begin
  Result := TCustomGroup.Create;
  Result.Id := Q.FieldByName('id').AsInteger;
  Result.ListId := Q.FieldByName('list_id').AsInteger;
  Result.Name := Q.FieldByName('name').AsString;
  Result.ContentType := ContentTypeFromString(Q.FieldByName('content_type').AsString);
  Result.IsFavorite := Q.FieldByName('is_favorite').AsInteger <> 0;
  Result.SortOrder := Q.FieldByName('sort_order').AsInteger;
end;

function TSQLiteStore.LoadGroups(AListId: Integer): TCustomGroupList;
var
  Q: TFDQuery;
begin
  Result := TCustomGroupList.Create(True);
  Q := NewQuery;
  try
    // favorites first, then the manual drag order (sort_order>0), then A->Z for any
    // groups not manually positioned yet
    Q.Open('SELECT * FROM list_groups WHERE list_id=:l ' +
      'ORDER BY is_favorite DESC, CASE WHEN sort_order>0 THEN 0 ELSE 1 END, sort_order, name COLLATE NOCASE',
      [AListId]);
    while not Q.Eof do
    begin
      Result.Add(ReadGroup(Q));
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TSQLiteStore.SaveGroup(const AGroup: TCustomGroup): Integer;
var
  Q: TFDQuery;
begin
  Q := NewQuery;
  try
    if AGroup.Id = 0 then
    begin
      Q.SQL.Text := 'INSERT INTO list_groups(list_id,name,content_type,is_favorite) ' +
        'VALUES(:l,:name,:c,:fav)';
      Q.ParamByName('l').AsInteger := AGroup.ListId; // only the INSERT has :l
    end
    else
    begin
      Q.SQL.Text := 'UPDATE list_groups SET name=:name,content_type=:c,is_favorite=:fav WHERE id=:id';
      Q.ParamByName('id').AsInteger := AGroup.Id;
    end;
    Q.ParamByName('name').AsWideString := AGroup.Name;
    Q.ParamByName('c').AsWideString := ContentTypeNames[AGroup.ContentType];
    Q.ParamByName('fav').AsInteger := Ord(AGroup.IsFavorite);
    Q.ExecSQL;
    if AGroup.Id = 0 then
      Result := FConn.GetLastAutoGenValue('')
    else
      Result := AGroup.Id;
    AGroup.Id := Result;
  finally
    Q.Free;
  end;
  TouchLineup;
end;

function TSQLiteStore.ReorderGroups(AListId: Integer; const AGroupIds: TArray<Integer>): Integer;
var
  Upd: TFDQuery;
  I: Integer;
begin
  // assign sort_order = 1,2,3… following the caller's group-id order (drag result);
  // ids not in this list are skipped. Favorites still sort first (LoadOutputChannels).
  Result := 0;
  Upd := NewQuery;
  try
    Upd.SQL.Text := 'UPDATE list_groups SET sort_order=:n WHERE id=:id AND list_id=:l';
    FConn.StartTransaction;
    try
      for I := 0 to High(AGroupIds) do
      begin
        Upd.ParamByName('n').AsInteger := I + 1;
        Upd.ParamByName('id').AsInteger := AGroupIds[I];
        Upd.ParamByName('l').AsInteger := AListId;
        Upd.ExecSQL;
        Inc(Result, Upd.RowsAffected);
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
  finally
    Upd.Free;
  end;
  TouchLineup;
end;

procedure TSQLiteStore.DeleteGroup(AId: Integer);
begin
  // detach items from the group, then remove it
  FConn.ExecSQL('UPDATE list_items SET custom_group_id=0 WHERE custom_group_id=:id', [AId]);
  FConn.ExecSQL('DELETE FROM list_groups WHERE id=:id', [AId]);
  TouchLineup;
end;

// ── Items ────────────────────────────────────────────────────────────────

function TSQLiteStore.ReadItem(Q: TFDQuery): TCustomItem;

  function Opt(const AName: string): string; // joined columns may be absent
  var
    F: TField;
  begin
    F := Q.FindField(AName);
    if F <> nil then
      Result := F.AsString
    else
      Result := '';
  end;

begin
  Result := TCustomItem.Create;
  Result.Id := Q.FieldByName('id').AsInteger;
  Result.ListId := Q.FieldByName('list_id').AsInteger;
  Result.StreamItemId := Q.FieldByName('stream_item_id').AsInteger;
  Result.CustomGroupId := Q.FieldByName('custom_group_id').AsInteger;
  Result.ContentType := ContentTypeFromString(Q.FieldByName('content_type').AsString);
  Result.DisplayName := Q.FieldByName('display_name').AsString;
  Result.LogoOverride := Q.FieldByName('logo_override').AsString;
  Result.TvgIdOverride := Opt('tvg_id_override');
  Result.ChannelNumber := Q.FieldByName('channel_number').AsInteger;
  Result.StreamName := Opt('stream_name');
  Result.StreamLogo := Opt('stream_logo');
  Result.StreamTvgId := Opt('stream_tvg');
  Result.StreamSourceId := StrToIntDef(Opt('stream_source'), 0);
  Result.StreamArchiveDays := StrToIntDef(Opt('stream_archive'), 0);
end;

function TSQLiteStore.LoadItems(AListId: Integer): TCustomItemList;
var
  Q: TFDQuery;
begin
  Result := TCustomItemList.Create(True);
  Q := NewQuery;
  try
    // join the upstream stream so the UI can show the real channel name/logo
    // even when no override is set (LEFT JOIN: keep the item if the stream is gone)
    Q.Open(
      'SELECT i.*, s.name AS stream_name, s.logo AS stream_logo, s.tvg_id AS stream_tvg, s.source_id AS stream_source, s.archive_days AS stream_archive ' +
      'FROM list_items i LEFT JOIN streams s ON s.id = i.stream_item_id ' +
      'WHERE i.list_id=:l ORDER BY i.channel_number, stream_name COLLATE NOCASE',
      [AListId]);
    while not Q.Eof do
    begin
      Result.Add(ReadItem(Q));
      Q.Next;
    end;
  finally
    Q.Free;
  end;
end;

function TSQLiteStore.LoadOutputChannels(AListId: Integer): TOutputChannelList;
var
  Q: TFDQuery;
  C: TOutputChannel;
begin
  Result := TOutputChannelList.Create(True);
  Q := NewQuery;
  try
    // Join item -> stream (upstream data) -> group (override). COALESCE applies
    // the rename/regroup/logo overrides; empty overrides fall back to upstream.
    Q.SQL.Text :=
      'SELECT i.stream_item_id AS sid, s.source_id AS srcid, i.channel_number AS num, i.content_type AS ctype,' +
      '  COALESCE(NULLIF(i.display_name,''''), s.name) AS cname,' +
      '  COALESCE(NULLIF(i.logo_override,''''), s.logo) AS clogo,' +
      '  COALESCE(NULLIF(i.tvg_id_override,''''), s.tvg_id) AS tvg, s.tvg_id AS utvg, s.upstream_url AS url,' +
      '  s.upstream_id AS uid, s.archive_days AS arch,' +
      '  COALESCE(NULLIF(g.name,''''), s.group_title) AS gname,' +
      '  COALESCE(g.is_favorite, 0) AS fav, COALESCE(g.sort_order, 0) AS gsort ' +
      'FROM list_items i ' +
      'JOIN streams s ON s.id = i.stream_item_id ' +
      'LEFT JOIN list_groups g ON g.id = i.custom_group_id ' +
      'WHERE i.list_id = :l ' +
      // favorites first, then the manual group drag-order (sort_order>0), then any
      // un-positioned groups A→Z; WITHIN a group honour the operator's channel
      // numbers (drag/sort-by-Nr) — numbered first in number order, then unnumbered A→Z.
      'ORDER BY fav DESC, CASE WHEN gsort > 0 THEN 0 ELSE 1 END, gsort, gname COLLATE NOCASE, ' +
      '  CASE WHEN num > 0 THEN 0 ELSE 1 END, num, cname COLLATE NOCASE';
    Q.Open(Q.SQL.Text, [AListId]);
    while not Q.Eof do
    begin
      C := TOutputChannel.Create;
      C.StreamItemId := Q.FieldByName('sid').AsInteger;
      C.SourceId := Q.FieldByName('srcid').AsInteger;
      C.Number := Q.FieldByName('num').AsInteger;
      C.ContentType := ContentTypeFromString(Q.FieldByName('ctype').AsString);
      C.Name := Q.FieldByName('cname').AsString;
      C.Logo := Q.FieldByName('clogo').AsString;
      C.TvgId := Q.FieldByName('tvg').AsString;
      C.UpstreamTvgId := Q.FieldByName('utvg').AsString;
      C.UpstreamUrl := Q.FieldByName('url').AsString;
      C.UpstreamId := Q.FieldByName('uid').AsString;
      C.ArchiveDays := Q.FieldByName('arch').AsInteger;
      C.GroupName := Q.FieldByName('gname').AsString;
      C.IsFavoriteGroup := Q.FieldByName('fav').AsInteger <> 0;
      Result.Add(C);
      Q.Next;
    end;
  finally
    Q.Free;
  end;
  ApplyExtraGuides(Result);
end;

function TSQLiteStore.SaveItem(const AItem: TCustomItem): Integer;
var
  Q: TFDQuery;
begin
  Q := NewQuery;
  try
    if AItem.Id = 0 then
    begin
      Q.SQL.Text :=
        'INSERT INTO list_items(list_id,stream_item_id,custom_group_id,content_type,' +
        'display_name,logo_override,channel_number,tvg_id_override) ' +
        'VALUES(:l,:sid,:grp,:c,:dn,:logo,:num,:tvg)';
      // :l and :sid exist only on the INSERT
      Q.ParamByName('l').AsInteger := AItem.ListId;
      Q.ParamByName('sid').AsInteger := AItem.StreamItemId;
    end
    else
    begin
      Q.SQL.Text :=
        'UPDATE list_items SET custom_group_id=:grp,content_type=:c,display_name=:dn,' +
        'logo_override=:logo,channel_number=:num,tvg_id_override=:tvg WHERE id=:id';
      Q.ParamByName('id').AsInteger := AItem.Id;
    end;
    Q.ParamByName('grp').AsInteger := AItem.CustomGroupId;
    Q.ParamByName('c').AsWideString := ContentTypeNames[AItem.ContentType];
    Q.ParamByName('dn').AsWideString := AItem.DisplayName;
    Q.ParamByName('logo').AsWideString := AItem.LogoOverride;
    Q.ParamByName('num').AsInteger := AItem.ChannelNumber;
    Q.ParamByName('tvg').AsWideString := AItem.TvgIdOverride;
    Q.ExecSQL;
    if AItem.Id = 0 then
      Result := FConn.GetLastAutoGenValue('')
    else
      Result := AItem.Id;
    AItem.Id := Result;
  finally
    Q.Free;
  end;
  TouchLineup;
end;

function TSQLiteStore.AddItems(AListId, ACustomGroupId: Integer;
  const AStreamItemIds: TArray<Integer>): Integer;
var
  Sid: Integer;
  Sel, Ins: TFDQuery;
  Name, Stripped, Ct: string;
begin
  Result := 0;
  if Length(AStreamItemIds) = 0 then
    Exit;
  // Read each stream + its source's strip-prefix tokens, strip the leading
  // provider prefix from the name (e.g. "NL| NPO 1" -> "NPO 1") and store the
  // cleaned label as display_name. We only set display_name when the strip
  // actually changed the name, so untouched names keep following the upstream
  // name (display_name empty => upstream). Bound via AsWideString to keep UTF-8.
  Sel := NewQuery;
  Ins := NewQuery;
  try
    // LEFT JOIN: a stream is still added when its source row is absent (sp NULL
    // -> no prefixes -> name kept). Stripping kicks in only when the source has
    // strip_prefixes configured.
    Sel.SQL.Text :=
      'SELECT s.name AS nm, s.content_type AS ct, src.strip_prefixes AS sp, src.strip_suffixes AS ss ' +
      'FROM streams s LEFT JOIN sources src ON src.id = s.source_id WHERE s.id = :sid';
    Ins.SQL.Text :=
      'INSERT OR IGNORE INTO list_items(list_id,stream_item_id,custom_group_id,content_type,display_name) ' +
      'VALUES(:l,:sid,:grp,:ct,:dn)';
    FConn.StartTransaction;
    try
      for Sid in AStreamItemIds do
      begin
        Sel.Close;
        Sel.ParamByName('sid').AsInteger := Sid;
        Sel.Open;
        if Sel.IsEmpty then
          Continue;
        Name := Sel.FieldByName('nm').AsString;
        Ct := Sel.FieldByName('ct').AsString;
        // strip_prefixes is ';'-delimited (a token may contain spaces/commas/pipes,
        // e.g. "┃F1 TV┃") — split with ';', NOT the default ',' (that would treat the
        // whole "a;b;c" string as one token and match nothing for multi-prefix sources).
        Stripped := CleanChannelName(Name, CsvToStrArray(Sel.FieldByName('sp').AsString, ';'),
          CsvToStrArray(Sel.FieldByName('ss').AsString, ';'));

        Ins.ParamByName('l').AsInteger := AListId;
        Ins.ParamByName('sid').AsInteger := Sid;
        Ins.ParamByName('grp').AsInteger := ACustomGroupId;
        Ins.ParamByName('ct').AsWideString := Ct;
        if (Stripped <> '') and (Stripped <> Name) then
          Ins.ParamByName('dn').AsWideString := Stripped
        else
          Ins.ParamByName('dn').AsWideString := '';
        Ins.ExecSQL;
        Inc(Result, Ins.RowsAffected);
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
  finally
    Sel.Free;
    Ins.Free;
  end;
  TouchLineup;
end;

// the value display_name auto-holds for a name under a source's strip rules: the
// cleaned form when stripping changes the name, else '' (follow the upstream name)
function AutoDisplayName(const AName: string; const APrefixes, ASuffixes: TArray<string>): string;
begin
  Result := CleanChannelName(AName, APrefixes, ASuffixes);
  if Result = AName then
    Result := '';
end;

function TSQLiteStore.RestripSourceItems(ASourceId: Integer;
  const AOldPrefixes, AOldSuffixes, ANewPrefixes, ANewSuffixes: TArray<string>): Integer;
var
  Sel, Upd: TFDQuery;
  Name, Dn, NewDn: string;
  Ids: TList<Integer>;
  NewDns: TList<string>;
  I: Integer;
begin
  Result := 0;
  Ids := TList<Integer>.Create;
  NewDns := TList<string>.Create;
  Sel := NewQuery;
  try
    // collect the items that are still auto-managed (display_name == the value the
    // OLD prefix rule produced) and whose value changes under the NEW rule
    Sel.SQL.Text :=
      'SELECT i.id AS iid, s.name AS nm, i.display_name AS dn ' +
      'FROM list_items i JOIN streams s ON s.id = i.stream_item_id ' +
      'WHERE s.source_id = :sid';
    Sel.ParamByName('sid').AsInteger := ASourceId;
    Sel.Open;
    while not Sel.Eof do
    begin
      Name := Sel.FieldByName('nm').AsString;
      Dn := Sel.FieldByName('dn').AsString;
      if Dn = AutoDisplayName(Name, AOldPrefixes, AOldSuffixes) then // not a manual rename
      begin
        NewDn := AutoDisplayName(Name, ANewPrefixes, ANewSuffixes);
        if NewDn <> Dn then
        begin
          Ids.Add(Sel.FieldByName('iid').AsInteger);
          NewDns.Add(NewDn);
        end;
      end;
      Sel.Next;
    end;
  finally
    Sel.Free;
  end;

  try
    if Ids.Count = 0 then
      Exit;

    Upd := NewQuery;
    try
      Upd.SQL.Text := 'UPDATE list_items SET display_name = :dn WHERE id = :id';
      FConn.StartTransaction;
      try
        for I := 0 to Ids.Count - 1 do
        begin
          Upd.ParamByName('dn').AsWideString := NewDns[I];
          Upd.ParamByName('id').AsInteger := Ids[I];
          Upd.ExecSQL;
          Inc(Result, Upd.RowsAffected);
        end;
        FConn.Commit;
      except
        FConn.Rollback;
        raise;
      end;
    finally
      Upd.Free;
    end;
  finally
    Ids.Free;
    NewDns.Free;
  end;
  TouchLineup;
end;

function TSQLiteStore.RestripAllItems: Integer;
var
  Sel, Upd: TFDQuery;
  Name, Dn, Stripped: string;
  Prefixes, Suffixes: TArray<string>;
  Ids: TList<Integer>;
  NewDns: TList<string>;
  I: Integer;
begin
  // Apply each source's CURRENT strip-prefixes to ALL of its channels on every
  // list: where the name has a strippable prefix and the operator hasn't manually
  // renamed the channel (display_name empty or still the upstream name), set
  // display_name to the stripped form. Manual renames are left untouched.
  Result := 0;
  Ids := TList<Integer>.Create;
  NewDns := TList<string>.Create;
  Sel := NewQuery;
  try
    Sel.SQL.Text :=
      'SELECT i.id AS iid, s.name AS nm, i.display_name AS dn, src.strip_prefixes AS sp, ' +
      '  src.strip_suffixes AS ss ' +
      'FROM list_items i JOIN streams s ON s.id = i.stream_item_id ' +
      'JOIN sources src ON src.id = s.source_id';
    Sel.Open;
    while not Sel.Eof do
    begin
      Name := Sel.FieldByName('nm').AsString;
      Dn := Sel.FieldByName('dn').AsString;
      // ';'-delimited (see AddItems): a token may itself contain ',' or pipes.
      Prefixes := CsvToStrArray(Sel.FieldByName('sp').AsString, ';');
      Suffixes := CsvToStrArray(Sel.FieldByName('ss').AsString, ';');
      if (Length(Prefixes) > 0) or (Length(Suffixes) > 0) then
      begin
        Stripped := CleanChannelName(Name, Prefixes, Suffixes);
        // only when stripping actually changes the name AND it isn't a manual rename
        // (a name still at its prefix-only auto value counts as auto, so adding
        // suffix tokens later also re-cleans channels added before)
        if (Stripped <> Name) and (Stripped <> Dn) and
           ((Dn = '') or (Dn = Name) or (Dn = StripNamePrefixes(Name, Prefixes))) then
        begin
          Ids.Add(Sel.FieldByName('iid').AsInteger);
          NewDns.Add(Stripped);
        end;
      end;
      Sel.Next;
    end;
  finally
    Sel.Free;
  end;

  try
    if Ids.Count = 0 then
      Exit;
    Upd := NewQuery;
    try
      Upd.SQL.Text := 'UPDATE list_items SET display_name = :dn WHERE id = :id';
      FConn.StartTransaction;
      try
        for I := 0 to Ids.Count - 1 do
        begin
          Upd.ParamByName('dn').AsWideString := NewDns[I];
          Upd.ParamByName('id').AsInteger := Ids[I];
          Upd.ExecSQL;
          Inc(Result, Upd.RowsAffected);
        end;
        FConn.Commit;
      except
        FConn.Rollback;
        raise;
      end;
    finally
      Upd.Free;
    end;
  finally
    Ids.Free;
    NewDns.Free;
  end;
  TouchLineup;
end;

function TSQLiteStore.ReplaceItemStreams(AListId: Integer;
  const AReplacements: TArray<TItemStreamReplace>): Integer;
var
  Sel, Upd: TFDQuery;
  R: TItemStreamReplace;
  OldName, OldCt, Dn, NewName, NewCt, NewDn: string;
  OldSp, OldSs, NewSp, NewSs: TArray<string>;
begin
  // Swap the stream behind existing list items IN PLACE (same row, group, channel
  // number, logo / tvg-id overrides). An auto-managed display_name (still what the
  // strip rules produced for the OLD name) follows the new name; a manual rename
  // is kept. Skipped: item not on this list, unknown stream, other content type,
  // or the new stream already on the list (UNIQUE(list_id, stream_item_id)).
  Result := 0;
  if Length(AReplacements) = 0 then
    Exit;
  Sel := NewQuery;
  Upd := NewQuery;
  try
    Upd.SQL.Text :=
      'UPDATE list_items SET stream_item_id = :sid, display_name = :dn ' +
      'WHERE id = :id AND list_id = :l';
    FConn.StartTransaction;
    try
      for R in AReplacements do
      begin
        if (R.ItemId <= 0) or (R.StreamId <= 0) then
          Continue;
        Sel.Close;
        Sel.SQL.Text :=
          'SELECT i.display_name AS dn, i.content_type AS ct, s.name AS nm, ' +
          '  src.strip_prefixes AS sp, src.strip_suffixes AS ss ' +
          'FROM list_items i LEFT JOIN streams s ON s.id = i.stream_item_id ' +
          'LEFT JOIN sources src ON src.id = s.source_id ' +
          'WHERE i.id = :id AND i.list_id = :l';
        Sel.ParamByName('id').AsInteger := R.ItemId;
        Sel.ParamByName('l').AsInteger := AListId;
        Sel.Open;
        if Sel.IsEmpty then
          Continue;
        Dn := Sel.FieldByName('dn').AsString;
        OldCt := Sel.FieldByName('ct').AsString;
        OldName := Sel.FieldByName('nm').AsString;
        OldSp := CsvToStrArray(Sel.FieldByName('sp').AsString, ';');
        OldSs := CsvToStrArray(Sel.FieldByName('ss').AsString, ';');

        Sel.Close;
        Sel.SQL.Text :=
          'SELECT s.name AS nm, s.content_type AS ct, src.strip_prefixes AS sp, ' +
          '  src.strip_suffixes AS ss, ' +
          '  (SELECT COUNT(*) FROM list_items x WHERE x.list_id = :l AND x.stream_item_id = s.id) AS used ' +
          'FROM streams s LEFT JOIN sources src ON src.id = s.source_id WHERE s.id = :sid';
        Sel.ParamByName('sid').AsInteger := R.StreamId;
        Sel.ParamByName('l').AsInteger := AListId;
        Sel.Open;
        if Sel.IsEmpty or (Sel.FieldByName('used').AsInteger > 0) then
          Continue;
        NewCt := Sel.FieldByName('ct').AsString;
        if not SameText(NewCt, OldCt) then
          Continue;
        NewName := Sel.FieldByName('nm').AsString;
        NewSp := CsvToStrArray(Sel.FieldByName('sp').AsString, ';');
        NewSs := CsvToStrArray(Sel.FieldByName('ss').AsString, ';');

        // auto-managed name (empty, upstream name, or the stripped form of it) ->
        // follow the new channel; otherwise keep the operator's own name
        if (Dn = '') or (Dn = OldName) or (Dn = AutoDisplayName(OldName, OldSp, OldSs)) or
           (Dn = StripNamePrefixes(OldName, OldSp)) then
          NewDn := AutoDisplayName(NewName, NewSp, NewSs)
        else
          NewDn := Dn;

        Upd.ParamByName('sid').AsInteger := R.StreamId;
        Upd.ParamByName('dn').AsWideString := NewDn;
        Upd.ParamByName('id').AsInteger := R.ItemId;
        Upd.ParamByName('l').AsInteger := AListId;
        Upd.ExecSQL;
        Inc(Result, Upd.RowsAffected);
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
  finally
    Sel.Free;
    Upd.Free;
  end;
  if Result > 0 then
    TouchLineup;
end;

function TSQLiteStore.RestripGroupItems(AListId, AGroupId: Integer;
  const AExtraPrefixes, AExtraSuffixes: TArray<string>; ADryRun: Boolean): TArray<TNameChange>;
var
  Sel, Upd: TFDQuery;
  Changes: TList<TNameChange>;
  C: TNameChange;
  Dn, Up, Shown, NewName: string;
begin
  // Clean the name each channel currently SHOWS (display name, else upstream name)
  // with its source's strip rules + the one-off extra tokens. Stripping is
  // idempotent, so an auto name gives the same result as cleaning the upstream
  // name, and a manual rename only changes when it really carries such a token.
  Changes := TList<TNameChange>.Create;
  Sel := NewQuery;
  try
    Sel.Open(
      'SELECT i.id AS iid, i.display_name AS dn, s.name AS nm, ' +
      '  src.strip_prefixes AS sp, src.strip_suffixes AS ss ' +
      'FROM list_items i JOIN streams s ON s.id = i.stream_item_id ' +
      'LEFT JOIN sources src ON src.id = s.source_id ' +
      'WHERE i.list_id = :l AND i.custom_group_id = :g ' +
      'ORDER BY i.channel_number, s.name COLLATE NOCASE', [AListId, AGroupId]);
    while not Sel.Eof do
    begin
      Dn := Sel.FieldByName('dn').AsString;
      Up := Sel.FieldByName('nm').AsString;
      if Dn.Trim <> '' then
        Shown := Dn
      else
        Shown := Up;
      NewName := CleanChannelName(Shown,
        CsvToStrArray(Sel.FieldByName('sp').AsString, ';') + AExtraPrefixes,
        CsvToStrArray(Sel.FieldByName('ss').AsString, ';') + AExtraSuffixes);
      if NewName <> Shown.Trim then
      begin
        C.ItemId := Sel.FieldByName('iid').AsInteger;
        C.OldName := Shown;
        C.NewName := NewName;
        C.Original := Up;
        Changes.Add(C);
      end;
      Sel.Next;
    end;
  finally
    Sel.Free;
  end;

  try
    Result := Changes.ToArray;
    if ADryRun or (Changes.Count = 0) then
      Exit;
    Upd := NewQuery;
    try
      Upd.SQL.Text := 'UPDATE list_items SET display_name = :dn WHERE id = :id AND list_id = :l';
      FConn.StartTransaction;
      try
        for C in Changes do
        begin
          // equal to the upstream name -> '' (keep following upstream renames)
          if C.NewName = C.Original then
            Upd.ParamByName('dn').AsWideString := ''
          else
            Upd.ParamByName('dn').AsWideString := C.NewName;
          Upd.ParamByName('id').AsInteger := C.ItemId;
          Upd.ParamByName('l').AsInteger := AListId;
          Upd.ExecSQL;
        end;
        FConn.Commit;
      except
        FConn.Rollback;
        raise;
      end;
    finally
      Upd.Free;
    end;
    TouchLineup;
  finally
    Changes.Free;
  end;
end;

procedure TSQLiteStore.DeleteItem(AId: Integer);
begin
  FConn.ExecSQL('DELETE FROM list_items WHERE id=:id', [AId]);
  TouchLineup;
end;

function TSQLiteStore.ClearGroupItems(AListId, ACustomGroupId: Integer): Integer;
begin
  Result := FConn.ExecSQL('DELETE FROM list_items WHERE list_id=:l AND custom_group_id=:g',
    [AListId, ACustomGroupId]);
  TouchLineup;
end;

function TSQLiteStore.DedupeListItems(AListId: Integer): Integer;
var
  Q: TFDQuery;
  Seen: TDictionary<string, Boolean>;
  ToDelete: TList<Integer>;
  Key: string;
begin
  Seen := TDictionary<string, Boolean>.Create;
  ToDelete := TList<Integer>.Create;
  Q := NewQuery;
  try
    // walk items in canonical order (favorite group first); the FIRST occurrence
    // of each upstream URL is kept, later ones are dropped as duplicates.
    Q.Open(
      'SELECT i.id AS iid, s.upstream_url AS url ' +
      'FROM list_items i JOIN streams s ON s.id = i.stream_item_id ' +
      'LEFT JOIN list_groups g ON g.id = i.custom_group_id ' +
      'WHERE i.list_id = :l ' +
      'ORDER BY COALESCE(g.is_favorite,0) DESC, ' +
      '  COALESCE(NULLIF(g.name,''''), s.group_title) COLLATE NOCASE, ' +
      '  COALESCE(NULLIF(i.display_name,''''), s.name) COLLATE NOCASE',
      [AListId]);
    while not Q.Eof do
    begin
      Key := Q.FieldByName('url').AsString;
      if (Key <> '') and Seen.ContainsKey(Key) then
        ToDelete.Add(Q.FieldByName('iid').AsInteger)
      else
        Seen.AddOrSetValue(Key, True);
      Q.Next;
    end;
    if ToDelete.Count > 0 then
      FConn.ExecSQL('DELETE FROM list_items WHERE id IN (' + IdsToCsv(ToDelete.ToArray) + ')');
    Result := ToDelete.Count;
  finally
    Q.Free;
    ToDelete.Free;
    Seen.Free;
  end;
  TouchLineup;
end;

function TSQLiteStore.SortGroupAlphabetically(AListId, ACustomGroupId: Integer): Integer;
var
  Q, Upd: TFDQuery;
  Ids: TList<Integer>;
  I, Base: Integer;
begin
  Ids := TList<Integer>.Create;
  Q := NewQuery;
  Upd := NewQuery;
  try
    Q.Open(
      'SELECT i.id AS iid FROM list_items i JOIN streams s ON s.id = i.stream_item_id ' +
      'WHERE i.list_id = :l AND i.custom_group_id = :g ' +
      'ORDER BY COALESCE(NULLIF(i.display_name,''''), s.name) COLLATE NOCASE',
      [AListId, ACustomGroupId]);
    while not Q.Eof do
    begin
      Ids.Add(Q.FieldByName('iid').AsInteger);
      Q.Next;
    end;
    Base := GroupNumberBase(AListId, ACustomGroupId);
    Upd.SQL.Text := 'UPDATE list_items SET channel_number=:n WHERE id=:id';
    FConn.StartTransaction;
    try
      for I := 0 to Ids.Count - 1 do
      begin
        Upd.ParamByName('n').AsInteger := Base + I;
        Upd.ParamByName('id').AsInteger := Ids[I];
        Upd.ExecSQL;
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
    Result := Ids.Count;
  finally
    Q.Free;
    Upd.Free;
    Ids.Free;
  end;
  TouchLineup;
end;

function TSQLiteStore.ReorderGroupItems(AListId, ACustomGroupId: Integer;
  const AItemIds: TArray<Integer>): Integer;
var
  Upd: TFDQuery;
  I, Base: Integer;
begin
  // Assign channel_number = base, base+1, … following the caller-supplied item
  // order (drag-and-drop result); base = the group's current lowest number, so a
  // bouquet-wide numbering survives. Only items that really belong to this
  // list+group are touched, so a stale or foreign id is ignored.
  Result := 0;
  Base := GroupNumberBase(AListId, ACustomGroupId);
  Upd := NewQuery;
  try
    Upd.SQL.Text :=
      'UPDATE list_items SET channel_number=:n ' +
      'WHERE id=:id AND list_id=:l AND custom_group_id=:g';
    FConn.StartTransaction;
    try
      for I := 0 to High(AItemIds) do
      begin
        Upd.ParamByName('n').AsInteger := Base + I;
        Upd.ParamByName('id').AsInteger := AItemIds[I];
        Upd.ParamByName('l').AsInteger := AListId;
        Upd.ParamByName('g').AsInteger := ACustomGroupId;
        Upd.ExecSQL;
        Inc(Result, Upd.RowsAffected);
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
  finally
    Upd.Free;
  end;
  TouchLineup;
end;


function TSQLiteStore.GroupNumberBase(AListId, ACustomGroupId: Integer): Integer;
var
  Q: TFDQuery;
begin
  Q := NewQuery;
  try
    Q.Open('SELECT MIN(channel_number) FROM list_items ' +
           'WHERE list_id = :l AND custom_group_id = :g AND channel_number > 0',
      [AListId, ACustomGroupId]);
    // MIN() over no rows is NULL and its column has no declared type: read as text
    Result := StrToIntDef(Q.Fields[0].AsString, 0);
  finally
    Q.Free;
  end;
  if Result <= 0 then
    Result := 1;
end;

function TSQLiteStore.SetItemNumbers(AListId: Integer; const ANumbers: TArray<TItemNumber>): Integer;
var
  Upd: TFDQuery;
  N: TItemNumber;
begin
  Result := 0;
  Upd := NewQuery;
  try
    Upd.SQL.Text := 'UPDATE list_items SET channel_number=:n WHERE id=:id AND list_id=:l';
    FConn.StartTransaction;
    try
      for N in ANumbers do
      begin
        Upd.ParamByName('n').AsInteger := Max(0, N.ChannelNumber);
        Upd.ParamByName('id').AsInteger := N.ItemId;
        Upd.ParamByName('l').AsInteger := AListId;
        Upd.ExecSQL;
        Inc(Result, Upd.RowsAffected);
      end;
      FConn.Commit;
    except
      FConn.Rollback;
      raise;
    end;
  finally
    Upd.Free;
  end;
  TouchLineup;
end;

end.
