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
  // RTL
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  Data.DB,
  // third-party (FireDAC)
  FireDAC.Stan.Intf, // core FireDAC types
  FireDAC.Comp.Client,
  FireDAC.Stan.Def,
  FireDAC.Stan.Async,
  FireDAC.Stan.Param,
  FireDAC.DApt,
  FireDAC.Phys.SQLite,
  FireDAC.Phys.SQLiteDef,
  FireDAC.Phys.SQLiteWrapper.Stat, // statically link the SQLite engine into the host
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList,
  IPTV.Storage.Intf;

type
  /// FireDAC/SQLite implementation of IStore (one connection; see the unit header).
  TSQLiteStore = class(TInterfacedObject, IStore)
  private type
    /// How a mirror bouquet plays one source: the source's own account (what the
    /// stored URLs contain) and the mirror's override for it.
    TPlaybackAccount = record
      SourceUrl: string;
      SourceUser: string;
      SourcePass: string;
      Credential: TMirrorCredential;
    end;
    /// One failover candidate: its upstream URL and the source it comes from.
    TSiblingUrl = record
      SourceId: Integer;
      Url: string;
    end;
  private
    FConn: TFDConnection;
    /// A new query on FConn (caller frees it).
    function NewQuery: TFDQuery;
    /// Execute one SQL statement without parameters.
    procedure Exec(const ASql: string);
    /// Stamp lineup_changed_utc (Plex-rescan reminder).
    procedure TouchLineup;
    /// One-time migration: re-key M3U streams credential-insensitively.
    procedure MigrateM3uStreamIds;
    /// (Re)compute streams.hidden / categories.hidden for one source from its
    /// name filters. AForce=False skips it when the filters didn't change.
    procedure RecomputeHidden(ASourceId: Integer; AForce: Boolean);
    /// Undo old quote-doubling in the stored filter/strip tokens; VACUUM when worthwhile.
    procedure RepairSourceTokens;
    /// Roll back the current (nested) transaction without masking the error being
    /// handled: no-op when SQLite already aborted it, a rollback failure is swallowed.
    procedure SafeRollback;
    /// True when ASourceId (> 0) was issued once but its sources row is gone
    /// (deleted, or replaced by a settings import) - writes for it would be orphans.
    function SourceWasDeleted(ASourceId: Integer): Boolean;
    /// Delete every row that belongs to source ASourceId except the sources row
    /// itself (list items of its streams first). Runs in the caller's transaction.
    procedure DeleteSourceRows(ASourceId: Integer);
    /// One-time-style cleanup at Init: rows left behind under a deleted source id.
    procedure PurgeOrphanedSourceRows;
    /// Content hash of a stream's metadata (change detection).
    function StreamHash(const AItem: TStreamItem): string;
    /// Match the channels to the extra (third-party) guides; sets ExtraGuideId.
    procedure ApplyExtraGuides(AChannels: TOutputChannelList);
    /// The master a list mirrors (lists.mirror_of_list_id); 0 = a normal list or unknown.
    function ListMasterId(AListId: Integer): Integer;
    /// Raise EStoreValidation when AList.MirrorOfListId breaks a mirror rule (see IStore.SaveList).
    procedure ValidateMirror(const AList: TCustomList);
    /// The names of the lists that mirror AListId, A-Z.
    function MirrorNamesOf(AListId: Integer): TArray<string>;
    /// The playback accounts of a mirror bouquet per source id (caller frees).
    function LoadPlaybackAccounts(AListId: Integer): TDictionary<Integer, TPlaybackAccount>;
    /// AUrl of a stream from ASourceId as the mirror plays it (unchanged without an override).
    function PlaybackUrl(const AAccounts: TDictionary<Integer, TPlaybackAccount>; ASourceId: Integer;
      const AUrl: string): string;
    /// LoadOutputChannels of a list's OWN items (no mirror resolution).
    function LoadListChannels(AListId: Integer): TOutputChannelList;
    /// LoadListStreamById scoped to a list's OWN items (no mirror resolution).
    function LoadScopedStream(AListId, AStreamItemId: Integer): TStreamItem;
    /// The failover candidates of a stream (see IStore.LoadStreamSiblings) with their source.
    function LoadSiblingUrls(AStreamItemId: Integer): TArray<TSiblingUrl>;
    // row -> object
    /// Read the current row of AQuery into a new object (caller owns it).
    function ReadSource(AQuery: TFDQuery): TSourceConfig;
    function ReadCategory(AQuery: TFDQuery): TCategory;
    function ReadStream(AQuery: TFDQuery): TStreamItem;
    function ReadProgramme(AQuery: TFDQuery): TEpgProgramme;
    function ReadList(AQuery: TFDQuery): TCustomList;
    function ReadGroup(AQuery: TFDQuery): TCustomGroup;
    function ReadItem(AQuery: TFDQuery): TCustomItem;
  public
    /// AUseWal turns on WAL journal mode — ONLY safe with a real filesystem and
    /// the separate read/write connection setup (opt-in). Default off: a single
    /// serialised connection on a rollback journal, which works everywhere
    /// (including the Unraid /mnt/user FUSE share, where WAL silently breaks).
    constructor Create(const ADatabasePath: string; AUseWal: Boolean = False);
    /// Closes and frees the connection.
    destructor Destroy; override;

    /// IStore implementation (see IPTV.Storage.Intf).
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
    /// The group's lowest channel number > 0 (1 when the group has none).
    function GroupNumberBase(AListId, ACustomGroupId: Integer): Integer;
  end;

implementation

uses
  // RTL
  System.Hash,
  System.StrUtils,
  System.Generics.Defaults,
  System.DateUtils,
  System.Math,
  // own units
  IPTV.Core.Utils;

const
  // the stream's source (alias src, LEFT JOINed) is enabled and offers the
  // stream's content type (alias s). A stream without a source row passes.
  // starts with a space: safe right after a multiline literal ending in AND
  cSqlSourceActive = ' ' + '''
    (src.id IS NULL OR (src.enabled = 1 AND
      (',' || REPLACE(src.content_types, ' ', '') || ',') LIKE ('%,' || s.content_type || ',%')))
    ''';

  // canonical Full-HD quality word (also written FULLHD / FULL-HD)
  cQualityFhd = 'FHD';
  // the same test without a join (streams aliased s): no source row, or an active one
  // starts with a space: safe right after a multiline literal ending in AND
  cSqlSourceActiveExists = ' ' + '''
    NOT EXISTS (SELECT 1 FROM sources src WHERE src.id = s.source_id AND NOT (src.enabled = 1 AND
      (',' || REPLACE(src.content_types, ' ', '') || ',') LIKE ('%,' || s.content_type || ',%')))
    ''';

  // connection setup (FireDAC driver + params, SQLite pragmas)
  cDriverSQLite = 'SQLite';
  cParamLockingModeNormal = 'LockingMode=Normal';
  cParamSynchronousNormal = 'Synchronous=Normal';
  cParamStringFormat = 'StringFormat';
  cStringFormatUnicode = 'Unicode';
  cBusyTimeoutMs = 5000; // PRAGMA busy_timeout: wait (not error) on a brief lock

  // schema migration
  cErrDuplicateColumn = 'duplicate column';
  // fragment of SQLite's constraint error (upper-cased for the compare)
  cErrUniqueConstraint = 'UNIQUE'; // SQLite error fragment (lower case) of ADD COLUMN on an existing column
  cVacuumAboveBytes = 64 * 1024 * 1024;     // VACUUM after the token repair when this much is free
  cStateM3uStreamIdV2 = 'm3u_stream_id_v2'; // app_state flag: M3U stream ids re-keyed once

  // precomputed hidden flags (RecomputeHidden)
  cRecomputeForce = True;       // recompute even when the filters didn't change
  cRecomputeIfChanged = False;  // skip when the filter signature is unchanged
  cHiddenOn = 1;                // streams.hidden / categories.hidden values
  cHiddenOff = 0;
  cHiddenUpdateChunk = 500;     // ids per UPDATE ... WHERE id IN (...)
  cStateHiddenSigPrefix = 'hidden_sig_'; // app_state key + source id
  // bump the version to recompute every source once after an upgrade
  cHiddenSigVersion = 'v2';
  cHiddenSigVersionSep = #3;
  cHiddenSigListSep = #2;
  cHiddenSigItemSep = #1;

  // tables scanned by name (RecomputeHidden, MergeSnapshot, DiscoverPrefixes)
  cTableStreams = 'streams';
  cTableCategories = 'categories';

  // in-memory composite keys ('content_type|upstream_id') and the stream hash fields
  cKeySep = '|';
  cHashFieldSep = '|';

  // strip prefixes/suffixes are stored ';'-separated (a token may contain spaces/commas/pipes)
  cStripTokenSep = ';';

  // a bare (delimiter-less) leading token counts as a prefix up to this length ("NL", "UK")
  cMaxBarePrefixLen = 4;

  // M3U url query parameters holding the account credentials
  cUrlParamUsername = 'username';
  cUrlParamPassword = 'password';

  // container extension of a series episode when the portal gives none
  cDefaultEpisodeExt = 'mp4';

  // quality variants: Full-HD is also written FULLHD / FULL-HD
  cFullHdLikePattern = '%FULL%';
  // FindStreamVariants: shortest head token worth a LIKE prefilter; the two passes
  cMinPrefilterTokenLen = 2;
  cPassByName = 1;
  cPassByTvg = 2;
  // TStreamVariant.MatchedBy values
  cMatchedBySelf = 'self';
  cMatchedByName = 'name';
  cMatchedByTvg = 'tvg';

  // bound parameters per IN (...) query, so a very large list never hits SQLite's
  // SQLITE_MAX_VARIABLE_NUMBER (historically 999)
  cOwnEpgParamChunk = 500;   // ApplyExtraGuides: prefer-own channels' guide ids
  cEpgTvgIdParamChunk = 800; // LoadEpgForTvgIds: tvg-ids

  // channel numbering of a group without numbers starts here
  cDefaultGroupNumberBase = 1;

  // sqlite_sequence row of the AUTOINCREMENT sources table (highest id ever issued)
  cSeqNameSources = 'sources';
  // provider source ids are > 0 (the extra-EPG slots use negative ids, no sources row)
  cMinProviderSourceId = 1;

  // mirror bouquets: lists.mirror_of_list_id of a normal list, and the validation
  // messages (shown to the operator as the API's 400 text)
  cNoMirror = 0;
  cMirrorNameSep = ', ';
  cMsgMirrorSelf = 'A bouquet can''t mirror itself';
  cMsgMirrorUnknown = 'The bouquet to mirror (id %d) does not exist';
  cMsgMirrorOfMirror = '"%s" is a mirror itself - mirror the bouquet it mirrors instead';
  cMsgMirroredCantMirror = 'This bouquet is mirrored by %s - it can''t become a mirror itself';
  cMsgMirrorNotEmpty = 'This bouquet still has groups or channels - empty the bouquet first';
  cMsgMasterHasMirrors = 'This bouquet is mirrored by %s - delete those mirrors first';
  cMsgNotAMirror = 'Only a mirror bouquet has its own provider credentials';

// Strong IPTV group/name delimiters. We deliberately exclude '-' and '.' since
// VOD titles use them freely, which would explode the discovered-prefix list.
// Includes the Unicode vertical bars providers decorate names with (┃ │ ¦ ｜ …) —
// these are > #255 so a CharInSet (AnsiChar) set can't see them; test via a case.
function IsStrongDelim(AChar: Char): Boolean;
begin
  case AChar of
    '|', ':', #$203A, #$00BB,            // | : › »
    cSepBrokenBar, cSepBoxLight, cSepBoxHeavy, cSepTripleDashLight,
    cSepTripleDashHeavy, cSepQuadDashLight, cSepQuadDashHeavy, cSepFullwidthBar:
      Result := True;
  else
    Result := False;
  end;
end;

function ExtractNamePrefix(const AName: string): string;
var
  lName, lToken: string;
  i, lStart: Integer;
begin
  lName := AName.Trim;
  if lName = '' then
    Exit('');
  // skip a leading delimiter run so "|NL| ..." / "┃NL┃ ..." yields "|NL|" / "┃NL┃"
  lStart := 1;
  while (lStart <= Length(lName)) and IsStrongDelim(lName[lStart]) do
    Inc(lStart);
  for i := lStart to Length(lName) do
    if IsStrongDelim(lName[i]) then
      Exit(Copy(lName, 1, i).Trim); // keep everything up to and incl. the delimiter
  // no delimiter: accept only a short all-caps leading token (a country/lang code
  // like "NL", "UK"), never an ordinary first word ("The", "Het", ...)
  i := Pos(' ', lName);
  if i > 1 then
    lToken := Copy(lName, 1, i - 1)
  else
    lToken := lName;
  if (Length(lToken) <= cMaxBarePrefixLen) and (lToken = UpperCase(lToken)) and (lToken <> '') then
    Result := lToken
  else
    Result := '';
end;

function IdsToCsv(const AIds: TArray<Integer>): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to High(AIds) do
    Result := Result + IfThen(i > 0, ',', '') + AIds[i].ToString;
end;

const
  SCHEMA: array[0..7] of string = (
    'CREATE TABLE IF NOT EXISTS app_state (key TEXT PRIMARY KEY, value TEXT)',

    '''
    CREATE TABLE IF NOT EXISTS sources (
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, kind TEXT NOT NULL,
      url TEXT NOT NULL, username TEXT, password TEXT, epg_url TEXT, user_agent TEXT NOT NULL DEFAULT '', referer TEXT NOT NULL DEFAULT '',
      force_hls INTEGER NOT NULL DEFAULT 0,
      enabled INTEGER NOT NULL DEFAULT 1, content_types TEXT NOT NULL DEFAULT 'live,movie,series,radio',
      include_filters TEXT NOT NULL DEFAULT '', exclude_filters TEXT NOT NULL DEFAULT '',
      strip_prefixes TEXT NOT NULL DEFAULT '', strip_suffixes TEXT NOT NULL DEFAULT '',
      last_refresh_utc TEXT)
    ''',

    '''
    CREATE TABLE IF NOT EXISTS categories (
      id INTEGER PRIMARY KEY AUTOINCREMENT, source_id INTEGER NOT NULL, upstream_id TEXT,
      content_type TEXT NOT NULL, name TEXT NOT NULL, is_new INTEGER NOT NULL DEFAULT 1,
      seen_at_utc TEXT,
      UNIQUE(source_id, content_type, upstream_id))
    ''',

    '''
    CREATE TABLE IF NOT EXISTS streams (
      id INTEGER PRIMARY KEY AUTOINCREMENT, source_id INTEGER NOT NULL, upstream_id TEXT NOT NULL,
      content_type TEXT NOT NULL, name TEXT, logo TEXT, group_title TEXT, category_upstream_id TEXT,
      tvg_id TEXT, tvg_name TEXT, upstream_url TEXT, content_hash TEXT,
      archive_days INTEGER NOT NULL DEFAULT 0,
      is_new INTEGER NOT NULL DEFAULT 1, seen_at_utc TEXT, first_seen_utc TEXT, last_seen_utc TEXT,
      UNIQUE(source_id, content_type, upstream_id))
    ''',

    '''
    CREATE TABLE IF NOT EXISTS epg (
      id INTEGER PRIMARY KEY AUTOINCREMENT, source_id INTEGER NOT NULL, channel_tvg_id TEXT NOT NULL,
      start_utc TEXT NOT NULL, stop_utc TEXT NOT NULL, title TEXT, description TEXT, category TEXT)
    ''',

    // output_username/password are OPTIONAL (empty => portal needs no auth).
    '''
    CREATE TABLE IF NOT EXISTS lists (
      id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL,
      output_username TEXT NOT NULL DEFAULT '', output_password TEXT NOT NULL DEFAULT '',
      enabled INTEGER NOT NULL DEFAULT 1, mirror_of_list_id INTEGER NOT NULL DEFAULT 0)
    ''',

    '''
    CREATE TABLE IF NOT EXISTS list_groups (
      id INTEGER PRIMARY KEY AUTOINCREMENT, list_id INTEGER NOT NULL, name TEXT NOT NULL,
      content_type TEXT NOT NULL, is_favorite INTEGER NOT NULL DEFAULT 0,
      sort_order INTEGER NOT NULL DEFAULT 0)
    ''',

    '''
    CREATE TABLE IF NOT EXISTS list_items (
      id INTEGER PRIMARY KEY AUTOINCREMENT, list_id INTEGER NOT NULL, stream_item_id INTEGER NOT NULL,
      custom_group_id INTEGER NOT NULL DEFAULT 0, content_type TEXT NOT NULL,
      display_name TEXT, logo_override TEXT, channel_number INTEGER NOT NULL DEFAULT 0,
      tvg_id_override TEXT NOT NULL DEFAULT '',
      UNIQUE(list_id, stream_item_id))
    '''
  );

{ TSQLiteStore }

constructor TSQLiteStore.Create(const ADatabasePath: string; AUseWal: Boolean);
var
  lQuery: TFDQuery;
begin
  inherited Create;
  FConn := TFDConnection.Create(nil);
  FConn.DriverName := cDriverSQLite;
  FConn.Params.Database := ADatabasePath;
  FConn.Params.Add(cParamLockingModeNormal);
  FConn.Params.Add(cParamSynchronousNormal);
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
  FConn.Params.Values[cParamStringFormat] := cStringFormatUnicode;
  FConn.Connected := True;
  // busy_timeout FIRST so any later statement waits (not errors) on a brief lock.
  Exec('PRAGMA busy_timeout=' + IntToStr(cBusyTimeoutMs));
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
    lQuery := NewQuery;
    try
      lQuery.Open('PRAGMA journal_mode=WAL');
    finally
      FreeAndNil(lQuery);
    end;
  end;
end;

destructor TSQLiteStore.Destroy;
begin
  FreeAndNil(FConn);
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
    string.Join(cHashFieldSep, [AItem.Name, AItem.Logo, AItem.GroupTitle,
                      AItem.CategoryUpstreamId, AItem.TvgId, AItem.UpstreamUrl]));
end;

procedure TSQLiteStore.Init;

  procedure AddColumn(const ATable, AColumnDef: string);
  begin
    try
      Exec('ALTER TABLE ' + ATable + ' ADD COLUMN ' + AColumnDef);
    except
      on E: Exception do
        // the column already exists - expected (SQLite has no ADD COLUMN IF NOT
        // EXISTS). Anything else (locked / IO on a FUSE share) must surface now,
        // not later as "no such column".
        if not E.Message.ToLower.Contains(cErrDuplicateColumn) then
          raise;
    end;
  end;

var
  lSql: string;
  lQuery: TFDQuery;
  lIds: TArray<Integer>;
  lSrcId: Integer;
begin
  for lSql in SCHEMA do
    Exec(lSql);

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
  Exec('''
    CREATE TABLE IF NOT EXISTS epg_channels (source_id INTEGER NOT NULL,
    channel_id TEXT NOT NULL, display_name TEXT NOT NULL DEFAULT '')
    ''');
  Exec('CREATE INDEX IF NOT EXISTS idx_epgch_src ON epg_channels(source_id)');
  // stable box-facing ids for Xtream series episodes (get_series_info)
  Exec('''
    CREATE TABLE IF NOT EXISTS series_episodes (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      stream_id INTEGER NOT NULL,
      upstream_episode_id TEXT NOT NULL,
      ext TEXT NOT NULL DEFAULT '',
      UNIQUE(stream_id, upstream_episode_id))
    ''');
  // per-item tvg-id override (empty => use the upstream stream's tvg-id)
  AddColumn('list_items', 'tvg_id_override TEXT NOT NULL DEFAULT ''''');
  // manual group drag-order (0 => unset, falls back to A→Z; favorites still first)
  AddColumn('list_groups', 'sort_order INTEGER NOT NULL DEFAULT 0');
  // mirror bouquets: the master a list mirrors (0 = own channels) and the mirror's
  // own provider account per source (playback only)
  AddColumn('lists', 'mirror_of_list_id INTEGER NOT NULL DEFAULT 0');
  Exec('''
    CREATE TABLE IF NOT EXISTS list_source_credentials (
      list_id INTEGER NOT NULL, source_id INTEGER NOT NULL,
      url TEXT NOT NULL DEFAULT '', username TEXT NOT NULL DEFAULT '', password TEXT NOT NULL DEFAULT '',
      PRIMARY KEY(list_id, source_id))
    ''');
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
  // new channels per group (catalog "+N new"): partial, so it stays tiny once things are seen
  Exec('CREATE INDEX IF NOT EXISTS idx_streams_new ON streams(source_id, content_type, category_upstream_id) ' +
    'WHERE is_new=1');
  Exec('CREATE INDEX IF NOT EXISTS idx_cats_source ON categories(source_id, content_type)');
  Exec('CREATE INDEX IF NOT EXISTS idx_epg_chan ON epg(channel_tvg_id, start_utc)');
  Exec('CREATE INDEX IF NOT EXISTS idx_epg_src ON epg(source_id)');
  Exec('CREATE INDEX IF NOT EXISTS idx_streams_tvg ON streams(tvg_id)');
  Exec('CREATE INDEX IF NOT EXISTS idx_items_list ON list_items(list_id)');
  // enforce unique credentials only when a username is actually set
  Exec('''
    CREATE UNIQUE INDEX IF NOT EXISTS idx_lists_user ON lists(output_username)
    WHERE output_username <> ''
    ''');

  MigrateM3uStreamIds;
  RepairSourceTokens;
  PurgeOrphanedSourceRows;

  // bring every source's hidden flags up to date (no-op when unchanged)
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT id FROM sources');
    lIds := [];
    while not lQuery.Eof do
    begin
      lIds := lIds + [lQuery.Fields[0].AsInteger];
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
  for lSrcId in lIds do
    RecomputeHidden(lSrcId, cRecomputeIfChanged);
end;

// Undo the quote-doubling of old StrArrayToCsv (see IPTV.Core.Utils) and drop
// unusable (>200 char) filter items. The '"' removal runs in SQLite (C speed on a
// multi-hundred-MB value); then VACUUM once if that freed a lot of space.
procedure TSQLiteStore.RepairSourceTokens;
var
  lQuery: TFDQuery;
  lIds: TArray<Integer>;
  lId: Integer;
  lInc, lExc, lNewInc, lNewExc: string;
  lChanged: Boolean;
  lCol: string;
begin
  lChanged := False;
  for lCol in TArray<string>.Create('include_filters', 'exclude_filters', 'strip_prefixes', 'strip_suffixes') do
    if FConn.ExecSQL(Format('''
      UPDATE sources SET %0:s = replace(%0:s, '"', '')
      WHERE instr(%0:s, '"') > 0
      ''', [lCol])) > 0 then
      lChanged := True;

  lIds := [];
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT id FROM sources');
    while not lQuery.Eof do
    begin
      lIds := lIds + [lQuery.Fields[0].AsInteger];
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
  for lId in lIds do
  begin
    lQuery := NewQuery;
    try
      lQuery.Open('SELECT include_filters, exclude_filters FROM sources WHERE id = :id', [lId]);
      lInc := lQuery.Fields[0].AsString;
      lExc := lQuery.Fields[1].AsString;
    finally
      FreeAndNil(lQuery);
    end;
    lNewInc := StrArrayToCsv(CleanFilterTokens(CsvToStrArray(lInc)));
    lNewExc := StrArrayToCsv(CleanFilterTokens(CsvToStrArray(lExc)));
    if (lNewInc <> lInc) or (lNewExc <> lExc) then
    begin
      // explicit types: a plain open array binds strings as ANSI on Win32 (CP1252),
      // which turned Unicode tokens like the heavy bar into '?'
      FConn.ExecSQL('UPDATE sources SET include_filters = :i, exclude_filters = :e WHERE id = :id',
        [lNewInc, lNewExc, lId], [ftWideString, ftWideString, ftInteger]);
      lChanged := True;
    end;
  end;

  if lChanged then
  begin
    lQuery := NewQuery;
    try
      lQuery.Open('''
        SELECT (SELECT freelist_count FROM pragma_freelist_count) *
        (SELECT page_size FROM pragma_page_size)
        ''');
      if lQuery.Fields[0].AsLargeInt > cVacuumAboveBytes then
      begin
        lQuery.Close;
        Exec('VACUUM');
      end;
    finally
      FreeAndNil(lQuery);
    end;
  end;
end;

procedure TSQLiteStore.RecomputeHidden(ASourceId: Integer; AForce: Boolean);
var
  lQuery: TFDQuery;
  lSource: TSourceConfig;
  lFilter: TPreparedNameFilter;
  lSig, lKey, lTable: string;
  lToHide, lToShow: TList<Integer>;
  lWithVisible: THashSet<string>; // 'contenttype|category upstream id' having a visible stream
  lPasses: Boolean;

  procedure Apply(const AIds: TList<Integer>; AValue: Integer);
  var
    i, j: Integer;
    lBuilder: TStringBuilder;
  begin
    i := 0;
    while i < AIds.Count do
    begin
      lBuilder := TStringBuilder.Create;
      try
        for j := i to Min(i + cHiddenUpdateChunk, AIds.Count) - 1 do
        begin
          if j > i then
            lBuilder.Append(',');
          lBuilder.Append(AIds[j]);
        end;
        Exec(Format('UPDATE %s SET hidden=%d WHERE id IN (%s)', [lTable, AValue, lBuilder.ToString]));
      finally
        FreeAndNil(lBuilder);
      end;
      Inc(i, cHiddenUpdateChunk);
    end;
  end;

begin
  lSource := nil;
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT * FROM sources WHERE id=:id', [ASourceId]);
    if lQuery.Eof then
      Exit;
    lSource := ReadSource(lQuery);
    lQuery.Close;
    // 'v2': groups with a visible channel stay visible — bumping it recomputes
    // every source once after an upgrade
    lSig := THashBobJenkins.GetHashString(cHiddenSigVersion + cHiddenSigVersionSep +
      StrArrayToCsv(lSource.IncludeFilters, cHiddenSigItemSep) + cHiddenSigListSep +
      StrArrayToCsv(lSource.ExcludeFilters, cHiddenSigItemSep));
    lKey := cStateHiddenSigPrefix + ASourceId.ToString;
    if (not AForce) and (GetState(lKey) = lSig) then
      Exit;
    lFilter := PrepareNameFilter(lSource.IncludeFilters, lSource.ExcludeFilters);
    lToHide := TList<Integer>.Create;
    lToShow := TList<Integer>.Create;
    lWithVisible := THashSet<string>.Create;
    try
      FConn.StartTransaction;
      try
        // streams FIRST: a group stays visible when it holds a visible channel
        // (e.g. include "UFC" keeps the UFC channels AND their "WORLD SPORTS"
        // group), unless an exclude token matches the group name itself
        for lTable in TArray<string>.Create(cTableStreams, cTableCategories) do
        begin
          lToHide.Clear;
          lToShow.Clear;
          if lTable = cTableCategories then
          begin
            lQuery.Open('''
              SELECT DISTINCT content_type, category_upstream_id FROM streams
              WHERE source_id=:s AND hidden=0
              ''', [ASourceId]);
            while not lQuery.Eof do
            begin
              lWithVisible.Add(lQuery.Fields[0].AsString + cKeySep + lQuery.Fields[1].AsString);
              lQuery.Next;
            end;
            lQuery.Close;
            lQuery.Open('SELECT id, name, hidden, content_type, upstream_id FROM categories WHERE source_id=:s',
              [ASourceId]);
          end
          else
            lQuery.Open('SELECT id, name, hidden FROM streams WHERE source_id=:s', [ASourceId]);
          while not lQuery.Eof do
          begin
            lPasses := PreparedNamePasses(lFilter, lQuery.Fields[1].AsWideString);
            if (not lPasses) and (lTable = cTableCategories) and
               lWithVisible.Contains(lQuery.Fields[3].AsString + cKeySep + lQuery.Fields[4].AsString) and
               not PreparedNameExcluded(lFilter, lQuery.Fields[1].AsWideString) then
              lPasses := True;
            if lPasses then
            begin
              if lQuery.Fields[2].AsInteger <> 0 then
                lToShow.Add(lQuery.Fields[0].AsInteger);
            end
            else if lQuery.Fields[2].AsInteger = 0 then
              lToHide.Add(lQuery.Fields[0].AsInteger);
            lQuery.Next;
          end;
          lQuery.Close;
          Apply(lToHide, cHiddenOn);
          Apply(lToShow, cHiddenOff);
        end;
        FConn.Commit;
      except
        SafeRollback;
        raise;
      end;
    finally
      FreeAndNil(lToHide);
      FreeAndNil(lToShow);
      FreeAndNil(lWithVisible);
    end;
    SetState(lKey, lSig);
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lSource);
  end;
end;

procedure TSQLiteStore.MigrateM3uStreamIds;
// One-time: M3U stream ids used to be SHA(full URL), which embeds the account
// credentials, so a new subscription at the same provider re-keyed every channel
// and detached the curated list_items. Re-key existing M3U streams to the
// credential-insensitive id (M3uStreamId) so current curation survives and the
// NEXT refresh matches in place. Guarded by an app_state flag so it runs once.
type
  TSrcInfo = record
    Id: Integer;
    User, Pass: string;
  end;
var
  lQuery, lUpdate: TFDQuery;
  lSrcs: TList<TSrcInfo>;
  lSi, lNewSi: TSrcInfo;
  lIds: TList<Integer>;
  lNewIds: TList<string>;
  k: Integer;
  lNid: string;
begin
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT value FROM app_state WHERE key=:k', [cStateM3uStreamIdV2]);
    if not lQuery.Eof then
      Exit; // already migrated
  finally
    FreeAndNil(lQuery);
  end;

  lSrcs := TList<TSrcInfo>.Create;
  lIds := TList<Integer>.Create;
  lNewIds := TList<string>.Create;
  try
    // collect m3u sources first (don't keep a cursor open while updating)
    lQuery := NewQuery;
    try
      lQuery.Open('SELECT id, username, password, url FROM sources WHERE kind=''m3u''');
      while not lQuery.Eof do
      begin
        lNewSi.Id := lQuery.FieldByName('id').AsInteger;
        lNewSi.User := lQuery.FieldByName('username').AsString;
        lNewSi.Pass := lQuery.FieldByName('password').AsString;
        if lNewSi.User = '' then
          lNewSi.User := UrlQueryParam(lQuery.FieldByName('url').AsString, cUrlParamUsername);
        if lNewSi.Pass = '' then
          lNewSi.Pass := UrlQueryParam(lQuery.FieldByName('url').AsString, cUrlParamPassword);
        lSrcs.Add(lNewSi);
        lQuery.Next;
      end;
    finally
      FreeAndNil(lQuery);
    end;

    lUpdate := NewQuery;
    try
      lUpdate.SQL.Text := 'UPDATE streams SET upstream_id=:new WHERE id=:id';
      for lSi in lSrcs do
      begin
        // collect this source's re-keyed rows, then close the cursor before updating
        lIds.Clear;
        lNewIds.Clear;
        lQuery := NewQuery;
        try
          lQuery.Open('SELECT id, upstream_url, upstream_id FROM streams WHERE source_id=:s', [lSi.Id]);
          while not lQuery.Eof do
          begin
            lNid := M3uStreamId(lQuery.FieldByName('upstream_url').AsString, lSi.User, lSi.Pass);
            if lNid <> lQuery.FieldByName('upstream_id').AsString then
            begin
              lIds.Add(lQuery.FieldByName('id').AsInteger);
              lNewIds.Add(lNid);
            end;
            lQuery.Next;
          end;
        finally
          FreeAndNil(lQuery);
        end;

        for k := 0 to lIds.Count - 1 do
        try
          lUpdate.ParamByName('new').AsWideString := lNewIds[k];
          lUpdate.ParamByName('id').AsInteger := lIds[k];
          lUpdate.ExecSQL;
        except
          on E: Exception do
            // a UNIQUE(source_id,content_type,upstream_id) clash (two rows that differ
            // only by credentials): leave this row's old id; harmless and very rare.
            // Anything else (locked / IO) must not be hidden - the migration flag
            // would otherwise be set although rows were not re-keyed.
            if not E.Message.ToUpper.Contains(cErrUniqueConstraint) then
              raise;
        end;
      end;
    finally
      FreeAndNil(lUpdate);
    end;

    Exec('INSERT OR REPLACE INTO app_state(key,value) VALUES(''' + cStateM3uStreamIdV2 + ''',''1'')');
  finally
    FreeAndNil(lSrcs);
    FreeAndNil(lIds);
    FreeAndNil(lNewIds);
  end;
end;

// ── Sources ──────────────────────────────────────────────────────────────

function TSQLiteStore.ReadSource(AQuery: TFDQuery): TSourceConfig;
begin
  Result := TSourceConfig.Create;
  Result.Id := AQuery.FieldByName('id').AsInteger;
  Result.Name := AQuery.FieldByName('name').AsString;
  Result.Kind := SourceKindFromString(AQuery.FieldByName('kind').AsString);
  Result.Url := AQuery.FieldByName('url').AsString;
  Result.Username := AQuery.FieldByName('username').AsString;
  Result.Password := AQuery.FieldByName('password').AsString;
  Result.EpgUrl := AQuery.FieldByName('epg_url').AsString;
  Result.UserAgent := AQuery.FieldByName('user_agent').AsString;
  Result.Referer := AQuery.FieldByName('referer').AsString;
  Result.ForceHls := AQuery.FieldByName('force_hls').AsInteger <> 0;
  Result.Enabled := AQuery.FieldByName('enabled').AsInteger <> 0;
  Result.ContentTypes := StrToContentTypes(AQuery.FieldByName('content_types').AsString);
  Result.IncludeFilters := CsvToStrArray(AQuery.FieldByName('include_filters').AsString);
  Result.ExcludeFilters := CsvToStrArray(AQuery.FieldByName('exclude_filters').AsString);
  // strip prefixes use ';' so a token may itself contain spaces/commas/pipes
  Result.StripPrefixes := CsvToStrArray(AQuery.FieldByName('strip_prefixes').AsString, cStripTokenSep);
  Result.StripSuffixes := CsvToStrArray(AQuery.FieldByName('strip_suffixes').AsString, cStripTokenSep);
  Result.LastRefreshUtc := IsoUtcToDateTime(AQuery.FieldByName('last_refresh_utc').AsString);
  Result.AccountStatus := AQuery.FieldByName('account_status').AsString;
  Result.ExpiresUtc := IsoUtcToDateTime(AQuery.FieldByName('expires_utc').AsString);
  Result.MaxConnections := AQuery.FieldByName('max_connections').AsInteger;
  Result.TzOffsetMin := AQuery.FieldByName('tz_offset_min').AsInteger;
  Result.PreferOwnEpg := AQuery.FieldByName('prefer_own_epg').AsInteger <> 0;
end;

function TSQLiteStore.LoadSources: TObjectList<TSourceConfig>;
var
  lQuery: TFDQuery;
begin
  Result := TObjectList<TSourceConfig>.Create(True);
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT * FROM sources ORDER BY name COLLATE NOCASE');
    while not lQuery.Eof do
    begin
      Result.Add(ReadSource(lQuery));
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.SaveSource(const ASource: TSourceConfig): Integer;
var
  lQuery: TFDQuery;
begin
  lQuery := NewQuery;
  try
    if ASource.Id = 0 then
      lQuery.SQL.Text :=
        '''
        INSERT INTO sources(name,kind,url,username,password,epg_url,user_agent,referer,force_hls,enabled,content_types,include_filters,exclude_filters,strip_prefixes,strip_suffixes,last_refresh_utc,account_status,expires_utc,max_connections,tz_offset_min,prefer_own_epg)
        VALUES(:name,:kind,:url,:username,:password,:epg_url,:user_agent,:referer,:force_hls,:enabled,:content_types,:include_filters,:exclude_filters,:strip_prefixes,:strip_suffixes,:last_refresh_utc,:account_status,:expires_utc,:max_connections,:tz_offset_min,:prefer_own_epg)
        '''
    else
    begin
      lQuery.SQL.Text :=
        '''
        UPDATE sources SET name=:name,kind=:kind,url=:url,username=:username,password=:password,epg_url=:epg_url,user_agent=:user_agent,referer=:referer,force_hls=:force_hls,enabled=:enabled,content_types=:content_types,include_filters=:include_filters,exclude_filters=:exclude_filters,strip_prefixes=:strip_prefixes,strip_suffixes=:strip_suffixes,last_refresh_utc=:last_refresh_utc,account_status=:account_status,expires_utc=:expires_utc,max_connections=:max_connections,tz_offset_min=:tz_offset_min,prefer_own_epg=:prefer_own_epg WHERE id=:id
        ''';
      lQuery.ParamByName('id').AsInteger := ASource.Id;
    end;
    lQuery.ParamByName('name').AsWideString := ASource.Name;
    lQuery.ParamByName('kind').AsWideString := SourceKindNames[ASource.Kind];
    lQuery.ParamByName('url').AsWideString := ASource.Url;
    lQuery.ParamByName('username').AsWideString := ASource.Username;
    lQuery.ParamByName('password').AsWideString := ASource.Password;
    lQuery.ParamByName('epg_url').AsWideString := ASource.EpgUrl;
    lQuery.ParamByName('user_agent').AsWideString := ASource.UserAgent;
    lQuery.ParamByName('referer').AsWideString := ASource.Referer;
    lQuery.ParamByName('force_hls').AsInteger := Ord(ASource.ForceHls);
    lQuery.ParamByName('enabled').AsInteger := Ord(ASource.Enabled);
    lQuery.ParamByName('content_types').AsWideString := ContentTypesToStr(ASource.ContentTypes);
    lQuery.ParamByName('include_filters').AsWideString := StrArrayToCsv(ASource.IncludeFilters);
    lQuery.ParamByName('exclude_filters').AsWideString := StrArrayToCsv(ASource.ExcludeFilters);
    lQuery.ParamByName('strip_prefixes').AsWideString := StrArrayToCsv(ASource.StripPrefixes, cStripTokenSep);
    lQuery.ParamByName('strip_suffixes').AsWideString := StrArrayToCsv(ASource.StripSuffixes, cStripTokenSep);
    lQuery.ParamByName('last_refresh_utc').AsWideString := DateTimeToIsoUtc(ASource.LastRefreshUtc);
    lQuery.ParamByName('account_status').AsWideString := ASource.AccountStatus;
    lQuery.ParamByName('expires_utc').AsWideString := DateTimeToIsoUtc(ASource.ExpiresUtc);
    lQuery.ParamByName('max_connections').AsInteger := ASource.MaxConnections;
    lQuery.ParamByName('tz_offset_min').AsInteger := ASource.TzOffsetMin;
    lQuery.ParamByName('prefer_own_epg').AsInteger := Ord(ASource.PreferOwnEpg);
    lQuery.ExecSQL;

    if ASource.Id = 0 then
      Result := FConn.GetLastAutoGenValue('')
    else
      Result := ASource.Id;
    ASource.Id := Result;
  finally
    FreeAndNil(lQuery);
  end;
  RecomputeHidden(Result, cRecomputeIfChanged); // filters may have changed (no-op otherwise)
end;

procedure TSQLiteStore.DeleteSourceRows(ASourceId: Integer);
begin
  // there are no FK cascades, so clean dependents by hand. Remove list_items that
  // point at this source's streams FIRST, else they dangle (orphaned rows that
  // LoadOutputChannels silently drops and the UI can never repair).
  FConn.ExecSQL(
    '''
    DELETE FROM list_items WHERE stream_item_id IN
    (SELECT id FROM streams WHERE source_id=:id)
    ''', [ASourceId]);
  FConn.ExecSQL(
    '''
    DELETE FROM series_episodes WHERE stream_id IN
    (SELECT id FROM streams WHERE source_id=:id)
    ''', [ASourceId]);
  FConn.ExecSQL('DELETE FROM streams WHERE source_id=:id', [ASourceId]);
  FConn.ExecSQL('DELETE FROM categories WHERE source_id=:id', [ASourceId]);
  FConn.ExecSQL('DELETE FROM epg WHERE source_id=:id', [ASourceId]);
  FConn.ExecSQL('DELETE FROM epg_channels WHERE source_id=:id', [ASourceId]);
  FConn.ExecSQL('DELETE FROM list_source_credentials WHERE source_id=:id', [ASourceId]);
end;

procedure TSQLiteStore.DeleteSource(AId: Integer);
begin
  // one transaction: a failure half-way must not leave a source without streams
  // (or list items pointing nowhere)
  FConn.StartTransaction;
  try
    DeleteSourceRows(AId);
    FConn.ExecSQL('DELETE FROM sources WHERE id=:id', [AId]);
    FConn.Commit;
  except
    SafeRollback;
    raise;
  end;
  TouchLineup;
end;

procedure TSQLiteStore.SafeRollback;
begin
  // SQLITE_FULL / IOERR / NOMEM make SQLite abort the WHOLE transaction itself; a
  // nested FireDAC rollback then targets a savepoint that no longer exists and
  // raises - from inside the caller's except, hiding the real error.
  if not FConn.InTransaction then
    Exit;
  try
    FConn.Rollback;
  except
    // deliberately swallowed: the caller re-raises the original exception, which
    // is the one worth reporting; the transaction is gone either way
  end;
end;

function TSQLiteStore.SourceWasDeleted(ASourceId: Integer): Boolean;
var
  lQuery: TFDQuery;
begin
  if ASourceId < cMinProviderSourceId then
    Exit(False); // extra-EPG slot (negative id): never has a sources row
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT 1 FROM sources WHERE id = :s', [ASourceId]);
    if not lQuery.IsEmpty then
      Exit(False);
    lQuery.Close;
    // the row is missing: only an id that was ISSUED once (<= the AUTOINCREMENT
    // high-water mark) was deleted; an id never issued (ad-hoc tooling/tests that
    // merge without a sources row) is left alone
    lQuery.Open('SELECT seq FROM sqlite_sequence WHERE name = :n', [cSeqNameSources]);
    Result := (not lQuery.IsEmpty) and (ASourceId <= lQuery.Fields[0].AsInteger);
  finally
    FreeAndNil(lQuery);
  end;
end;

procedure TSQLiteStore.PurgeOrphanedSourceRows;
var
  lQuery: TFDQuery;
  lIds: TArray<Integer>;
  lId: Integer;
begin
  // rows written under a source id whose sources row is gone (a refresh that
  // finished after the source was deleted, before MergeSnapshot/ReplaceEpg
  // checked for it); cSqlSourceActive lets them through, so they would surface
  // in the catalog, failover, variants and EPG forever
  lIds := [];
  lQuery := NewQuery;
  try
    lQuery.Open(
      '''
      SELECT o.sid FROM (
        SELECT DISTINCT source_id AS sid FROM streams
        UNION SELECT DISTINCT source_id FROM categories
        UNION SELECT DISTINCT source_id FROM epg
        UNION SELECT DISTINCT source_id FROM epg_channels) o
      WHERE o.sid >= :m
        AND NOT EXISTS (SELECT 1 FROM sources src WHERE src.id = o.sid)
        AND o.sid <= COALESCE((SELECT seq FROM sqlite_sequence WHERE name = :n), 0)
      ''', [cMinProviderSourceId, cSeqNameSources]);
    while not lQuery.Eof do
    begin
      lIds := lIds + [lQuery.Fields[0].AsInteger];
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
  if Length(lIds) = 0 then
    Exit;
  FConn.StartTransaction;
  try
    for lId in lIds do
      DeleteSourceRows(lId);
    FConn.Commit;
  except
    SafeRollback;
    raise;
  end;
  TouchLineup; // list items of those streams may have gone
end;

// ── Catalog ────────────────────────────────────────────────────────────────

procedure TSQLiteStore.MergeSnapshot(const ASnapshot: TSourceSnapshot);
var
  lCat: TCategory;
  lStream: TStreamItem;
  lNow, lKey, lOldCt, lNewCt, lUid: string;
  lCatKeys, lStrKeys, lSnapKeys: TDictionary<string, Boolean>;
  // upstream id -> ALL stored content types (Xtream: live 500 and series 500 are
  // separate id spaces, so one upstream id can be stored under several types)
  lTypesByUid: TDictionary<string, TArray<string>>;
  lTypes: TArray<string>;
  lLoadQuery, lCatIns, lCatUpd, lStrIns, lStrUpd, lReKey: TFDQuery;
  lIsM3U: Boolean;
  i, lOldIdx: Integer;

  function LoadKeys(const ATable: string): TDictionary<string, Boolean>;
  begin
    Result := TDictionary<string, Boolean>.Create;
    lLoadQuery.Close;
    lLoadQuery.Open('SELECT content_type, upstream_id FROM ' + ATable + ' WHERE source_id=:s',
      [ASnapshot.SourceId]);
    while not lLoadQuery.Eof do
    begin
      Result.AddOrSetValue(lLoadQuery.FieldByName('content_type').AsString + cKeySep +
        lLoadQuery.FieldByName('upstream_id').AsString, True);
      lLoadQuery.Next;
    end;
  end;

  procedure BindReKey(const ANew, AOld, AUid: string);
  begin
    lReKey.ParamByName('n').AsWideString := ANew;
    lReKey.ParamByName('s').AsInteger := ASnapshot.SourceId;
    lReKey.ParamByName('o').AsWideString := AOld;
    lReKey.ParamByName('u').AsWideString := AUid;
  end;

begin
  lNow := DateTimeToIsoUtc(NowUtc);
  lLoadQuery := NewQuery;
  lCatIns := NewQuery;
  lCatUpd := NewQuery;
  lStrIns := NewQuery;
  lStrUpd := NewQuery;
  lReKey := NewQuery;
  lCatKeys := nil;
  lStrKeys := nil;
  lSnapKeys := nil;
  lTypesByUid := nil;
  try
    // one read each instead of a SELECT per row; lets us decide insert vs update
    // (and so flag is_new) in memory.
    lCatKeys := LoadKeys(cTableCategories);
    lStrKeys := LoadKeys(cTableStreams);
    lTypesByUid := TDictionary<string, TArray<string>>.Create;
    for lKey in lStrKeys.Keys do
    begin
      lUid := lKey.Substring(lKey.IndexOf(cKeySep) + 1);
      if not lTypesByUid.TryGetValue(lUid, lTypes) then
        lTypes := [];
      lTypesByUid.AddOrSetValue(lUid, lTypes + [lKey.Substring(0, lKey.IndexOf(cKeySep))]);
    end;
    lSnapKeys := TDictionary<string, Boolean>.Create;
    for lStream in ASnapshot.Streams do
      lSnapKeys.AddOrSetValue(ContentTypeNames[lStream.ContentType] + cKeySep + lStream.UpstreamId, True);
    lLoadQuery.Close;
    lLoadQuery.Open('SELECT kind FROM sources WHERE id=:s', [ASnapshot.SourceId]);
    lIsM3U := (not lLoadQuery.IsEmpty) and SameText(lLoadQuery.Fields[0].AsString, SourceKindNames[skM3U]);
    lLoadQuery.Close;

    // prepared once, reused per row (no SQL re-parse per item)
    lCatIns.SQL.Text := 'INSERT INTO categories(source_id,upstream_id,content_type,name,is_new) VALUES(:s,:u,:c,:n,1)';
    lCatUpd.SQL.Text := 'UPDATE categories SET name=:n WHERE source_id=:s AND content_type=:c AND upstream_id=:u';
    lStrIns.SQL.Text := '''
      INSERT INTO streams(source_id,upstream_id,content_type,name,logo,group_title,category_upstream_id,tvg_id,tvg_name,upstream_url,content_hash,archive_days,is_new,first_seen_utc,last_seen_utc)
      VALUES(:s,:u,:c,:n,:logo,:grp,:cat,:tvg,:tvgn,:url,:hash,:arch,1,:now,:now)
      ''';
    lStrUpd.SQL.Text := '''
      UPDATE streams SET name=:n,logo=:logo,group_title=:grp,category_upstream_id=:cat,tvg_id=:tvg,tvg_name=:tvgn,upstream_url=:url,content_hash=:hash,archive_days=:arch,last_seen_utc=:now
      WHERE source_id=:s AND content_type=:c AND upstream_id=:u
      ''';

    FConn.StartTransaction;
    try
      // the read behind this snapshot can take minutes: when the source was deleted
      // (or replaced by a settings import) meanwhile, writing would leave thousands
      // of orphaned rows under a dead id - skip the merge silently
      if SourceWasDeleted(ASnapshot.SourceId) then
      begin
        FConn.Commit;
        Exit;
      end;
      for lCat in ASnapshot.Categories do
      begin
        lKey := ContentTypeNames[lCat.ContentType] + cKeySep + lCat.UpstreamId;
        if lCatKeys.ContainsKey(lKey) then
        begin
          lCatUpd.ParamByName('n').AsWideString := lCat.Name;
          lCatUpd.ParamByName('s').AsInteger := ASnapshot.SourceId;
          lCatUpd.ParamByName('c').AsWideString := ContentTypeNames[lCat.ContentType];
          lCatUpd.ParamByName('u').AsWideString := lCat.UpstreamId;
          lCatUpd.ExecSQL;
        end
        else
        begin
          lCatIns.ParamByName('s').AsInteger := ASnapshot.SourceId;
          lCatIns.ParamByName('u').AsWideString := lCat.UpstreamId;
          lCatIns.ParamByName('c').AsWideString := ContentTypeNames[lCat.ContentType];
          lCatIns.ParamByName('n').AsWideString := lCat.Name;
          lCatIns.ExecSQL;
          lCatKeys.AddOrSetValue(lKey, True);
        end;
      end;

      for lStream in ASnapshot.Streams do
      begin
        lKey := ContentTypeNames[lStream.ContentType] + cKeySep + lStream.UpstreamId;
        // The same upstream item now arrives as another content type (the reader's
        // classification changed, e.g. Xtream radio_streams live -> radio, or an M3U
        // "NL| FILM" group movie -> live): re-key the stored row in place, so the
        // id, the curated list items and the seen-state stay. Only when the old
        // type is gone from this snapshot, and only where the upstream id names the
        // same thing across types (M3U: URL-derived; Xtream: live <-> radio share
        // the live stream ids - a VOD id 123 is not live channel 123).
        lNewCt := ContentTypeNames[lStream.ContentType];
        lOldIdx := -1;
        if (not lStrKeys.ContainsKey(lKey)) and lTypesByUid.TryGetValue(lStream.UpstreamId, lTypes) then
          for i := 0 to High(lTypes) do
            if (lTypes[i] <> lNewCt) and
               lStrKeys.ContainsKey(lTypes[i] + cKeySep + lStream.UpstreamId) and
               not lSnapKeys.ContainsKey(lTypes[i] + cKeySep + lStream.UpstreamId) and
               (lIsM3U or (MatchText(lTypes[i], [ContentTypeNames[ctLive], ContentTypeNames[ctRadio]]) and
                 (lStream.ContentType in [ctLive, ctRadio]))) then
            begin
              lOldIdx := i;
              Break;
            end;
        if lOldIdx >= 0 then
        begin
          lOldCt := lTypes[lOldIdx];
          lReKey.SQL.Text := '''
            UPDATE list_items SET content_type = :n
            WHERE stream_item_id IN (SELECT id FROM streams WHERE source_id = :s AND content_type = :o AND upstream_id = :u)
            ''';
          BindReKey(lNewCt, lOldCt, lStream.UpstreamId);
          lReKey.ExecSQL;
          lReKey.SQL.Text := '''
            UPDATE streams SET content_type = :n
            WHERE source_id = :s AND content_type = :o AND upstream_id = :u
            ''';
          BindReKey(lNewCt, lOldCt, lStream.UpstreamId);
          lReKey.ExecSQL;
          lStrKeys.Remove(lOldCt + cKeySep + lStream.UpstreamId);
          lStrKeys.AddOrSetValue(lKey, True);
          lTypes[lOldIdx] := lNewCt; // the stored row now carries the new type
          lTypesByUid.AddOrSetValue(lStream.UpstreamId, lTypes);
        end;
        if lStrKeys.ContainsKey(lKey) then
        begin
          lStrUpd.ParamByName('n').AsWideString := lStream.Name;
          lStrUpd.ParamByName('logo').AsWideString := lStream.Logo;
          lStrUpd.ParamByName('grp').AsWideString := lStream.GroupTitle;
          lStrUpd.ParamByName('cat').AsWideString := lStream.CategoryUpstreamId;
          lStrUpd.ParamByName('tvg').AsWideString := lStream.TvgId;
          lStrUpd.ParamByName('tvgn').AsWideString := lStream.TvgName;
          lStrUpd.ParamByName('url').AsWideString := lStream.UpstreamUrl;
          lStrUpd.ParamByName('hash').AsWideString := StreamHash(lStream);
          lStrUpd.ParamByName('arch').AsInteger := lStream.ArchiveDays;
          lStrUpd.ParamByName('now').AsWideString := lNow;
          lStrUpd.ParamByName('s').AsInteger := ASnapshot.SourceId;
          lStrUpd.ParamByName('c').AsWideString := ContentTypeNames[lStream.ContentType];
          lStrUpd.ParamByName('u').AsWideString := lStream.UpstreamId;
          lStrUpd.ExecSQL;
        end
        else
        begin
          lStrIns.ParamByName('s').AsInteger := ASnapshot.SourceId;
          lStrIns.ParamByName('u').AsWideString := lStream.UpstreamId;
          lStrIns.ParamByName('c').AsWideString := ContentTypeNames[lStream.ContentType];
          lStrIns.ParamByName('n').AsWideString := lStream.Name;
          lStrIns.ParamByName('logo').AsWideString := lStream.Logo;
          lStrIns.ParamByName('grp').AsWideString := lStream.GroupTitle;
          lStrIns.ParamByName('cat').AsWideString := lStream.CategoryUpstreamId;
          lStrIns.ParamByName('tvg').AsWideString := lStream.TvgId;
          lStrIns.ParamByName('tvgn').AsWideString := lStream.TvgName;
          lStrIns.ParamByName('url').AsWideString := lStream.UpstreamUrl;
          lStrIns.ParamByName('hash').AsWideString := StreamHash(lStream);
          lStrIns.ParamByName('arch').AsInteger := lStream.ArchiveDays;
          lStrIns.ParamByName('now').AsWideString := lNow;
          lStrIns.ExecSQL;
          lStrKeys.AddOrSetValue(lKey, True); // guard against duplicates within one snapshot
        end;
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lCatKeys);
    FreeAndNil(lStrKeys);
    FreeAndNil(lSnapKeys);
    FreeAndNil(lTypesByUid);
    FreeAndNil(lReKey);
    FreeAndNil(lStrUpd);
    FreeAndNil(lStrIns);
    FreeAndNil(lCatUpd);
    FreeAndNil(lCatIns);
    FreeAndNil(lLoadQuery);
  end;
  // new rows arrive with hidden=0: re-apply this source's filters to them
  RecomputeHidden(ASnapshot.SourceId, cRecomputeForce);
end;

function TSQLiteStore.ReadCategory(AQuery: TFDQuery): TCategory;
begin
  Result := TCategory.Create;
  Result.Id := AQuery.FieldByName('id').AsInteger;
  Result.SourceId := AQuery.FieldByName('source_id').AsInteger;
  Result.UpstreamId := AQuery.FieldByName('upstream_id').AsString;
  Result.ContentType := ContentTypeFromString(AQuery.FieldByName('content_type').AsString);
  Result.Name := AQuery.FieldByName('name').AsString;
  Result.IsNew := AQuery.FieldByName('is_new').AsInteger <> 0;
  Result.SeenAtUtc := IsoUtcToDateTime(AQuery.FieldByName('seen_at_utc').AsString);
end;

function TSQLiteStore.ReadStream(AQuery: TFDQuery): TStreamItem;
begin
  Result := TStreamItem.Create;
  Result.Id := AQuery.FieldByName('id').AsInteger;
  Result.SourceId := AQuery.FieldByName('source_id').AsInteger;
  Result.UpstreamId := AQuery.FieldByName('upstream_id').AsString;
  Result.ContentType := ContentTypeFromString(AQuery.FieldByName('content_type').AsString);
  Result.Name := AQuery.FieldByName('name').AsWideString;
  Result.Logo := AQuery.FieldByName('logo').AsWideString;
  Result.GroupTitle := AQuery.FieldByName('group_title').AsWideString;
  Result.CategoryUpstreamId := AQuery.FieldByName('category_upstream_id').AsString;
  Result.TvgId := AQuery.FieldByName('tvg_id').AsString;
  Result.TvgName := AQuery.FieldByName('tvg_name').AsString;
  Result.UpstreamUrl := AQuery.FieldByName('upstream_url').AsString;
  Result.ContentHash := AQuery.FieldByName('content_hash').AsString;
  // FindField: a few callers select an explicit column list
  if AQuery.FindField('archive_days') <> nil then
    Result.ArchiveDays := AQuery.FindField('archive_days').AsInteger;
  Result.IsNew := AQuery.FieldByName('is_new').AsInteger <> 0;
  Result.SeenAtUtc := IsoUtcToDateTime(AQuery.FieldByName('seen_at_utc').AsString);
  Result.FirstSeenUtc := IsoUtcToDateTime(AQuery.FieldByName('first_seen_utc').AsString);
  Result.LastSeenUtc := IsoUtcToDateTime(AQuery.FieldByName('last_seen_utc').AsString);
end;

// Build a SQL fragment that hides names not matching the source's filters.
// A token matches as a whole, separator-delimited PREFIX or SUFFIX word,
// case-insensitive (SQLite LIKE is ASCII-CI) — consistent with StripNamePrefixes.
// We first map every separator (| - : tab) to a space and trim, so a token like
// "NL" matches "NL| x", "|NL| x", " | NL | x" or "x | NL" alike, but never the
// middle of a word ("Netherlands"). Tokens come from operator config; we escape
// LIKE wildcards just in case.
function NameFilterSql(const ACol: string; const AInclude, AExclude: TArray<string>): string;

  function EscapeLike(const AText: string): string;
  begin
    Result := AText.Replace('\', '\\').Replace('%', '\%').Replace('_', '\_');
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
    i: Integer;
  begin
    Result := ACol;
    for i := Low(Seps) to High(Seps) do
      Result := 'REPLACE(' + Result + ', ' + Seps[i] + ', '' '')';
    Result := 'TRIM(' + Result + ')';
  end;

  // normalise a configured token the same way (seps -> space, trim) so it lines
  // up with NormCol (e.g. "NL|", "|NL|", "┃NL┃" all become "NL").
  function NormToken(const AText: string): string;
  begin
    Result := AText
      .Replace('|', ' ').Replace('-', ' ').Replace(':', ' ').Replace(#9, ' ')
      .Replace(cSepBrokenBar, ' ').Replace(cSepBoxLight, ' ').Replace(cSepBoxHeavy, ' ')
      .Replace(cSepTripleDashLight, ' ').Replace(cSepTripleDashHeavy, ' ').Replace(cSepQuadDashLight, ' ')
      .Replace(cSepQuadDashHeavy, ' ').Replace(cSepFullwidthBar, ' ')
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
    lMid: Integer;
  begin
    if ALo = AHi then
      Result := ALeaves[ALo]
    else
    begin
      lMid := (ALo + AHi) div 2;
      Result := '(' + BalancedOr(ALeaves, ALo, lMid) + ' OR ' + BalancedOr(ALeaves, lMid + 1, AHi) + ')';
    end;
  end;

  function AnyMatch(const ATokens: TArray<string>): string;
  var
    lToken, lEsc: string;
    lLeaves: TList<string>;
  begin
    lLeaves := TList<string>.Create;
    try
      for lToken in ATokens do
        if NormToken(lToken) <> '' then
        begin
          lEsc := EscapeLike(NormToken(lToken));
          // whole name, or token as the first word, or token as the last word
          lLeaves.Add('(' + Like(lEsc) + ' OR ' + Like(lEsc + ' %') + ' OR ' + Like('% ' + lEsc) + ')');
        end;
      if lLeaves.Count = 0 then
        Result := ''
      else
        Result := BalancedOr(lLeaves.ToArray, 0, lLeaves.Count - 1);
    finally
      FreeAndNil(lLeaves);
    end;
  end;

var
  lIncSql, lExcSql: string;
begin
  Result := '';
  // drop pasted-list / oversized tokens first (SQLite rejects LIKE patterns over
  // 50 000 chars and such a token can't match a real name anyway)
  lIncSql := AnyMatch(CleanFilterTokens(AInclude));
  if lIncSql <> '' then
    Result := Result + ' AND ' + lIncSql;
  lExcSql := AnyMatch(CleanFilterTokens(AExclude));
  if lExcSql <> '' then
    Result := Result + ' AND NOT ' + lExcSql;
end;

// Full name-filter fragment for a catalog query: the global filter (no source
// guard, for a single selected source) plus each per-source filter guarded by
// its source_id (so the "all sources" view filters every source by its own rules).
function CatalogFilterSql(const AFilter: TCatalogFilter; const ACol: string): string;
var
  lSourceFilter: TSourceFilter;
  lSub: string;
begin
  Result := NameFilterSql(ACol, AFilter.IncludeFilters, AFilter.ExcludeFilters);
  for lSourceFilter in AFilter.SourceFilters do
  begin
    lSub := NameFilterSql(ACol, lSourceFilter.IncludeFilters, lSourceFilter.ExcludeFilters);
    if lSub <> '' then
      // a row passes if it's from another source, or it satisfies this source's filter
      Result := Result + Format(' AND (source_id <> %d OR (1=1%s))', [lSourceFilter.SourceId, lSub]);
  end;
end;

// Multi-word search: split on commas/whitespace and AND each term as a
// case-insensitive substring (so "NL UHD" keeps only names containing BOTH).
function SearchSql(const ACol, ASearch: string): string;

  function Esc(const AText: string): string;
  begin
    Result := AText.Replace('\', '\\').Replace('%', '\%').Replace('_', '\_');
  end;

var
  lTerms: TArray<string>;
  lTerm: string;
begin
  Result := '';
  lTerms := ASearch.Split([',', ' ', #9], TStringSplitOptions.ExcludeEmpty);
  for lTerm in lTerms do
    Result := Result + ' AND ' + ACol + ' LIKE ' + QuotedStr('%' + Esc(lTerm) + '%') +
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
  i: Integer;
begin
  Result.Global := PrepareNameFilter(AFilter.IncludeFilters, AFilter.ExcludeFilters);
  SetLength(Result.SourceIds, Length(AFilter.SourceFilters));
  SetLength(Result.PerSource, Length(AFilter.SourceFilters));
  for i := 0 to High(AFilter.SourceFilters) do
  begin
    Result.SourceIds[i] := AFilter.SourceFilters[i].SourceId;
    Result.PerSource[i] := PrepareNameFilter(AFilter.SourceFilters[i].IncludeFilters,
      AFilter.SourceFilters[i].ExcludeFilters);
  end;
end;

function CategoryPassesFilter(const ACat: TCategory; const AFilter: TPreparedCatalogFilter): Boolean;
var
  i: Integer;
begin
  if not PreparedNamePasses(AFilter.Global, ACat.Name) then
    Exit(False);
  for i := 0 to High(AFilter.SourceIds) do
    if (AFilter.SourceIds[i] = ACat.SourceId) and
       not PreparedNamePasses(AFilter.PerSource[i], ACat.Name) then
      Exit(False);
  Result := True;
end;

// ' AND source_id=… AND content_type=…' for the source / content type of AFilter
// (both tables carry these two columns)
function SourceTypeSql(const AFilter: TCatalogFilter): string;
begin
  Result := '';
  if AFilter.SourceId > 0 then
    Result := Result + ' AND source_id=' + AFilter.SourceId.ToString;
  if AFilter.HasContentType then
    Result := Result + ' AND content_type=' + QuotedStr(ContentTypeNames[AFilter.ContentType]);
end;

// key of one category for the new-stream counts: source, content type, upstream id
function CategoryKey(ASourceId: Integer; const AContentType, AUpstreamId: string): string;
const
  cCategoryKeyFmt = '%d|%s|%s';
begin
  Result := Format(cCategoryKeyFmt, [ASourceId, AContentType, AUpstreamId]);
end;

function TSQLiteStore.LoadCategories(const AFilter: TCatalogFilter): TCategoryList;
const
  // new streams per category (a stream links to its category by upstream id)
  cSqlNewPerCategory = '''
    SELECT source_id, content_type, COALESCE(category_upstream_id, '') AS cat, COUNT(*) AS n
    FROM streams WHERE is_new=1
    ''';
  cSqlNewPerCategoryGroup = ' GROUP BY source_id, content_type, cat';
var
  lQuery: TFDQuery;
  lWhere: string;
  lCat: TCategory;
  lPrepared: TPreparedCatalogFilter;
  lNewCounts: TDictionary<string, Integer>;
  lCount: Integer;
begin
  Result := TCategoryList.Create(True);
  lPrepared := PrepareCatalogFilter(AFilter);
  lNewCounts := TDictionary<string, Integer>.Create;
  lQuery := NewQuery;
  try
    // 1) new streams per category, so a group that is not new itself but holds new
    //    channels shows "+N new" and stays in the "only new" view
    lWhere := SourceTypeSql(AFilter);
    if AFilter.UseHiddenFlag then
      lWhere := lWhere + ' AND hidden=0';
    lQuery.SQL.Text := cSqlNewPerCategory + lWhere + cSqlNewPerCategoryGroup;
    lQuery.Open;
    while not lQuery.Eof do
    begin
      lNewCounts.AddOrSetValue(CategoryKey(lQuery.FieldByName('source_id').AsInteger,
        lQuery.FieldByName('content_type').AsString, lQuery.FieldByName('cat').AsString),
        lQuery.FieldByName('n').AsInteger);
      lQuery.Next;
    end;
    lQuery.Close;

    // 2) the categories
    lWhere := ' WHERE 1=1' + SourceTypeSql(AFilter);
    if AFilter.UseHiddenFlag then
      lWhere := lWhere + ' AND hidden=0';
    lWhere := lWhere + SearchSql('name', AFilter.Search); // multi-word AND search
    lQuery.SQL.Text := 'SELECT * FROM categories' + lWhere + ' ORDER BY name COLLATE NOCASE';
    lQuery.Open;
    // hide groups whose name matches the source's filters (live view filter) —
    // done here in memory, not as SQL: with hundreds of filter tokens the nested
    // REPLACE/LIKE tree made this the slowest query in the app (~20 s on the NAS)
    // while holding the single DB connection. Groups are few; matching is cheap.
    while not lQuery.Eof do
    begin
      lCat := ReadCategory(lQuery);
      if lNewCounts.TryGetValue(CategoryKey(lCat.SourceId, ContentTypeNames[lCat.ContentType], lCat.UpstreamId),
        lCount) then
        lCat.NewCount := lCount;
      // "only new": the group itself is new, or it holds new channels
      if CategoryPassesFilter(lCat, lPrepared) and
         (not AFilter.OnlyNew or lCat.IsNew or (lCat.NewCount > 0)) then
        Result.Add(lCat)
      else
        FreeAndNil(lCat);
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lNewCounts);
  end;
end;

// escape LIKE wildcards in a literal so a '%' or '_' in the value is matched
// literally (paired with an ESCAPE '\' clause) — a discovered prefix can legitimately
// contain '%'/'_' (e.g. a "100% HD" group), which would otherwise match anything.
function EscapeLikeLiteral(const AText: string): string;
begin
  Result := AText.Replace('\', '\\').Replace('%', '\%').Replace('_', '\_');
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

procedure BindStreamFilter(AQuery: TFDQuery; const AFilter: TCatalogFilter);
begin
  if AFilter.Prefix <> '' then
    // escape wildcards in the literal prefix; the trailing '%' stays a wildcard
    AQuery.ParamByName('prefix').AsWideString := EscapeLikeLiteral(AFilter.Prefix) + '%';
  if AFilter.HasCategory then
    AQuery.ParamByName('cat').AsWideString := AFilter.CategoryUpstreamId;
end;

function TSQLiteStore.LoadStreams(const AFilter: TCatalogFilter): TStreamItemList;
var
  lQuery: TFDQuery;
  lSql: string;
begin
  Result := TStreamItemList.Create(True);
  lQuery := NewQuery;
  try
    // id as tiebreak: equal names in an undefined order made paging repeat or skip rows
    lSql := 'SELECT * FROM streams' + StreamWhere(AFilter) + ' ORDER BY name COLLATE NOCASE, id';
    if AFilter.Limit > 0 then
      lSql := lSql + ' LIMIT :limit OFFSET :offset';
    lQuery.SQL.Text := lSql;
    BindStreamFilter(lQuery, AFilter);
    if AFilter.Limit > 0 then
    begin
      lQuery.ParamByName('limit').AsInteger := AFilter.Limit;
      lQuery.ParamByName('offset').AsInteger := AFilter.Offset;
    end;
    lQuery.Open;
    while not lQuery.Eof do
    begin
      Result.Add(ReadStream(lQuery));
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.CountStreams(const AFilter: TCatalogFilter): Integer;
var
  lQuery: TFDQuery;
begin
  lQuery := NewQuery;
  try
    lQuery.SQL.Text := 'SELECT COUNT(*) AS c FROM streams' + StreamWhere(AFilter);
    BindStreamFilter(lQuery, AFilter);
    lQuery.Open;
    Result := lQuery.FieldByName('c').AsInteger;
  finally
    FreeAndNil(lQuery);
  end;
end;

procedure TSQLiteStore.MarkCategoriesSeen(const AIds: TArray<Integer>);
const
  // the new streams of those categories too, so the group's "+N new" badge clears
  cSqlStreamsOfCategoriesSeen = '''
    UPDATE streams SET is_new=0, seen_at_utc=:t
    WHERE is_new=1 AND EXISTS (SELECT 1 FROM categories c WHERE c.id IN (%s)
      AND c.source_id=streams.source_id AND c.content_type=streams.content_type
      AND COALESCE(c.upstream_id, '')=COALESCE(streams.category_upstream_id, ''))
    ''';
var
  lNow: string;
begin
  if Length(AIds) = 0 then
    Exit;
  lNow := DateTimeToIsoUtc(NowUtc);
  FConn.StartTransaction;
  try
    FConn.ExecSQL(Format('UPDATE categories SET is_new=0, seen_at_utc=:t WHERE id IN (%s)', [IdsToCsv(AIds)]),
      [lNow]);
    FConn.ExecSQL(Format(cSqlStreamsOfCategoriesSeen, [IdsToCsv(AIds)]), [lNow]);
    FConn.Commit;
  except
    SafeRollback;
    raise;
  end;
end;

function TSQLiteStore.CountNew(const AFilter: TCatalogFilter): TNewCounts;
var
  lQuery: TFDQuery;
begin
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT COUNT(*) AS n FROM categories WHERE is_new=1' + SourceTypeSql(AFilter));
    Result.Categories := lQuery.FieldByName('n').AsInteger;
    lQuery.Close;
    lQuery.Open('SELECT COUNT(*) AS n FROM streams WHERE is_new=1' + SourceTypeSql(AFilter));
    Result.Streams := lQuery.FieldByName('n').AsInteger;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.MarkAllSeen(const AFilter: TCatalogFilter): TNewCounts;
var
  lNow: string;
begin
  lNow := DateTimeToIsoUtc(NowUtc);
  FConn.StartTransaction;
  try
    Result.Categories := FConn.ExecSQL('UPDATE categories SET is_new=0, seen_at_utc=:t WHERE is_new=1' +
      SourceTypeSql(AFilter), [lNow]);
    Result.Streams := FConn.ExecSQL('UPDATE streams SET is_new=0, seen_at_utc=:t WHERE is_new=1' +
      SourceTypeSql(AFilter), [lNow]);
    FConn.Commit;
  except
    SafeRollback;
    raise;
  end;
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
  lQuery: TFDQuery;
begin
  Result := nil;
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT * FROM streams WHERE id=:id', [AId]);
    if not lQuery.IsEmpty then
      Result := ReadStream(lQuery);
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.LoadSiblingUrls(AStreamItemId: Integer): TArray<TSiblingUrl>;
var
  lQuery: TFDQuery;
  lCt, lTvg, lName: string;
  lUrls: TList<TSiblingUrl>;
  lSibling: TSiblingUrl;
begin
  Result := nil;
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT content_type, tvg_id, name FROM streams WHERE id = :id', [AStreamItemId]);
    if lQuery.IsEmpty then
      Exit;
    lCt := lQuery.FieldByName('content_type').AsString;
    lTvg := lQuery.FieldByName('tvg_id').AsString;
    lName := lQuery.FieldByName('name').AsString;
    lQuery.Close;
    lUrls := TList<TSiblingUrl>.Create;
    try
      // same channel from a DIFFERENT row: by tvg-id when present (reliable), else by
      // exact case-insensitive name (conservative — avoids failing over to a wrong
      // channel). Same content type; skip self and empty URLs.
      lQuery.SQL.Text :=
        '''
        SELECT s.upstream_url, s.source_id FROM streams s
        LEFT JOIN sources src ON src.id = s.source_id
        WHERE s.id <> :id AND s.content_type = :ct AND s.upstream_url <> ''
          AND ((:tvg <> '' AND s.tvg_id = :tvg) OR (:tvg = '' AND s.name = :nm COLLATE NOCASE))
          AND
        ''' + cSqlSourceActive + ' ORDER BY s.source_id';
      lQuery.ParamByName('id').AsInteger := AStreamItemId;
      lQuery.ParamByName('ct').AsWideString := lCt;
      lQuery.ParamByName('tvg').AsWideString := lTvg;
      lQuery.ParamByName('nm').AsWideString := lName;
      lQuery.Open;
      while not lQuery.Eof do
      begin
        lSibling.Url := lQuery.Fields[0].AsString;
        lSibling.SourceId := lQuery.Fields[1].AsInteger;
        lUrls.Add(lSibling);
        lQuery.Next;
      end;
      Result := lUrls.ToArray;
    finally
      FreeAndNil(lUrls);
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.LoadStreamSiblings(AStreamItemId: Integer): TArray<string>;
var
  lSibling: TSiblingUrl;
begin
  Result := nil;
  for lSibling in LoadSiblingUrls(AStreamItemId) do
    Result := Result + [lSibling.Url];
end;

function TSQLiteStore.LoadStreamSiblingsForList(AListId, AStreamItemId: Integer): TArray<string>;
var
  lSibling: TSiblingUrl;
  lAccounts: TDictionary<Integer, TPlaybackAccount>;
begin
  Result := nil;
  if ListMasterId(AListId) = cNoMirror then
    Exit(LoadStreamSiblings(AStreamItemId));
  // a mirror plays each candidate with its own account at that candidate's source
  lAccounts := LoadPlaybackAccounts(AListId);
  try
    for lSibling in LoadSiblingUrls(AStreamItemId) do
      Result := Result + [PlaybackUrl(lAccounts, lSibling.SourceId, lSibling.Url)];
  finally
    FreeAndNil(lAccounts);
  end;
end;

function TSQLiteStore.LoadListStreamById(AListId, AStreamItemId: Integer): TStreamItem;
var
  lMasterId: Integer;
  lAccounts: TDictionary<Integer, TPlaybackAccount>;
begin
  lMasterId := ListMasterId(AListId);
  if lMasterId = cNoMirror then
    Exit(LoadScopedStream(AListId, AStreamItemId));
  // a mirror: the master's channels (incl. its series episodes), played with the
  // mirror's own provider account
  Result := LoadScopedStream(lMasterId, AStreamItemId);
  if Result = nil then
    Exit;
  lAccounts := LoadPlaybackAccounts(AListId);
  try
    Result.UpstreamUrl := PlaybackUrl(lAccounts, Result.SourceId, Result.UpstreamUrl);
  finally
    FreeAndNil(lAccounts);
  end;
end;

function TSQLiteStore.LoadScopedStream(AListId, AStreamItemId: Integer): TStreamItem;
var
  lQuery: TFDQuery;
begin
  // only return the stream when it is actually an item on this list, so the
  // credential-scoped output can't serve a stream off another list / not curated.
  Result := nil;
  lQuery := NewQuery;
  try
    if AStreamItemId >= cEpisodeIdBase then
    begin
      // a series episode: allowed when its series is on this list
      lQuery.Open(
        '''
        SELECT e.upstream_episode_id AS eid, e.ext AS ext, s.id AS sid, s.source_id AS srcid,
               s.name AS nm, src.url AS surl, src.username AS su, src.password AS sp
        FROM series_episodes e
        JOIN streams s ON s.id = e.stream_id
        JOIN list_items i ON i.stream_item_id = s.id
        LEFT JOIN sources src ON src.id = s.source_id
        WHERE e.id = :e AND i.list_id = :l AND src.id IS NOT NULL AND
        ''' + cSqlSourceActive + ' LIMIT 1',
        [AStreamItemId - cEpisodeIdBase, AListId]);
      if not lQuery.IsEmpty then
      begin
        Result := TStreamItem.Create;
        Result.Id := AStreamItemId;
        Result.SourceId := lQuery.FieldByName('srcid').AsInteger;
        Result.ContentType := ctSeries;
        Result.UpstreamId := lQuery.FieldByName('eid').AsString;
        Result.Name := lQuery.FieldByName('nm').AsString;
        // built from the source's CURRENT url/credentials (a credential swap keeps working)
        Result.UpstreamUrl := Format('%s/series/%s/%s/%s.%s',
          [lQuery.FieldByName('surl').AsString.Trim.TrimRight(['/']), UrlPathSafe(lQuery.FieldByName('su').AsString),
           UrlPathSafe(lQuery.FieldByName('sp').AsString), Result.UpstreamId,
           System.StrUtils.IfThen(lQuery.FieldByName('ext').AsString = '', cDefaultEpisodeExt,
             lQuery.FieldByName('ext').AsString)]);
      end;
      Exit;
    end;
    lQuery.Open(
      '''
      SELECT s.* FROM streams s
      JOIN list_items i ON i.stream_item_id = s.id
      LEFT JOIN sources src ON src.id = s.source_id
      WHERE i.list_id = :l AND s.id = :id AND
      ''' + cSqlSourceActive + ' LIMIT 1', [AListId, AStreamItemId]);
    if not lQuery.IsEmpty then
      Result := ReadStream(lQuery);
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.FindEpisodeIds(ASeriesStreamId: Integer; const AUpstreamIds,
  AExts: TArray<string>): TArray<Integer>;
var
  lQuery: TFDQuery;
  lKnown: TDictionary<string, TPair<Integer, string>>; // upstream id -> (row id, ext)
  lHit: TPair<Integer, string>;
  lExt: string;
  i: Integer;
begin
  SetLength(Result, Length(AUpstreamIds));
  if Length(AUpstreamIds) = 0 then
    Exit;
  lKnown := TDictionary<string, TPair<Integer, string>>.Create;
  lQuery := NewQuery;
  try
    lQuery.SQL.Text := 'SELECT id, upstream_episode_id, ext FROM series_episodes WHERE stream_id = :s';
    lQuery.ParamByName('s').AsInteger := ASeriesStreamId;
    lQuery.Open;
    while not lQuery.Eof do
    begin
      lKnown.AddOrSetValue(lQuery.FieldByName('upstream_episode_id').AsWideString,
        TPair<Integer, string>.Create(lQuery.FieldByName('id').AsInteger, lQuery.FieldByName('ext').AsWideString));
      lQuery.Next;
    end;
    for i := 0 to High(AUpstreamIds) do
    begin
      lExt := '';
      if i <= High(AExts) then
        lExt := AExts[i];
      if lKnown.TryGetValue(AUpstreamIds[i], lHit) and (lHit.Value = lExt) then
        Result[i] := cEpisodeIdBase + lHit.Key
      else
        Result[i] := 0;
    end;
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lKnown);
  end;
end;

function TSQLiteStore.EnsureEpisodeIds(ASeriesStreamId: Integer; const AUpstreamIds,
  AExts: TArray<string>): TArray<Integer>;
var
  lInsert, lSelect: TFDQuery;
  i: Integer;
  lExt: string;
begin
  SetLength(Result, Length(AUpstreamIds));
  if Length(AUpstreamIds) = 0 then
    Exit;
  lInsert := NewQuery;
  lSelect := NewQuery;
  try
    lInsert.SQL.Text := '''
      INSERT INTO series_episodes(stream_id, upstream_episode_id, ext) VALUES(:s, :u, :x)
      ON CONFLICT(stream_id, upstream_episode_id) DO UPDATE SET ext = excluded.ext
      ''';
    lSelect.SQL.Text := 'SELECT id FROM series_episodes WHERE stream_id = :s AND upstream_episode_id = :u';
    FConn.StartTransaction;
    try
      for i := 0 to High(AUpstreamIds) do
      begin
        lExt := '';
        if i <= High(AExts) then
          lExt := AExts[i];
        lInsert.ParamByName('s').AsInteger := ASeriesStreamId;
        lInsert.ParamByName('u').AsWideString := AUpstreamIds[i];
        lInsert.ParamByName('x').AsWideString := lExt;
        lInsert.ExecSQL;
        lSelect.ParamByName('s').AsInteger := ASeriesStreamId;
        lSelect.ParamByName('u').AsWideString := AUpstreamIds[i];
        lSelect.Open;
        Result[i] := cEpisodeIdBase + lSelect.Fields[0].AsInteger;
        lSelect.Close;
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lInsert);
    FreeAndNil(lSelect);
  end;
end;

function TSQLiteStore.DiscoverPrefixes(ASourceId: Integer): TArray<TPrefixCount>;
var
  lQuery: TFDQuery;
  lCounts: TDictionary<string, Integer>;
  lPrefix: string;
  lCount: Integer;
  lPair: TPair<string, Integer>;
  i: Integer;
  lTable: string;
begin
  lCounts := TDictionary<string, Integer>.Create;
  lQuery := NewQuery;
  try
    // Scan BOTH channel names and category/group names: the operator filters by
    // either, and groups often use a different prefix scheme than their channels
    // (e.g. group "AL| ALBANIA" while channels are "ALB| ..."). Surfacing both
    // lets a single exclude token hide the matching groups AND channels.
    for lTable in [cTableStreams, cTableCategories] do
    begin
      if ASourceId > 0 then
        lQuery.Open(Format('SELECT name FROM %s WHERE source_id=:s', [lTable]), [ASourceId])
      else
        lQuery.Open(Format('SELECT name FROM %s', [lTable]));
      while not lQuery.Eof do
      begin
        lPrefix := ExtractNamePrefix(lQuery.Fields[0].AsString);
        if lPrefix <> '' then
        begin
          lCounts.TryGetValue(lPrefix, lCount);
          lCounts.AddOrSetValue(lPrefix, lCount + 1);
        end;
        lQuery.Next;
      end;
      lQuery.Close;
    end;

    SetLength(Result, lCounts.Count);
    i := 0;
    for lPair in lCounts do
    begin
      Result[i].Prefix := lPair.Key;
      Result[i].Count := lPair.Value;
      Inc(i);
    end;
    // most common first, then alphabetical (case-insensitive) as a tiebreaker
    TArray.Sort<TPrefixCount>(Result, TComparer<TPrefixCount>.Construct(
      function(const ALeft, ARight: TPrefixCount): Integer
      begin
        Result := ARight.Count - ALeft.Count;
        if Result = 0 then
          Result := CompareText(ALeft.Prefix, ARight.Prefix);
      end));
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lCounts);
  end;
end;

function TSQLiteStore.LoadKnownTvgIds: TArray<TTvgIdInfo>;
var
  lQuery: TFDQuery;
  lList: TList<TTvgIdInfo>;
  lInfo: TTvgIdInfo;
begin
  lList := TList<TTvgIdInfo>.Create;
  lQuery := NewQuery;
  try
    // distinct tvg-ids in the catalog with one representative channel name
    lQuery.Open('''
      SELECT tvg_id, MIN(name) AS nm FROM streams WHERE tvg_id <> ''
      GROUP BY tvg_id ORDER BY nm COLLATE NOCASE
      ''');
    while not lQuery.Eof do
    begin
      lInfo.TvgId := lQuery.FieldByName('tvg_id').AsString;
      lInfo.Name := lQuery.FieldByName('nm').AsString;
      lList.Add(lInfo);
      lQuery.Next;
    end;
    Result := lList.ToArray;
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lList);
  end;
end;

function TSQLiteStore.FindQualityVariants(AListId, ASourceGroupId: Integer;
  const ATargetQuality: string): TArray<TVariantMatch>;
type
  TCand = record
    Id, SourceId: Integer;
    Name: string;
  end;
  TRules = record
    Prefixes, Suffixes: TArray<string>;
  end;
var
  lQuery: TFDQuery;
  lItems: TList<TVariantMatch>;
  lItemSrc: TList<Integer>;  // parallel to Items: source_id (same-source preference)
  lBases: TList<string>;     // parallel to Items: quality-stripped base key
  lHeads: TList<string>;     // parallel to Items: tokens before the quality word
  lNeededBase, lNeededHead: TDictionary<string, Boolean>;
  lDictBase, lDictHead: TDictionary<string, TList<TCand>>;
  lInList: TDictionary<Integer, Boolean>;
  lRules: TDictionary<Integer, TRules>;
  lCts: TStringList;
  lTarget, lBase, lHead, lQual, lInClause: string;
  lMatch: TVariantMatch;
  lCand: TCand;
  lCands: TList<TCand>;
  lRule: TRules;
  i, lPicked: Integer;

  // the match key is computed on the CLEANED name (the source's strip prefixes
  // and suffixes removed, e.g. "NL |" and "(S)"), so tags that differ between
  // variants don't break the match; decorative letters are folded by the key
  function KeyOf(const AName: string; ASourceId: Integer; out AQual, AHead: string): string;
  var
    lSourceRules: TRules;
  begin
    if lRules.TryGetValue(ASourceId, lSourceRules) then
      Result := QualityMatchKey(CleanChannelName(AName, lSourceRules.Prefixes, lSourceRules.Suffixes), AQual, AHead)
    else
      Result := QualityMatchKey(AName, AQual, AHead);
  end;

  procedure AddCand(ADict: TDictionary<string, TList<TCand>>; const AKey: string; const ACand: TCand);
  var
    lList: TList<TCand>;
  begin
    if not ADict.TryGetValue(AKey, lList) then
    begin
      lList := TList<TCand>.Create;
      ADict.Add(AKey, lList);
    end;
    lList.Add(ACand);
  end;

  // prefer the SAME source, never the item's own stream; among equals the
  // shortest name (the plainest variant, e.g. "NPO 1 4K+" over "NPO 1 4K+ backup")
  function Pick(AList: TList<TCand>; AOwnStream, ASrc: Integer): Integer;
  var
    k: Integer;
  begin
    Result := -1;
    for k := 0 to AList.Count - 1 do
      if (AList[k].Id <> AOwnStream) and (AList[k].SourceId = ASrc) and
         ((Result < 0) or (Length(AList[k].Name) < Length(AList[Result].Name))) then
        Result := k;
    if Result < 0 then
      for k := 0 to AList.Count - 1 do
        if (AList[k].Id <> AOwnStream) and
           ((Result < 0) or (Length(AList[k].Name) < Length(AList[Result].Name))) then
          Result := k;
  end;

begin
  lTarget := CanonicalQuality(ATargetQuality);
  if lTarget = '' then
    Exit(nil); // unknown/blank target quality

  lItems := TList<TVariantMatch>.Create;
  lItemSrc := TList<Integer>.Create;
  lBases := TList<string>.Create;
  lHeads := TList<string>.Create;
  lNeededBase := TDictionary<string, Boolean>.Create;
  lNeededHead := TDictionary<string, Boolean>.Create;
  lDictBase := TDictionary<string, TList<TCand>>.Create;
  lDictHead := TDictionary<string, TList<TCand>>.Create;
  lInList := TDictionary<Integer, Boolean>.Create;
  lRules := TDictionary<Integer, TRules>.Create;
  lCts := TStringList.Create;
  try
    lCts.Sorted := True;
    lCts.Duplicates := dupIgnore;

    // 0. every source's strip rules (few rows)
    lQuery := NewQuery;
    try
      lQuery.Open('SELECT id, strip_prefixes, strip_suffixes FROM sources');
      while not lQuery.Eof do
      begin
        lRule.Prefixes := CsvToStrArray(lQuery.Fields[1].AsString, cStripTokenSep);
        lRule.Suffixes := CsvToStrArray(lQuery.Fields[2].AsString, cStripTokenSep);
        lRules.AddOrSetValue(lQuery.Fields[0].AsInteger, lRule);
        lQuery.Next;
      end;
    finally
      FreeAndNil(lQuery);
    end;

    // 1. the source group's items + their current (ORIGINAL upstream) stream name.
    //    Matching uses the stream's own name, never the list's stripped display
    //    name, so a prefix/suffix stripped on the list doesn't matter.
    lQuery := NewQuery;
    try
      lQuery.Open(
        '''
        SELECT i.id AS iid, i.stream_item_id AS sid, s.name AS sname,
          s.content_type AS ct, s.source_id AS srcid
        FROM list_items i JOIN streams s ON s.id = i.stream_item_id
        WHERE i.list_id = :l AND i.custom_group_id = :g
        ORDER BY i.channel_number, sname COLLATE NOCASE
        ''', [AListId, ASourceGroupId]);
      while not lQuery.Eof do
      begin
        lMatch := Default(TVariantMatch);
        lMatch.ItemId := lQuery.FieldByName('iid').AsInteger;
        lMatch.StreamId := lQuery.FieldByName('sid').AsInteger;
        lMatch.Name := lQuery.FieldByName('sname').AsString;
        lBase := KeyOf(lMatch.Name, lQuery.FieldByName('srcid').AsInteger, lQual, lHead);
        lMatch.Quality := lQual;
        lItems.Add(lMatch);
        lBases.Add(lBase);
        lHeads.Add(lHead);
        lItemSrc.Add(lQuery.FieldByName('srcid').AsInteger);
        if lBase <> '' then
          lNeededBase.AddOrSetValue(lBase, True);
        if lHead <> '' then
          lNeededHead.AddOrSetValue(lHead, True);
        lCts.Add(lQuery.FieldByName('ct').AsString);
        lQuery.Next;
      end;
    finally
      FreeAndNil(lQuery);
    end;
    if lItems.Count = 0 then
      Exit(nil);

    // 2. stream ids already on this list (a candidate already here can't be re-added)
    lQuery := NewQuery;
    try
      lQuery.Open('SELECT stream_item_id FROM list_items WHERE list_id = :l', [AListId]);
      while not lQuery.Eof do
      begin
        lInList.AddOrSetValue(lQuery.FieldByName('stream_item_id').AsInteger, True);
        lQuery.Next;
      end;
    finally
      FreeAndNil(lQuery);
    end;

    // 3. candidate pool: streams of the same content type(s) that carry the TARGET
    //    quality and whose base key (or, as a fallback, head key) matches
    lInClause := '';
    for i := 0 to lCts.Count - 1 do
      lInClause := lInClause + IfThen(i > 0, ',', '') + QuotedStr(lCts[i]);
    lQuery := NewQuery;
    try
      // only active sources: a swap onto a switched-off provider would silently
      // drop the channel from the box
      // SQL prefilter: only names that can carry the target quality word - it in
      // plain letters (LIKE is ASCII case-insensitive), or any non-ASCII name
      // (decorative letters like the small-caps "ꜰʜᴅ" fold to it only in Delphi).
      // Before, every stream of the type ran through KeyOf under the read lock.
      lQuery.SQL.Text := '''
        SELECT id, source_id, name FROM streams s
        WHERE content_type IN (
        ''' + lInClause + ') AND upstream_url <> '''' AND ' + cSqlSourceActiveExists + '''

        AND (name LIKE :q1 ESCAPE '\' OR name LIKE :q2 ESCAPE '\' OR name GLOB '*[^ -~]*')
        ''';
      lQuery.ParamByName('q1').AsWideString := '%' + EscapeLikeLiteral(lTarget) + '%';
      if lTarget = cQualityFhd then
        lQuery.ParamByName('q2').AsWideString := cFullHdLikePattern // FULLHD / FULL-HD
      else
        lQuery.ParamByName('q2').AsWideString := '%' + EscapeLikeLiteral(lTarget) + '%';
      lQuery.Open;
      while not lQuery.Eof do
      begin
        lBase := KeyOf(lQuery.FieldByName('name').AsString, lQuery.FieldByName('source_id').AsInteger, lQual, lHead);
        if lQual = lTarget then
        begin
          lCand.Id := lQuery.FieldByName('id').AsInteger;
          lCand.SourceId := lQuery.FieldByName('source_id').AsInteger;
          lCand.Name := lQuery.FieldByName('name').AsString;
          if (lBase <> '') and lNeededBase.ContainsKey(lBase) then
            AddCand(lDictBase, lBase, lCand);
          if (lHead <> '') and lNeededHead.ContainsKey(lHead) then
            AddCand(lDictHead, lHead, lCand);
        end;
        lQuery.Next;
      end;
    finally
      FreeAndNil(lQuery);
    end;

    // 4. pick a candidate per item: exact base key first; else the head key
    //    (ignores tags AFTER the quality word, e.g. "NPO 1 RAW (S)" -> "NPO 1 4K+")
    for i := 0 to lItems.Count - 1 do
    begin
      lMatch := lItems[i];
      lPicked := -1;
      lCands := nil;
      if lDictBase.TryGetValue(lBases[i], lCands) then
        lPicked := Pick(lCands, lMatch.StreamId, lItemSrc[i]);
      if (lPicked < 0) and (lHeads[i] <> '') and lDictHead.TryGetValue(lHeads[i], lCands) then
        lPicked := Pick(lCands, lMatch.StreamId, lItemSrc[i]);
      if lPicked >= 0 then
      begin
        lMatch.CandidateStreamId := lCands[lPicked].Id;
        lMatch.CandidateName := lCands[lPicked].Name;
        lMatch.AlreadyInList := lInList.ContainsKey(lCands[lPicked].Id);
      end;
      lItems[i] := lMatch;
    end;

    Result := lItems.ToArray;
  finally
    for lCands in lDictBase.Values do
      lCands.Free;
    for lCands in lDictHead.Values do
      lCands.Free;
    FreeAndNil(lDictBase);
    FreeAndNil(lDictHead);
    FreeAndNil(lNeededBase);
    FreeAndNil(lNeededHead);
    FreeAndNil(lInList);
    FreeAndNil(lRules);
    FreeAndNil(lItems);
    FreeAndNil(lItemSrc);
    FreeAndNil(lBases);
    FreeAndNil(lHeads);
    FreeAndNil(lCts);
  end;
end;

function TSQLiteStore.FindStreamVariants(AStreamId: Integer; AAllSources: Boolean;
  AListId: Integer): TArray<TStreamVariant>;
type
  TRules = record
    Prefixes, Suffixes: TArray<string>;
  end;
var
  lQuery: TFDQuery;
  lRules: TDictionary<Integer, TRules>;
  lInList: TDictionary<Integer, Boolean>;
  lList: TList<TStreamVariant>;
  lRule: TRules;
  lVariant: TStreamVariant;
  lCt, lTvg, lName, lBase, lHead, lQual, lCBase, lCHead, lCQual, lSql: string;
  lSrcId, lPass, k: Integer;
  lByName, lByTvg: Boolean;
  lTok, lWord, lExtra: string;
  lTvgArr: TArray<string>;
  lSeen: TDictionary<Integer, Boolean>;
  lTvgs: TDictionary<string, string>; // lower-case id -> the id as written

  function KeyOf(const AName: string; ASourceId: Integer; out AQual, AHead: string): string;
  var
    lSourceRules: TRules;
  begin
    if lRules.TryGetValue(ASourceId, lSourceRules) then
      Result := QualityMatchKey(CleanChannelName(AName, lSourceRules.Prefixes, lSourceRules.Suffixes), AQual, AHead)
    else
      Result := QualityMatchKey(AName, AQual, AHead);
  end;

  function IsPlainAscii(const AStr: string): Boolean;
  var
    lChar: Char;
  begin
    for lChar in AStr do
      if not CharInSet(lChar, ['a'..'z', '0'..'9']) then
        Exit(False);
    Result := True;
  end;

begin
  Result := nil;
  lRules := TDictionary<Integer, TRules>.Create;
  lInList := TDictionary<Integer, Boolean>.Create;
  lList := TList<TStreamVariant>.Create;
  lSeen := TDictionary<Integer, Boolean>.Create;
  lTvgs := TDictionary<string, string>.Create;
  try
    lQuery := NewQuery;
    try
      lQuery.Open('SELECT id, strip_prefixes, strip_suffixes FROM sources');
      while not lQuery.Eof do
      begin
        lRule.Prefixes := CsvToStrArray(lQuery.Fields[1].AsString, cStripTokenSep);
        lRule.Suffixes := CsvToStrArray(lQuery.Fields[2].AsString, cStripTokenSep);
        lRules.AddOrSetValue(lQuery.Fields[0].AsInteger, lRule);
        lQuery.Next;
      end;

      lQuery.Close;
      lQuery.Open('SELECT content_type, tvg_id, name, source_id FROM streams WHERE id = :id', [AStreamId]);
      if lQuery.IsEmpty then
        Exit;
      lCt := lQuery.FieldByName('content_type').AsString;
      lTvg := lQuery.FieldByName('tvg_id').AsString.Trim;
      lName := lQuery.FieldByName('name').AsString;
      lSrcId := lQuery.FieldByName('source_id').AsInteger;
      lBase := KeyOf(lName, lSrcId, lQual, lHead);

      if AListId > 0 then
      begin
        lQuery.Close;
        lQuery.Open('SELECT stream_item_id FROM list_items WHERE list_id = :l', [AListId]);
        while not lQuery.Eof do
        begin
          lInList.AddOrSetValue(lQuery.Fields[0].AsInteger, True);
          lQuery.Next;
        end;
      end;

      // candidate pool: same content type (and source unless all sources), still
      // playable. Keys are computed in Delphi (decorative letters, strip rules).
      lSql := '''
        SELECT id, source_id, name, tvg_id, group_title FROM streams s
        WHERE content_type = :ct AND upstream_url <> '' AND
        ''' + cSqlSourceActiveExists;
      if lTvg <> '' then
        lTvgs.AddOrSetValue(lTvg.ToLower, lTvg);
      // pass 1: self + name matches (collecting their tvg-ids); pass 2: rows that
      // only share one of those tvg-ids, so a variant without a tvg-id still
      // finds a differently named sibling through the others
      // SQL prefilter (68k+ rows across sources): pass 1 only rows whose name
      // contains the longest plain token of the head key (every name/head match
      // must contain it), pass 2 only rows carrying one of the collected tvg-ids
      lTok := '';
      for lWord in lHead.Split([' ']) do
        if (Length(lWord) > Length(lTok)) and (Length(lWord) >= cMinPrefilterTokenLen) and IsPlainAscii(lWord) then
          lTok := lWord;
      for lPass := cPassByName to cPassByTvg do
      begin
        if (lPass = cPassByTvg) and (lTvgs.Count = 0) then
          Break;
        lQuery.Close;
        lExtra := IfThen(AAllSources, '', ' AND source_id = :s');
        lTvgArr := lTvgs.Keys.ToArray;
        if (lPass = cPassByName) and (lTok <> '') then
          // (a non-ASCII name may carry the token in decorative letters)
          lExtra := lExtra + ' AND (id = :self OR name LIKE :tok OR name GLOB ''*[^ -~]*'')'
        else if lPass = cPassByTvg then
        begin
          // SQLite's lower() only folds ASCII: also match the ids as they were written
          // (a non-ASCII capital in a tvg-id never matched the Delphi-lowered key)
          lExtra := lExtra + ' AND tvg_id <> '''' AND (lower(tvg_id) IN (';
          for k := 0 to High(lTvgArr) do
            lExtra := lExtra + IfThen(k > 0, ',', '') + ':t' + IntToStr(k);
          lExtra := lExtra + ') OR tvg_id IN (';
          for k := 0 to High(lTvgArr) do
            lExtra := lExtra + IfThen(k > 0, ',', '') + ':o' + IntToStr(k);
          lExtra := lExtra + '))';
        end;
        lQuery.SQL.Text := lSql + lExtra;
        lQuery.ParamByName('ct').AsWideString := lCt;
        if not AAllSources then
          lQuery.ParamByName('s').AsInteger := lSrcId;
        if (lPass = cPassByName) and (lTok <> '') then
        begin
          lQuery.ParamByName('self').AsInteger := AStreamId;
          lQuery.ParamByName('tok').AsWideString := '%' + lTok + '%';
        end
        else if lPass = cPassByTvg then
          for k := 0 to High(lTvgArr) do
          begin
            lQuery.ParamByName('t' + IntToStr(k)).AsWideString := lTvgArr[k];
            lQuery.ParamByName('o' + IntToStr(k)).AsWideString := lTvgs[lTvgArr[k]];
          end;
        lQuery.Open;
        while not lQuery.Eof do
        begin
          if lSeen.ContainsKey(lQuery.FieldByName('id').AsInteger) then
          begin
            lQuery.Next;
            Continue;
          end;
          lVariant := Default(TStreamVariant);
          lVariant.StreamId := lQuery.FieldByName('id').AsInteger;
          lVariant.SourceId := lQuery.FieldByName('source_id').AsInteger;
          lVariant.Name := lQuery.FieldByName('name').AsString;
          lVariant.TvgId := lQuery.FieldByName('tvg_id').AsString.Trim;
          lVariant.GroupTitle := lQuery.FieldByName('group_title').AsString;
          lCBase := KeyOf(lVariant.Name, lVariant.SourceId, lCQual, lCHead);
          lVariant.Quality := lCQual;
          lVariant.IsSelf := lVariant.StreamId = AStreamId;
          // same channel when the quality-stripped name matches; the head key (the
          // tokens before the quality word) catches tags after it ("RAW (S)") but
          // only when BOTH carry a quality word, so "NPO 1" never eats "NPO 1 EXTRA"
          lByName := ((lBase <> '') and (lCBase = lBase)) or
                    ((lHead <> '') and (lCHead = lHead) and (lQual <> '') and (lCQual <> ''));
          // same tvg-id (EPG id) + a quality word: a variant named differently
          lByTvg := (lPass = cPassByTvg) and (lVariant.TvgId <> '') and lTvgs.ContainsKey(lVariant.TvgId.ToLower) and
                   (lCQual <> '');
          if lPass = cPassByTvg then
            lByName := False;
          if ((lPass = cPassByName) and (lVariant.IsSelf or lByName)) or lByTvg then
          begin
            lSeen.AddOrSetValue(lVariant.StreamId, True);
            if (lPass = cPassByName) and (lVariant.TvgId <> '') then
              lTvgs.AddOrSetValue(lVariant.TvgId.ToLower, lVariant.TvgId);
            if lVariant.IsSelf then
              lVariant.MatchedBy := cMatchedBySelf
            else if lByName then
              lVariant.MatchedBy := cMatchedByName
            else
              lVariant.MatchedBy := cMatchedByTvg;
            lVariant.OnList := lInList.ContainsKey(lVariant.StreamId);
            lList.Add(lVariant);
          end;
          lQuery.Next;
        end;
      end;
    finally
      FreeAndNil(lQuery);
    end;

    // own source first, then the quality ladder (best tier first), then name
    lList.Sort(TComparer<TStreamVariant>.Construct(
      function(const ALeft, ARight: TStreamVariant): Integer
      begin
        Result := Ord(ALeft.SourceId <> lSrcId) - Ord(ARight.SourceId <> lSrcId);
        if Result = 0 then
          Result := ALeft.SourceId - ARight.SourceId;
        if Result = 0 then
          Result := QualityRank(ALeft.Quality) - QualityRank(ARight.Quality);
        if Result = 0 then
          Result := CompareText(ALeft.Name, ARight.Name);
      end));
    Result := lList.ToArray;
  finally
    FreeAndNil(lTvgs);
    FreeAndNil(lSeen);
    FreeAndNil(lList);
    FreeAndNil(lInList);
    FreeAndNil(lRules);
  end;
end;

function TSQLiteStore.FindProviderVariants(AListId, ASourceGroupId,
  ATargetSourceId: Integer): TArray<TVariantMatch>;
type
  TRow = record
    M: TVariantMatch;
    Ct, Tvg: string;
  end;
var
  lQuery: TFDQuery;
  lRows: TList<TRow>;
  lRow: TRow;
  lInList: TDictionary<Integer, Boolean>;
  lRes: TList<TVariantMatch>;
  lMatch: TVariantMatch;
  i: Integer;
begin
  lRows := TList<TRow>.Create;
  lInList := TDictionary<Integer, Boolean>.Create;
  lRes := TList<TVariantMatch>.Create;
  try
    lQuery := NewQuery;
    try
      // stream ids already on this list (a candidate already here can't be re-added)
      lQuery.Open('SELECT stream_item_id FROM list_items WHERE list_id = :l', [AListId]);
      while not lQuery.Eof do
      begin
        lInList.AddOrSetValue(lQuery.FieldByName('stream_item_id').AsInteger, True);
        lQuery.Next;
      end;
      lQuery.Close;

      // collect the source group's items, then close the cursor before per-item lookups
      lQuery.Open(
        '''
        SELECT i.id AS iid, i.stream_item_id AS sid, s.name AS sname,
          s.content_type AS ct, s.tvg_id AS tvg
        FROM list_items i JOIN streams s ON s.id = i.stream_item_id
        WHERE i.list_id = :l AND i.custom_group_id = :g
        ORDER BY i.channel_number, sname COLLATE NOCASE
        ''', [AListId, ASourceGroupId]);
      while not lQuery.Eof do
      begin
        lRow.M := Default(TVariantMatch);
        lRow.M.ItemId := lQuery.FieldByName('iid').AsInteger;
        lRow.M.StreamId := lQuery.FieldByName('sid').AsInteger;
        lRow.M.Name := lQuery.FieldByName('sname').AsString;
        lRow.Ct := lQuery.FieldByName('ct').AsString;
        lRow.Tvg := lQuery.FieldByName('tvg').AsString;
        lRows.Add(lRow);
        lQuery.Next;
      end;
      lQuery.Close;

      // per item: the SAME channel in the chosen target source — by tvg-id when the
      // channel has one (reliable), else by exact case-insensitive name; same content
      // type; skip placeholder rows with no URL.
      lQuery.SQL.Text :=
        '''
        SELECT id, name FROM streams s
        WHERE source_id = :src AND content_type = :ct AND upstream_url <> '' AND (
          (:tvg <> '' AND tvg_id = :tvg) OR
          (:tvg = '' AND name = :nm COLLATE NOCASE)) AND
        ''' + cSqlSourceActiveExists + ' ORDER BY id LIMIT 1';
      for i := 0 to lRows.Count - 1 do
      begin
        lMatch := lRows[i].M;
        lQuery.Close;
        lQuery.ParamByName('src').AsInteger := ATargetSourceId;
        lQuery.ParamByName('ct').AsWideString := lRows[i].Ct;
        lQuery.ParamByName('tvg').AsWideString := lRows[i].Tvg;
        lQuery.ParamByName('nm').AsWideString := lMatch.Name;
        lQuery.Open;
        if not lQuery.IsEmpty then
        begin
          lMatch.CandidateStreamId := lQuery.FieldByName('id').AsInteger;
          lMatch.CandidateName := lQuery.FieldByName('name').AsString;
          lMatch.AlreadyInList := lInList.ContainsKey(lMatch.CandidateStreamId);
        end;
        lRes.Add(lMatch);
      end;
    finally
      FreeAndNil(lQuery);
    end;
    Result := lRes.ToArray;
  finally
    FreeAndNil(lRows);
    FreeAndNil(lInList);
    FreeAndNil(lRes);
  end;
end;

function TSQLiteStore.GetState(const AKey: string): string;
var
  lQuery: TFDQuery;
begin
  Result := '';
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT value FROM app_state WHERE key = :k', [AKey]);
    if not lQuery.IsEmpty then
      Result := lQuery.Fields[0].AsString;
  finally
    FreeAndNil(lQuery);
  end;
end;

procedure TSQLiteStore.SetState(const AKey, AValue: string);
var
  lQuery: TFDQuery;
begin
  lQuery := NewQuery;
  try
    lQuery.SQL.Text := '''
      INSERT INTO app_state(key, value) VALUES(:k, :v)
      ON CONFLICT(key) DO UPDATE SET value = :v
      ''';
    lQuery.ParamByName('k').AsWideString := AKey;
    lQuery.ParamByName('v').AsWideString := AValue;
    lQuery.ExecSQL;
  finally
    FreeAndNil(lQuery);
  end;
end;

procedure TSQLiteStore.TouchLineup;
begin
  // any bouquet edit (add/remove/rename/regroup/number/tvg/group/restrip) bumps
  // this; the Plex-rescan reminder compares it to the last rescan stamp. A daily
  // catalog refresh does NOT call this (it would nag after every refresh).
  SetState(cStateLineupChanged, DateTimeToIsoUtc(NowUtc));
end;

// ── EPG ──────────────────────────────────────────────────────────────────

procedure TSQLiteStore.ReplaceEpg(ASourceId: Integer; const AProgrammes: TEpgProgrammeList);
var
  lProgramme: TEpgProgramme;
  lQuery: TFDQuery;
begin
  lQuery := NewQuery;
  try
    FConn.StartTransaction;
    try
      // a source deleted while its guide was downloading: don't write orphans
      // (extra-EPG slots have negative ids and are never treated as deleted)
      if SourceWasDeleted(ASourceId) then
      begin
        FConn.Commit;
        Exit;
      end;
      FConn.ExecSQL('DELETE FROM epg WHERE source_id=:s', [ASourceId]);
      // prepared once, reused per row (was re-parsing per programme = very slow)
      lQuery.SQL.Text :=
        '''
        INSERT INTO epg(source_id,channel_tvg_id,start_utc,stop_utc,title,description,category)
        VALUES(:s,:ch,:start,:stop,:title,:desc,:cat)
        ''';
      for lProgramme in AProgrammes do
      begin
        lQuery.ParamByName('s').AsInteger := ASourceId;
        lQuery.ParamByName('ch').AsWideString := lProgramme.ChannelTvgId;
        lQuery.ParamByName('start').AsWideString := DateTimeToIsoUtc(lProgramme.StartUtc);
        lQuery.ParamByName('stop').AsWideString := DateTimeToIsoUtc(lProgramme.StopUtc);
        lQuery.ParamByName('title').AsWideString := lProgramme.Title;
        lQuery.ParamByName('desc').AsWideString := lProgramme.Description;
        lQuery.ParamByName('cat').AsWideString := lProgramme.Category;
        lQuery.ExecSQL;
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

procedure TSQLiteStore.ReplaceExtraEpg(ASourceId: Integer;
  const AChannels: TArray<TEpgChannelInfo>; const AProgrammes: TEpgProgrammeList);
var
  lQuery: TFDQuery;
  lChannel: TEpgChannelInfo;
begin
  lQuery := NewQuery;
  try
    // one transaction (ReplaceEpg's own nests as a savepoint): a failure can't
    // leave new programmes with the old channel list (or the other way round)
    FConn.StartTransaction;
    try
      ReplaceEpg(ASourceId, AProgrammes);
      FConn.ExecSQL('DELETE FROM epg_channels WHERE source_id=:s', [ASourceId]);
      lQuery.SQL.Text := 'INSERT INTO epg_channels(source_id,channel_id,display_name) VALUES(:s,:id,:n)';
      for lChannel in AChannels do
      begin
        lQuery.ParamByName('s').AsInteger := ASourceId;
        lQuery.ParamByName('id').AsWideString := lChannel.Id;
        lQuery.ParamByName('n').AsWideString := lChannel.Name;
        lQuery.ExecSQL;
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lQuery);
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
  lQuery: TFDQuery;
  lNowS, lCand, lId, lIdA, lIdB: string;
  lKeys: TDictionary<string, TKeyHit>;
  lPreferOwn: TDictionary<Integer, Byte>;
  lOwnFuture: TDictionary<string, Byte>;
  lChannel: TOutputChannel;
  lHasOwn: Boolean;
  lWanted: TList<string>;
  lWantedSet: TDictionary<string, Byte>;
  lLo, lHi, j: Integer;

  function Placeholders(ACount: Integer): string;
  var
    i: Integer;
  begin
    Result := '';
    for i := 0 to ACount - 1 do
      Result := Result + IfThen(i > 0, ',', '') + ':p' + i.ToString;
  end;

  procedure AddKey(const AKey, AId: string; ASlot: Integer);
  var
    lKeyHit: TKeyHit;
  begin
    if AKey = '' then
      Exit;
    if lKeys.TryGetValue(AKey, lKeyHit) then
    begin
      if (lKeyHit.Slot = ASlot) and (lKeyHit.Id <> AId) then
      begin
        lKeyHit.Id := ''; // two channels of the same guide share the key: don't guess
        lKeys[AKey] := lKeyHit;
      end;
      Exit; // an earlier (better) guide already owns this key
    end;
    lKeyHit.Id := AId;
    lKeyHit.Slot := ASlot;
    lKeys.Add(AKey, lKeyHit);
  end;

  function Hit(const AKey: string): string;
  var
    lKeyHit: TKeyHit;
  begin
    if (AKey <> '') and lKeys.TryGetValue(AKey, lKeyHit) then
      Result := lKeyHit.Id
    else
      Result := '';
  end;

begin
  if AChannels.Count = 0 then
    Exit;
  lNowS := DateTimeToIsoUtc(NowUtc);
  lKeys := TDictionary<string, TKeyHit>.Create;
  lPreferOwn := TDictionary<Integer, Byte>.Create;
  lOwnFuture := TDictionary<string, Byte>.Create;
  lQuery := NewQuery;
  try
    lQuery.Open(
      '''
      SELECT c.source_id AS sid, c.channel_id AS cid, c.display_name AS dn FROM epg_channels c
      WHERE c.source_id < 0 AND EXISTS (SELECT 1 FROM epg e WHERE e.channel_tvg_id = :pfx || c.channel_id
        AND e.source_id = c.source_id AND e.stop_utc > :now)
      ORDER BY c.source_id DESC, c.channel_id
      ''', [EXTRA_EPG_PREFIX, lNowS]);
    while not lQuery.Eof do
    begin
      lId := EXTRA_EPG_PREFIX + lQuery.FieldByName('cid').AsWideString;
      AddKey(EpgIdKey(lQuery.FieldByName('cid').AsWideString), lId, lQuery.FieldByName('sid').AsInteger);
      AddKey(EpgNameKey(lQuery.FieldByName('dn').AsWideString), lId, lQuery.FieldByName('sid').AsInteger);
      lQuery.Next;
    end;
    lQuery.Close;
    if lKeys.Count = 0 then
      Exit; // no extra guide configured / nothing upcoming in it

    lQuery.Open('SELECT id FROM sources WHERE prefer_own_epg <> 0');
    while not lQuery.Eof do
    begin
      lPreferOwn.AddOrSetValue(lQuery.FieldByName('id').AsInteger, 0);
      lQuery.Next;
    end;
    lQuery.Close;
    if lPreferOwn.Count > 0 then
    begin
      // only the ids of THIS list's prefer-own channels (not every guide id of every
      // source: that was a full scan of the epg table per box request)
      lWanted := TList<string>.Create;
      lWantedSet := TDictionary<string, Byte>.Create;
      try
        for lChannel in AChannels do
          if (lChannel.ContentType = ctLive) and lPreferOwn.ContainsKey(lChannel.SourceId) then
            for lId in lChannel.EpgReadIds do
              if (lId <> '') and not lWantedSet.ContainsKey(lId) then
              begin
                lWantedSet.Add(lId, 0);
                lWanted.Add(lId);
              end;
        lLo := 0;
        while lLo < lWanted.Count do
        begin
          lHi := Min(lLo + cOwnEpgParamChunk, lWanted.Count) - 1;
          lQuery.SQL.Text := '''
            SELECT DISTINCT channel_tvg_id AS t FROM epg WHERE source_id > 0 AND stop_utc > :now
            AND channel_tvg_id IN (
            ''' + Placeholders(lHi - lLo + 1) + ')';
          lQuery.ParamByName('now').AsWideString := lNowS;
          for j := lLo to lHi do
            lQuery.ParamByName('p' + (j - lLo).ToString).AsWideString := lWanted[j];
          lQuery.Open;
          while not lQuery.Eof do
          begin
            lOwnFuture.AddOrSetValue(lQuery.FieldByName('t').AsWideString, 0);
            lQuery.Next;
          end;
          lQuery.Close;
          lLo := lHi + 1;
        end;
      finally
        FreeAndNil(lWantedSet);
        FreeAndNil(lWanted);
      end;
    end;

    for lChannel in AChannels do
    begin
      if lChannel.ContentType <> ctLive then
        Continue;
      // the name the operator sees decides first ...
      lCand := Hit(EpgNameKey(lChannel.Name));
      // ... else the tvg-id(s), but only when they agree on one guide channel
      if lCand = '' then
      begin
        lIdA := Hit(EpgIdKey(lChannel.TvgId));
        lIdB := Hit(EpgIdKey(lChannel.UpstreamTvgId));
        if (lIdA <> '') and ((lIdB = '') or (lIdB = lIdA)) then
          lCand := lIdA
        else if (lIdA = '') and (lIdB <> '') then
          lCand := lIdB;
      end;
      if lCand = '' then
        Continue;
      if lPreferOwn.ContainsKey(lChannel.SourceId) then
      begin
        lHasOwn := False;
        for lId in lChannel.EpgReadIds do
          if lOwnFuture.ContainsKey(lId) then
            lHasOwn := True;
        if lHasOwn then
          Continue; // this provider's own guide goes first and it has data
      end;
      lChannel.ExtraGuideId := lCand;
    end;
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lOwnFuture);
    FreeAndNil(lPreferOwn);
    FreeAndNil(lKeys);
  end;
end;

function TSQLiteStore.LoadListTvgIds: TArray<string>;
var
  lQuery: TFDQuery;
  lList: TList<string>;
begin
  lList := TList<string>.Create;
  lQuery := NewQuery;
  try
    // Keep EPG for BOTH the upstream id AND the effective (override) id of every
    // chosen channel. The provider's XMLTV may publish under either: a pure
    // "relabel" override has its programmes under the upstream id, while a "match
    // an existing guide" override points at an id that already has its own EPG.
    // Serving (BuildXmltv / list EPG) re-keys whatever is found to the effective id.
    lQuery.Open('''
      SELECT DISTINCT tvg FROM (
        SELECT s.tvg_id AS tvg FROM list_items i
          JOIN streams s ON s.id = i.stream_item_id WHERE s.tvg_id <> ''
        UNION
        SELECT COALESCE(NULLIF(i.tvg_id_override,''), s.tvg_id) AS tvg FROM list_items i
          JOIN streams s ON s.id = i.stream_item_id
          WHERE COALESCE(NULLIF(i.tvg_id_override,''), s.tvg_id) <> '')
      ''');
    while not lQuery.Eof do
    begin
      lList.Add(lQuery.Fields[0].AsString);
      lQuery.Next;
    end;
    Result := lList.ToArray;
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lList);
  end;
end;

function TSQLiteStore.ReadProgramme(AQuery: TFDQuery): TEpgProgramme;
begin
  Result := TEpgProgramme.Create;
  Result.Id := AQuery.FieldByName('id').AsInteger;
  Result.SourceId := AQuery.FieldByName('source_id').AsInteger;
  Result.ChannelTvgId := AQuery.FieldByName('channel_tvg_id').AsString;
  Result.StartUtc := IsoUtcToDateTime(AQuery.FieldByName('start_utc').AsString);
  Result.StopUtc := IsoUtcToDateTime(AQuery.FieldByName('stop_utc').AsString);
  Result.Title := AQuery.FieldByName('title').AsString;
  Result.Description := AQuery.FieldByName('description').AsString;
  Result.Category := AQuery.FieldByName('category').AsString;
end;

function TSQLiteStore.LoadEpgForTvgIds(const ATvgIds: TArray<string>;
  AMaxDays: Integer): TEpgProgrammeList;
var
  lQuery: TFDQuery;
  lPlaceholders, lCutoff: string;
  lLo, lHi, i: Integer;
begin
  Result := TEpgProgrammeList.Create(True);
  if Length(ATvgIds) = 0 then
    Exit;
  if AMaxDays > 0 then
    lCutoff := DateTimeToIsoUtc(IncDay(NowUtc, AMaxDays));
  lLo := 0;
  while lLo <= High(ATvgIds) do
  begin
    lHi := lLo + cEpgTvgIdParamChunk - 1;
    if lHi > High(ATvgIds) then
      lHi := High(ATvgIds);
    lQuery := NewQuery;
    try
      lPlaceholders := '';
      for i := lLo to lHi do
        lPlaceholders := lPlaceholders + IfThen(i > lLo, ',', '') + ':p' + i.ToString;
      lQuery.SQL.Text := 'SELECT * FROM epg WHERE channel_tvg_id IN (' + lPlaceholders + ')';
      // optional cap: drop programmes that start beyond now + AMaxDays (0 = no cap)
      if AMaxDays > 0 then
        lQuery.SQL.Text := lQuery.SQL.Text + ' AND start_utc < :cutoff';
      lQuery.SQL.Text := lQuery.SQL.Text + ' ORDER BY channel_tvg_id, start_utc';
      for i := lLo to lHi do
        lQuery.ParamByName('p' + i.ToString).AsWideString := ATvgIds[i];
      if AMaxDays > 0 then
        lQuery.ParamByName('cutoff').AsWideString := lCutoff;
      lQuery.Open;
      while not lQuery.Eof do
      begin
        Result.Add(ReadProgramme(lQuery));
        lQuery.Next;
      end;
    finally
      FreeAndNil(lQuery);
    end;
    lLo := lHi + 1;
  end;
  // several providers deliver the same channel's guide: serve one, not all
  KeepOneSourcePerChannel(Result, NowUtc);
end;

// ── Lists ──────────────────────────────────────────────────────────────────

function TSQLiteStore.ReadList(AQuery: TFDQuery): TCustomList;
begin
  Result := TCustomList.Create;
  Result.Id := AQuery.FieldByName('id').AsInteger;
  Result.Name := AQuery.FieldByName('name').AsString;
  Result.OutputUsername := AQuery.FieldByName('output_username').AsString;
  Result.OutputPassword := AQuery.FieldByName('output_password').AsString;
  Result.Enabled := AQuery.FieldByName('enabled').AsInteger <> 0;
  Result.MirrorOfListId := AQuery.FieldByName('mirror_of_list_id').AsInteger;
end;

function TSQLiteStore.LoadLists: TObjectList<TCustomList>;
var
  lQuery: TFDQuery;
begin
  Result := TObjectList<TCustomList>.Create(True);
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT * FROM lists ORDER BY name COLLATE NOCASE');
    while not lQuery.Eof do
    begin
      Result.Add(ReadList(lQuery));
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.ListMasterId(AListId: Integer): Integer;
var
  lQuery: TFDQuery;
begin
  Result := cNoMirror;
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT mirror_of_list_id FROM lists WHERE id=:id', [AListId]);
    if not lQuery.IsEmpty then
      Result := lQuery.Fields[0].AsInteger;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.MirrorNamesOf(AListId: Integer): TArray<string>;
var
  lQuery: TFDQuery;
begin
  Result := nil;
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT name FROM lists WHERE mirror_of_list_id=:id ORDER BY name COLLATE NOCASE', [AListId]);
    while not lQuery.Eof do
    begin
      Result := Result + [lQuery.Fields[0].AsString];
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

procedure TSQLiteStore.ValidateMirror(const AList: TCustomList);
var
  lQuery: TFDQuery;
  lMirrors: TArray<string>;
begin
  if AList.MirrorOfListId = cNoMirror then
    Exit;
  if AList.MirrorOfListId < cNoMirror then
    raise EStoreValidation.CreateFmt(cMsgMirrorUnknown, [AList.MirrorOfListId]);
  if AList.MirrorOfListId = AList.Id then
    raise EStoreValidation.Create(cMsgMirrorSelf);
  lQuery := NewQuery;
  try
    lQuery.Open('SELECT name, mirror_of_list_id FROM lists WHERE id=:id', [AList.MirrorOfListId]);
    if lQuery.IsEmpty then
      raise EStoreValidation.CreateFmt(cMsgMirrorUnknown, [AList.MirrorOfListId]);
    if lQuery.Fields[1].AsInteger <> cNoMirror then
      raise EStoreValidation.CreateFmt(cMsgMirrorOfMirror, [lQuery.Fields[0].AsString]);
    lQuery.Close;
    if AList.Id = 0 then
      Exit; // a new list has no mirrors, groups or items yet
    lMirrors := MirrorNamesOf(AList.Id);
    if Length(lMirrors) > 0 then
      raise EStoreValidation.CreateFmt(cMsgMirroredCantMirror, [string.Join(cMirrorNameSep, lMirrors)]);
    lQuery.Open(
      '''
      SELECT (SELECT COUNT(*) FROM list_groups WHERE list_id=:g)
           + (SELECT COUNT(*) FROM list_items WHERE list_id=:i)
      ''', [AList.Id, AList.Id]);
    if lQuery.Fields[0].AsInteger > 0 then
      raise EStoreValidation.Create(cMsgMirrorNotEmpty);
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.SaveList(const AList: TCustomList): Integer;
var
  lQuery: TFDQuery;
begin
  ValidateMirror(AList);
  lQuery := NewQuery;
  try
    FConn.StartTransaction;
    try
      if AList.Id = 0 then
        lQuery.SQL.Text := '''
          INSERT INTO lists(name,output_username,output_password,enabled,mirror_of_list_id)
          VALUES(:name,:u,:p,:enabled,:m)
          '''
      else
      begin
        lQuery.SQL.Text := '''
          UPDATE lists SET name=:name,output_username=:u,output_password=:p,enabled=:enabled,
            mirror_of_list_id=:m
          WHERE id=:id
          ''';
        lQuery.ParamByName('id').AsInteger := AList.Id;
      end;
      lQuery.ParamByName('name').AsWideString := AList.Name;
      lQuery.ParamByName('u').AsWideString := AList.OutputUsername;
      lQuery.ParamByName('p').AsWideString := AList.OutputPassword;
      lQuery.ParamByName('enabled').AsInteger := Ord(AList.Enabled);
      lQuery.ParamByName('m').AsInteger := AList.MirrorOfListId;
      lQuery.ExecSQL;
      if AList.Id = 0 then
        Result := FConn.GetLastAutoGenValue('')
      else
        Result := AList.Id;
      // only a mirror has its own provider credentials
      if AList.MirrorOfListId = cNoMirror then
        FConn.ExecSQL('DELETE FROM list_source_credentials WHERE list_id=:id', [Result]);
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
    AList.Id := Result;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.LoadMirrorCredentials(AListId: Integer): TArray<TMirrorCredential>;
var
  lQuery: TFDQuery;
  lCredential: TMirrorCredential;
begin
  Result := nil;
  lQuery := NewQuery;
  try
    lQuery.Open(
      '''
      SELECT source_id, url, username, password FROM list_source_credentials
      WHERE list_id=:l ORDER BY source_id
      ''', [AListId]);
    while not lQuery.Eof do
    begin
      lCredential.SourceId := lQuery.FieldByName('source_id').AsInteger;
      lCredential.Url := lQuery.FieldByName('url').AsString;
      lCredential.Username := lQuery.FieldByName('username').AsString;
      lCredential.Password := lQuery.FieldByName('password').AsString;
      Result := Result + [lCredential];
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

procedure TSQLiteStore.SaveMirrorCredentials(AListId: Integer; const ACredentials: TArray<TMirrorCredential>);
var
  lQuery: TFDQuery;
  lCredential: TMirrorCredential;
begin
  if ListMasterId(AListId) = cNoMirror then
    raise EStoreValidation.Create(cMsgNotAMirror);
  lQuery := NewQuery;
  try
    FConn.StartTransaction;
    try
      FConn.ExecSQL('DELETE FROM list_source_credentials WHERE list_id=:l', [AListId]);
      // a row for a source that doesn't exist (any more) is not stored
      lQuery.SQL.Text :=
        '''
        INSERT OR REPLACE INTO list_source_credentials(list_id, source_id, url, username, password)
        SELECT :l, :s, :url, :u, :p WHERE EXISTS (SELECT 1 FROM sources WHERE id=:s)
        ''';
      for lCredential in ACredentials do
      begin
        if (lCredential.SourceId < cMinProviderSourceId) or ((lCredential.Url.Trim = '') and
          (lCredential.Username.Trim = '') and (lCredential.Password.Trim = '')) then
          Continue;
        lQuery.ParamByName('l').AsInteger := AListId;
        lQuery.ParamByName('s').AsInteger := lCredential.SourceId;
        lQuery.ParamByName('url').AsWideString := lCredential.Url.Trim;
        lQuery.ParamByName('u').AsWideString := lCredential.Username.Trim;
        lQuery.ParamByName('p').AsWideString := lCredential.Password.Trim;
        lQuery.ExecSQL;
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.LoadPlaybackAccounts(AListId: Integer): TDictionary<Integer, TPlaybackAccount>;
var
  lQuery: TFDQuery;
  lAccount: TPlaybackAccount;
begin
  Result := TDictionary<Integer, TPlaybackAccount>.Create;
  lQuery := NewQuery;
  try
    lQuery.Open(
      '''
      SELECT c.source_id, c.url, c.username, c.password,
        src.url AS surl, src.username AS su, src.password AS sp
      FROM list_source_credentials c
      JOIN sources src ON src.id = c.source_id
      WHERE c.list_id = :l
      ''', [AListId]);
    while not lQuery.Eof do
    begin
      lAccount.SourceUrl := lQuery.FieldByName('surl').AsString;
      lAccount.SourceUser := lQuery.FieldByName('su').AsString;
      lAccount.SourcePass := lQuery.FieldByName('sp').AsString;
      lAccount.Credential.SourceId := lQuery.FieldByName('source_id').AsInteger;
      lAccount.Credential.Url := lQuery.FieldByName('url').AsString;
      lAccount.Credential.Username := lQuery.FieldByName('username').AsString;
      lAccount.Credential.Password := lQuery.FieldByName('password').AsString;
      Result.AddOrSetValue(lAccount.Credential.SourceId, lAccount);
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.PlaybackUrl(const AAccounts: TDictionary<Integer, TPlaybackAccount>;
  ASourceId: Integer; const AUrl: string): string;
var
  lAccount: TPlaybackAccount;
begin
  if not AAccounts.TryGetValue(ASourceId, lAccount) then
    Exit(AUrl);
  Result := RewriteProviderUrl(AUrl, lAccount.SourceUrl, lAccount.SourceUser, lAccount.SourcePass,
    lAccount.Credential.Url, lAccount.Credential.Username, lAccount.Credential.Password);
end;

procedure TSQLiteStore.RunInTransaction(const AProc: TProc<IStore>);
begin
  // the writes inside start their own transactions too: those nest as savepoints
  FConn.StartTransaction;
  try
    AProc(Self);
    FConn.Commit;
  except
    SafeRollback;
    raise;
  end;
end;

procedure TSQLiteStore.DeleteList(AId: Integer);
var
  lMirrors: TArray<string>;
begin
  lMirrors := MirrorNamesOf(AId);
  if Length(lMirrors) > 0 then
    raise EStoreValidation.CreateFmt(cMsgMasterHasMirrors, [string.Join(cMirrorNameSep, lMirrors)]);
  FConn.StartTransaction;
  try
    FConn.ExecSQL('DELETE FROM list_items WHERE list_id=:id', [AId]);
    FConn.ExecSQL('DELETE FROM list_groups WHERE list_id=:id', [AId]);
    FConn.ExecSQL('DELETE FROM list_source_credentials WHERE list_id=:id', [AId]);
    FConn.ExecSQL('DELETE FROM lists WHERE id=:id', [AId]);
    FConn.Commit;
  except
    SafeRollback;
    raise;
  end;
  TouchLineup; // Plex may serve this bouquet
end;

function TSQLiteStore.FindListByCredentials(const AUser, APass: string): TCustomList;
var
  lQuery: TFDQuery;
begin
  Result := nil;
  lQuery := NewQuery;
  try
    if AUser = '' then
      // optional credentials: an empty login only reaches a bouquet that itself
      // has NO login - never one that is protected by a username/password
      lQuery.Open('''
        SELECT * FROM lists WHERE enabled=1 AND COALESCE(output_username,'')=''
        ORDER BY id LIMIT 1
        ''')
    else
      // typed as wide strings: an untyped open array binds ANSI on Win32, so a
      // password with e.g. Cyrillic letters never matched
      lQuery.Open('SELECT * FROM lists WHERE enabled=1 AND output_username=:u AND output_password=:p LIMIT 1',
        [AUser, APass], [ftWideString, ftWideString]);
    if not lQuery.IsEmpty then
      Result := ReadList(lQuery);
  finally
    FreeAndNil(lQuery);
  end;
end;

// ── Groups ───────────────────────────────────────────────────────────────

function TSQLiteStore.ReadGroup(AQuery: TFDQuery): TCustomGroup;
begin
  Result := TCustomGroup.Create;
  Result.Id := AQuery.FieldByName('id').AsInteger;
  Result.ListId := AQuery.FieldByName('list_id').AsInteger;
  Result.Name := AQuery.FieldByName('name').AsString;
  Result.ContentType := ContentTypeFromString(AQuery.FieldByName('content_type').AsString);
  Result.IsFavorite := AQuery.FieldByName('is_favorite').AsInteger <> 0;
  Result.SortOrder := AQuery.FieldByName('sort_order').AsInteger;
end;

function TSQLiteStore.LoadGroups(AListId: Integer): TCustomGroupList;
var
  lQuery: TFDQuery;
begin
  Result := TCustomGroupList.Create(True);
  lQuery := NewQuery;
  try
    // favorites first, then the manual drag order (sort_order>0), then A->Z for any
    // groups not manually positioned yet
    lQuery.Open('''
      SELECT * FROM list_groups WHERE list_id=:l
      ORDER BY is_favorite DESC, CASE WHEN sort_order>0 THEN 0 ELSE 1 END, sort_order, name COLLATE NOCASE
      ''',
      [AListId]);
    while not lQuery.Eof do
    begin
      Result.Add(ReadGroup(lQuery));
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.SaveGroup(const AGroup: TCustomGroup): Integer;
var
  lQuery: TFDQuery;
begin
  lQuery := NewQuery;
  try
    if AGroup.Id = 0 then
    begin
      lQuery.SQL.Text := '''
        INSERT INTO list_groups(list_id,name,content_type,is_favorite)
        VALUES(:l,:name,:c,:fav)
        ''';
      lQuery.ParamByName('l').AsInteger := AGroup.ListId; // only the INSERT has :l
    end
    else
    begin
      lQuery.SQL.Text := 'UPDATE list_groups SET name=:name,content_type=:c,is_favorite=:fav WHERE id=:id';
      lQuery.ParamByName('id').AsInteger := AGroup.Id;
    end;
    lQuery.ParamByName('name').AsWideString := AGroup.Name;
    lQuery.ParamByName('c').AsWideString := ContentTypeNames[AGroup.ContentType];
    lQuery.ParamByName('fav').AsInteger := Ord(AGroup.IsFavorite);
    lQuery.ExecSQL;
    if AGroup.Id = 0 then
      Result := FConn.GetLastAutoGenValue('')
    else
      Result := AGroup.Id;
    AGroup.Id := Result;
  finally
    FreeAndNil(lQuery);
  end;
  TouchLineup;
end;

function TSQLiteStore.ReorderGroups(AListId: Integer; const AGroupIds: TArray<Integer>): Integer;
var
  lUpdate: TFDQuery;
  i: Integer;
begin
  // assign sort_order = 1,2,3… following the caller's group-id order (drag result);
  // ids not in this list are skipped. Favorites still sort first (LoadOutputChannels).
  Result := 0;
  lUpdate := NewQuery;
  try
    lUpdate.SQL.Text := 'UPDATE list_groups SET sort_order=:n WHERE id=:id AND list_id=:l';
    FConn.StartTransaction;
    try
      for i := 0 to High(AGroupIds) do
      begin
        lUpdate.ParamByName('n').AsInteger := i + 1;
        lUpdate.ParamByName('id').AsInteger := AGroupIds[i];
        lUpdate.ParamByName('l').AsInteger := AListId;
        lUpdate.ExecSQL;
        Inc(Result, lUpdate.RowsAffected);
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lUpdate);
  end;
  TouchLineup;
end;

procedure TSQLiteStore.DeleteGroup(AId: Integer);
begin
  // detach items from the group, then remove it
  FConn.StartTransaction;
  try
    FConn.ExecSQL('UPDATE list_items SET custom_group_id=0 WHERE custom_group_id=:id', [AId]);
    FConn.ExecSQL('DELETE FROM list_groups WHERE id=:id', [AId]);
    FConn.Commit;
  except
    SafeRollback;
    raise;
  end;
  TouchLineup;
end;

// ── Items ────────────────────────────────────────────────────────────────

function TSQLiteStore.ReadItem(AQuery: TFDQuery): TCustomItem;

  function Opt(const AName: string): string; // joined columns may be absent
  var
    lField: TField;
  begin
    lField := AQuery.FindField(AName);
    if lField <> nil then
      Result := lField.AsString
    else
      Result := '';
  end;

begin
  Result := TCustomItem.Create;
  Result.Id := AQuery.FieldByName('id').AsInteger;
  Result.ListId := AQuery.FieldByName('list_id').AsInteger;
  Result.StreamItemId := AQuery.FieldByName('stream_item_id').AsInteger;
  Result.CustomGroupId := AQuery.FieldByName('custom_group_id').AsInteger;
  Result.ContentType := ContentTypeFromString(AQuery.FieldByName('content_type').AsString);
  Result.DisplayName := AQuery.FieldByName('display_name').AsString;
  Result.LogoOverride := AQuery.FieldByName('logo_override').AsString;
  Result.TvgIdOverride := Opt('tvg_id_override');
  Result.ChannelNumber := AQuery.FieldByName('channel_number').AsInteger;
  Result.StreamName := Opt('stream_name');
  Result.StreamLogo := Opt('stream_logo');
  Result.StreamTvgId := Opt('stream_tvg');
  Result.StreamSourceId := StrToIntDef(Opt('stream_source'), 0);
  Result.StreamArchiveDays := StrToIntDef(Opt('stream_archive'), 0);
end;

function TSQLiteStore.LoadItems(AListId: Integer): TCustomItemList;
var
  lQuery: TFDQuery;
begin
  Result := TCustomItemList.Create(True);
  lQuery := NewQuery;
  try
    // join the upstream stream so the UI can show the real channel name/logo
    // even when no override is set (LEFT JOIN: keep the item if the stream is gone)
    lQuery.Open(
      '''
      SELECT i.*, s.name AS stream_name, s.logo AS stream_logo, s.tvg_id AS stream_tvg, s.source_id AS stream_source, s.archive_days AS stream_archive
      FROM list_items i LEFT JOIN streams s ON s.id = i.stream_item_id
      WHERE i.list_id=:l ORDER BY i.channel_number, stream_name COLLATE NOCASE
      ''',
      [AListId]);
    while not lQuery.Eof do
    begin
      Result.Add(ReadItem(lQuery));
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
end;

function TSQLiteStore.LoadOutputChannels(AListId: Integer): TOutputChannelList;
var
  lMasterId: Integer;
  lAccounts: TDictionary<Integer, TPlaybackAccount>;
  lChannel: TOutputChannel;
begin
  lMasterId := ListMasterId(AListId);
  if lMasterId = cNoMirror then
    Exit(LoadListChannels(AListId));
  // a mirror: exactly the master's channels, played with the mirror's own account
  Result := LoadListChannels(lMasterId);
  lAccounts := LoadPlaybackAccounts(AListId);
  try
    for lChannel in Result do
      lChannel.UpstreamUrl := PlaybackUrl(lAccounts, lChannel.SourceId, lChannel.UpstreamUrl);
  finally
    FreeAndNil(lAccounts);
  end;
end;

function TSQLiteStore.LoadListChannels(AListId: Integer): TOutputChannelList;
var
  lQuery: TFDQuery;
  lChannel: TOutputChannel;
begin
  Result := TOutputChannelList.Create(True);
  lQuery := NewQuery;
  try
    // Join item -> stream (upstream data) -> group (override). COALESCE applies
    // the rename/regroup/logo overrides; empty overrides fall back to upstream.
    // A disabled source / content type is never offered to a box (cSqlSourceActive).
    // Order: favorites first, then the manual group drag-order (sort_order>0), then
    // any un-positioned groups A→Z; WITHIN a group honour the operator's channel
    // numbers (drag/sort-by-Nr) — numbered first in number order, then unnumbered A→Z.
    lQuery.SQL.Text :=
      '''
      SELECT i.stream_item_id AS sid, s.source_id AS srcid, i.channel_number AS num, i.content_type AS ctype,
        COALESCE(NULLIF(i.display_name,''), s.name) AS cname,
        COALESCE(NULLIF(i.logo_override,''), s.logo) AS clogo,
        COALESCE(NULLIF(i.tvg_id_override,''), s.tvg_id) AS tvg, s.tvg_id AS utvg, s.upstream_url AS url,
        s.upstream_id AS uid, s.archive_days AS arch,
        COALESCE(NULLIF(g.name,''), s.group_title) AS gname,
        COALESCE(g.is_favorite, 0) AS fav, COALESCE(g.sort_order, 0) AS gsort
      FROM list_items i
      JOIN streams s ON s.id = i.stream_item_id
      LEFT JOIN list_groups g ON g.id = i.custom_group_id
      LEFT JOIN sources src ON src.id = s.source_id
      WHERE i.list_id = :l AND
      ''' + cSqlSourceActive +
      '''

      ORDER BY fav DESC, CASE WHEN gsort > 0 THEN 0 ELSE 1 END, gsort, gname COLLATE NOCASE,
        CASE WHEN num > 0 THEN 0 ELSE 1 END, num, cname COLLATE NOCASE
      ''';
    lQuery.Open(lQuery.SQL.Text, [AListId]);
    while not lQuery.Eof do
    begin
      lChannel := TOutputChannel.Create;
      lChannel.StreamItemId := lQuery.FieldByName('sid').AsInteger;
      lChannel.SourceId := lQuery.FieldByName('srcid').AsInteger;
      lChannel.Number := lQuery.FieldByName('num').AsInteger;
      lChannel.ContentType := ContentTypeFromString(lQuery.FieldByName('ctype').AsString);
      lChannel.Name := lQuery.FieldByName('cname').AsString;
      lChannel.Logo := lQuery.FieldByName('clogo').AsString;
      lChannel.TvgId := lQuery.FieldByName('tvg').AsString;
      lChannel.UpstreamTvgId := lQuery.FieldByName('utvg').AsString;
      lChannel.UpstreamUrl := lQuery.FieldByName('url').AsString;
      lChannel.UpstreamId := lQuery.FieldByName('uid').AsString;
      lChannel.ArchiveDays := lQuery.FieldByName('arch').AsInteger;
      lChannel.GroupName := lQuery.FieldByName('gname').AsString;
      lChannel.IsFavoriteGroup := lQuery.FieldByName('fav').AsInteger <> 0;
      Result.Add(lChannel);
      lQuery.Next;
    end;
  finally
    FreeAndNil(lQuery);
  end;
  ApplyExtraGuides(Result);
end;

function TSQLiteStore.SaveItem(const AItem: TCustomItem): Integer;
var
  lQuery: TFDQuery;
begin
  lQuery := NewQuery;
  try
    if AItem.Id = 0 then
    begin
      lQuery.SQL.Text :=
        '''
        INSERT INTO list_items(list_id,stream_item_id,custom_group_id,content_type,display_name,logo_override,channel_number,tvg_id_override)
        VALUES(:l,:sid,:grp,:c,:dn,:logo,:num,:tvg)
        ''';
      // :l and :sid exist only on the INSERT
      lQuery.ParamByName('l').AsInteger := AItem.ListId;
      lQuery.ParamByName('sid').AsInteger := AItem.StreamItemId;
    end
    else
    begin
      lQuery.SQL.Text :=
        '''
        UPDATE list_items SET custom_group_id=:grp,content_type=:c,display_name=:dn,logo_override=:logo,channel_number=:num,tvg_id_override=:tvg WHERE id=:id
        ''';
      lQuery.ParamByName('id').AsInteger := AItem.Id;
    end;
    lQuery.ParamByName('grp').AsInteger := AItem.CustomGroupId;
    lQuery.ParamByName('c').AsWideString := ContentTypeNames[AItem.ContentType];
    lQuery.ParamByName('dn').AsWideString := AItem.DisplayName;
    lQuery.ParamByName('logo').AsWideString := AItem.LogoOverride;
    lQuery.ParamByName('num').AsInteger := AItem.ChannelNumber;
    lQuery.ParamByName('tvg').AsWideString := AItem.TvgIdOverride;
    lQuery.ExecSQL;
    if AItem.Id = 0 then
      Result := FConn.GetLastAutoGenValue('')
    else
      Result := AItem.Id;
    AItem.Id := Result;
  finally
    FreeAndNil(lQuery);
  end;
  TouchLineup;
end;

function TSQLiteStore.AddItems(AListId, ACustomGroupId: Integer;
  const AStreamItemIds: TArray<Integer>): Integer;
var
  lSid: Integer;
  lSelect, lInsert: TFDQuery;
  lName, lStripped, lCt: string;
begin
  Result := 0;
  if Length(AStreamItemIds) = 0 then
    Exit;
  // Read each stream + its source's strip-prefix tokens, strip the leading
  // provider prefix from the name (e.g. "NL| NPO 1" -> "NPO 1") and store the
  // cleaned label as display_name. We only set display_name when the strip
  // actually changed the name, so untouched names keep following the upstream
  // name (display_name empty => upstream). Bound via AsWideString to keep UTF-8.
  lSelect := NewQuery;
  lInsert := NewQuery;
  try
    // LEFT JOIN: a stream is still added when its source row is absent (sp NULL
    // -> no prefixes -> name kept). Stripping kicks in only when the source has
    // strip_prefixes configured.
    lSelect.SQL.Text :=
      '''
      SELECT s.name AS nm, s.content_type AS ct, src.strip_prefixes AS sp, src.strip_suffixes AS ss
      FROM streams s LEFT JOIN sources src ON src.id = s.source_id WHERE s.id = :sid
      ''';
    lInsert.SQL.Text :=
      '''
      INSERT OR IGNORE INTO list_items(list_id,stream_item_id,custom_group_id,content_type,display_name)
      VALUES(:l,:sid,:grp,:ct,:dn)
      ''';
    FConn.StartTransaction;
    try
      for lSid in AStreamItemIds do
      begin
        lSelect.Close;
        lSelect.ParamByName('sid').AsInteger := lSid;
        lSelect.Open;
        if lSelect.IsEmpty then
          Continue;
        lName := lSelect.FieldByName('nm').AsString;
        lCt := lSelect.FieldByName('ct').AsString;
        // strip_prefixes is ';'-delimited (a token may contain spaces/commas/pipes,
        // e.g. "┃F1 TV┃") — split with ';', NOT the default ',' (that would treat the
        // whole "a;b;c" string as one token and match nothing for multi-prefix sources).
        lStripped := CleanChannelName(lName, CsvToStrArray(lSelect.FieldByName('sp').AsString, cStripTokenSep),
          CsvToStrArray(lSelect.FieldByName('ss').AsString, cStripTokenSep));

        lInsert.ParamByName('l').AsInteger := AListId;
        lInsert.ParamByName('sid').AsInteger := lSid;
        lInsert.ParamByName('grp').AsInteger := ACustomGroupId;
        lInsert.ParamByName('ct').AsWideString := lCt;
        if (lStripped <> '') and (lStripped <> lName) then
          lInsert.ParamByName('dn').AsWideString := lStripped
        else
          lInsert.ParamByName('dn').AsWideString := '';
        lInsert.ExecSQL;
        Inc(Result, lInsert.RowsAffected);
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lSelect);
    FreeAndNil(lInsert);
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
  lSelect, lUpdate: TFDQuery;
  lName, lDn, lNewDn: string;
  lIds: TList<Integer>;
  lNewDns: TList<string>;
  i: Integer;
begin
  Result := 0;
  lIds := TList<Integer>.Create;
  lNewDns := TList<string>.Create;
  lSelect := NewQuery;
  try
    // collect the items that are still auto-managed (display_name == the value the
    // OLD prefix rule produced) and whose value changes under the NEW rule
    lSelect.SQL.Text :=
      '''
      SELECT i.id AS iid, s.name AS nm, i.display_name AS dn
      FROM list_items i JOIN streams s ON s.id = i.stream_item_id
      WHERE s.source_id = :sid
      ''';
    lSelect.ParamByName('sid').AsInteger := ASourceId;
    lSelect.Open;
    while not lSelect.Eof do
    begin
      lName := lSelect.FieldByName('nm').AsString;
      lDn := lSelect.FieldByName('dn').AsString;
      if lDn = AutoDisplayName(lName, AOldPrefixes, AOldSuffixes) then // not a manual rename
      begin
        lNewDn := AutoDisplayName(lName, ANewPrefixes, ANewSuffixes);
        if lNewDn <> lDn then
        begin
          lIds.Add(lSelect.FieldByName('iid').AsInteger);
          lNewDns.Add(lNewDn);
        end;
      end;
      lSelect.Next;
    end;
  finally
    FreeAndNil(lSelect);
  end;

  try
    if lIds.Count = 0 then
      Exit;

    lUpdate := NewQuery;
    try
      lUpdate.SQL.Text := 'UPDATE list_items SET display_name = :dn WHERE id = :id';
      FConn.StartTransaction;
      try
        for i := 0 to lIds.Count - 1 do
        begin
          lUpdate.ParamByName('dn').AsWideString := lNewDns[i];
          lUpdate.ParamByName('id').AsInteger := lIds[i];
          lUpdate.ExecSQL;
          Inc(Result, lUpdate.RowsAffected);
        end;
        FConn.Commit;
      except
        SafeRollback;
        raise;
      end;
    finally
      FreeAndNil(lUpdate);
    end;
  finally
    FreeAndNil(lIds);
    FreeAndNil(lNewDns);
  end;
  TouchLineup;
end;

function TSQLiteStore.RestripAllItems: Integer;
var
  lSelect, lUpdate: TFDQuery;
  lName, lDn, lStripped: string;
  lPrefixes, lSuffixes: TArray<string>;
  lIds: TList<Integer>;
  lNewDns: TList<string>;
  i: Integer;
begin
  // Apply each source's CURRENT strip-prefixes to ALL of its channels on every
  // list: where the name has a strippable prefix and the operator hasn't manually
  // renamed the channel (display_name empty or still the upstream name), set
  // display_name to the stripped form. Manual renames are left untouched.
  Result := 0;
  lIds := TList<Integer>.Create;
  lNewDns := TList<string>.Create;
  lSelect := NewQuery;
  try
    lSelect.SQL.Text :=
      '''
      SELECT i.id AS iid, s.name AS nm, i.display_name AS dn, src.strip_prefixes AS sp,
        src.strip_suffixes AS ss
      FROM list_items i JOIN streams s ON s.id = i.stream_item_id
      JOIN sources src ON src.id = s.source_id
      ''';
    lSelect.Open;
    while not lSelect.Eof do
    begin
      lName := lSelect.FieldByName('nm').AsString;
      lDn := lSelect.FieldByName('dn').AsString;
      // ';'-delimited (see AddItems): a token may itself contain ',' or pipes.
      lPrefixes := CsvToStrArray(lSelect.FieldByName('sp').AsString, cStripTokenSep);
      lSuffixes := CsvToStrArray(lSelect.FieldByName('ss').AsString, cStripTokenSep);
      if (Length(lPrefixes) > 0) or (Length(lSuffixes) > 0) then
      begin
        lStripped := CleanChannelName(lName, lPrefixes, lSuffixes);
        // only when stripping actually changes the name AND it isn't a manual rename
        // (a name still at its prefix-only auto value counts as auto, so adding
        // suffix tokens later also re-cleans channels added before)
        if (lStripped <> lName) and (lStripped <> lDn) and
           ((lDn = '') or (lDn = lName) or (lDn = StripNamePrefixes(lName, lPrefixes))) then
        begin
          lIds.Add(lSelect.FieldByName('iid').AsInteger);
          lNewDns.Add(lStripped);
        end;
      end;
      lSelect.Next;
    end;
  finally
    FreeAndNil(lSelect);
  end;

  try
    if lIds.Count = 0 then
      Exit;
    lUpdate := NewQuery;
    try
      lUpdate.SQL.Text := 'UPDATE list_items SET display_name = :dn WHERE id = :id';
      FConn.StartTransaction;
      try
        for i := 0 to lIds.Count - 1 do
        begin
          lUpdate.ParamByName('dn').AsWideString := lNewDns[i];
          lUpdate.ParamByName('id').AsInteger := lIds[i];
          lUpdate.ExecSQL;
          Inc(Result, lUpdate.RowsAffected);
        end;
        FConn.Commit;
      except
        SafeRollback;
        raise;
      end;
    finally
      FreeAndNil(lUpdate);
    end;
  finally
    FreeAndNil(lIds);
    FreeAndNil(lNewDns);
  end;
  TouchLineup;
end;

function TSQLiteStore.ReplaceItemStreams(AListId: Integer;
  const AReplacements: TArray<TItemStreamReplace>): Integer;
var
  lSelect, lUpdate: TFDQuery;
  lR: TItemStreamReplace;
  lOldName, lOldCt, lDn, lNewName, lNewCt, lNewDn: string;
  lOldSp, lOldSs, lNewSp, lNewSs: TArray<string>;
begin
  // Swap the stream behind existing list items IN PLACE (same row, group, channel
  // number, logo / tvg-id overrides). An auto-managed display_name (still what the
  // strip rules produced for the OLD name) follows the new name; a manual rename
  // is kept. Skipped: item not on this list, unknown stream, other content type,
  // or the new stream already on the list (UNIQUE(list_id, stream_item_id)).
  Result := 0;
  if Length(AReplacements) = 0 then
    Exit;
  lSelect := NewQuery;
  lUpdate := NewQuery;
  try
    lUpdate.SQL.Text :=
      '''
      UPDATE list_items SET stream_item_id = :sid, display_name = :dn
      WHERE id = :id AND list_id = :l
      ''';
    FConn.StartTransaction;
    try
      for lR in AReplacements do
      begin
        if (lR.ItemId <= 0) or (lR.StreamId <= 0) then
          Continue;
        lSelect.Close;
        lSelect.SQL.Text :=
          '''
          SELECT i.display_name AS dn, i.content_type AS ct, s.name AS nm,
            src.strip_prefixes AS sp, src.strip_suffixes AS ss
          FROM list_items i LEFT JOIN streams s ON s.id = i.stream_item_id
          LEFT JOIN sources src ON src.id = s.source_id
          WHERE i.id = :id AND i.list_id = :l
          ''';
        lSelect.ParamByName('id').AsInteger := lR.ItemId;
        lSelect.ParamByName('l').AsInteger := AListId;
        lSelect.Open;
        if lSelect.IsEmpty then
          Continue;
        lDn := lSelect.FieldByName('dn').AsString;
        lOldCt := lSelect.FieldByName('ct').AsString;
        lOldName := lSelect.FieldByName('nm').AsString;
        lOldSp := CsvToStrArray(lSelect.FieldByName('sp').AsString, cStripTokenSep);
        lOldSs := CsvToStrArray(lSelect.FieldByName('ss').AsString, cStripTokenSep);

        lSelect.Close;
        lSelect.SQL.Text :=
          '''
          SELECT s.name AS nm, s.content_type AS ct, src.strip_prefixes AS sp,
            src.strip_suffixes AS ss,
            (SELECT COUNT(*) FROM list_items x WHERE x.list_id = :l AND x.stream_item_id = s.id) AS used
          FROM streams s LEFT JOIN sources src ON src.id = s.source_id WHERE s.id = :sid AND
          ''' + cSqlSourceActive; // never onto a switched-off source / type
        lSelect.ParamByName('sid').AsInteger := lR.StreamId;
        lSelect.ParamByName('l').AsInteger := AListId;
        lSelect.Open;
        if lSelect.IsEmpty or (lSelect.FieldByName('used').AsInteger > 0) then
          Continue;
        lNewCt := lSelect.FieldByName('ct').AsString;
        if not SameText(lNewCt, lOldCt) then
          Continue;
        lNewName := lSelect.FieldByName('nm').AsString;
        lNewSp := CsvToStrArray(lSelect.FieldByName('sp').AsString, cStripTokenSep);
        lNewSs := CsvToStrArray(lSelect.FieldByName('ss').AsString, cStripTokenSep);

        // auto-managed name (empty, upstream name, or the stripped form of it) ->
        // follow the new channel; otherwise keep the operator's own name
        if (lDn = '') or (lDn = lOldName) or (lDn = AutoDisplayName(lOldName, lOldSp, lOldSs)) or
           (lDn = StripNamePrefixes(lOldName, lOldSp)) then
          lNewDn := AutoDisplayName(lNewName, lNewSp, lNewSs)
        else
          lNewDn := lDn;

        lUpdate.ParamByName('sid').AsInteger := lR.StreamId;
        lUpdate.ParamByName('dn').AsWideString := lNewDn;
        lUpdate.ParamByName('id').AsInteger := lR.ItemId;
        lUpdate.ParamByName('l').AsInteger := AListId;
        lUpdate.ExecSQL;
        Inc(Result, lUpdate.RowsAffected);
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lSelect);
    FreeAndNil(lUpdate);
  end;
  if Result > 0 then
    TouchLineup;
end;

function TSQLiteStore.RestripGroupItems(AListId, AGroupId: Integer;
  const AExtraPrefixes, AExtraSuffixes: TArray<string>; ADryRun: Boolean): TArray<TNameChange>;
var
  lSelect, lUpdate: TFDQuery;
  lChanges: TList<TNameChange>;
  lChange: TNameChange;
  lDn, lUp, lShown, lNewName: string;
begin
  // Clean the name each channel currently SHOWS (display name, else upstream name)
  // with its source's strip rules + the one-off extra tokens. Stripping is
  // idempotent, so an auto name gives the same result as cleaning the upstream
  // name, and a manual rename only changes when it really carries such a token.
  lChanges := TList<TNameChange>.Create;
  lSelect := NewQuery;
  try
    lSelect.Open(
      '''
      SELECT i.id AS iid, i.display_name AS dn, s.name AS nm,
        src.strip_prefixes AS sp, src.strip_suffixes AS ss
      FROM list_items i JOIN streams s ON s.id = i.stream_item_id
      LEFT JOIN sources src ON src.id = s.source_id
      WHERE i.list_id = :l AND i.custom_group_id = :g
      ORDER BY i.channel_number, s.name COLLATE NOCASE
      ''', [AListId, AGroupId]);
    while not lSelect.Eof do
    begin
      lDn := lSelect.FieldByName('dn').AsString;
      lUp := lSelect.FieldByName('nm').AsString;
      if lDn.Trim <> '' then
        lShown := lDn
      else
        lShown := lUp;
      lNewName := CleanChannelName(lShown,
        CsvToStrArray(lSelect.FieldByName('sp').AsString, cStripTokenSep) + AExtraPrefixes,
        CsvToStrArray(lSelect.FieldByName('ss').AsString, cStripTokenSep) + AExtraSuffixes);
      if lNewName <> lShown.Trim then
      begin
        lChange.ItemId := lSelect.FieldByName('iid').AsInteger;
        lChange.OldName := lShown;
        lChange.NewName := lNewName;
        lChange.Original := lUp;
        lChanges.Add(lChange);
      end;
      lSelect.Next;
    end;
  finally
    FreeAndNil(lSelect);
  end;

  try
    Result := lChanges.ToArray;
    if ADryRun or (lChanges.Count = 0) then
      Exit;
    lUpdate := NewQuery;
    try
      lUpdate.SQL.Text := 'UPDATE list_items SET display_name = :dn WHERE id = :id AND list_id = :l';
      FConn.StartTransaction;
      try
        for lChange in lChanges do
        begin
          // equal to the upstream name -> '' (keep following upstream renames)
          if lChange.NewName = lChange.Original then
            lUpdate.ParamByName('dn').AsWideString := ''
          else
            lUpdate.ParamByName('dn').AsWideString := lChange.NewName;
          lUpdate.ParamByName('id').AsInteger := lChange.ItemId;
          lUpdate.ParamByName('l').AsInteger := AListId;
          lUpdate.ExecSQL;
        end;
        FConn.Commit;
      except
        SafeRollback;
        raise;
      end;
    finally
      FreeAndNil(lUpdate);
    end;
    TouchLineup;
  finally
    FreeAndNil(lChanges);
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
  lQuery: TFDQuery;
  lSeen: TDictionary<string, Boolean>;
  lToDelete: TList<Integer>;
  lKey: string;
begin
  lSeen := TDictionary<string, Boolean>.Create;
  lToDelete := TList<Integer>.Create;
  lQuery := NewQuery;
  try
    // walk items in the OUTPUT order (as LoadOutputChannels: favorites, group
    // drag-order, groups A-Z, channel numbers, names A-Z); the FIRST occurrence of
    // each upstream URL is kept, later ones are dropped as duplicates.
    lQuery.Open(
      '''
      SELECT i.id AS iid, s.upstream_url AS url, i.channel_number AS num,
        COALESCE(NULLIF(g.name,''), s.group_title) AS gname,
        COALESCE(NULLIF(i.display_name,''), s.name) AS cname,
        COALESCE(g.is_favorite, 0) AS fav, COALESCE(g.sort_order, 0) AS gsort
      FROM list_items i JOIN streams s ON s.id = i.stream_item_id
      LEFT JOIN list_groups g ON g.id = i.custom_group_id
      WHERE i.list_id = :l
      ORDER BY fav DESC, CASE WHEN gsort > 0 THEN 0 ELSE 1 END, gsort, gname COLLATE NOCASE,
        CASE WHEN num > 0 THEN 0 ELSE 1 END, num, cname COLLATE NOCASE
      ''',
      [AListId]);
    while not lQuery.Eof do
    begin
      lKey := lQuery.FieldByName('url').AsString;
      if (lKey <> '') and lSeen.ContainsKey(lKey) then
        lToDelete.Add(lQuery.FieldByName('iid').AsInteger)
      else
        lSeen.AddOrSetValue(lKey, True);
      lQuery.Next;
    end;
    if lToDelete.Count > 0 then
      FConn.ExecSQL('DELETE FROM list_items WHERE id IN (' + IdsToCsv(lToDelete.ToArray) + ')');
    Result := lToDelete.Count;
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lToDelete);
    FreeAndNil(lSeen);
  end;
  if Result > 0 then
    TouchLineup; // only a real change makes Plex rescan
end;

function TSQLiteStore.SortGroupAlphabetically(AListId, ACustomGroupId: Integer): Integer;
var
  lQuery, lUpdate: TFDQuery;
  lIds: TList<Integer>;
  i, lBase: Integer;
begin
  lIds := TList<Integer>.Create;
  lQuery := NewQuery;
  lUpdate := NewQuery;
  try
    lQuery.Open(
      '''
      SELECT i.id AS iid FROM list_items i JOIN streams s ON s.id = i.stream_item_id
      WHERE i.list_id = :l AND i.custom_group_id = :g
      ORDER BY COALESCE(NULLIF(i.display_name,''), s.name) COLLATE NOCASE
      ''',
      [AListId, ACustomGroupId]);
    while not lQuery.Eof do
    begin
      lIds.Add(lQuery.FieldByName('iid').AsInteger);
      lQuery.Next;
    end;
    lBase := GroupNumberBase(AListId, ACustomGroupId);
    lUpdate.SQL.Text := 'UPDATE list_items SET channel_number=:n WHERE id=:id';
    FConn.StartTransaction;
    try
      for i := 0 to lIds.Count - 1 do
      begin
        lUpdate.ParamByName('n').AsInteger := lBase + i;
        lUpdate.ParamByName('id').AsInteger := lIds[i];
        lUpdate.ExecSQL;
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
    Result := lIds.Count;
  finally
    FreeAndNil(lQuery);
    FreeAndNil(lUpdate);
    FreeAndNil(lIds);
  end;
  TouchLineup;
end;

function TSQLiteStore.ReorderGroupItems(AListId, ACustomGroupId: Integer;
  const AItemIds: TArray<Integer>): Integer;
var
  lUpdate: TFDQuery;
  i, lBase: Integer;
begin
  // Assign channel_number = base, base+1, … following the caller-supplied item
  // order (drag-and-drop result); base = the group's current lowest number, so a
  // bouquet-wide numbering survives. Only items that really belong to this
  // list+group are touched, so a stale or foreign id is ignored.
  Result := 0;
  lBase := GroupNumberBase(AListId, ACustomGroupId);
  lUpdate := NewQuery;
  try
    lUpdate.SQL.Text :=
      '''
      UPDATE list_items SET channel_number=:n
      WHERE id=:id AND list_id=:l AND custom_group_id=:g
      ''';
    FConn.StartTransaction;
    try
      for i := 0 to High(AItemIds) do
      begin
        lUpdate.ParamByName('n').AsInteger := lBase + i;
        lUpdate.ParamByName('id').AsInteger := AItemIds[i];
        lUpdate.ParamByName('l').AsInteger := AListId;
        lUpdate.ParamByName('g').AsInteger := ACustomGroupId;
        lUpdate.ExecSQL;
        Inc(Result, lUpdate.RowsAffected);
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lUpdate);
  end;
  TouchLineup;
end;


function TSQLiteStore.GroupNumberBase(AListId, ACustomGroupId: Integer): Integer;
var
  lQuery: TFDQuery;
begin
  lQuery := NewQuery;
  try
    lQuery.Open('''
      SELECT MIN(channel_number) FROM list_items
      WHERE list_id = :l AND custom_group_id = :g AND channel_number > 0
      ''',
      [AListId, ACustomGroupId]);
    // MIN() over no rows is NULL and its column has no declared type: read as text
    Result := StrToIntDef(lQuery.Fields[0].AsString, 0);
  finally
    FreeAndNil(lQuery);
  end;
  if Result <= 0 then
    Result := cDefaultGroupNumberBase;
end;

function TSQLiteStore.SetItemNumbers(AListId: Integer; const ANumbers: TArray<TItemNumber>): Integer;
var
  lUpdate: TFDQuery;
  lNumber: TItemNumber;
begin
  Result := 0;
  lUpdate := NewQuery;
  try
    lUpdate.SQL.Text := 'UPDATE list_items SET channel_number=:n WHERE id=:id AND list_id=:l';
    FConn.StartTransaction;
    try
      for lNumber in ANumbers do
      begin
        lUpdate.ParamByName('n').AsInteger := Max(0, lNumber.ChannelNumber);
        lUpdate.ParamByName('id').AsInteger := lNumber.ItemId;
        lUpdate.ParamByName('l').AsInteger := AListId;
        lUpdate.ExecSQL;
        Inc(Result, lUpdate.RowsAffected);
      end;
      FConn.Commit;
    except
      SafeRollback;
      raise;
    end;
  finally
    FreeAndNil(lUpdate);
  end;
  TouchLineup;
end;

end.
