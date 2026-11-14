unit IPTV.Api.Mars.Admin;

{ Admin REST API as a MARS-Curiosity resource, mounted at /api. This drives the
  React "merge / filter / rename / sort" workbench. Routing/(de)serialisation is
  MARS; all behaviour still lives in the core (reached via the global App).
  JSON shapes are produced by IPTV.Api.Serializers (camelCase). }

interface

uses
  // RTL
  System.JSON,
  // third-party
  MARS.Core.Attributes,
  MARS.Core.MediaType,
  MARS.Core.RequestAndResponse.Interfaces;

type
  /// <summary>Admin REST API (/api) behind the web app.</summary>
  [Path('api')]
  TAdminResource = class
  protected
    [Context] Response: IMARSResponse;
    [Context] Request: IMARSRequest;
    /// Guard run at the start of every handler: 503 if the service isn't up, and
    /// 401 if an admin password is configured but missing/wrong on the request.
    /// AAllowQueryPassword: also accept ?pw= (only the download links, which can't
    /// send a header - a password in a URL ends up in browser history / proxy logs)
    procedure RequireApp(AAllowQueryPassword: Boolean = False);
  public
    /// Liveness + version; needs no login.
    [GET, Path('health'), Produces(TMediaType.APPLICATION_JSON)]
    function Health: TJSONObject;

    // ── sources ──────────────────────────────────────────────────────────
    /// All configured sources.
    [GET, Path('sources'), Produces(TMediaType.APPLICATION_JSON)]
    function GetSources: TJSONArray;
    /// Create or (partially) update a source.
    [POST, Path('sources'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostSource([BodyParam] ABody: TJSONObject): TJSONObject;
    /// Delete a source with its catalog and EPG.
    [DELETE, Path('sources/{id}')]
    procedure DeleteSource([PathParam('id')] AId: Integer);
    /// Start a background refresh of one source.
    [POST, Path('sources/{id}/refresh'), Produces(TMediaType.APPLICATION_JSON)]
    function RefreshSource([PathParam('id')] AId: Integer): TJSONObject;
    /// Channel-name prefixes of a source with their counts (filter discovery).
    [GET, Path('sources/{id}/prefixes'), Produces(TMediaType.APPLICATION_JSON)]
    function GetSourcePrefixes([PathParam('id')] AId: Integer): TJSONArray;
    // distinct guide ids (tvg-id) in the catalog, for the per-channel tvg-id picker
    [GET, Path('tvg-ids'), Produces(TMediaType.APPLICATION_JSON)]
    function GetTvgIds: TJSONArray;
    // UI language files dropped into the mounted lang/ folder (built-ins live in
    // the frontend). List them, and fetch one's translation dictionary.
    [GET, Path('languages'), Produces(TMediaType.APPLICATION_JSON)]
    function GetLanguages: TJSONArray;
    [GET, Path('languages/{code}'), Produces(TMediaType.APPLICATION_JSON)]
    function GetLanguage([PathParam('code')] ACode: string): TJSONObject;
    /// Start a background refresh of all sources.
    [POST, Path('refresh'), Produces(TMediaType.APPLICATION_JSON)]
    function RefreshAll: TJSONObject;
    // re-apply every source's strip-prefixes to all channels already on lists
    [POST, Path('restrip-prefixes'), Produces(TMediaType.APPLICATION_JSON)]
    function RestripPrefixes: TJSONObject;
    /// Per-source refresh state.
    [GET, Path('refresh/status'), Produces(TMediaType.APPLICATION_JSON)]
    function GetRefreshStatus: TJSONArray;
    /// Start a background EPG-only refresh.
    [POST, Path('epg/refresh'), Produces(TMediaType.APPLICATION_JSON)]
    function RefreshEpg: TJSONObject;

    // ── catalog ─────────────────────────────────────────────────────────
    /// Catalog categories matching the filter.
    [GET, Path('catalog/categories'), Produces(TMediaType.APPLICATION_JSON)]
    function GetCategories([QueryParam('sourceId')] ASourceId: Integer;
      [QueryParam('type')] AType: string; [QueryParam('onlyNew')] AOnlyNew: string;
      [QueryParam('search')] ASearch: string; [QueryParam('prefix')] APrefix: string;
      [QueryParam('includeHidden')] AIncludeHidden: string): TJSONArray;
    /// One page of catalog streams matching the filter.
    [GET, Path('catalog/streams'), Produces(TMediaType.APPLICATION_JSON)]
    function GetStreams([QueryParam('sourceId')] ASourceId: Integer;
      [QueryParam('type')] AType: string; [QueryParam('onlyNew')] AOnlyNew: string;
      [QueryParam('search')] ASearch: string; [QueryParam('prefix')] APrefix: string;
      [QueryParam('category')] ACategory: string;
      [QueryParam('limit')] ALimit: Integer; [QueryParam('offset')] AOffset: Integer;
      [QueryParam('includeHidden')] AIncludeHidden: string;
      [QueryParam('inCategory')] AInCategory: string): TJSONArray;
    /// Number of catalog streams matching the filter.
    [GET, Path('catalog/streams/count'), Produces(TMediaType.APPLICATION_JSON)]
    function CountStreams([QueryParam('sourceId')] ASourceId: Integer;
      [QueryParam('type')] AType: string; [QueryParam('onlyNew')] AOnlyNew: string;
      [QueryParam('search')] ASearch: string; [QueryParam('prefix')] APrefix: string;
      [QueryParam('category')] ACategory: string;
      [QueryParam('includeHidden')] AIncludeHidden: string;
      [QueryParam('inCategory')] AInCategory: string): TJSONObject;
    /// Clear the 'new' badge of the given categories.
    [POST, Path('catalog/categories/seen'), Consumes(TMediaType.APPLICATION_JSON)]
    procedure MarkCategoriesSeen([BodyParam] ABody: TJSONObject);
    /// Clear the 'new' badge of the given streams.
    [POST, Path('catalog/streams/seen'), Consumes(TMediaType.APPLICATION_JSON)]
    procedure MarkStreamsSeen([BodyParam] ABody: TJSONObject);

    // ── EPG ─────────────────────────────────────────────────────────────
    /// Source EPG of one tvg-id.
    [GET, Path('epg'), Produces(TMediaType.APPLICATION_JSON)]
    function GetEpg([QueryParam('tvgId')] ATvgId: string): TJSONArray;

    // ── lists / groups / items ──────────────────────────────────────────
    /// All output lists.
    [GET, Path('lists'), Produces(TMediaType.APPLICATION_JSON)]
    function GetLists: TJSONArray;
    /// Create or (partially) update an output list.
    [POST, Path('lists'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostList([BodyParam] ABody: TJSONObject): TJSONObject;
    /// Delete an output list with its groups and items.
    [DELETE, Path('lists/{id}')]
    procedure DeleteList([PathParam('id')] AId: Integer);
    /// Curated EPG of a list, keyed by the effective tvg-ids.
    [GET, Path('lists/{id}/epg'), Produces(TMediaType.APPLICATION_JSON)]
    function GetListEpg([PathParam('id')] AId: Integer): TJSONArray;
    /// Groups of a list.
    [GET, Path('lists/{id}/groups'), Produces(TMediaType.APPLICATION_JSON)]
    function GetGroups([PathParam('id')] AId: Integer): TJSONArray;
    /// Create or (partially) update a group of a list.
    [POST, Path('lists/{id}/groups'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostGroup([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    /// Delete a group.
    [DELETE, Path('groups/{id}')]
    procedure DeleteGroup([PathParam('id')] AId: Integer);
    /// Items of a list.
    [GET, Path('lists/{id}/items'), Produces(TMediaType.APPLICATION_JSON)]
    function GetItems([PathParam('id')] AId: Integer): TJSONArray;
    /// Create or (partially) update an item of a list.
    [POST, Path('lists/{id}/items'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostItem([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    /// Add many catalog streams to a list/group at once.
    [POST, Path('lists/{id}/items/bulk'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostItemsBulk([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    // swap the stream behind existing items in place (variant replace inside a
    // group). Body: { replacements: [ { itemId, streamId }, … ] } -> { replaced: n }
    [POST, Path('lists/{id}/items/replace'),
      Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostItemsReplace([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    /// Delete an item.
    [DELETE, Path('items/{id}')]
    procedure DeleteItem([PathParam('id')] AId: Integer);
    /// Remove all items of one group.
    [POST, Path('lists/{id}/items/clear'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function ClearGroupItems([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    /// Remove duplicate items of a list.
    [POST, Path('lists/{id}/dedupe'), Produces(TMediaType.APPLICATION_JSON)]
    function DedupeList([PathParam('id')] AId: Integer): TJSONObject;
    /// Sort one group's channels A-Z (renumbers them).
    [POST, Path('lists/{id}/groups/sort'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function SortGroup([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    /// Set one group's channel order (renumbers them).
    [POST, Path('lists/{id}/groups/reorder'),
      Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function ReorderGroup([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    // set the manual drag-order of the list's GROUPS (body: { groupIds:[…] })
    [POST, Path('lists/{id}/groups/order'),
      Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function OrderGroups([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    // renumber the whole bouquet across all groups in one transaction; the client
    // computes the plan. Body: { numbers:[ { itemId, channelNumber }, … ] } -> { numbered }
    [POST, Path('lists/{id}/renumber'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function RenumberList([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    // proposed quality-variant mapping for a group's channels (for "duplicate group
    // at another quality"). ?quality=UHD; the client reviews then creates a new
    // group + bulk-adds the chosen candidate stream ids.
    [GET, Path('lists/{id}/groups/{gid}/variants'), Produces(TMediaType.APPLICATION_JSON)]
    function GetGroupVariants([PathParam('id')] AId: Integer;
      [PathParam('gid')] AGroupId: Integer; [QueryParam('quality')] AQuality: string): TJSONArray;
    // proposed mapping to the SAME channels from another provider/source, for
    // "duplicate group from another provider". ?sourceId=N
    [GET, Path('lists/{id}/groups/{gid}/provider-variants'), Produces(TMediaType.APPLICATION_JSON)]
    function GetGroupProviderVariants([PathParam('id')] AId: Integer;
      [PathParam('gid')] AGroupId: Integer; [QueryParam('sourceId')] ASourceId: Integer): TJSONArray;
    // clean the names of a group's channels after the fact (source strip rules +
    // one-off extra tokens). Body: { extraPrefixes:[], extraSuffixes:[], dryRun }
    // -> [ { itemId, oldName, newName, original } ] (dryRun = preview only)
    [POST, Path('lists/{id}/groups/{gid}/restrip'),
      Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostGroupRestrip([PathParam('id')] AId: Integer;
      [PathParam('gid')] AGroupId: Integer; [BodyParam] ABody: TJSONObject): TJSONArray;
    // every quality variant of ONE channel (self included), for the quality probe.
    // ?allSources=1 also searches the other providers; ?listId=N flags onList.
    [GET, Path('catalog/streams/{id}/variants'), Produces(TMediaType.APPLICATION_JSON)]
    function GetStreamVariants([PathParam('id')] AId: Integer;
      [QueryParam('allSources')] AAllSources: string; [QueryParam('listId')] AListId: Integer): TJSONArray;
    // measure a channel: pull ~N s of the stream from the provider and report codec,
    // resolution, fps, interlacing, audio, bitrate, real-time factor. ?seconds=8.
    // Serialised server-side (provider connection limits); nothing is relayed.
    [POST, Path('catalog/streams/{id}/probe'), Produces(TMediaType.APPLICATION_JSON)]
    function PostStreamProbe([PathParam('id')] AId: Integer;
      [QueryParam('seconds')] ASeconds: Integer): TJSONObject;

    // ── settings (config.json) ──────────────────────────────────────────
    /// Runtime settings (editable and read-only).
    [GET, Path('config'), Produces(TMediaType.APPLICATION_JSON)]
    function GetConfig: TJSONObject;
    /// Apply and persist runtime settings (partial body allowed).
    [POST, Path('config'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostConfig([BodyParam] ABody: TJSONObject): TJSONObject;
    // tell the configured Plex server to reload its DVR guide/lineup
    [POST, Path('plex/rescan'), Produces(TMediaType.APPLICATION_JSON)]
    function PlexRescan: TJSONObject;
    // reminder state: is a Plex rescan due (bouquet changed since last rescan)?
    [GET, Path('plex/status'), Produces(TMediaType.APPLICATION_JSON)]
    function PlexStatus: TJSONObject;

    // ── media servers (Plex/Jellyfin) ───────────────────────────────────
    // the group-titles available to select (from the served/default list), with counts
    [GET, Path('media/groups'), Produces(TMediaType.APPLICATION_JSON)]
    function GetMediaGroups: TJSONArray;
    // status of the current global group filter: channels published + real vs dummy EPG
    [GET, Path('media/status'), Produces(TMediaType.APPLICATION_JSON)]
    function GetMediaStatus: TJSONObject;
    // the in-memory log (Log tab): lines after ?since=<seq>, oldest first
    [GET, Path('logs'), Produces(TMediaType.APPLICATION_JSON)]
    function GetLogs([QueryParam('since')] ASince: string): TJSONObject;
    // regenerate the HDHomeRun DeviceID so Plex re-imports the lineup as a fresh device
    [POST, Path('media/device-id/reset'), Produces(TMediaType.APPLICATION_JSON)]
    function ResetDeviceId: TJSONObject;

    // ── settings export / import (portable config bundle: config + sources +
    //    lists + groups; NOT the picked channels/catalog, which are data) ────
    /// Settings bundle for download.
    [GET, Path('export'), Produces(TMediaType.APPLICATION_JSON)]
    function ExportSettings: TJSONObject;
    /// Replace the configuration from a settings bundle.
    [POST, Path('import'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function ImportSettings([BodyParam] ABody: TJSONObject): TJSONObject;

    // ── exports (downloads) ─────────────────────────────────────────────
    /// List as an M3U download.
    [GET, Path('lists/{id}/export.m3u'), Produces('application/x-mpegurl')]
    function ExportM3U([PathParam('id')] AId: Integer): string;
    /// List EPG as an XMLTV download.
    [GET, Path('lists/{id}/export.xmltv'), Produces(TMediaType.APPLICATION_XML)]
    function ExportXmltv([PathParam('id')] AId: Integer): string;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.Generics.Collections,
  System.IOUtils,
  System.Math,
  // third-party
  MARS.Core.Registry,
  MARS.Core.Exceptions,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList,
  IPTV.Storage.Intf,
  IPTV.App.Config,
  IPTV.App.Context,
  IPTV.Ingest.Service,
  IPTV.Api.Serializers,
  IPTV.Api.SettingsIO,
  IPTV.Output.Builder,
  IPTV.Core.Utils,
  IPTV.Plex.Client,
  IPTV.Source.Probe;

const
  // admin authentication: header (web app), query param (download links only)
  cAdminPasswordHeader = 'X-Admin-Password';
  cAdminPasswordQuery = 'pw';
  cAllowQueryPassword = True; // RequireApp AAllowQueryPassword

  // truthy query-param values ('1' / 'true', case-insensitive)
  cQueryTrueDigit = '1';
  cQueryTrueText = 'true';

  // settings fields whose values are checked (POST /api/config and import); the
  // valid ranges come from IPTV.App.Config (the same ones TAppConfig.Load clamps to)
  cFieldRefreshHour = 'refreshHour';
  cFieldRefreshMinute = 'refreshMinute';
  cFieldProxyPort = 'proxyPort';
  cFieldEpgMaxDays = 'epgMaxDays';
  cFieldPlexTunerCount = 'plexTunerCount';
  cFieldPlexListId = 'plexListId';
  cFieldDummyEpgBlockMinutes = 'dummyEpgBlockMinutes';
  cFieldDummyEpgHoursBack = 'dummyEpgHoursBack';
  cFieldDummyEpgHoursAhead = 'dummyEpgHoursAhead';
  cFieldPublicBaseUrl = 'publicBaseUrl';
  cFieldWarnings = 'warnings';
  // settings fields that must be true/false when present
  cBoolFields: array[0..10] of string = ('proxyStreams', 'streamFailover', 'plexM3uEnabled',
    'plexM3uProxy', 'plexHdhrEnabled', 'plexHdhrProxy', 'dummyEpgEnabled', 'nameShowGroup',
    'nameShowNumber', 'nameShowSource', 'idSortPrefix');
  cMinRefreshHour = 0;
  cMinRefreshMinute = 0;
  cMinEpgMaxDays = 0;
  cBadBaseUrlMsg = 'publicBaseUrl is not a valid URL (e.g. http://192.168.1.10:7777)';

  // catalog paging / EPG window: 0 = unlimited
  cNoLimit = 0;
  cNoOffset = 0;
  cNoEpgDayLimit = 0;

  // separator the strip-prefix/suffix token lists are compared with
  cStripTokenSep = ';';
  // chars of an oversized filter item quoted in the 400 message
  cFilterPreviewLen = 40;

  // UI language files: <exedir>/lang/<code>.json, optional "_name" label
  cLangDirName = 'lang';
  cLangFileExt = '.json';
  cLangFileMask = '*' + cLangFileExt;
  cLangNameKey = '_name';

  // quality probe
  cDefaultProbeSeconds = 8;  // ?seconds= absent or <= 0
  cProbeRoundDigits = -2;    // RoundTo: 2 decimals

  // download exports
  cHeaderContentDisposition = 'Content-Disposition';
  cAttachmentFmt = 'attachment; filename="%s"';
  cExportM3uFileName = 'playlist.m3u';
  cExportXmltvFileName = 'epg.xml';

procedure TAdminResource.RequireApp(AAllowQueryPassword: Boolean);
var
  lPw: string;
begin
  if App = nil then
    raise EMARSHttpException.Create('service not started', cHttpServiceUnavailable);
  lPw := App.Config.AdminPassword;
  if lPw <> '' then
    if not IsSamePassword(Request.GetHeaderParamValue(cAdminPasswordHeader), lPw) and
       not (AAllowQueryPassword and IsSamePassword(Request.GetQueryParamValue(cAdminPasswordQuery), lPw)) then
      raise EMARSHttpException.Create('Unauthorized', cHttpUnauthorized);
end;

function ParseIds(const ABody: TJSONObject): TArray<Integer>;
begin
  Result := IntArrayFromJson(ABody, 'ids');
end;

function IsTrue(const AValue: string): Boolean;
begin
  Result := (AValue = cQueryTrueDigit) or SameText(AValue, cQueryTrueText);
end;

// The integer of a settings field. False when the body doesn't carry it; 400 when
// it is there but no whole number (it used to surface as a 500 half-way the apply).
function SettingsInt(const ACfg: TJSONObject; const AKey: string; out AValue: Integer): Boolean;
var
  lValue: TJSONValue;
begin
  AValue := 0;
  lValue := ACfg.GetValue(AKey);
  Result := lValue <> nil;
  if Result and not ((lValue is TJSONNumber) and TryStrToInt(TJSONNumber(lValue).Value, AValue)) then
    raise EMARSHttpException.Create(Format('%s must be a whole number', [AKey]), cHttpBadRequest);
end;

// 400 when the body carries AKey with a value outside AMin..AMax
procedure CheckIntField(const ACfg: TJSONObject; const AKey: string; AMin, AMax: Integer);
var
  lValue: Integer;
begin
  if SettingsInt(ACfg, AKey, lValue) and ((lValue < AMin) or (lValue > AMax)) then
    raise EMARSHttpException.Create(Format('%s must be %d-%d', [AKey, AMin, AMax]), cHttpBadRequest);
end;

// 400 for values the service can't use (POST /api/config and the import's config
// section), checked BEFORE anything is applied. Only the fields the body carries are
// checked: a stored value that is out of range must not block an unrelated save
// (config.json with epgMaxDays 60 used to fail every POST /api/config).
procedure CheckSettingsRange(const ACfg: TJSONObject);
var
  lValue: Integer;
  lKey: string;
  lField: TJSONValue;
begin
  CheckIntField(ACfg, cFieldRefreshHour, cMinRefreshHour, cMaxRefreshHour);
  CheckIntField(ACfg, cFieldRefreshMinute, cMinRefreshMinute, cMaxRefreshMinute);
  CheckIntField(ACfg, cFieldProxyPort, cMinPort, cMaxPort);
  if SettingsInt(ACfg, cFieldProxyPort, lValue) and (lValue = App.Config.HttpPort) then
    raise EMARSHttpException.Create('proxyPort must differ from the web/API port', cHttpBadRequest);
  CheckIntField(ACfg, cFieldEpgMaxDays, cMinEpgMaxDays, cMaxEpgMaxDays);
  CheckIntField(ACfg, cFieldPlexTunerCount, cMinPlexTunerCount, cMaxPlexTunerCount);
  CheckIntField(ACfg, cFieldDummyEpgBlockMinutes, cMinDummyEpgBlockMinutes, cMaxDummyEpgBlockMinutes);
  CheckIntField(ACfg, cFieldDummyEpgHoursBack, cMinDummyEpgHoursBack, cMaxDummyEpgHoursBack);
  CheckIntField(ACfg, cFieldDummyEpgHoursAhead, cMinDummyEpgHoursAhead, cMaxDummyEpgHoursAhead);
  SettingsInt(ACfg, cFieldPlexListId, lValue); // type check only
  for lKey in cBoolFields do
  begin
    lField := ACfg.GetValue(lKey);
    if (lField <> nil) and not (lField is TJSONBool) then
      raise EMARSHttpException.Create(Format('%s must be true or false', [lKey]), cHttpBadRequest);
  end;
end;

// The Plex bouquet of an imported bundle: the import recreates the lists (new ids),
// so map the bundle's plexListId through its list NAME; 0 (= first enabled) if gone.
function ImportedPlexListId(const ABody, ACfg: TJSONObject): Integer;
var
  lOldId: Integer;
  lName: string;
  lItem: TJSONValue;
  lLists: TObjectList<TCustomList>;
  i: Integer;
begin
  Result := 0;
  lOldId := ACfg.GetValue<Integer>('plexListId', 0);
  if (lOldId = 0) or not (ABody.GetValue('lists') is TJSONArray) then
    Exit;
  lName := '';
  for lItem in TJSONArray(ABody.GetValue('lists')) do
    if (lItem is TJSONObject) and (TJSONObject(lItem).GetValue<Integer>('id', 0) = lOldId) then
      lName := TJSONObject(lItem).GetValue<string>('name', '');
  if lName = '' then
    Exit;
  lLists := App.Store.LoadLists;
  try
    for i := 0 to lLists.Count - 1 do
      if SameText(lLists[i].Name, lName) then
        Exit(lLists[i].Id);
  finally
    FreeAndNil(lLists);
  end;
end;

// The publicBaseUrl a settings body asks for, normalised like a saved one; the
// current one when the body doesn't carry it. False (ABaseUrl = the current one) when
// the given value is unusable (no scheme/host - that used to break every box login).
function SettingsBaseUrl(const ACfg: TJSONObject; out ABaseUrl: string): Boolean;
var
  lValue: TJSONValue;
begin
  ABaseUrl := App.Config.PublicBaseUrl;
  lValue := ACfg.GetValue(cFieldPublicBaseUrl);
  if lValue = nil then
    Exit(True);
  Result := (lValue is TJSONString) and NormalizePublicBaseUrl(TJSONString(lValue).Value, ABaseUrl);
  if not Result then
    ABaseUrl := App.Config.PublicBaseUrl;
end;

function MakeFilter(ASourceId: Integer; const AType, AOnlyNew, ASearch, APrefix, ACategory: string;
  ALimit: Integer = 0; AOffset: Integer = 0; AIncludeHidden: Boolean = False;
  AInCategory: Boolean = False): TCatalogFilter;
begin
  Result := Default(TCatalogFilter);
  Result.SourceId := ASourceId;
  if AType <> '' then
  begin
    Result.HasContentType := True;
    Result.ContentType := ContentTypeFromString(AType);
  end;
  Result.OnlyNew := IsTrue(AOnlyNew);
  Result.Search := ASearch;
  Result.Prefix := APrefix;
  // AInCategory: the drilled group has an EMPTY upstream id (an M3U group-less
  // bucket) - an absent and an empty query param look the same otherwise
  if (ACategory <> '') or AInCategory then
  begin
    Result.HasCategory := True;
    Result.CategoryUpstreamId := ACategory;
  end;
  Result.Limit := ALimit;
  Result.Offset := AOffset;
  // Each source's include/exclude acts as a LIVE view filter (hide, never
  // delete). The result is precomputed per row (`hidden`, refreshed on ingest
  // and on filter change), so the query just tests a flag — evaluating hundreds
  // of filter tokens per row in SQL took minutes on 26k streams. 'includeHidden'
  // lets the UI reveal hidden items so they can be re-selected.
  Result.UseHiddenFlag := not AIncludeHidden;
end;

{ TAdminResource }

function TAdminResource.Health: TJSONObject;
begin
  Result := TJSONObject.Create;
  Result.AddPair('status', 'ok');
  Result.AddPair('version', APP_VERSION);
  Result.AddPair('hasApp', TJSONBool.Create(App <> nil));
end;

function TAdminResource.GetSources: TJSONArray;
var
  lList: TObjectList<TSourceConfig>;
begin
  RequireApp;
  lList := App.Store.LoadSources;
  try
    Result := SourcesToJson(lList);
  finally
    FreeAndNil(lList);
  end;
end;

function TAdminResource.PostSource(ABody: TJSONObject): TJSONObject;
var
  lSource, lExisting: TSourceConfig;
  lSources: TObjectList<TSourceConfig>;
  lId: Integer;
  lOldStrip, lOldStripSfx: TArray<string>;
  lTooLong: string;
begin
  RequireApp;
  lOldStrip := [];
  lOldStripSfx := [];
  lSource := TSourceConfig.Create;
  try
    // For an update, pre-load the stored row so a PARTIAL body (e.g. just a
    // content-type toggle) doesn't blank out the other columns. SourceFromJson
    // then overrides only the fields the client actually sent.
    lId := ABody.GetValue<Integer>('id', 0);
    if lId > 0 then
    begin
      lSources := App.Store.LoadSources;
      try
        for lExisting in lSources do
          if lExisting.Id = lId then
          begin
            lSource.Assign(lExisting);
            lOldStrip := lExisting.StripPrefixes; // remember to re-strip existing items if it changes
            lOldStripSfx := lExisting.StripSuffixes;
            Break;
          end;
      finally
        FreeAndNil(lSources);
      end;
    end;
    SourceFromJson(ABody, lSource);
    // a name-filter item can't be a whole pasted list: refuse oversized items
    // (they used to reach SQLite as one giant LIKE pattern and fail every catalog
    // query) and split pasted multi-line items into separate tokens
    lTooLong := FirstTooLongFilterToken(lSource.IncludeFilters + lSource.ExcludeFilters);
    if lTooLong <> '' then
      raise EMARSHttpException.Create(Format(
        'Filter item too long (%d chars, max %d) — split it into separate items: "%s…"',
        [Length(lTooLong), MaxFilterTokenLen, Copy(lTooLong, 1, cFilterPreviewLen)]), cHttpBadRequest);
    lSource.IncludeFilters := CleanFilterTokens(lSource.IncludeFilters);
    lSource.ExcludeFilters := CleanFilterTokens(lSource.ExcludeFilters);
    App.Store.SaveSource(lSource);
    // if a strip-prefix/suffix rule changed, re-clean already-added channel names
    // (auto-named items only; manual renames are preserved)
    if (lId > 0) and
       ((StrArrayToCsv(lOldStrip, cStripTokenSep) <> StrArrayToCsv(lSource.StripPrefixes, cStripTokenSep)) or
       (StrArrayToCsv(lOldStripSfx, cStripTokenSep) <> StrArrayToCsv(lSource.StripSuffixes, cStripTokenSep))) then
      App.Store.RestripSourceItems(lSource.Id, lOldStrip, lOldStripSfx, lSource.StripPrefixes, lSource.StripSuffixes);
    Result := SourceToJson(lSource);
  finally
    FreeAndNil(lSource);
  end;
end;

procedure TAdminResource.DeleteSource(AId: Integer);
begin
  RequireApp;
  App.Store.DeleteSource(AId);
end;

function TAdminResource.RefreshSource(AId: Integer): TJSONObject;
begin
  RequireApp;
  App.SpawnBackground(
    procedure
    begin
      App.Ingest.RefreshSource(AId);
    end);
  Result := TJSONObject.Create.AddPair('started', TJSONBool.Create(True));
end;

function TAdminResource.RefreshEpg: TJSONObject;
begin
  RequireApp;
  App.SpawnBackground(
    procedure
    begin
      App.Ingest.RefreshEpgAll;
    end);
  Result := TJSONObject.Create.AddPair('started', TJSONBool.Create(True));
end;

function TAdminResource.GetRefreshStatus: TJSONArray;
var
  lStatuses: TArray<TIngestStatus>;
  lStatus: TIngestStatus;
  lEntry: TJSONObject;
begin
  RequireApp;
  lStatuses := App.Ingest.GetStatus;
  Result := TJSONArray.Create;
  for lStatus in lStatuses do
  begin
    lEntry := TJSONObject.Create;
    lEntry.AddPair('sourceId', TJSONNumber.Create(lStatus.SourceId));
    lEntry.AddPair('running', TJSONBool.Create(lStatus.Running));
    lEntry.AddPair('startedUtc', DateTimeToIsoUtc(lStatus.StartedUtc));
    lEntry.AddPair('finishedUtc', DateTimeToIsoUtc(lStatus.FinishedUtc));
    lEntry.AddPair('streams', TJSONNumber.Create(lStatus.Streams));
    lEntry.AddPair('categories', TJSONNumber.Create(lStatus.Categories));
    lEntry.AddPair('programmes', TJSONNumber.Create(lStatus.Programmes));
    lEntry.AddPair('error', lStatus.Error);
    Result.Add(lEntry);
  end;
end;

function TAdminResource.GetSourcePrefixes(AId: Integer): TJSONArray;
var
  lPrefixes: TArray<TPrefixCount>;
  lPrefix: TPrefixCount;
begin
  RequireApp;
  lPrefixes := App.Store.DiscoverPrefixes(AId);
  Result := TJSONArray.Create;
  for lPrefix in lPrefixes do
    Result.Add(TJSONObject.Create
      .AddPair('prefix', lPrefix.Prefix)
      .AddPair('count', TJSONNumber.Create(lPrefix.Count)));
end;

function TAdminResource.GetTvgIds: TJSONArray;
var
  lIds: TArray<TTvgIdInfo>;
  lInfo: TTvgIdInfo;
begin
  RequireApp;
  lIds := App.Store.LoadKnownTvgIds;
  Result := TJSONArray.Create;
  for lInfo in lIds do
    Result.Add(TJSONObject.Create
      .AddPair('tvgId', lInfo.TvgId)
      .AddPair('name', lInfo.Name));
end;

// The mounted language folder, next to the service exe: <exedir>/lang. Operators
// drop <code>.json dictionaries here (e.g. de.json) to add UI languages beyond
// the built-in en/nl that ship inside the frontend bundle.
function LangDir: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), cLangDirName);
  ForceDirectories(Result);
end;

function TAdminResource.GetLanguages: TJSONArray;
var
  lFileName, lCode, lDisplayName: string;
  lValue: TJSONValue;
  lLangObj: TJSONObject;
begin
  RequireApp;
  Result := TJSONArray.Create;
  try
    if not TDirectory.Exists(LangDir) then
      Exit;
    for lFileName in TDirectory.GetFiles(LangDir, cLangFileMask) do
    begin
      lCode := TPath.GetFileNameWithoutExtension(lFileName);
      lDisplayName := lCode;
      // the optional "_name" key gives a human label (e.g. "Deutsch"); fall back to code.
      // Parse to a TJSONValue and free it whatever its concrete type — a non-object
      // file (e.g. a JSON array) must not leak the parsed node.
      lValue := nil;
      try
        lValue := TJSONObject.ParseJSONValue(TFile.ReadAllText(lFileName, TEncoding.UTF8));
        if (lValue is TJSONObject) and (TJSONObject(lValue).GetValue(cLangNameKey) <> nil) then
          lDisplayName := TJSONObject(lValue).GetValue(cLangNameKey).Value;
      except
        // malformed file → skip the label, keep the code
      end;
      FreeAndNil(lValue);
      lLangObj := TJSONObject.Create;
      lLangObj.AddPair('code', lCode);
      lLangObj.AddPair('name', lDisplayName);
      Result.Add(lLangObj);
    end;
  except
    FreeAndNil(Result); // MARS only frees what we return
    raise;
  end;
end;

function TAdminResource.GetLanguage(ACode: string): TJSONObject;
var
  lFileName: string;
  lValue: TJSONValue;
begin
  RequireApp;
  // path-traversal guard: codes are simple identifiers, never paths
  if (ACode = '') or ACode.Contains('/') or ACode.Contains('\') or ACode.Contains('..') or
     ACode.Contains(':') then
    raise EMARSHttpException.Create('Bad language code', cHttpBadRequest);
  lFileName := TPath.Combine(LangDir, ACode + cLangFileExt);
  if not TFile.Exists(lFileName) then
    raise EMARSHttpException.Create('Unknown language', cHttpNotFound);
  // parse to a value first; a non-object (or unparseable) file must not leak
  lValue := TJSONObject.ParseJSONValue(TFile.ReadAllText(lFileName, TEncoding.UTF8));
  if not (lValue is TJSONObject) then
  begin
    FreeAndNil(lValue); // nil-safe; frees a non-object value too
    raise EMARSHttpException.Create('Malformed language file', cHttpInternalServerError);
  end;
  Result := TJSONObject(lValue);
end;

function TAdminResource.RefreshAll: TJSONObject;
begin
  RequireApp;
  App.SpawnBackground(
    procedure
    begin
      App.Ingest.RefreshAll;
    end);
  Result := TJSONObject.Create.AddPair('started', TJSONBool.Create(True));
end;

function TAdminResource.RestripPrefixes: TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create.AddPair('updated', TJSONNumber.Create(App.Store.RestripAllItems));
end;

function TAdminResource.GetCategories(ASourceId: Integer; AType, AOnlyNew, ASearch, APrefix,
  AIncludeHidden: string): TJSONArray;
var
  lList: TCategoryList;
begin
  RequireApp;
  lList := App.Store.LoadCategories(MakeFilter(ASourceId, AType, AOnlyNew, ASearch, APrefix, '', cNoLimit,
    cNoOffset, IsTrue(AIncludeHidden)));
  try
    Result := CategoriesToJson(lList);
  finally
    FreeAndNil(lList);
  end;
end;

function TAdminResource.GetStreams(ASourceId: Integer; AType, AOnlyNew, ASearch, APrefix, ACategory: string;
  ALimit, AOffset: Integer; AIncludeHidden, AInCategory: string): TJSONArray;
var
  lList: TStreamItemList;
begin
  RequireApp;
  lList := App.Store.LoadStreams(MakeFilter(ASourceId, AType, AOnlyNew, ASearch, APrefix, ACategory,
    ALimit, AOffset, IsTrue(AIncludeHidden), IsTrue(AInCategory)));
  try
    Result := StreamsToJson(lList);
  finally
    FreeAndNil(lList);
  end;
end;

function TAdminResource.CountStreams(ASourceId: Integer; AType, AOnlyNew, ASearch, APrefix, ACategory,
  AIncludeHidden, AInCategory: string): TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create.AddPair('count',
    TJSONNumber.Create(App.Store.CountStreams(MakeFilter(ASourceId, AType, AOnlyNew, ASearch, APrefix, ACategory,
      cNoLimit, cNoOffset, IsTrue(AIncludeHidden), IsTrue(AInCategory)))));
end;

procedure TAdminResource.MarkCategoriesSeen(ABody: TJSONObject);
begin
  RequireApp;
  App.Store.MarkCategoriesSeen(ParseIds(ABody));
end;

procedure TAdminResource.MarkStreamsSeen(ABody: TJSONObject);
begin
  RequireApp;
  App.Store.MarkStreamsSeen(ParseIds(ABody));
end;

function TAdminResource.GetEpg(ATvgId: string): TJSONArray;
var
  lList: TEpgProgrammeList;
begin
  RequireApp;
  lList := App.Store.LoadEpgForTvgIds([ATvgId], App.Config.EpgMaxDays);
  try
    Result := ProgrammesToJson(lList);
  finally
    FreeAndNil(lList);
  end;
end;

function TAdminResource.GetLists: TJSONArray;
var
  lList: TObjectList<TCustomList>;
begin
  RequireApp;
  lList := App.Store.LoadLists;
  try
    Result := ListsToJson(lList);
  finally
    FreeAndNil(lList);
  end;
end;

function TAdminResource.PostList(ABody: TJSONObject): TJSONObject;
var
  lList, lExisting: TCustomList;
  lLists: TObjectList<TCustomList>;
  lId: Integer;
begin
  RequireApp;
  lList := TCustomList.Create;
  try
    // load-then-merge so a partial patch can't blank the other list fields
    lId := ABody.GetValue<Integer>('id', 0);
    if lId > 0 then
    begin
      lLists := App.Store.LoadLists;
      try
        for lExisting in lLists do
          if lExisting.Id = lId then
          begin
            lList.Id := lExisting.Id;
            lList.Name := lExisting.Name;
            lList.OutputUsername := lExisting.OutputUsername;
            lList.OutputPassword := lExisting.OutputPassword;
            lList.Enabled := lExisting.Enabled;
            Break;
          end;
      finally
        FreeAndNil(lLists);
      end;
    end;
    ListFromJson(ABody, lList);
    App.Store.SaveList(lList);
    Result := ListToJson(lList);
  finally
    FreeAndNil(lList);
  end;
end;

procedure TAdminResource.DeleteList(AId: Integer);
begin
  RequireApp;
  App.Store.DeleteList(AId);
end;

function TAdminResource.GetConfig: TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create;
  // editable fields
  Result.AddPair('refreshHour', TJSONNumber.Create(App.Config.RefreshHour));
  Result.AddPair('refreshMinute', TJSONNumber.Create(App.Config.RefreshMinute));
  Result.AddPair('epgMaxDays', TJSONNumber.Create(App.Config.EpgMaxDays));
  Result.AddPair('proxyStreams', TJSONBool.Create(App.Config.ProxyStreams));
  Result.AddPair('proxyPort', TJSONNumber.Create(App.Config.ProxyPort));
  Result.AddPair('streamFailover', TJSONBool.Create(App.Config.StreamFailover));
  // Plex Live TV (each tuner surface on/off + its own proxy choice)
  Result.AddPair('plexM3uEnabled', TJSONBool.Create(App.Config.PlexM3uEnabled));
  Result.AddPair('plexM3uProxy', TJSONBool.Create(App.Config.PlexM3uProxy));
  Result.AddPair('plexHdhrEnabled', TJSONBool.Create(App.Config.PlexHdhrEnabled));
  Result.AddPair('plexHdhrProxy', TJSONBool.Create(App.Config.PlexHdhrProxy));
  Result.AddPair('plexTunerCount', TJSONNumber.Create(App.Config.PlexTunerCount));
  Result.AddPair('plexListId', TJSONNumber.Create(App.Config.PlexListId));
  Result.AddPair('plexServerUrl', App.Config.PlexServerUrl);
  Result.AddPair('plexToken', App.Config.PlexToken);
  // media servers: base URL (now editable) + dummy-EPG settings + global group filter
  Result.AddPair('publicBaseUrl', App.Config.PublicBaseUrl);
  Result.AddPair('dummyEpgEnabled', TJSONBool.Create(App.Config.DummyEpgEnabled));
  Result.AddPair('dummyEpgBlockMinutes', TJSONNumber.Create(App.Config.DummyEpgBlockMinutes));
  Result.AddPair('dummyEpgHoursBack', TJSONNumber.Create(App.Config.DummyEpgHoursBack));
  Result.AddPair('dummyEpgHoursAhead', TJSONNumber.Create(App.Config.DummyEpgHoursAhead));
  Result.AddPair('nameShowGroup', TJSONBool.Create(App.Config.NameShowGroup));
  Result.AddPair('nameShowNumber', TJSONBool.Create(App.Config.NameShowNumber));
  Result.AddPair('nameShowSource', TJSONBool.Create(App.Config.NameShowSource));
  Result.AddPair('idSortPrefix', TJSONBool.Create(App.Config.IdSortPrefix));
  Result.AddPair('visibleGroups', StrArrayToJson(App.Config.VisibleGroups));
  Result.AddPair('extraEpgUrls', StrArrayToJson(App.Config.ExtraEpgUrls));
  Result.AddPair('mediaAllowedClients', StrArrayToJson(App.Config.MediaAllowedClients));
  // read-only context (shown but not editable from the UI)
  Result.AddPair('httpPort', TJSONNumber.Create(App.Config.HttpPort));
  Result.AddPair('useHttps', TJSONBool.Create(App.Config.UseHttps));
  Result.AddPair('plexDeviceId', App.Config.PlexDeviceId);
end;

function TAdminResource.PostConfig(ABody: TJSONObject): TJSONObject;
var
  lGroups: TArray<string>;
  lArrValue: TJSONValue;
  lBase: string;
  lHour, lMinute, lProxyPort, lEpgDays: Integer;
begin
  RequireApp;
  // EVERY field is checked BEFORE anything is applied (hour 24 never fired; -1
  // wrapped to 65535; a bad dummy-EPG value used to fail after the relay had moved)
  CheckSettingsRange(ABody);
  // validated: a value without scheme/host used to break every box login (500)
  if not SettingsBaseUrl(ABody, lBase) then
    raise EMARSHttpException.Create(cBadBaseUrlMsg, cHttpBadRequest);
  // default each field to its current value, so a partial body is fine
  lHour := ABody.GetValue<Integer>(cFieldRefreshHour, App.Config.RefreshHour);
  lMinute := ABody.GetValue<Integer>(cFieldRefreshMinute, App.Config.RefreshMinute);
  lProxyPort := ABody.GetValue<Integer>(cFieldProxyPort, App.Config.ProxyPort);
  lEpgDays := ABody.GetValue<Integer>(cFieldEpgMaxDays, App.Config.EpgMaxDays);
  App.UpdateSettings(lHour, lMinute,
    ABody.GetValue<Boolean>('proxyStreams', App.Config.ProxyStreams),
    lProxyPort, lEpgDays,
    ABody.GetValue<Boolean>('streamFailover', App.Config.StreamFailover));
  App.UpdatePlexSettings(
    ABody.GetValue<Boolean>('plexM3uEnabled', App.Config.PlexM3uEnabled),
    ABody.GetValue<Boolean>('plexM3uProxy', App.Config.PlexM3uProxy),
    ABody.GetValue<Boolean>('plexHdhrEnabled', App.Config.PlexHdhrEnabled),
    ABody.GetValue<Boolean>('plexHdhrProxy', App.Config.PlexHdhrProxy),
    ABody.GetValue<Integer>('plexTunerCount', App.Config.PlexTunerCount),
    ABody.GetValue<string>('plexServerUrl', App.Config.PlexServerUrl),
    ABody.GetValue<string>('plexToken', App.Config.PlexToken));
  App.SetPlexListId(ABody.GetValue<Integer>('plexListId', App.Config.PlexListId));
  // media servers: global group filter + base URL (trailing slash normalised) + dummy EPG
  lArrValue := ABody.GetValue('visibleGroups');
  if lArrValue is TJSONArray then
    lGroups := StrArrayFromJson(TJSONArray(lArrValue))
  else
    lGroups := App.Config.VisibleGroups;
  App.UpdateMediaConfig(lGroups, lBase,
    ABody.GetValue<Boolean>('dummyEpgEnabled', App.Config.DummyEpgEnabled),
    ABody.GetValue<Integer>('dummyEpgBlockMinutes', App.Config.DummyEpgBlockMinutes),
    ABody.GetValue<Integer>('dummyEpgHoursBack', App.Config.DummyEpgHoursBack),
    ABody.GetValue<Integer>('dummyEpgHoursAhead', App.Config.DummyEpgHoursAhead),
    ABody.GetValue<Boolean>('nameShowGroup', App.Config.NameShowGroup),
    ABody.GetValue<Boolean>('nameShowNumber', App.Config.NameShowNumber),
    ABody.GetValue<Boolean>('nameShowSource', App.Config.NameShowSource),
    ABody.GetValue<Boolean>('idSortPrefix', App.Config.IdSortPrefix));
  // media-server client allow-list: only when the body carries the field
  lArrValue := ABody.GetValue('mediaAllowedClients');
  if lArrValue is TJSONArray then
    App.UpdateMediaAllowedClients(StrArrayFromJson(TJSONArray(lArrValue)));
  // extra (third-party) XMLTV guides: only when the body carries the field
  lArrValue := ABody.GetValue('extraEpgUrls');
  if lArrValue is TJSONArray then
    App.UpdateExtraEpgUrls(StrArrayFromJson(TJSONArray(lArrValue)));
  Result := GetConfig;
end;

function TAdminResource.PlexRescan: TJSONObject;
var
  lCount: Integer;
begin
  RequireApp;
  try
    lCount := ReloadPlexGuides(App.Config.PlexServerUrl, App.Config.PlexToken);
    App.MarkPlexRescanned; // clears the "rescan due" reminder
    App.Log(Format('Plex rescan: reloaded %d DVR(s)', [lCount]));
    Result := TJSONObject.Create.AddPair('dvrs', TJSONNumber.Create(lCount));
  except
    on E: Exception do
      raise EMARSHttpException.Create('Plex rescan failed: ' + E.Message, cHttpBadRequest);
  end;
end;

function TAdminResource.ExportSettings: TJSONObject;
begin
  RequireApp;
  // store-backed bundle (sources + lists + groups + chosen channels) ...
  Result := ExportStoreSettings(App.Store);
  // ... plus the app-level settings (refresh time / proxy)
  Result.AddPair('config', GetConfig);
end;

// Replace the whole curation from an exported bundle: wipes sources + lists
// (and their groups/items/catalog) then recreates everything, INCLUDING the
// chosen channels - their streams are re-created in the catalog (matched by
// source+upstreamId on a later refresh) and the items re-linked by upstream URL.
function TAdminResource.ImportSettings(ABody: TJSONObject): TJSONObject;
var
  lCounts: TImportCounts;
  lCfg: TJSONObject;
  lGroups: TArray<string>;
  lBase: string;
  lWarnings: TList<string>;
begin
  RequireApp;
  if not ((ABody.GetValue('sources') is TJSONArray) or (ABody.GetValue('lists') is TJSONArray)) then
    raise EMARSHttpException.Create('Invalid import file (no "sources"/"lists")', cHttpBadRequest);

  // the bundle's settings are checked BEFORE the store is replaced: a bad value used
  // to fail the import (400) after the sources and bouquets were already swapped
  lCfg := nil;
  if ABody.GetValue('config') is TJSONObject then
  begin
    lCfg := TJSONObject(ABody.GetValue('config'));
    CheckSettingsRange(lCfg);
  end;

  // one transaction: a failure half-way leaves the old sources and bouquets intact
  // (before, an error after the wipe left a half-imported setup)
  App.Store.RunInTransaction(
    procedure(AStore: IStore)
    begin
      lCounts := ImportStoreSettings(AStore, ABody);
    end);

  // from here on the store IS replaced: a setting that can't be applied (the relay
  // port is taken here, SSDP can't bind) is reported as a warning, not as a failed
  // import
  lWarnings := TList<string>.Create;
  try
    if lCfg <> nil then
    begin
      try
        App.UpdateSettings(
          lCfg.GetValue<Integer>(cFieldRefreshHour, App.Config.RefreshHour),
          lCfg.GetValue<Integer>(cFieldRefreshMinute, App.Config.RefreshMinute),
          lCfg.GetValue<Boolean>('proxyStreams', App.Config.ProxyStreams),
          lCfg.GetValue<Integer>(cFieldProxyPort, App.Config.ProxyPort),
          lCfg.GetValue<Integer>(cFieldEpgMaxDays, App.Config.EpgMaxDays), // was dropped on import
          lCfg.GetValue<Boolean>('streamFailover', App.Config.StreamFailover));
      except
        on E: Exception do
        begin
          lWarnings.Add('Stream relay settings not applied (relay could not be started): ' + E.Message);
          // UpdateSettings changed nothing: apply the rest with the relay as it is now
          try
            App.UpdateSettings(
              lCfg.GetValue<Integer>(cFieldRefreshHour, App.Config.RefreshHour),
              lCfg.GetValue<Integer>(cFieldRefreshMinute, App.Config.RefreshMinute),
              App.Config.ProxyStreams,
              App.Config.ProxyPort,
              lCfg.GetValue<Integer>(cFieldEpgMaxDays, App.Config.EpgMaxDays),
              lCfg.GetValue<Boolean>('streamFailover', App.Config.StreamFailover));
          except
            on E2: Exception do
              lWarnings.Add('Refresh/EPG settings not applied: ' + E2.Message);
          end;
        end;
      end;
      // were exported but never restored
      if lCfg.GetValue('extraEpgUrls') is TJSONArray then
        App.UpdateExtraEpgUrls(StrArrayFromJson(TJSONArray(lCfg.GetValue('extraEpgUrls'))));
      if lCfg.GetValue('mediaAllowedClients') is TJSONArray then
        App.UpdateMediaAllowedClients(StrArrayFromJson(TJSONArray(lCfg.GetValue('mediaAllowedClients'))));
      App.SetPlexListId(ImportedPlexListId(ABody, lCfg));
      // the Plex tuner surfaces are part of the clone too — restore them as well
      try
        App.UpdatePlexSettings(
          lCfg.GetValue<Boolean>('plexM3uEnabled', App.Config.PlexM3uEnabled),
          lCfg.GetValue<Boolean>('plexM3uProxy', App.Config.PlexM3uProxy),
          lCfg.GetValue<Boolean>('plexHdhrEnabled', App.Config.PlexHdhrEnabled),
          lCfg.GetValue<Boolean>('plexHdhrProxy', App.Config.PlexHdhrProxy),
          lCfg.GetValue<Integer>(cFieldPlexTunerCount, App.Config.PlexTunerCount),
          lCfg.GetValue<string>('plexServerUrl', App.Config.PlexServerUrl),
          lCfg.GetValue<string>('plexToken', App.Config.PlexToken));
      except
        on E: Exception do
          lWarnings.Add('Plex relay/discovery could not be started: ' + E.Message);
      end;
      // media servers: the global group filter + base URL + dummy-EPG settings
      // the base URL, dummy EPG and name options are restored also when the bundle has
      // no group filter (then the current filter stays)
      if lCfg.GetValue('visibleGroups') is TJSONArray then
        lGroups := StrArrayFromJson(TJSONArray(lCfg.GetValue('visibleGroups')))
      else
        lGroups := App.Config.VisibleGroups;
      // an unusable base URL keeps the current one
      if not SettingsBaseUrl(lCfg, lBase) then
        lWarnings.Add('publicBaseUrl in the bundle is not a valid URL - kept ' + lBase);
      try
        App.UpdateMediaConfig(lGroups, lBase,
          lCfg.GetValue<Boolean>('dummyEpgEnabled', App.Config.DummyEpgEnabled),
          lCfg.GetValue<Integer>(cFieldDummyEpgBlockMinutes, App.Config.DummyEpgBlockMinutes),
          lCfg.GetValue<Integer>(cFieldDummyEpgHoursBack, App.Config.DummyEpgHoursBack),
          lCfg.GetValue<Integer>(cFieldDummyEpgHoursAhead, App.Config.DummyEpgHoursAhead),
          lCfg.GetValue<Boolean>('nameShowGroup', App.Config.NameShowGroup),
          lCfg.GetValue<Boolean>('nameShowNumber', App.Config.NameShowNumber),
          lCfg.GetValue<Boolean>('nameShowSource', App.Config.NameShowSource),
          lCfg.GetValue<Boolean>('idSortPrefix', App.Config.IdSortPrefix));
      except
        on E: Exception do
          lWarnings.Add('Plex relay/discovery could not be started: ' + E.Message);
      end;
    end;

    Result := TJSONObject.Create;
    Result.AddPair('sources', TJSONNumber.Create(lCounts.Sources));
    Result.AddPair('lists', TJSONNumber.Create(lCounts.Lists));
    Result.AddPair('groups', TJSONNumber.Create(lCounts.Groups));
    Result.AddPair('items', TJSONNumber.Create(lCounts.Items));
    Result.AddPair(cFieldWarnings, StrArrayToJson(lWarnings.ToArray));
  finally
    FreeAndNil(lWarnings);
  end;
end;

function TAdminResource.PlexStatus: TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create;
  // pending = bouquet changed since last rescan; enabled = a Plex tuner is on;
  // configured = the rescan API (server+token) is set so the button can act.
  Result.AddPair('pending', TJSONBool.Create(App.PlexSyncPending));
  Result.AddPair('enabled', TJSONBool.Create(App.PlexEnabled));
  Result.AddPair('configured',
    TJSONBool.Create((App.Config.PlexServerUrl <> '') and (App.Config.PlexToken <> '')));
end;

// the served (default) list a media server sees; nil if none configured
function ServedListForMedia: TCustomList;
begin
  Result := App.PlexList;
end;

function TAdminResource.GetMediaGroups: TJSONArray;
var
  lList: TCustomList;
  lChannels: TOutputChannelList;
  lChannel: TOutputChannel;
  lCounts: TDictionary<string, Integer>;
  lNames: TStringList;
  lCount, i: Integer;
begin
  RequireApp;
  lList := ServedListForMedia;
  Result := TJSONArray.Create;
  if lList = nil then
    Exit;
  lCounts := nil;
  lNames := nil;
  try
    lCounts := TDictionary<string, Integer>.Create;
    lNames := TStringList.Create;
    try
      lNames.Sorted := True;
      lNames.Duplicates := dupIgnore;
      lNames.CaseSensitive := False;
      lChannels := App.Store.LoadOutputChannels(lList.Id);
      try
        for lChannel in lChannels do
        begin
          if not lCounts.TryGetValue(lChannel.GroupName, lCount) then
          begin
            lCount := 0;
            lNames.Add(lChannel.GroupName);
          end;
          lCounts.AddOrSetValue(lChannel.GroupName, lCount + 1);
        end;
      finally
        FreeAndNil(lChannels);
      end;
      for i := 0 to lNames.Count - 1 do
        Result.Add(TJSONObject.Create
          .AddPair('name', lNames[i])
          .AddPair('channels', TJSONNumber.Create(lCounts[lNames[i]])));
    finally
      FreeAndNil(lCounts);
      FreeAndNil(lNames);
      FreeAndNil(lList);
    end;
  except
    FreeAndNil(Result); // MARS only frees what we return
    raise;
  end;
end;

function TAdminResource.GetLogs(ASince: string): TJSONObject;
var
  lPw: string;
  lLines: TArray<TLogLine>;
  lLine: TLogLine;
  lArr: TJSONArray;
  lEntry: TJSONObject;
  lLast: Int64;
begin
  // no RequireApp (the log is most useful when the app failed to start), but the
  // admin password IS checked: provider errors in the log may name hosts/accounts
  lPw := AdminPasswordEarly;
  if App <> nil then
    lPw := App.Config.AdminPassword;
  // header only (the web app's Log tab sends it; a ?pw= would end up in URLs)
  if (lPw <> '') and not IsSamePassword(Request.GetHeaderParamValue(cAdminPasswordHeader), lPw) then
    raise EMARSHttpException.Create('Unauthorized', cHttpUnauthorized);
  Result := TJSONObject.Create;
  lArr := TJSONArray.Create;
  lLast := StrToInt64Def(ASince, 0);
  if LogRing <> nil then
  begin
    lLines := LogRing.Since(lLast);
    for lLine in lLines do
    begin
      lEntry := TJSONObject.Create;
      lEntry.AddPair('seq', TJSONNumber.Create(lLine.Seq));
      lEntry.AddPair('t', DateTimeToIsoUtc(lLine.TimeUtc));
      lEntry.AddPair('text', lLine.Text);
      lArr.Add(lEntry);
      lLast := lLine.Seq;
    end;
  end;
  Result.AddPair('next', TJSONNumber.Create(lLast));
  Result.AddPair('lines', lArr);
end;

function TAdminResource.GetMediaStatus: TJSONObject;
var
  lList: TCustomList;
  lChannels: TOutputChannelList;
  lChannel: TOutputChannel;
  lIds: TStringList;
  lGotEpg: TStringList;
  lProgs: TEpgProgrammeList;
  lTotal, lReal, i: Integer;
  lHasReal: Boolean;
  lEff: string;
begin
  RequireApp;
  Result := TJSONObject.Create;
  lTotal := 0;
  lReal := 0;
  lList := ServedListForMedia;
  if lList <> nil then
  try
    lChannels := nil;
    lIds := nil;
    lGotEpg := nil;
    try
      // the channels actually published under the current global group filter
      lChannels := SelectOutputChannels(App.Store, lList.Id, App.Config.VisibleGroups);
      KeepContentTypes(lChannels, cLinearContentTypes); // what the media servers actually get
      lIds := TStringList.Create;
      lGotEpg := TStringList.Create;
      lIds.Sorted := True;
      lIds.Duplicates := dupIgnore;
      lGotEpg.Sorted := True;
      lGotEpg.Duplicates := dupIgnore;
      for lChannel in lChannels do
        for lEff in lChannel.EpgReadIds do
          lIds.Add(lEff);
      lProgs := App.Store.LoadEpgForTvgIds(lIds.ToStringArray, cNoEpgDayLimit);
      try
        for i := 0 to lProgs.Count - 1 do
          lGotEpg.Add(lProgs[i].ChannelTvgId);
      finally
        FreeAndNil(lProgs);
      end;
      lTotal := lChannels.Count;
      for lChannel in lChannels do
      begin
        lHasReal := False;
        for lEff in lChannel.EpgReadIds do
          if lGotEpg.IndexOf(lEff) >= 0 then
            lHasReal := True;
        if lHasReal then
          Inc(lReal);
      end;
    finally
      FreeAndNil(lIds);
      FreeAndNil(lGotEpg);
      FreeAndNil(lChannels);
    end;
  finally
    FreeAndNil(lList);
  end;
  Result.AddPair('channels', TJSONNumber.Create(lTotal));
  Result.AddPair('realEpg', TJSONNumber.Create(lReal));
  Result.AddPair('dummyEpg', TJSONNumber.Create(lTotal - lReal));
end;

function TAdminResource.ResetDeviceId: TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create.AddPair('deviceId', App.ResetPlexDeviceId);
end;

function TAdminResource.GetListEpg(AId: Integer): TJSONArray;
var
  lChannels: TOutputChannelList;
  lChannel: TOutputChannel;
  lUpstreams: TStringList;
  lEffById: TDictionary<string, string>; // upstream tvg-id -> effective (override) id
  lProgs: TEpgProgrammeList;
  lProgramme: TEpgProgramme;
  lEff: string;
begin
  RequireApp;
  lUpstreams := nil;
  lEffById := nil;
  try
    lUpstreams := TStringList.Create;
    lUpstreams.Sorted := True;
    lUpstreams.Duplicates := dupIgnore;
    lEffById := TDictionary<string, string>.Create;
    lChannels := App.Store.LoadOutputChannels(AId);
    try
      // fetch EPG by UPSTREAM id (where the provider's programmes are stored), and
      // remember the effective (override) id to re-key them to on the way out
      for lChannel in lChannels do
        if lChannel.TvgId <> '' then
          for lEff in lChannel.EpgReadIds do
          begin
            lUpstreams.Add(lEff);
            lEffById.AddOrSetValue(lEff, lChannel.TvgId);
          end;
    finally
      FreeAndNil(lChannels);
    end;
    lProgs := App.Store.LoadEpgForTvgIds(lUpstreams.ToStringArray, App.Config.EpgMaxDays);
    try
      for lProgramme in lProgs do
        if lEffById.TryGetValue(lProgramme.ChannelTvgId, lEff) then
          lProgramme.ChannelTvgId := lEff;
      Result := ProgrammesToJson(lProgs);
    finally
      FreeAndNil(lProgs);
    end;
  finally
    FreeAndNil(lUpstreams);
    FreeAndNil(lEffById);
  end;
end;

function TAdminResource.GetGroups(AId: Integer): TJSONArray;
var
  lList: TCustomGroupList;
begin
  RequireApp;
  lList := App.Store.LoadGroups(AId);
  try
    Result := GroupsToJson(lList);
  finally
    FreeAndNil(lList);
  end;
end;

function TAdminResource.PostGroup(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  lGroup, lExisting: TCustomGroup;
  lGroups: TCustomGroupList;
  lId: Integer;
begin
  RequireApp;
  lGroup := TCustomGroup.Create;
  try
    // load-then-merge for an update: a PARTIAL patch (e.g. just the favorite
    // star, or just a rename) must not blank the group's other fields.
    lId := ABody.GetValue<Integer>('id', 0);
    if lId > 0 then
    begin
      lGroups := App.Store.LoadGroups(AId);
      try
        for lExisting in lGroups do
          if lExisting.Id = lId then
          begin
            lGroup.Id := lExisting.Id;
            lGroup.ListId := lExisting.ListId;
            lGroup.Name := lExisting.Name;
            lGroup.ContentType := lExisting.ContentType;
            lGroup.IsFavorite := lExisting.IsFavorite;
            Break;
          end;
      finally
        FreeAndNil(lGroups);
      end;
    end;
    GroupFromJson(ABody, lGroup); // overrides only the fields the client actually sent
    lGroup.ListId := AId;
    App.Store.SaveGroup(lGroup);
    Result := GroupToJson(lGroup);
  finally
    FreeAndNil(lGroup);
  end;
end;

procedure TAdminResource.DeleteGroup(AId: Integer);
begin
  RequireApp;
  App.Store.DeleteGroup(AId);
end;

function TAdminResource.GetItems(AId: Integer): TJSONArray;
var
  lList: TCustomItemList;
begin
  RequireApp;
  lList := App.Store.LoadItems(AId);
  try
    Result := ItemsToJson(lList);
  finally
    FreeAndNil(lList);
  end;
end;

function TAdminResource.PostItem(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  lItem, lExisting: TCustomItem;
  lItems: TCustomItemList;
  lId: Integer;
begin
  RequireApp;
  lItem := TCustomItem.Create;
  try
    // load-then-merge: a partial patch must not reset channel_number / move the
    // item to the upstream group (custom_group_id) etc.
    lId := ABody.GetValue<Integer>('id', 0);
    if lId > 0 then
    begin
      lItems := App.Store.LoadItems(AId);
      try
        for lExisting in lItems do
          if lExisting.Id = lId then
          begin
            lItem.Id := lExisting.Id;
            lItem.ListId := lExisting.ListId;
            lItem.StreamItemId := lExisting.StreamItemId;
            lItem.CustomGroupId := lExisting.CustomGroupId;
            lItem.ContentType := lExisting.ContentType;
            lItem.DisplayName := lExisting.DisplayName;
            lItem.LogoOverride := lExisting.LogoOverride;
            lItem.TvgIdOverride := lExisting.TvgIdOverride;
            lItem.ChannelNumber := lExisting.ChannelNumber;
            Break;
          end;
      finally
        FreeAndNil(lItems);
      end;
    end;
    ItemFromJson(ABody, lItem);
    lItem.ListId := AId;
    App.Store.SaveItem(lItem);
    Result := ItemToJson(lItem);
  finally
    FreeAndNil(lItem);
  end;
end;

function TAdminResource.PostItemsBulk(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  lAdded: Integer;
begin
  RequireApp;
  lAdded := App.Store.AddItems(AId, ABody.GetValue<Integer>('customGroupId', 0),
    IntArrayFromJson(ABody, 'streamItemIds'));
  Result := TJSONObject.Create.AddPair('added', TJSONNumber.Create(lAdded));
end;

function TAdminResource.PostItemsReplace(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  lArr: TJSONArray;
  lValue: TJSONValue;
  lReplace: TItemStreamReplace;
  lReps: TArray<TItemStreamReplace>;
begin
  RequireApp;
  lReps := [];
  if ABody.GetValue('replacements') is TJSONArray then
  begin
    lArr := ABody.GetValue('replacements') as TJSONArray;
    for lValue in lArr do
      if lValue is TJSONObject then
      begin
        lReplace.ItemId := TJSONObject(lValue).GetValue<Integer>('itemId', 0);
        lReplace.StreamId := TJSONObject(lValue).GetValue<Integer>('streamId', 0);
        if (lReplace.ItemId > 0) and (lReplace.StreamId > 0) then
          lReps := lReps + [lReplace];
      end;
  end;
  Result := TJSONObject.Create.AddPair('replaced',
    TJSONNumber.Create(App.Store.ReplaceItemStreams(AId, lReps)));
end;

procedure TAdminResource.DeleteItem(AId: Integer);
begin
  RequireApp;
  App.Store.DeleteItem(AId);
end;

function TAdminResource.ClearGroupItems(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  lRemoved: Integer;
begin
  RequireApp;
  lRemoved := App.Store.ClearGroupItems(AId, ABody.GetValue<Integer>('customGroupId', 0));
  Result := TJSONObject.Create.AddPair('removed', TJSONNumber.Create(lRemoved));
end;

function TAdminResource.DedupeList(AId: Integer): TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create.AddPair('removed', TJSONNumber.Create(App.Store.DedupeListItems(AId)));
end;

function TAdminResource.SortGroup(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  lSorted: Integer;
begin
  RequireApp;
  lSorted := App.Store.SortGroupAlphabetically(AId, ABody.GetValue<Integer>('customGroupId', 0));
  Result := TJSONObject.Create.AddPair('sorted', TJSONNumber.Create(lSorted));
end;

function TAdminResource.ReorderGroup(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  lNumbered: Integer;
begin
  RequireApp;
  // body: { customGroupId, itemIds:[…] } — itemIds in the desired display order
  lNumbered := App.Store.ReorderGroupItems(AId, ABody.GetValue<Integer>('customGroupId', 0),
    IntArrayFromJson(ABody, 'itemIds'));
  Result := TJSONObject.Create.AddPair('numbered', TJSONNumber.Create(lNumbered));
end;

function TAdminResource.RenumberList(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  lArr: TJSONArray;
  lValue: TJSONValue;
  lNumber: TItemNumber;
  lNumbers: TArray<TItemNumber>;
begin
  RequireApp;
  lNumbers := [];
  if ABody.GetValue('numbers') is TJSONArray then
  begin
    lArr := ABody.GetValue('numbers') as TJSONArray;
    for lValue in lArr do
      if lValue is TJSONObject then
      begin
        lNumber.ItemId := TJSONObject(lValue).GetValue<Integer>('itemId', 0);
        lNumber.ChannelNumber := TJSONObject(lValue).GetValue<Integer>('channelNumber', 0);
        if lNumber.ItemId > 0 then
          lNumbers := lNumbers + [lNumber];
      end;
  end;
  Result := TJSONObject.Create.AddPair('numbered',
    TJSONNumber.Create(App.Store.SetItemNumbers(AId, lNumbers)));
end;

function TAdminResource.OrderGroups(AId: Integer; ABody: TJSONObject): TJSONObject;
begin
  RequireApp;
  // body: { groupIds:[…] } — group ids in the desired display order (drag result)
  Result := TJSONObject.Create.AddPair('ordered',
    TJSONNumber.Create(App.Store.ReorderGroups(AId, IntArrayFromJson(ABody, 'groupIds'))));
end;

function VariantsToJson(const AMatches: TArray<TVariantMatch>): TJSONArray;
var
  lMatch: TVariantMatch;
  lEntry: TJSONObject;
begin
  Result := TJSONArray.Create;
  for lMatch in AMatches do
  begin
    lEntry := TJSONObject.Create;
    lEntry.AddPair('itemId', TJSONNumber.Create(lMatch.ItemId));
    lEntry.AddPair('streamId', TJSONNumber.Create(lMatch.StreamId));
    lEntry.AddPair('name', lMatch.Name);
    lEntry.AddPair('quality', lMatch.Quality);
    lEntry.AddPair('candidateStreamId', TJSONNumber.Create(lMatch.CandidateStreamId));
    lEntry.AddPair('candidateName', lMatch.CandidateName);
    lEntry.AddPair('matched', TJSONBool.Create(lMatch.CandidateStreamId > 0));
    lEntry.AddPair('alreadyInList', TJSONBool.Create(lMatch.AlreadyInList));
    Result.AddElement(lEntry);
  end;
end;

function TAdminResource.GetGroupVariants(AId, AGroupId: Integer; AQuality: string): TJSONArray;
begin
  RequireApp;
  Result := VariantsToJson(App.Store.FindQualityVariants(AId, AGroupId, AQuality));
end;

function TAdminResource.GetGroupProviderVariants(AId, AGroupId, ASourceId: Integer): TJSONArray;
begin
  RequireApp;
  Result := VariantsToJson(App.Store.FindProviderVariants(AId, AGroupId, ASourceId));
end;

function TAdminResource.PostGroupRestrip(AId, AGroupId: Integer; ABody: TJSONObject): TJSONArray;
var
  lPrefixes, lSuffixes: TArray<string>;
  lChange: TNameChange;
  lEntry: TJSONObject;
begin
  RequireApp;
  lPrefixes := [];
  lSuffixes := [];
  if ABody.GetValue('extraPrefixes') is TJSONArray then
    lPrefixes := StrArrayFromJson(ABody.GetValue('extraPrefixes') as TJSONArray);
  if ABody.GetValue('extraSuffixes') is TJSONArray then
    lSuffixes := StrArrayFromJson(ABody.GetValue('extraSuffixes') as TJSONArray);
  Result := TJSONArray.Create;
  for lChange in App.Store.RestripGroupItems(AId, AGroupId, lPrefixes, lSuffixes,
    ABody.GetValue<Boolean>('dryRun', False)) do
  begin
    lEntry := TJSONObject.Create;
    lEntry.AddPair('itemId', TJSONNumber.Create(lChange.ItemId));
    lEntry.AddPair('oldName', lChange.OldName);
    lEntry.AddPair('newName', lChange.NewName);
    lEntry.AddPair('original', lChange.Original);
    Result.AddElement(lEntry);
  end;
end;

function TAdminResource.GetStreamVariants(AId: Integer; AAllSources: string;
  AListId: Integer): TJSONArray;
var
  lVariant: TStreamVariant;
  lEntry: TJSONObject;
begin
  RequireApp;
  Result := TJSONArray.Create;
  for lVariant in App.Store.FindStreamVariants(AId,
    IsTrue(AAllSources), AListId) do
  begin
    lEntry := TJSONObject.Create;
    lEntry.AddPair('streamId', TJSONNumber.Create(lVariant.StreamId));
    lEntry.AddPair('sourceId', TJSONNumber.Create(lVariant.SourceId));
    lEntry.AddPair('name', lVariant.Name);
    lEntry.AddPair('quality', lVariant.Quality);
    lEntry.AddPair('tvgId', lVariant.TvgId);
    lEntry.AddPair('groupTitle', lVariant.GroupTitle);
    lEntry.AddPair('isSelf', TJSONBool.Create(lVariant.IsSelf));
    lEntry.AddPair('matchedBy', lVariant.MatchedBy);
    lEntry.AddPair('onList', TJSONBool.Create(lVariant.OnList));
    Result.AddElement(lEntry);
  end;
end;

function TAdminResource.PostStreamProbe(AId, ASeconds: Integer): TJSONObject;
var
  lStream: TStreamItem;
  lProbe: TProbeResult;
  lUrl, lUserAgent, lReferer: string;
  lSrcId: Integer;
  lAudio: TProbeAudio;
  lArr: TJSONArray;
  lSources: TObjectList<TSourceConfig>;
  lSource: TSourceConfig;
begin
  RequireApp;
  lStream := App.Store.LoadStreamById(AId);
  if lStream = nil then
    raise EMARSHttpException.Create('stream not found', cHttpNotFound);
  try
    lUrl := lStream.UpstreamUrl;
    lSrcId := lStream.SourceId;
  finally
    FreeAndNil(lStream);
  end;
  // fetch like the source is configured: its own User-Agent / Referer, if set
  lUserAgent := '';
  lReferer := '';
  lSources := App.Store.LoadSources;
  try
    for lSource in lSources do
      if lSource.Id = lSrcId then
      begin
        lUserAgent := lSource.UserAgent;
        lReferer := lSource.Referer;
      end;
  finally
    FreeAndNil(lSources);
  end;
  if ASeconds <= 0 then
    ASeconds := cDefaultProbeSeconds;
  lProbe := ProbeStream(lUrl, ASeconds, lUserAgent, lReferer); // never raises; serialised inside
  Result := TJSONObject.Create;
  Result.AddPair('streamId', TJSONNumber.Create(AId));
  Result.AddPair('ok', TJSONBool.Create(lProbe.Ok));
  Result.AddPair('error', lProbe.Error);
  Result.AddPair('container', lProbe.Container);
  Result.AddPair('videoCodec', lProbe.VideoCodec);
  Result.AddPair('profile', lProbe.Profile);
  Result.AddPair('width', TJSONNumber.Create(lProbe.Width));
  Result.AddPair('height', TJSONNumber.Create(lProbe.Height));
  Result.AddPair('fps', TJSONNumber.Create(lProbe.Fps));
  Result.AddPair('interlaced', TJSONBool.Create(lProbe.Interlaced));
  Result.AddPair('bitDepth', TJSONNumber.Create(lProbe.BitDepth));
  lArr := TJSONArray.Create;
  for lAudio in lProbe.Audio do
    lArr.AddElement(TJSONObject.Create.AddPair('codec', lAudio.Codec).AddPair('language', lAudio.Language));
  Result.AddPair('audio', lArr);
  Result.AddPair('bitrateKbps', TJSONNumber.Create(lProbe.BitrateKbps));
  Result.AddPair('mediaSeconds', TJSONNumber.Create(RoundTo(lProbe.MediaSeconds, cProbeRoundDigits)));
  Result.AddPair('wallSeconds', TJSONNumber.Create(RoundTo(lProbe.WallSeconds, cProbeRoundDigits)));
  Result.AddPair('realtime', TJSONNumber.Create(RoundTo(lProbe.Realtime, cProbeRoundDigits)));
  Result.AddPair('firstByteMs', TJSONNumber.Create(lProbe.FirstByteMs));
  Result.AddPair('redirects', TJSONNumber.Create(lProbe.Redirects));
  Result.AddPair('bytes', TJSONNumber.Create(lProbe.Bytes));
end;

function TAdminResource.ExportM3U(AId: Integer): string;
begin
  RequireApp(cAllowQueryPassword); // a download link
  Response.SetHeader(cHeaderContentDisposition, Format(cAttachmentFmt, [cExportM3uFileName]));
  Result := BuildM3U(App.Store, AId);
end;

function TAdminResource.ExportXmltv(AId: Integer): string;
begin
  RequireApp(cAllowQueryPassword); // a download link
  Response.SetHeader(cHeaderContentDisposition, Format(cAttachmentFmt, [cExportXmltvFileName]));
  Result := BuildXmltv(App.Store, AId, App.Config.EpgMaxDays);
end;

initialization
  MARSRegister(TAdminResource);

end.
