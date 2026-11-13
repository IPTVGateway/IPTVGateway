unit IPTV.Api.Mars.Admin;

{ Admin REST API as a MARS-Curiosity resource, mounted at /api. This drives the
  React "merge / filter / rename / sort" workbench. Routing/(de)serialisation is
  MARS; all behaviour still lives in the core (reached via the global App).
  JSON shapes are produced by IPTV.Api.Serializers (camelCase). }

interface

uses
  System.JSON,
  MARS.Core.Attributes, MARS.Core.MediaType,
  MARS.Core.RequestAndResponse.Interfaces;

type
  [Path('api')]
  TAdminResource = class
  protected
    [Context] Response: IMARSResponse;
    [Context] Request: IMARSRequest;
    /// Guard run at the start of every handler: 503 if the service isn't up, and
    /// 401 if an admin password is configured but missing/wrong on the request.
    procedure RequireApp;
  public
    [GET, Path('health'), Produces(TMediaType.APPLICATION_JSON)]
    function Health: TJSONObject;

    // ── sources ──────────────────────────────────────────────────────────
    [GET, Path('sources'), Produces(TMediaType.APPLICATION_JSON)]
    function GetSources: TJSONArray;
    [POST, Path('sources'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostSource([BodyParam] ABody: TJSONObject): TJSONObject;
    [DELETE, Path('sources/{id}')]
    procedure DeleteSource([PathParam('id')] AId: Integer);
    [POST, Path('sources/{id}/refresh'), Produces(TMediaType.APPLICATION_JSON)]
    function RefreshSource([PathParam('id')] AId: Integer): TJSONObject;
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
    [POST, Path('refresh'), Produces(TMediaType.APPLICATION_JSON)]
    function RefreshAll: TJSONObject;
    // re-apply every source's strip-prefixes to all channels already on lists
    [POST, Path('restrip-prefixes'), Produces(TMediaType.APPLICATION_JSON)]
    function RestripPrefixes: TJSONObject;
    [GET, Path('refresh/status'), Produces(TMediaType.APPLICATION_JSON)]
    function GetRefreshStatus: TJSONArray;
    [POST, Path('epg/refresh'), Produces(TMediaType.APPLICATION_JSON)]
    function RefreshEpg: TJSONObject;

    // ── catalog ─────────────────────────────────────────────────────────
    [GET, Path('catalog/categories'), Produces(TMediaType.APPLICATION_JSON)]
    function GetCategories([QueryParam('sourceId')] ASourceId: Integer;
      [QueryParam('type')] AType: string; [QueryParam('onlyNew')] AOnlyNew: string;
      [QueryParam('search')] ASearch: string; [QueryParam('prefix')] APrefix: string;
      [QueryParam('includeHidden')] AIncludeHidden: string): TJSONArray;
    [GET, Path('catalog/streams'), Produces(TMediaType.APPLICATION_JSON)]
    function GetStreams([QueryParam('sourceId')] ASourceId: Integer;
      [QueryParam('type')] AType: string; [QueryParam('onlyNew')] AOnlyNew: string;
      [QueryParam('search')] ASearch: string; [QueryParam('prefix')] APrefix: string;
      [QueryParam('category')] ACategory: string;
      [QueryParam('limit')] ALimit: Integer; [QueryParam('offset')] AOffset: Integer;
      [QueryParam('includeHidden')] AIncludeHidden: string): TJSONArray;
    [GET, Path('catalog/streams/count'), Produces(TMediaType.APPLICATION_JSON)]
    function CountStreams([QueryParam('sourceId')] ASourceId: Integer;
      [QueryParam('type')] AType: string; [QueryParam('onlyNew')] AOnlyNew: string;
      [QueryParam('search')] ASearch: string; [QueryParam('prefix')] APrefix: string;
      [QueryParam('category')] ACategory: string;
      [QueryParam('includeHidden')] AIncludeHidden: string): TJSONObject;
    [POST, Path('catalog/categories/seen'), Consumes(TMediaType.APPLICATION_JSON)]
    procedure MarkCategoriesSeen([BodyParam] ABody: TJSONObject);
    [POST, Path('catalog/streams/seen'), Consumes(TMediaType.APPLICATION_JSON)]
    procedure MarkStreamsSeen([BodyParam] ABody: TJSONObject);

    // ── EPG ─────────────────────────────────────────────────────────────
    [GET, Path('epg'), Produces(TMediaType.APPLICATION_JSON)]
    function GetEpg([QueryParam('tvgId')] ATvgId: string): TJSONArray;

    // ── lists / groups / items ──────────────────────────────────────────
    [GET, Path('lists'), Produces(TMediaType.APPLICATION_JSON)]
    function GetLists: TJSONArray;
    [POST, Path('lists'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostList([BodyParam] ABody: TJSONObject): TJSONObject;
    [DELETE, Path('lists/{id}')]
    procedure DeleteList([PathParam('id')] AId: Integer);
    [GET, Path('lists/{id}/epg'), Produces(TMediaType.APPLICATION_JSON)]
    function GetListEpg([PathParam('id')] AId: Integer): TJSONArray;
    [GET, Path('lists/{id}/groups'), Produces(TMediaType.APPLICATION_JSON)]
    function GetGroups([PathParam('id')] AId: Integer): TJSONArray;
    [POST, Path('lists/{id}/groups'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostGroup([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    [DELETE, Path('groups/{id}')]
    procedure DeleteGroup([PathParam('id')] AId: Integer);
    [GET, Path('lists/{id}/items'), Produces(TMediaType.APPLICATION_JSON)]
    function GetItems([PathParam('id')] AId: Integer): TJSONArray;
    [POST, Path('lists/{id}/items'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostItem([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    [POST, Path('lists/{id}/items/bulk'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostItemsBulk([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    // swap the stream behind existing items in place (variant replace inside a
    // group). Body: { replacements: [ { itemId, streamId }, … ] } -> { replaced: n }
    [POST, Path('lists/{id}/items/replace'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function PostItemsReplace([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    [DELETE, Path('items/{id}')]
    procedure DeleteItem([PathParam('id')] AId: Integer);
    [POST, Path('lists/{id}/items/clear'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function ClearGroupItems([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    [POST, Path('lists/{id}/dedupe'), Produces(TMediaType.APPLICATION_JSON)]
    function DedupeList([PathParam('id')] AId: Integer): TJSONObject;
    [POST, Path('lists/{id}/groups/sort'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function SortGroup([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    [POST, Path('lists/{id}/groups/reorder'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function ReorderGroup([PathParam('id')] AId: Integer; [BodyParam] ABody: TJSONObject): TJSONObject;
    // set the manual drag-order of the list's GROUPS (body: { groupIds:[…] })
    [POST, Path('lists/{id}/groups/order'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
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
    [POST, Path('lists/{id}/groups/{gid}/restrip'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
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
    [GET, Path('config'), Produces(TMediaType.APPLICATION_JSON)]
    function GetConfig: TJSONObject;
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
    [GET, Path('export'), Produces(TMediaType.APPLICATION_JSON)]
    function ExportSettings: TJSONObject;
    [POST, Path('import'), Consumes(TMediaType.APPLICATION_JSON), Produces(TMediaType.APPLICATION_JSON)]
    function ImportSettings([BodyParam] ABody: TJSONObject): TJSONObject;

    // ── exports (downloads) ─────────────────────────────────────────────
    [GET, Path('lists/{id}/export.m3u'), Produces('application/x-mpegurl')]
    function ExportM3U([PathParam('id')] AId: Integer): string;
    [GET, Path('lists/{id}/export.xmltv'), Produces(TMediaType.APPLICATION_XML)]
    function ExportXmltv([PathParam('id')] AId: Integer): string;
  end;

implementation

uses
  System.SysUtils, System.Classes, System.Generics.Collections, System.IOUtils, System.Math,
  MARS.Core.Registry, MARS.Core.Exceptions,
  IPTV.Model.Types, IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Model.Epg,
  IPTV.Model.CustomList, IPTV.Storage.Intf, IPTV.App.Config, IPTV.App.Context, IPTV.Ingest.Service,
  IPTV.Api.Serializers, IPTV.Api.SettingsIO, IPTV.Output.Builder, IPTV.Core.Utils,
  IPTV.Plex.Client, IPTV.Source.Probe;

procedure TAdminResource.RequireApp;
var
  Pw: string;
begin
  if App = nil then
    raise Exception.Create('service not started');
  Pw := App.Config.AdminPassword;
  if Pw <> '' then
    // accept the password from a header (preferred) or a ?pw= query fallback
    if (Request.GetHeaderParamValue('X-Admin-Password') <> Pw) and
       (Request.GetQueryParamValue('pw') <> Pw) then
      raise EMARSHttpException.Create('Unauthorized', 401);
end;

function ParseIds(const ABody: TJSONObject): TArray<Integer>;
begin
  Result := IntArrayFromJson(ABody, 'ids');
end;

function IsTrue(const S: string): Boolean;
begin
  Result := (S = '1') or SameText(S, 'true');
end;

function MakeFilter(ASourceId: Integer; const AType, AOnlyNew, ASearch, APrefix, ACategory: string;
  ALimit: Integer = 0; AOffset: Integer = 0; AIncludeHidden: Boolean = False): TCatalogFilter;
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
  if ACategory <> '' then
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
  L: TObjectList<TSourceConfig>;
begin
  RequireApp;
  L := App.Store.LoadSources;
  try
    Result := SourcesToJson(L);
  finally
    L.Free;
  end;
end;

function TAdminResource.PostSource(ABody: TJSONObject): TJSONObject;
var
  S, Ex: TSourceConfig;
  Existing: TObjectList<TSourceConfig>;
  Id: Integer;
  OldStrip, OldStripSfx: TArray<string>;
  TooLong: string;
begin
  RequireApp;
  OldStrip := [];
  OldStripSfx := [];
  S := TSourceConfig.Create;
  try
    // For an update, pre-load the stored row so a PARTIAL body (e.g. just a
    // content-type toggle) doesn't blank out the other columns. SourceFromJson
    // then overrides only the fields the client actually sent.
    Id := ABody.GetValue<Integer>('id', 0);
    if Id > 0 then
    begin
      Existing := App.Store.LoadSources;
      try
        for Ex in Existing do
          if Ex.Id = Id then
          begin
            S.Assign(Ex);
            OldStrip := Ex.StripPrefixes; // remember to re-strip existing items if it changes
            OldStripSfx := Ex.StripSuffixes;
            Break;
          end;
      finally
        Existing.Free;
      end;
    end;
    SourceFromJson(ABody, S);
    // a name-filter item can't be a whole pasted list: refuse oversized items
    // (they used to reach SQLite as one giant LIKE pattern and fail every catalog
    // query) and split pasted multi-line items into separate tokens
    TooLong := FirstTooLongFilterToken(S.IncludeFilters + S.ExcludeFilters);
    if TooLong <> '' then
      raise EMARSHttpException.Create(Format(
        'Filter item too long (%d chars, max %d) — split it into separate items: "%s…"',
        [Length(TooLong), MaxFilterTokenLen, Copy(TooLong, 1, 40)]), 400);
    S.IncludeFilters := CleanFilterTokens(S.IncludeFilters);
    S.ExcludeFilters := CleanFilterTokens(S.ExcludeFilters);
    App.Store.SaveSource(S);
    // if a strip-prefix/suffix rule changed, re-clean already-added channel names
    // (auto-named items only; manual renames are preserved)
    if (Id > 0) and ((StrArrayToCsv(OldStrip, ';') <> StrArrayToCsv(S.StripPrefixes, ';')) or
       (StrArrayToCsv(OldStripSfx, ';') <> StrArrayToCsv(S.StripSuffixes, ';'))) then
      App.Store.RestripSourceItems(S.Id, OldStrip, OldStripSfx, S.StripPrefixes, S.StripSuffixes);
    Result := SourceToJson(S);
  finally
    S.Free;
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
  Arr: TArray<TIngestStatus>;
  St: TIngestStatus;
  O: TJSONObject;
begin
  RequireApp;
  Arr := App.Ingest.GetStatus;
  Result := TJSONArray.Create;
  for St in Arr do
  begin
    O := TJSONObject.Create;
    O.AddPair('sourceId', TJSONNumber.Create(St.SourceId));
    O.AddPair('running', TJSONBool.Create(St.Running));
    O.AddPair('startedUtc', DateTimeToIsoUtc(St.StartedUtc));
    O.AddPair('finishedUtc', DateTimeToIsoUtc(St.FinishedUtc));
    O.AddPair('streams', TJSONNumber.Create(St.Streams));
    O.AddPair('categories', TJSONNumber.Create(St.Categories));
    O.AddPair('programmes', TJSONNumber.Create(St.Programmes));
    O.AddPair('error', St.Error);
    Result.Add(O);
  end;
end;

function TAdminResource.GetSourcePrefixes(AId: Integer): TJSONArray;
var
  Prefixes: TArray<TPrefixCount>;
  P: TPrefixCount;
begin
  RequireApp;
  Prefixes := App.Store.DiscoverPrefixes(AId);
  Result := TJSONArray.Create;
  for P in Prefixes do
    Result.Add(TJSONObject.Create
      .AddPair('prefix', P.Prefix)
      .AddPair('count', TJSONNumber.Create(P.Count)));
end;

function TAdminResource.GetTvgIds: TJSONArray;
var
  Ids: TArray<TTvgIdInfo>;
  T: TTvgIdInfo;
begin
  RequireApp;
  Ids := App.Store.LoadKnownTvgIds;
  Result := TJSONArray.Create;
  for T in Ids do
    Result.Add(TJSONObject.Create
      .AddPair('tvgId', T.TvgId)
      .AddPair('name', T.Name));
end;

// The mounted language folder, next to the service exe: <exedir>/lang. Operators
// drop <code>.json dictionaries here (e.g. de.json) to add UI languages beyond
// the built-in en/nl that ship inside the frontend bundle.
function LangDir: string;
begin
  Result := TPath.Combine(ExtractFilePath(ParamStr(0)), 'lang');
  ForceDirectories(Result);
end;

function TAdminResource.GetLanguages: TJSONArray;
var
  FileName, Code, DisplayName: string;
  Val: TJSONValue;
  Name: TJSONObject;
begin
  RequireApp;
  Result := TJSONArray.Create;
  if not TDirectory.Exists(LangDir) then
    Exit;
  for FileName in TDirectory.GetFiles(LangDir, '*.json') do
  begin
    Code := TPath.GetFileNameWithoutExtension(FileName);
    DisplayName := Code;
    // the optional "_name" key gives a human label (e.g. "Deutsch"); fall back to code.
    // Parse to a TJSONValue and free it whatever its concrete type — a non-object
    // file (e.g. a JSON array) must not leak the parsed node.
    Val := nil;
    try
      Val := TJSONObject.ParseJSONValue(TFile.ReadAllText(FileName, TEncoding.UTF8));
      if (Val is TJSONObject) and (TJSONObject(Val).GetValue('_name') <> nil) then
        DisplayName := TJSONObject(Val).GetValue('_name').Value;
    except
      // malformed file → skip the label, keep the code
    end;
    Val.Free;
    Name := TJSONObject.Create;
    Name.AddPair('code', Code);
    Name.AddPair('name', DisplayName);
    Result.Add(Name);
  end;
end;

function TAdminResource.GetLanguage(ACode: string): TJSONObject;
var
  FileName: string;
  Val: TJSONValue;
begin
  RequireApp;
  // path-traversal guard: codes are simple identifiers, never paths
  if (ACode = '') or ACode.Contains('/') or ACode.Contains('\') or ACode.Contains('..') then
    raise EMARSHttpException.Create('Bad language code', 400);
  FileName := TPath.Combine(LangDir, ACode + '.json');
  if not TFile.Exists(FileName) then
    raise EMARSHttpException.Create('Unknown language', 404);
  // parse to a value first; a non-object (or unparseable) file must not leak
  Val := TJSONObject.ParseJSONValue(TFile.ReadAllText(FileName, TEncoding.UTF8));
  if not (Val is TJSONObject) then
  begin
    Val.Free; // nil-safe; frees a non-object value too
    raise EMARSHttpException.Create('Malformed language file', 500);
  end;
  Result := TJSONObject(Val);
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

function TAdminResource.GetCategories(ASourceId: Integer; AType, AOnlyNew, ASearch, APrefix, AIncludeHidden: string): TJSONArray;
var
  L: TCategoryList;
begin
  RequireApp;
  L := App.Store.LoadCategories(MakeFilter(ASourceId, AType, AOnlyNew, ASearch, APrefix, '', 0, 0, IsTrue(AIncludeHidden)));
  try
    Result := CategoriesToJson(L);
  finally
    L.Free;
  end;
end;

function TAdminResource.GetStreams(ASourceId: Integer; AType, AOnlyNew, ASearch, APrefix, ACategory: string;
  ALimit, AOffset: Integer; AIncludeHidden: string): TJSONArray;
var
  L: TStreamItemList;
begin
  RequireApp;
  L := App.Store.LoadStreams(MakeFilter(ASourceId, AType, AOnlyNew, ASearch, APrefix, ACategory,
    ALimit, AOffset, IsTrue(AIncludeHidden)));
  try
    Result := StreamsToJson(L);
  finally
    L.Free;
  end;
end;

function TAdminResource.CountStreams(ASourceId: Integer; AType, AOnlyNew, ASearch, APrefix, ACategory, AIncludeHidden: string): TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create.AddPair('count',
    TJSONNumber.Create(App.Store.CountStreams(MakeFilter(ASourceId, AType, AOnlyNew, ASearch, APrefix, ACategory,
      0, 0, IsTrue(AIncludeHidden)))));
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
  L: TEpgProgrammeList;
begin
  RequireApp;
  L := App.Store.LoadEpgForTvgIds([ATvgId], App.Config.EpgMaxDays);
  try
    Result := ProgrammesToJson(L);
  finally
    L.Free;
  end;
end;

function TAdminResource.GetLists: TJSONArray;
var
  L: TObjectList<TCustomList>;
begin
  RequireApp;
  L := App.Store.LoadLists;
  try
    Result := ListsToJson(L);
  finally
    L.Free;
  end;
end;

function TAdminResource.PostList(ABody: TJSONObject): TJSONObject;
var
  X, Ex: TCustomList;
  Existing: TObjectList<TCustomList>;
  Id: Integer;
begin
  RequireApp;
  X := TCustomList.Create;
  try
    // load-then-merge so a partial patch can't blank the other list fields
    Id := ABody.GetValue<Integer>('id', 0);
    if Id > 0 then
    begin
      Existing := App.Store.LoadLists;
      try
        for Ex in Existing do
          if Ex.Id = Id then
          begin
            X.Id := Ex.Id;
            X.Name := Ex.Name;
            X.OutputUsername := Ex.OutputUsername;
            X.OutputPassword := Ex.OutputPassword;
            X.Enabled := Ex.Enabled;
            Break;
          end;
      finally
        Existing.Free;
      end;
    end;
    ListFromJson(ABody, X);
    App.Store.SaveList(X);
    Result := ListToJson(X);
  finally
    X.Free;
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
  // read-only context (shown but not editable from the UI)
  Result.AddPair('httpPort', TJSONNumber.Create(App.Config.HttpPort));
  Result.AddPair('useHttps', TJSONBool.Create(App.Config.UseHttps));
  Result.AddPair('plexDeviceId', App.Config.PlexDeviceId);
end;

function TAdminResource.PostConfig(ABody: TJSONObject): TJSONObject;
var
  Groups: TArray<string>;
  GArr: TJSONValue;
  Base: string;
begin
  RequireApp;
  // default each field to its current value, so a partial body is fine
  App.UpdateSettings(
    ABody.GetValue<Integer>('refreshHour', App.Config.RefreshHour),
    ABody.GetValue<Integer>('refreshMinute', App.Config.RefreshMinute),
    ABody.GetValue<Boolean>('proxyStreams', App.Config.ProxyStreams),
    ABody.GetValue<Integer>('proxyPort', App.Config.ProxyPort),
    ABody.GetValue<Integer>('epgMaxDays', App.Config.EpgMaxDays),
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
  GArr := ABody.GetValue('visibleGroups');
  if GArr is TJSONArray then
    Groups := StrArrayFromJson(TJSONArray(GArr))
  else
    Groups := App.Config.VisibleGroups;
  Base := ABody.GetValue<string>('publicBaseUrl', App.Config.PublicBaseUrl).Trim;
  while Base.EndsWith('/') do
    Base := Base.Substring(0, Base.Length - 1);
  App.UpdateMediaConfig(Groups, Base,
    ABody.GetValue<Boolean>('dummyEpgEnabled', App.Config.DummyEpgEnabled),
    ABody.GetValue<Integer>('dummyEpgBlockMinutes', App.Config.DummyEpgBlockMinutes),
    ABody.GetValue<Integer>('dummyEpgHoursBack', App.Config.DummyEpgHoursBack),
    ABody.GetValue<Integer>('dummyEpgHoursAhead', App.Config.DummyEpgHoursAhead),
    ABody.GetValue<Boolean>('nameShowGroup', App.Config.NameShowGroup),
    ABody.GetValue<Boolean>('nameShowNumber', App.Config.NameShowNumber),
    ABody.GetValue<Boolean>('nameShowSource', App.Config.NameShowSource),
    ABody.GetValue<Boolean>('idSortPrefix', App.Config.IdSortPrefix));
  // extra (third-party) XMLTV guides: only when the body carries the field
  GArr := ABody.GetValue('extraEpgUrls');
  if GArr is TJSONArray then
    App.UpdateExtraEpgUrls(StrArrayFromJson(TJSONArray(GArr)));
  Result := GetConfig;
end;

function TAdminResource.PlexRescan: TJSONObject;
var
  Count: Integer;
begin
  RequireApp;
  try
    Count := ReloadPlexGuides(App.Config.PlexServerUrl, App.Config.PlexToken);
    App.MarkPlexRescanned; // clears the "rescan due" reminder
    App.Log(Format('Plex rescan: reloaded %d DVR(s)', [Count]));
    Result := TJSONObject.Create.AddPair('dvrs', TJSONNumber.Create(Count));
  except
    on E: Exception do
      raise EMARSHttpException.Create('Plex rescan failed: ' + E.Message, 400);
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
  Counts: TImportCounts;
  Cfg: TJSONObject;
begin
  RequireApp;
  if not ((ABody.GetValue('sources') is TJSONArray) or (ABody.GetValue('lists') is TJSONArray)) then
    raise EMARSHttpException.Create('Invalid import file (no "sources"/"lists")', 400);

  Counts := ImportStoreSettings(App.Store, ABody);

  if ABody.GetValue('config') is TJSONObject then
  begin
    Cfg := TJSONObject(ABody.GetValue('config'));
    App.UpdateSettings(
      Cfg.GetValue<Integer>('refreshHour', App.Config.RefreshHour),
      Cfg.GetValue<Integer>('refreshMinute', App.Config.RefreshMinute),
      Cfg.GetValue<Boolean>('proxyStreams', App.Config.ProxyStreams),
      Cfg.GetValue<Integer>('proxyPort', App.Config.ProxyPort),
      Cfg.GetValue<Integer>('epgMaxDays', App.Config.EpgMaxDays), // was dropped on import
      Cfg.GetValue<Boolean>('streamFailover', App.Config.StreamFailover));
    // the Plex tuner surfaces are part of the clone too — restore them as well
    App.UpdatePlexSettings(
      Cfg.GetValue<Boolean>('plexM3uEnabled', App.Config.PlexM3uEnabled),
      Cfg.GetValue<Boolean>('plexM3uProxy', App.Config.PlexM3uProxy),
      Cfg.GetValue<Boolean>('plexHdhrEnabled', App.Config.PlexHdhrEnabled),
      Cfg.GetValue<Boolean>('plexHdhrProxy', App.Config.PlexHdhrProxy),
      Cfg.GetValue<Integer>('plexTunerCount', App.Config.PlexTunerCount),
      Cfg.GetValue<string>('plexServerUrl', App.Config.PlexServerUrl),
      Cfg.GetValue<string>('plexToken', App.Config.PlexToken));
    // media servers: the global group filter + base URL + dummy-EPG settings
    if Cfg.GetValue('visibleGroups') is TJSONArray then
      App.UpdateMediaConfig(StrArrayFromJson(TJSONArray(Cfg.GetValue('visibleGroups'))),
        Cfg.GetValue<string>('publicBaseUrl', App.Config.PublicBaseUrl),
        Cfg.GetValue<Boolean>('dummyEpgEnabled', App.Config.DummyEpgEnabled),
        Cfg.GetValue<Integer>('dummyEpgBlockMinutes', App.Config.DummyEpgBlockMinutes),
        Cfg.GetValue<Integer>('dummyEpgHoursBack', App.Config.DummyEpgHoursBack),
        Cfg.GetValue<Integer>('dummyEpgHoursAhead', App.Config.DummyEpgHoursAhead),
        Cfg.GetValue<Boolean>('nameShowGroup', App.Config.NameShowGroup),
        Cfg.GetValue<Boolean>('nameShowNumber', App.Config.NameShowNumber),
        Cfg.GetValue<Boolean>('nameShowSource', App.Config.NameShowSource),
        Cfg.GetValue<Boolean>('idSortPrefix', App.Config.IdSortPrefix));
  end;

  Result := TJSONObject.Create;
  Result.AddPair('sources', TJSONNumber.Create(Counts.Sources));
  Result.AddPair('lists', TJSONNumber.Create(Counts.Lists));
  Result.AddPair('groups', TJSONNumber.Create(Counts.Groups));
  Result.AddPair('items', TJSONNumber.Create(Counts.Items));
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
  L: TCustomList;
  Channels: TOutputChannelList;
  C: TOutputChannel;
  Counts: TDictionary<string, Integer>;
  Names: TStringList;
  N, I: Integer;
begin
  RequireApp;
  Result := TJSONArray.Create;
  L := ServedListForMedia;
  if L = nil then
    Exit;
  Counts := TDictionary<string, Integer>.Create;
  Names := TStringList.Create;
  try
    Names.Sorted := True;
    Names.Duplicates := dupIgnore;
    Names.CaseSensitive := False;
    Channels := App.Store.LoadOutputChannels(L.Id);
    try
      for C in Channels do
      begin
        if not Counts.TryGetValue(C.GroupName, N) then
        begin
          N := 0;
          Names.Add(C.GroupName);
        end;
        Counts.AddOrSetValue(C.GroupName, N + 1);
      end;
    finally
      Channels.Free;
    end;
    for I := 0 to Names.Count - 1 do
      Result.Add(TJSONObject.Create
        .AddPair('name', Names[I])
        .AddPair('channels', TJSONNumber.Create(Counts[Names[I]])));
  finally
    Counts.Free;
    Names.Free;
    L.Free;
  end;
end;

function TAdminResource.GetLogs(ASince: string): TJSONObject;
var
  Lines: TArray<TLogLine>;
  L: TLogLine;
  Arr: TJSONArray;
  O: TJSONObject;
  Last: Int64;
begin
  // no RequireApp: the log is most useful exactly when the app failed to start
  Result := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Last := StrToInt64Def(ASince, 0);
  if LogRing <> nil then
  begin
    Lines := LogRing.Since(Last);
    for L in Lines do
    begin
      O := TJSONObject.Create;
      O.AddPair('seq', TJSONNumber.Create(L.Seq));
      O.AddPair('t', DateTimeToIsoUtc(L.TimeUtc));
      O.AddPair('text', L.Text);
      Arr.Add(O);
      Last := L.Seq;
    end;
  end;
  Result.AddPair('next', TJSONNumber.Create(Last));
  Result.AddPair('lines', Arr);
end;

function TAdminResource.GetMediaStatus: TJSONObject;
var
  L: TCustomList;
  Channels: TOutputChannelList;
  C: TOutputChannel;
  Ids: TStringList;
  GotEpg: TStringList;
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  Total, Real_, I: Integer;
  HasReal: Boolean;
  Eff: string;
begin
  RequireApp;
  Result := TJSONObject.Create;
  Total := 0; Real_ := 0;
  L := ServedListForMedia;
  if L <> nil then
  try
    // the channels actually published under the current global group filter
    Channels := SelectOutputChannels(App.Store, L.Id, App.Config.VisibleGroups);
    Ids := TStringList.Create;
    GotEpg := TStringList.Create;
    try
      Ids.Sorted := True; Ids.Duplicates := dupIgnore;
      GotEpg.Sorted := True; GotEpg.Duplicates := dupIgnore;
      for C in Channels do
        for Eff in C.EpgReadIds do
          Ids.Add(Eff);
      Progs := App.Store.LoadEpgForTvgIds(Ids.ToStringArray, 0);
      try
        for I := 0 to Progs.Count - 1 do
          GotEpg.Add(Progs[I].ChannelTvgId);
      finally
        Progs.Free;
      end;
      Total := Channels.Count;
      for C in Channels do
      begin
        HasReal := False;
        for Eff in C.EpgReadIds do
          if GotEpg.IndexOf(Eff) >= 0 then
            HasReal := True;
        if HasReal then
          Inc(Real_);
      end;
    finally
      Ids.Free;
      GotEpg.Free;
      Channels.Free;
    end;
  finally
    L.Free;
  end;
  Result.AddPair('channels', TJSONNumber.Create(Total));
  Result.AddPair('realEpg', TJSONNumber.Create(Real_));
  Result.AddPair('dummyEpg', TJSONNumber.Create(Total - Real_));
end;

function TAdminResource.ResetDeviceId: TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create.AddPair('deviceId', App.ResetPlexDeviceId);
end;

function TAdminResource.GetListEpg(AId: Integer): TJSONArray;
var
  Channels: TOutputChannelList;
  C: TOutputChannel;
  Upstreams: TStringList;
  EffById: TDictionary<string, string>; // upstream tvg-id -> effective (override) id
  Progs: TEpgProgrammeList;
  P: TEpgProgramme;
  Eff: string;
begin
  RequireApp;
  Upstreams := TStringList.Create;
  Upstreams.Sorted := True;
  Upstreams.Duplicates := dupIgnore;
  EffById := TDictionary<string, string>.Create;
  try
    Channels := App.Store.LoadOutputChannels(AId);
    try
      // fetch EPG by UPSTREAM id (where the provider's programmes are stored), and
      // remember the effective (override) id to re-key them to on the way out
      for C in Channels do
        if C.TvgId <> '' then
          for Eff in C.EpgReadIds do
          begin
            Upstreams.Add(Eff);
            EffById.AddOrSetValue(Eff, C.TvgId);
          end;
    finally
      Channels.Free;
    end;
    Progs := App.Store.LoadEpgForTvgIds(Upstreams.ToStringArray, App.Config.EpgMaxDays);
    try
      for P in Progs do
        if EffById.TryGetValue(P.ChannelTvgId, Eff) then
          P.ChannelTvgId := Eff;
      Result := ProgrammesToJson(Progs);
    finally
      Progs.Free;
    end;
  finally
    Upstreams.Free;
    EffById.Free;
  end;
end;

function TAdminResource.GetGroups(AId: Integer): TJSONArray;
var
  L: TCustomGroupList;
begin
  RequireApp;
  L := App.Store.LoadGroups(AId);
  try
    Result := GroupsToJson(L);
  finally
    L.Free;
  end;
end;

function TAdminResource.PostGroup(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  G, Ex: TCustomGroup;
  Existing: TCustomGroupList;
  Id: Integer;
begin
  RequireApp;
  G := TCustomGroup.Create;
  try
    // load-then-merge for an update: a PARTIAL patch (e.g. just the favorite
    // star, or just a rename) must not blank the group's other fields.
    Id := ABody.GetValue<Integer>('id', 0);
    if Id > 0 then
    begin
      Existing := App.Store.LoadGroups(AId);
      try
        for Ex in Existing do
          if Ex.Id = Id then
          begin
            G.Id := Ex.Id;
            G.ListId := Ex.ListId;
            G.Name := Ex.Name;
            G.ContentType := Ex.ContentType;
            G.IsFavorite := Ex.IsFavorite;
            Break;
          end;
      finally
        Existing.Free;
      end;
    end;
    GroupFromJson(ABody, G); // overrides only the fields the client actually sent
    G.ListId := AId;
    App.Store.SaveGroup(G);
    Result := GroupToJson(G);
  finally
    G.Free;
  end;
end;

procedure TAdminResource.DeleteGroup(AId: Integer);
begin
  RequireApp;
  App.Store.DeleteGroup(AId);
end;

function TAdminResource.GetItems(AId: Integer): TJSONArray;
var
  L: TCustomItemList;
begin
  RequireApp;
  L := App.Store.LoadItems(AId);
  try
    Result := ItemsToJson(L);
  finally
    L.Free;
  end;
end;

function TAdminResource.PostItem(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  I, Ex: TCustomItem;
  Existing: TCustomItemList;
  Id: Integer;
begin
  RequireApp;
  I := TCustomItem.Create;
  try
    // load-then-merge: a partial patch must not reset channel_number / move the
    // item to the upstream group (custom_group_id) etc.
    Id := ABody.GetValue<Integer>('id', 0);
    if Id > 0 then
    begin
      Existing := App.Store.LoadItems(AId);
      try
        for Ex in Existing do
          if Ex.Id = Id then
          begin
            I.Id := Ex.Id;
            I.ListId := Ex.ListId;
            I.StreamItemId := Ex.StreamItemId;
            I.CustomGroupId := Ex.CustomGroupId;
            I.ContentType := Ex.ContentType;
            I.DisplayName := Ex.DisplayName;
            I.LogoOverride := Ex.LogoOverride;
            I.TvgIdOverride := Ex.TvgIdOverride;
            I.ChannelNumber := Ex.ChannelNumber;
            Break;
          end;
      finally
        Existing.Free;
      end;
    end;
    ItemFromJson(ABody, I);
    I.ListId := AId;
    App.Store.SaveItem(I);
    Result := ItemToJson(I);
  finally
    I.Free;
  end;
end;

function TAdminResource.PostItemsBulk(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  Added: Integer;
begin
  RequireApp;
  Added := App.Store.AddItems(AId, ABody.GetValue<Integer>('customGroupId', 0),
    IntArrayFromJson(ABody, 'streamItemIds'));
  Result := TJSONObject.Create.AddPair('added', TJSONNumber.Create(Added));
end;

function TAdminResource.PostItemsReplace(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  Arr: TJSONArray;
  V: TJSONValue;
  R: TItemStreamReplace;
  Reps: TArray<TItemStreamReplace>;
begin
  RequireApp;
  Reps := [];
  if ABody.GetValue('replacements') is TJSONArray then
  begin
    Arr := ABody.GetValue('replacements') as TJSONArray;
    for V in Arr do
      if V is TJSONObject then
      begin
        R.ItemId := TJSONObject(V).GetValue<Integer>('itemId', 0);
        R.StreamId := TJSONObject(V).GetValue<Integer>('streamId', 0);
        if (R.ItemId > 0) and (R.StreamId > 0) then
          Reps := Reps + [R];
      end;
  end;
  Result := TJSONObject.Create.AddPair('replaced',
    TJSONNumber.Create(App.Store.ReplaceItemStreams(AId, Reps)));
end;

procedure TAdminResource.DeleteItem(AId: Integer);
begin
  RequireApp;
  App.Store.DeleteItem(AId);
end;

function TAdminResource.ClearGroupItems(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  Removed: Integer;
begin
  RequireApp;
  Removed := App.Store.ClearGroupItems(AId, ABody.GetValue<Integer>('customGroupId', 0));
  Result := TJSONObject.Create.AddPair('removed', TJSONNumber.Create(Removed));
end;

function TAdminResource.DedupeList(AId: Integer): TJSONObject;
begin
  RequireApp;
  Result := TJSONObject.Create.AddPair('removed', TJSONNumber.Create(App.Store.DedupeListItems(AId)));
end;

function TAdminResource.SortGroup(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  Sorted: Integer;
begin
  RequireApp;
  Sorted := App.Store.SortGroupAlphabetically(AId, ABody.GetValue<Integer>('customGroupId', 0));
  Result := TJSONObject.Create.AddPair('sorted', TJSONNumber.Create(Sorted));
end;

function TAdminResource.ReorderGroup(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  Numbered: Integer;
begin
  RequireApp;
  // body: { customGroupId, itemIds:[…] } — itemIds in the desired display order
  Numbered := App.Store.ReorderGroupItems(AId, ABody.GetValue<Integer>('customGroupId', 0),
    IntArrayFromJson(ABody, 'itemIds'));
  Result := TJSONObject.Create.AddPair('numbered', TJSONNumber.Create(Numbered));
end;

function TAdminResource.RenumberList(AId: Integer; ABody: TJSONObject): TJSONObject;
var
  Arr: TJSONArray;
  V: TJSONValue;
  N: TItemNumber;
  L: TArray<TItemNumber>;
begin
  RequireApp;
  L := [];
  if ABody.GetValue('numbers') is TJSONArray then
  begin
    Arr := ABody.GetValue('numbers') as TJSONArray;
    for V in Arr do
      if V is TJSONObject then
      begin
        N.ItemId := TJSONObject(V).GetValue<Integer>('itemId', 0);
        N.ChannelNumber := TJSONObject(V).GetValue<Integer>('channelNumber', 0);
        if N.ItemId > 0 then
          L := L + [N];
      end;
  end;
  Result := TJSONObject.Create.AddPair('numbered',
    TJSONNumber.Create(App.Store.SetItemNumbers(AId, L)));
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
  M: TVariantMatch;
  O: TJSONObject;
begin
  Result := TJSONArray.Create;
  for M in AMatches do
  begin
    O := TJSONObject.Create;
    O.AddPair('itemId', TJSONNumber.Create(M.ItemId));
    O.AddPair('streamId', TJSONNumber.Create(M.StreamId));
    O.AddPair('name', M.Name);
    O.AddPair('quality', M.Quality);
    O.AddPair('candidateStreamId', TJSONNumber.Create(M.CandidateStreamId));
    O.AddPair('candidateName', M.CandidateName);
    O.AddPair('matched', TJSONBool.Create(M.CandidateStreamId > 0));
    O.AddPair('alreadyInList', TJSONBool.Create(M.AlreadyInList));
    Result.AddElement(O);
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
  Pfx, Sfx: TArray<string>;
  C: TNameChange;
  O: TJSONObject;
begin
  RequireApp;
  Pfx := [];
  Sfx := [];
  if ABody.GetValue('extraPrefixes') is TJSONArray then
    Pfx := StrArrayFromJson(ABody.GetValue('extraPrefixes') as TJSONArray);
  if ABody.GetValue('extraSuffixes') is TJSONArray then
    Sfx := StrArrayFromJson(ABody.GetValue('extraSuffixes') as TJSONArray);
  Result := TJSONArray.Create;
  for C in App.Store.RestripGroupItems(AId, AGroupId, Pfx, Sfx,
    ABody.GetValue<Boolean>('dryRun', False)) do
  begin
    O := TJSONObject.Create;
    O.AddPair('itemId', TJSONNumber.Create(C.ItemId));
    O.AddPair('oldName', C.OldName);
    O.AddPair('newName', C.NewName);
    O.AddPair('original', C.Original);
    Result.AddElement(O);
  end;
end;

function TAdminResource.GetStreamVariants(AId: Integer; AAllSources: string;
  AListId: Integer): TJSONArray;
var
  V: TStreamVariant;
  O: TJSONObject;
begin
  RequireApp;
  Result := TJSONArray.Create;
  for V in App.Store.FindStreamVariants(AId,
    SameText(AAllSources, '1') or SameText(AAllSources, 'true'), AListId) do
  begin
    O := TJSONObject.Create;
    O.AddPair('streamId', TJSONNumber.Create(V.StreamId));
    O.AddPair('sourceId', TJSONNumber.Create(V.SourceId));
    O.AddPair('name', V.Name);
    O.AddPair('quality', V.Quality);
    O.AddPair('tvgId', V.TvgId);
    O.AddPair('groupTitle', V.GroupTitle);
    O.AddPair('isSelf', TJSONBool.Create(V.IsSelf));
    O.AddPair('matchedBy', V.MatchedBy);
    O.AddPair('onList', TJSONBool.Create(V.OnList));
    Result.AddElement(O);
  end;
end;

function TAdminResource.PostStreamProbe(AId, ASeconds: Integer): TJSONObject;
var
  S: TStreamItem;
  R: TProbeResult;
  Url, Ua, Ref: string;
  SrcId: Integer;
  A: TProbeAudio;
  Arr: TJSONArray;
  Srcs: TObjectList<TSourceConfig>;
  Src: TSourceConfig;
begin
  RequireApp;
  S := App.Store.LoadStreamById(AId);
  if S = nil then
    raise EMARSHttpException.Create('stream not found', 404);
  try
    Url := S.UpstreamUrl;
    SrcId := S.SourceId;
  finally
    S.Free;
  end;
  // fetch like the source is configured: its own User-Agent / Referer, if set
  Ua := '';
  Ref := '';
  Srcs := App.Store.LoadSources;
  try
    for Src in Srcs do
      if Src.Id = SrcId then
      begin
        Ua := Src.UserAgent;
        Ref := Src.Referer;
      end;
  finally
    Srcs.Free;
  end;
  if ASeconds <= 0 then
    ASeconds := 8;
  R := ProbeStream(Url, ASeconds, Ua, Ref); // never raises; serialised inside
  Result := TJSONObject.Create;
  Result.AddPair('streamId', TJSONNumber.Create(AId));
  Result.AddPair('ok', TJSONBool.Create(R.Ok));
  Result.AddPair('error', R.Error);
  Result.AddPair('container', R.Container);
  Result.AddPair('videoCodec', R.VideoCodec);
  Result.AddPair('profile', R.Profile);
  Result.AddPair('width', TJSONNumber.Create(R.Width));
  Result.AddPair('height', TJSONNumber.Create(R.Height));
  Result.AddPair('fps', TJSONNumber.Create(R.Fps));
  Result.AddPair('interlaced', TJSONBool.Create(R.Interlaced));
  Result.AddPair('bitDepth', TJSONNumber.Create(R.BitDepth));
  Arr := TJSONArray.Create;
  for A in R.Audio do
    Arr.AddElement(TJSONObject.Create.AddPair('codec', A.Codec).AddPair('language', A.Language));
  Result.AddPair('audio', Arr);
  Result.AddPair('bitrateKbps', TJSONNumber.Create(R.BitrateKbps));
  Result.AddPair('mediaSeconds', TJSONNumber.Create(RoundTo(R.MediaSeconds, -2)));
  Result.AddPair('wallSeconds', TJSONNumber.Create(RoundTo(R.WallSeconds, -2)));
  Result.AddPair('realtime', TJSONNumber.Create(RoundTo(R.Realtime, -2)));
  Result.AddPair('firstByteMs', TJSONNumber.Create(R.FirstByteMs));
  Result.AddPair('redirects', TJSONNumber.Create(R.Redirects));
  Result.AddPair('bytes', TJSONNumber.Create(R.Bytes));
end;

function TAdminResource.ExportM3U(AId: Integer): string;
begin
  RequireApp;
  Response.SetHeader('Content-Disposition', 'attachment; filename="playlist.m3u"');
  Result := BuildM3U(App.Store, AId);
end;

function TAdminResource.ExportXmltv(AId: Integer): string;
begin
  RequireApp;
  Response.SetHeader('Content-Disposition', 'attachment; filename="epg.xml"');
  Result := BuildXmltv(App.Store, AId, App.Config.EpgMaxDays);
end;

initialization
  MARSRegister(TAdminResource);

end.
