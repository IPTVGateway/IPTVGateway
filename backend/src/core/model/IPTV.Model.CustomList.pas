unit IPTV.Model.CustomList;

{ The operator-curated output list — the heart of the product.

  A TCustomList is published downstream as its own Xtream portal (and as an
  M3U via get.php). Each TCustomItem references an ingested TStreamItem and
  layers user overrides on top: rename, re-group, custom logo and a channel
  number. Empty override fields fall back to the upstream value.

  Groups are first-class and operator-created (TCustomGroup). A group can be
  flagged IsFavorite. Default ordering (used when building output and in the UI):
    1. favorite groups first,
    2. then groups by Name, case-insensitive A→Z,
    3. channels within a group by display name, case-insensitive A→Z.
  See OrderingComparer notes in CLAUDE.md / IPTV.Output.Builder.

  Output credentials are OPTIONAL: a list may have empty OutputUsername /
  OutputPassword, in which case the portal is reachable without authenticating
  (a box can connect with no/blank credentials). When several lists exist,
  named credentials disambiguate; an unauthenticated request resolves to the
  single enabled "default" list.

  The DB is multi-list capable (each list has its own OutputUsername /
  OutputPassword); v1 drives a single list. }

interface

uses
  // RTL
  System.Generics.Collections,
  // Own units
  IPTV.Model.Types;

type
  /// An operator-curated output list, published as its own Xtream portal.
  TCustomList = class
  private
    FId: Integer;
    FName: string;
    FOutputUsername: string;
    FOutputPassword: string;
    FEnabled: Boolean;
  public
    /// Creates an enabled list.
    constructor Create;
    property Id: Integer read FId write FId;
    property Name: string read FName write FName;
    property OutputUsername: string read FOutputUsername write FOutputUsername;
    property OutputPassword: string read FOutputPassword write FOutputPassword;
    property Enabled: Boolean read FEnabled write FEnabled;
  end;

  /// An operator-created group within a list. Favorites sort to the top;
  /// the rest sort case-insensitively by Name.
  TCustomGroup = class
  private
    FId: Integer;
    FListId: Integer;
    FName: string;
    FContentType: TContentType;
    FIsFavorite: Boolean;
    FSortOrder: Integer;
  public
    property Id: Integer read FId write FId;
    property ListId: Integer read FListId write FListId;
    property Name: string read FName write FName;
    property ContentType: TContentType read FContentType write FContentType;
    property IsFavorite: Boolean read FIsFavorite write FIsFavorite;
    /// Manual drag order (0 = unset → falls back to A→Z). Favorites still sort first.
    property SortOrder: Integer read FSortOrder write FSortOrder;
  end;

  /// A list entry: an ingested stream plus the operator's overrides.
  TCustomItem = class
  private
    FId: Integer;
    FListId: Integer;
    FStreamItemId: Integer;     // FK -> ingested TStreamItem
    FCustomGroupId: Integer;    // FK -> TCustomGroup; 0 => fall back to upstream group-title
    FContentType: TContentType;
    FDisplayName: string;       // override; empty => upstream name
    FLogoOverride: string;      // override; empty => upstream logo
    FTvgIdOverride: string;     // override; empty => upstream tvg-id (EPG/Plex matching)
    FChannelNumber: Integer;    // 0 => derived from alphabetical position
    FStreamName: string;        // read-only: upstream channel name (for the UI)
    FStreamLogo: string;        // read-only: upstream logo
    FStreamTvgId: string;       // read-only: upstream tvg-id
    FStreamSourceId: Integer;   // read-only: source the upstream stream comes from (0 = stream gone)
    FStreamArchiveDays: Integer; // read-only: provider catch-up window of the stream (0 = none)
  public
    property Id: Integer read FId write FId;
    property ListId: Integer read FListId write FListId;
    property StreamItemId: Integer read FStreamItemId write FStreamItemId;
    property CustomGroupId: Integer read FCustomGroupId write FCustomGroupId;
    property ContentType: TContentType read FContentType write FContentType;
    property DisplayName: string read FDisplayName write FDisplayName;
    property LogoOverride: string read FLogoOverride write FLogoOverride;
    property TvgIdOverride: string read FTvgIdOverride write FTvgIdOverride;
    property ChannelNumber: Integer read FChannelNumber write FChannelNumber;
    // upstream values resolved on load (read-only; the UI shows them as the
    // fallback label when there's no DisplayName override)
    property StreamName: string read FStreamName write FStreamName;
    property StreamLogo: string read FStreamLogo write FStreamLogo;
    property StreamTvgId: string read FStreamTvgId write FStreamTvgId;
    property StreamSourceId: Integer read FStreamSourceId write FStreamSourceId;
    property StreamArchiveDays: Integer read FStreamArchiveDays write FStreamArchiveDays;
  end;

  /// Owning list of custom groups.
  TCustomGroupList = class(TObjectList<TCustomGroup>);
  /// Owning list of custom items.
  TCustomItemList = class(TObjectList<TCustomItem>);

  /// A fully-resolved output row: a custom item joined with its upstream stream
  /// and group, with overrides already applied. Produced by the store in the
  /// canonical order (favorite groups first, groups A→Z, channels A→Z) so the
  /// Xtream/M3U builders just iterate. Name/Logo are the effective values.
  TOutputChannel = class
  private
    FStreamItemId: Integer;
    FSourceId: Integer;
    FNumber: Integer;
    FName: string;
    FLogo: string;
    FTvgId: string;
    FUpstreamTvgId: string;
    FUpstreamUrl: string;
    FGroupName: string;
    FContentType: TContentType;
    FIsFavoriteGroup: Boolean;
    FUpstreamId: string;
    FArchiveDays: Integer;
    FExtraGuideId: string;
  public
    /// The stored channel ids whose programmes make up this channel's guide: the
    /// matched extra guide when set, else the upstream id and the override id.
    function EpgReadIds: TArray<string>;
    property StreamItemId: Integer read FStreamItemId write FStreamItemId;
    /// Source (provider) this channel's stream came from — for the per-source
    /// letter prefix on the Plex surfaces.
    property SourceId: Integer read FSourceId write FSourceId;
    property Number: Integer read FNumber write FNumber;
    property Name: string read FName write FName;
    property Logo: string read FLogo write FLogo;
    /// Effective guide id (per-item override wins) — what the output advertises.
    property TvgId: string read FTvgId write FTvgId;
    /// Raw upstream guide id (before override) — where the provider's EPG is stored.
    property UpstreamTvgId: string read FUpstreamTvgId write FUpstreamTvgId;
    property UpstreamUrl: string read FUpstreamUrl write FUpstreamUrl;
    property GroupName: string read FGroupName write FGroupName;
    property ContentType: TContentType read FContentType write FContentType;
    property IsFavoriteGroup: Boolean read FIsFavoriteGroup write FIsFavoriteGroup;
    /// Provider's own stream id (Xtream stream_id) — the id in an upstream timeshift URL.
    property UpstreamId: string read FUpstreamId write FUpstreamId;
    /// Provider catch-up window in days (0 = no archive).
    property ArchiveDays: Integer read FArchiveDays write FArchiveDays;
    /// Stored id (with EXTRA_EPG_PREFIX) of the extra guide channel this channel
    /// reads its programmes from; '' = the provider's own guide.
    property ExtraGuideId: string read FExtraGuideId write FExtraGuideId;
  end;

  /// Owning list of resolved output channels.
  TOutputChannelList = class(TObjectList<TOutputChannel>);

implementation

function TOutputChannel.EpgReadIds: TArray<string>;
begin
  Result := nil;
  if FExtraGuideId <> '' then
  begin
    Result := [FExtraGuideId];
    Exit;
  end;
  if FUpstreamTvgId <> '' then
    Result := Result + [FUpstreamTvgId];
  if (FTvgId <> '') and (FTvgId <> FUpstreamTvgId) then
    Result := Result + [FTvgId];
end;

constructor TCustomList.Create;
begin
  inherited;
  FEnabled := True;
end;

end.
