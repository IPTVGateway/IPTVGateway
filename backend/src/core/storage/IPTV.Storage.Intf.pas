unit IPTV.Storage.Intf;

{ Persistence contract. One repository interface for the whole core so the
  storage backend (SQLite today) stays swappable. All times are UTC. }

interface

uses
  // RTL
  System.SysUtils,
  System.Generics.Collections,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList;

const
  /// Series episodes handed to boxes get ids from this base up (cEpisodeIdBase +
  /// series_episodes.id), so they never collide with catalog stream ids.
  cEpisodeIdBase = 1000000000;
  /// app_state key: stamp of the last bouquet edit (Plex-rescan reminder); written
  /// by the store (TouchLineup), read by the app context.
  cStateLineupChanged = 'lineup_changed_utc';

type
  /// A write the store refuses because it would break a data rule (mirror bouquet
  /// validation): the message is meant for the operator, the API answers it as 400.
  EStoreValidation = class(Exception);

  /// A name-prefix discovered in a source's ingested streams, with how many
  /// streams carry it. Powers the "pick a filter prefix" UI when editing a source.
  TPrefixCount = record
    Prefix: string;
    Count: Integer;
  end;

  /// A known guide id (tvg-id) found in the catalog, with a sample channel name.
  /// Powers the searchable "set this channel's tvg-id" picker.
  TTvgIdInfo = record
    TvgId: string;
    Name: string;
  end;

  /// One channel in a group with its proposed quality-variant replacement, for
  /// "duplicate this group at another quality". CandidateStreamId = 0 when no
  /// variant of the target quality was found (the channel is then flagged in the
  /// preview and simply left out of the new group).
  TVariantMatch = record
    ItemId: Integer;            // the source group's list_items row
    StreamId: Integer;          // the channel's current stream
    Name: string;               // current channel name (upstream)
    Quality: string;            // current detected quality ('' if none)
    CandidateStreamId: Integer; // the target-quality variant (0 = none found)
    CandidateName: string;
    AlreadyInList: Boolean;     // candidate is already curated on this list (can't re-add)
  end;

  /// One variant of a single channel (quality probe: "measure NPO 1 in all
  /// qualities"). Includes the channel itself (IsSelf).
  TStreamVariant = record
    StreamId: Integer;
    SourceId: Integer;
    Name: string;               // upstream name
    Quality: string;            // canonical quality word ('' if none)
    TvgId: string;
    GroupTitle: string;
    IsSelf: Boolean;            // the stream the search started from
    MatchedBy: string;          // 'self' | 'name' | 'tvg'
    OnList: Boolean;            // already curated on the given list (AListId > 0)
  end;

  /// "Give this list item that channel number" (bouquet-wide renumber).
  TItemNumber = record
    ItemId: Integer;
    ChannelNumber: Integer;
  end;

  /// "Swap the stream behind this list item for that one" (in-place variant replace).
  TItemStreamReplace = record
    ItemId: Integer;
    StreamId: Integer;
  end;

  /// One channel whose shown name changes when a group's names are cleaned.
  TNameChange = record
    ItemId: Integer;
    OldName: string;  // currently shown (display name, else upstream name)
    NewName: string;  // after stripping
    Original: string; // upstream name (incl. prefix/suffix)
  end;

  /// One source's name filters, used to filter that source's rows even in the
  /// "all sources" catalog view (each row is judged against its own source).
  TSourceFilter = record
    SourceId: Integer;
    IncludeFilters: TArray<string>;
    ExcludeFilters: TArray<string>;
  end;

  /// Filter for browsing the ingested catalog from the admin API.
  /// Search and Prefix are independent and combine (AND) when both set.
  TCatalogFilter = record
    SourceId: Integer;       // 0 => any
    ContentType: TContentType;
    HasContentType: Boolean; // False => any content type
    OnlyNew: Boolean;        // True => only items with IsNew
    Search: string;          // case-insensitive name contains
    Prefix: string;          // case-insensitive name starts-with (e.g. "NL:", "UK |")
    CategoryUpstreamId: string; // filter to one group/category (upstream id); '' => any
    HasCategory: Boolean;       // True => apply CategoryUpstreamId (so '' can match the empty category)
    // Name filters applied LIVE to browse results (prefix OR suffix,
    // case-insensitive), mirroring TSourceConfig. Empty arrays => no filtering.
    // Global (no source guard) — used when one source is already selected.
    IncludeFilters: TArray<string>; // keep only names matching one of these
    ExcludeFilters: TArray<string>; // drop names matching any of these
    // Per-source filters — used in the "all sources" view so each source's rows
    // are judged against that source's own filters.
    SourceFilters: TArray<TSourceFilter>;
    // Use the precomputed per-row `hidden` flag (each source's own filters,
    // evaluated once on refresh / filter change) instead of evaluating filters
    // in the query. This is what the admin catalog uses; explicit filters above
    // still work for callers that pass their own.
    UseHiddenFlag: Boolean;
    Limit: Integer;            // page size; 0 => no limit (LoadStreams only)
    Offset: Integer;           // page offset
  end;

  /// The persistence contract of the whole core (sources, catalog, EPG, lists).
  IStore = interface
    ['{9F2C7A41-5D6B-4E3A-8C1F-2B3D4E5F6A70}']
    /// Create the schema if absent and run migrations.
    procedure Init; // create schema if absent, run migrations

    // ── Sources ──────────────────────────────────────────────────────
    /// All configured sources (caller owns the list).
    function LoadSources: TObjectList<TSourceConfig>;
    /// Insert or update a source; returns its id.
    function SaveSource(const ASource: TSourceConfig): Integer; // returns id
    /// Delete a source by id.
    procedure DeleteSource(AId: Integer);

    // ── Catalog (ingested) ───────────────────────────────────────────
    /// Upsert a freshly-read snapshot; stamps LastSeen, flags genuinely new
    /// items (IsNew) by diffing against what is already stored for the source.
    procedure MergeSnapshot(const ASnapshot: TSourceSnapshot);
    /// Ingested categories matching the filter (caller owns the list).
    function LoadCategories(const AFilter: TCatalogFilter): TCategoryList;
    /// Ingested streams matching the filter, paged by Limit/Offset (caller owns the list).
    function LoadStreams(const AFilter: TCatalogFilter): TStreamItemList;
    /// Number of streams matching the filter, ignoring Limit/Offset.
    function CountStreams(const AFilter: TCatalogFilter): Integer; // total ignoring Limit/Offset
    /// Mark categories/streams as seen (clears the "new" badge).
    procedure MarkCategoriesSeen(const AIds: TArray<Integer>);
    /// Mark streams as seen (clears the "new" badge).
    procedure MarkStreamsSeen(const AIds: TArray<Integer>);
    /// Single ingested stream by id (for the output redirect). nil if absent.
    function LoadStreamById(AId: Integer): TStreamItem;
    /// Single stream by id, but ONLY if it is an item on the given list — so the
    /// credential-scoped output (redirect / proxy relay) can't serve a stream that
    /// isn't on the authenticated list. nil if absent or not on the list.
    /// Also resolves a series EPISODE id (>= cEpisodeIdBase, see EnsureEpisodeIds)
    /// when its series is on the list: the result then carries the episode's URL.
    /// Streams of a disabled source / content type are never returned.
    /// For a mirror bouquet the lookup is scoped to the MASTER's items and the URL
    /// is rewritten to the mirror's own provider credentials.
    function LoadListStreamById(AListId, AStreamItemId: Integer): TStreamItem;
    /// Stable box-facing ids for the upstream episodes of a series stream (Xtream
    /// get_series_info): one row per (series, upstream episode id); AExts[i] is the
    /// container extension. Returns cEpisodeIdBase + row id per input.
    function EnsureEpisodeIds(ASeriesStreamId: Integer; const AUpstreamIds,
      AExts: TArray<string>): TArray<Integer>;
    /// Read-only twin of EnsureEpisodeIds: the existing ids, 0 for an episode that
    /// is unknown or whose stored extension differs from AExts[i].
    function FindEpisodeIds(ASeriesStreamId: Integer; const AUpstreamIds,
      AExts: TArray<string>): TArray<Integer>;
    /// Upstream URLs of the SAME channel from OTHER sources (stream failover):
    /// matched by tvg-id when the stream has one, else by exact (case-insensitive)
    /// name; same content type; excludes the stream itself and empty URLs.
    function LoadStreamSiblings(AStreamItemId: Integer): TArray<string>;
    /// LoadStreamSiblings as played through list AListId: for a mirror bouquet each
    /// URL is rewritten to the mirror's own provider credentials of its source.
    function LoadStreamSiblingsForList(AListId, AStreamItemId: Integer): TArray<string>;
    /// Distinct leading name-prefixes (e.g. "NL|", "UK:") found across a source's
    /// ingested streams, each with its stream count, most common first. Drives the
    /// "select a filter prefix" UI. Empty when the source has nothing ingested yet.
    function DiscoverPrefixes(ASourceId: Integer): TArray<TPrefixCount>;
    /// Distinct tvg-ids present in the catalog (with a sample name), for the
    /// per-channel tvg-id picker. Sorted by name.
    function LoadKnownTvgIds: TArray<TTvgIdInfo>;
    /// For each channel in a list group, find the same channel at another quality
    /// (ATargetQuality, canonical e.g. 'UHD') so the group can be duplicated as a
    /// quality variant. Matches on the quality-stripped base name; prefers a
    /// candidate from the SAME source. One entry per source-group item, in the
    /// group's item order.
    function FindQualityVariants(AListId, ASourceGroupId: Integer;
      const ATargetQuality: string): TArray<TVariantMatch>;
    /// As FindQualityVariants, but the replacement is the SAME channel from a chosen
    /// other source (ATargetSourceId) — matched by tvg-id, else exact name. Backs
    /// "duplicate this group from another provider".
    function FindProviderVariants(AListId, ASourceGroupId,
      ATargetSourceId: Integer): TArray<TVariantMatch>;
    /// Every quality variant of ONE channel: same content type, same quality-
    /// stripped base key (or head key) of the source-cleaned name, or the same
    /// non-empty tvg-id with a quality word. Only the stream's own source unless
    /// AAllSources. Self included. Ordered source, quality rank, name. OnList is
    /// filled when AListId > 0. Backs the per-channel quality probe.
    function FindStreamVariants(AStreamId: Integer; AAllSources: Boolean;
      AListId: Integer): TArray<TStreamVariant>;

    /// Small persistent key/value state (e.g. lineup-changed / plex-rescan stamps).
    function GetState(const AKey: string): string;
    /// Store a key/value state entry.
    procedure SetState(const AKey, AValue: string);

    // ── EPG ──────────────────────────────────────────────────────────
    /// Replace the stored EPG of one source with the given programmes.
    procedure ReplaceEpg(ASourceId: Integer; const AProgrammes: TEpgProgrammeList);
    /// Store an extra (third-party) guide under a NEGATIVE source id (-1 = first
    /// URL): its programmes (ids with EXTRA_EPG_PREFIX) and its channel list.
    procedure ReplaceExtraEpg(ASourceId: Integer; const AChannels: TArray<TEpgChannelInfo>;
      const AProgrammes: TEpgProgrammeList);
    /// Drop extra-guide slots below AMinSourceId (URLs removed from the settings).
    procedure ClearExtraEpgBelow(AMinSourceId: Integer);
    /// Load stored EPG for the given tvg-ids. AMaxDays > 0 caps the result to
    /// programmes starting within that many days from now (0 = no cap).
    function LoadEpgForTvgIds(const ATvgIds: TArray<string>; AMaxDays: Integer = 0): TEpgProgrammeList;
    /// Distinct non-empty tvg-ids that are actually used on a list (so ingest can
    /// fetch EPG only for channels you curated, not the whole 100+ MB guide).
    function LoadListTvgIds: TArray<string>;

    // ── Custom lists (output) ────────────────────────────────────────
    /// All output lists (caller owns the list).
    function LoadLists: TObjectList<TCustomList>;
    /// Insert or update a list; returns its id. Raises EStoreValidation when
    /// MirrorOfListId is invalid: not 0 and not an existing list, the list itself,
    /// a list that is a mirror itself, a list that is mirrored itself, or the list
    /// still has groups/items. A list that stops being a mirror loses its
    /// mirror credentials.
    function SaveList(const AList: TCustomList): Integer;
    /// Delete a list and everything under it (its groups + items + mirror
    /// credentials). Raises EStoreValidation while mirrors point at it.
    procedure DeleteList(AId: Integer);
    /// The stored provider credentials of a mirror bouquet, one per source
    /// (ordered by source id); empty for a normal list.
    function LoadMirrorCredentials(AListId: Integer): TArray<TMirrorCredential>;
    /// Replace all provider credentials of a mirror bouquet; rows whose url,
    /// username and password are all empty are not stored. Raises EStoreValidation
    /// when the list is not a mirror.
    procedure SaveMirrorCredentials(AListId: Integer; const ACredentials: TArray<TMirrorCredential>);
    /// <summary>Runs AProc inside ONE database transaction: everything it writes
    /// commits together, or nothing does when it raises (the exception is re-raised).
    /// AProc gets the store to use for it - call that one, not the outer store.</summary>
    procedure RunInTransaction(const AProc: TProc<IStore>);
    /// Resolve the list a box authenticates as. Credentials are OPTIONAL:
    /// when AUser is empty, return the single enabled list (the default);
    /// otherwise match on output_username/output_password. nil if no match.
    function FindListByCredentials(const AUser, APass: string): TCustomList;

    /// The custom groups of a list (caller owns the list).
    function LoadGroups(AListId: Integer): TCustomGroupList;
    /// Insert or update a custom group; returns its id.
    function SaveGroup(const AGroup: TCustomGroup): Integer;
    /// Set the manual drag order of a list's groups (sort_order = 1..N following the
    /// given id order). Favorites still sort first. Returns how many were updated.
    function ReorderGroups(AListId: Integer; const AGroupIds: TArray<Integer>): Integer;
    /// Delete a custom group by id.
    procedure DeleteGroup(AId: Integer);

    /// The items of a list (caller owns the list).
    function LoadItems(AListId: Integer): TCustomItemList;
    /// Resolved output rows (item⋈stream⋈group, overrides applied) in canonical
    /// order: favorite groups first, groups A→Z, channels A→Z (case-insensitive).
    /// For a mirror bouquet: the master's rows, each UpstreamUrl rewritten to the
    /// mirror's own provider credentials (RewriteProviderUrl).
    function LoadOutputChannels(AListId: Integer): TOutputChannelList;
    /// Insert or update a list item; returns its id.
    function SaveItem(const AItem: TCustomItem): Integer;
    /// Bulk-add chosen stream items to a list (and optional group, 0 => none)
    /// in one transaction; items already on the list are skipped. Returns the
    /// number actually added. Backs the checkbox multi-select "add to list".
    function AddItems(AListId, ACustomGroupId: Integer; const AStreamItemIds: TArray<Integer>): Integer;
    /// Re-apply a source's strip-prefix/suffix rules to its already-added list items
    /// after a rule changed: recompute display_name from the upstream name, but only
    /// for items still showing the auto value produced by the OLD rules — a manual
    /// rename is left untouched. Returns how many display names were updated.
    function RestripSourceItems(ASourceId: Integer;
      const AOldPrefixes, AOldSuffixes, ANewPrefixes, ANewSuffixes: TArray<string>): Integer;
    /// Apply every source's CURRENT strip-prefixes/suffixes to ALL its channels on
    /// every list (display_name := cleaned name) — skipping manual renames. One-click
    /// "strip prefixes from all channels now". Returns how many were updated.
    function RestripAllItems: Integer;
    /// Replace the stream behind existing items in place (keeps group, channel
    /// number, logo/tvg-id overrides; an auto display name follows the new stream).
    /// Items whose new stream is already on the list are skipped. Returns # replaced.
    function ReplaceItemStreams(AListId: Integer; const AReplacements: TArray<TItemStreamReplace>): Integer;
    /// Clean the shown names of one group's channels after the fact: strip each
    /// channel's source prefixes/suffixes PLUS the given one-off extra tokens from
    /// the name it currently shows (display name, else upstream name). Returns the
    /// channels whose name changes; ADryRun = only report (preview), else apply.
    /// A result equal to the upstream name is stored as '' (follow upstream).
    function RestripGroupItems(AListId, AGroupId: Integer;
      const AExtraPrefixes, AExtraSuffixes: TArray<string>; ADryRun: Boolean): TArray<TNameChange>;
    /// Delete a list item by id.
    procedure DeleteItem(AId: Integer);
    /// Remove every item of a list that sits in one group (custom_group_id;
    /// 0 = the upstream group). Returns how many were removed. One-click "empty".
    function ClearGroupItems(AListId, ACustomGroupId: Integer): Integer;
    /// Remove duplicate channels from a list (same upstream stream URL = the same
    /// channel), keeping the best copy (favorite group first, then canonical
    /// order). Returns how many were removed.
    function DedupeListItems(AListId: Integer): Integer;
    /// Renumber a group's items in alphabetical name order, so the box shows them
    /// A→Z. Numbering starts at the group's current lowest number (1 if none), so
    /// a bouquet-wide numbering (group blocks 101…, 201…) survives. Returns count.
    function SortGroupAlphabetically(AListId, ACustomGroupId: Integer): Integer;
    /// Renumber a group's items following an explicit item-id order (the drag-and-
    /// drop result), from the group's current lowest number (1 if none). Ids not in this list+group are
    /// skipped. Returns how many were numbered.
    function ReorderGroupItems(AListId, ACustomGroupId: Integer; const AItemIds: TArray<Integer>): Integer;
    /// Set explicit channel numbers for many items of one list in ONE transaction
    /// (bouquet-wide renumber across all groups; the client computes the plan).
    /// Ids not on this list are skipped. Returns how many were numbered.
    function SetItemNumbers(AListId: Integer; const ANumbers: TArray<TItemNumber>): Integer;
  end;

implementation

end.
