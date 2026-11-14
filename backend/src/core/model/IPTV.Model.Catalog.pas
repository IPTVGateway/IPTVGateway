unit IPTV.Model.Catalog;

{ The ingested catalog: everything read from all upstream sources, merged into
  one place but kept traceable to its origin (SourceId + UpstreamId).

  Change-tracking fields support the "show me what is new" workflow:
    - FirstSeenUtc / LastSeenUtc are stamped during ingest.
    - IsNew is set when an item appears that was not in the previous snapshot.
    - SeenAtUtc is set when the operator ticks the item off as "seen".
    - ContentHash detects upstream metadata changes between refreshes. }

interface

uses
  // RTL
  System.Generics.Collections,
  // Own units
  IPTV.Model.Types;

type
  /// An ingested upstream category (group) of one content type of one source.
  TCategory = class
  private
    FId: Integer;
    FSourceId: Integer;
    FUpstreamId: string;
    FContentType: TContentType;
    FName: string;
    FIsNew: Boolean;
    FSeenAtUtc: TDateTime;
    FNewCount: Integer;
  public
    property Id: Integer read FId write FId;
    property SourceId: Integer read FSourceId write FSourceId;
    property UpstreamId: string read FUpstreamId write FUpstreamId;
    property ContentType: TContentType read FContentType write FContentType;
    property Name: string read FName write FName;
    property IsNew: Boolean read FIsNew write FIsNew;
    property SeenAtUtc: TDateTime read FSeenAtUtc write FSeenAtUtc;
    /// Number of new (unseen, not hidden) streams in this category; filled by
    /// IStore.LoadCategories, not stored.
    property NewCount: Integer read FNewCount write FNewCount;
  end;

  /// A single ingested stream (channel / movie / series-entry / radio station).
  TStreamItem = class
  private
    FId: Integer;
    FSourceId: Integer;
    FUpstreamId: string;       // Xtream stream_id, or a stable hash for M3U entries
    FContentType: TContentType;
    FName: string;
    FLogo: string;
    FGroupTitle: string;       // raw group-title / category name from upstream
    FCategoryUpstreamId: string;
    FTvgId: string;            // maps to EPG channel id
    FTvgName: string;
    FUpstreamUrl: string;      // the real provider URL the box will be redirected to
    FContentHash: string;
    FArchiveDays: Integer;     // provider catch-up/timeshift window in days (Xtream tv_archive), 0 = none
    FIsNew: Boolean;
    FSeenAtUtc: TDateTime;
    FFirstSeenUtc: TDateTime;
    FLastSeenUtc: TDateTime;
  public
    property Id: Integer read FId write FId;
    property SourceId: Integer read FSourceId write FSourceId;
    property UpstreamId: string read FUpstreamId write FUpstreamId;
    property ContentType: TContentType read FContentType write FContentType;
    property Name: string read FName write FName;
    property Logo: string read FLogo write FLogo;
    property GroupTitle: string read FGroupTitle write FGroupTitle;
    property CategoryUpstreamId: string read FCategoryUpstreamId write FCategoryUpstreamId;
    property TvgId: string read FTvgId write FTvgId;
    property TvgName: string read FTvgName write FTvgName;
    property UpstreamUrl: string read FUpstreamUrl write FUpstreamUrl;
    property ContentHash: string read FContentHash write FContentHash;
    property ArchiveDays: Integer read FArchiveDays write FArchiveDays;
    property IsNew: Boolean read FIsNew write FIsNew;
    property SeenAtUtc: TDateTime read FSeenAtUtc write FSeenAtUtc;
    property FirstSeenUtc: TDateTime read FFirstSeenUtc write FFirstSeenUtc;
    property LastSeenUtc: TDateTime read FLastSeenUtc write FLastSeenUtc;
  end;

  /// Owning list of categories.
  TCategoryList = class(TObjectList<TCategory>);
  /// Owning list of stream items.
  TStreamItemList = class(TObjectList<TStreamItem>);

  /// Result of reading one source: the raw set of categories + streams.
  /// Owned by the caller; ingest diffs it against the stored snapshot.
  TSourceSnapshot = class
  private
    FSourceId: Integer;
    FEpgUrl: string; // discovered XMLTV url (M3U url-tvg / x-tvg-url header attr)
    FHasAccountInfo: Boolean;   // reader fetched provider account info (Xtream user_info)
    FAccountStatus: string;
    FExpiresUtc: TDateTime;     // 0 = no end date
    FMaxConnections: Integer;
    FHasTzOffset: Boolean;      // reader derived the portal's clock offset (server_info)
    FTzOffsetMin: Integer;      // portal local time - UTC, minutes (timeshift start times)
    FCategories: TCategoryList;
    FStreams: TStreamItemList;
  public
    constructor Create(ASourceId: Integer);
    destructor Destroy; override;
    property SourceId: Integer read FSourceId write FSourceId;
    property EpgUrl: string read FEpgUrl write FEpgUrl;
    property HasAccountInfo: Boolean read FHasAccountInfo write FHasAccountInfo;
    property AccountStatus: string read FAccountStatus write FAccountStatus;
    property ExpiresUtc: TDateTime read FExpiresUtc write FExpiresUtc;
    property MaxConnections: Integer read FMaxConnections write FMaxConnections;
    property HasTzOffset: Boolean read FHasTzOffset write FHasTzOffset;
    property TzOffsetMin: Integer read FTzOffsetMin write FTzOffsetMin;
    property Categories: TCategoryList read FCategories;
    property Streams: TStreamItemList read FStreams;
  end;

implementation

uses
  // RTL
  System.SysUtils;

constructor TSourceSnapshot.Create(ASourceId: Integer);
begin
  inherited Create;
  FSourceId := ASourceId;
  FCategories := TCategoryList.Create(True);
  FStreams := TStreamItemList.Create(True);
end;

destructor TSourceSnapshot.Destroy;
begin
  FreeAndNil(FStreams);
  FreeAndNil(FCategories);
  inherited;
end;

end.
