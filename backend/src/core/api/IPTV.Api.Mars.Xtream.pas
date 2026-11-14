unit IPTV.Api.Mars.Xtream;

{ Outgoing Xtream Codes portal emulation as MARS resources, mounted at the root
  so an IPTV box reaches /player_api.php, /get.php, /xmltv.php and the stream
  paths directly. Credentials are optional (empty -> default list). Video never
  flows through us: stream endpoints 302-redirect to the upstream URL and get.php
  embeds raw upstream URLs. Ordering is the store's canonical order. }

interface

uses
  // RTL
  System.JSON,
  // third-party
  MARS.Core.Attributes,
  MARS.Core.MediaType,
  MARS.Core.RequestAndResponse.Interfaces;

type
  /// <summary>Xtream player_api.php: account info, categories, streams, EPG, VOD/series info.</summary>
  [Path('player_api.php')]
  TPlayerApiResource = class
  protected
    [Context] Response: IMARSResponse;
    [Context] Request: IMARSRequest;
  public
    /// <summary>Dispatches on the Xtream action (empty = account info).</summary>
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function PlayerApi([QueryParam('username')] AUser: string;
      [QueryParam('password')] APass: string;
      [QueryParam('action')] AAction: string;
      [QueryParam('stream_id')] AStreamId: string;
      [QueryParam('limit')] ALimit: string; // string: boxes send 'limit=' empty (MARS 2 would 400)
      [QueryParam('vod_id')] AVodId: string;
      [QueryParam('series_id')] ASeriesId: string;
      [QueryParam('category_id')] ACategoryId: string): TJSONValue;
  end;

  /// <summary>Xtream get.php: the list as an M3U playlist.</summary>
  [Path('get.php')]
  TGetPhpResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    /// <summary>M3U of the authenticated list (raw upstream or relay URLs).</summary>
    [GET, Produces('application/x-mpegurl')]
    function GetPhp([QueryParam('username')] AUser: string;
      [QueryParam('password')] APass: string): string;
  end;

  /// <summary>Xtream xmltv.php: the list's own XMLTV guide.</summary>
  [Path('xmltv.php')]
  TXmltvResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    /// <summary>XMLTV restricted to the channels on the authenticated list.</summary>
    [GET, Produces(TMediaType.APPLICATION_XML)]
    function Xmltv([QueryParam('username')] AUser: string;
      [QueryParam('password')] APass: string): string;
  end;

  // live|movie|series/{user}/{pass}/{id} -> 302 redirect to the upstream URL
  [Path('live')]
  TLiveStreamResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    /// <summary>302 to the stream's upstream URL (or the relay in proxy mode).</summary>
    [GET, Path('{user}/{pass}/{id}')]
    procedure Redirect([PathParam('user')] AUser: string;
      [PathParam('pass')] APass: string; [PathParam('id')] AId: string);
  end;

  /// <summary>movie/{user}/{pass}/{id}: 302 to the upstream movie URL.</summary>
  [Path('movie')]
  TMovieStreamResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    /// <summary>302 to the stream's upstream URL (or the relay in proxy mode).</summary>
    [GET, Path('{user}/{pass}/{id}')]
    procedure Redirect([PathParam('user')] AUser: string;
      [PathParam('pass')] APass: string; [PathParam('id')] AId: string);
  end;

  /// <summary>series/{user}/{pass}/{id}: 302 to the upstream episode URL.</summary>
  [Path('series')]
  TSeriesStreamResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    /// <summary>302 to the stream's upstream URL (or the relay in proxy mode).</summary>
    [GET, Path('{user}/{pass}/{id}')]
    procedure Redirect([PathParam('user')] AUser: string;
      [PathParam('pass')] APass: string; [PathParam('id')] AId: string);
  end;

  // catch-up: timeshift/{user}/{pass}/{minutes}/{YYYY-MM-DD:HH-MM}/{id}.ts
  // -> 302 to the provider's own timeshift URL (start shifted to its clock)
  [Path('timeshift')]
  TTimeshiftResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    /// <summary>302 to the provider's timeshift URL (or the relay in proxy mode).</summary>
    [GET, Path('{user}/{pass}/{duration}/{start}/{id}')]
    procedure Redirect([PathParam('user')] AUser: string;
      [PathParam('pass')] APass: string; [PathParam('duration')] ADuration: string;
      [PathParam('start')] AStart: string; [PathParam('id')] AId: string);
  end;

  // the query-string flavour some players use:
  // streaming/timeshift.php?username=&password=&stream=&start=&duration=
  [Path('streaming')]
  TTimeshiftPhpResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    /// <summary>Query-string variant of the timeshift redirect.</summary>
    [GET, Path('timeshift.php')]
    procedure Redirect([QueryParam('username')] AUser: string;
      [QueryParam('password')] APass: string; [QueryParam('stream')] AStream: string;
      [QueryParam('start')] AStart: string; [QueryParam('duration')] ADuration: string);
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Generics.Collections,
  System.Generics.Defaults,
  System.StrUtils,
  System.Math,
  System.RegularExpressions,
  System.Net.URLClient,
  System.NetEncoding,
  System.DateUtils,
  System.Hash,
  // third-party
  MARS.Core.Registry,
  // own units
  IPTV.Model.Types,
  IPTV.Model.Catalog,
  IPTV.Model.Epg,
  IPTV.Model.CustomList,
  IPTV.Model.Source,
  IPTV.Storage.Intf,
  IPTV.App.Context,
  IPTV.Output.Builder,
  IPTV.Core.Utils,
  IPTV.Source.Xtream,
  IPTV.Api.AuthThrottle,
  IPTV.Api.Serializers;

const
  // player_api.php actions
  cActGetAccountInfo = 'get_account_info';
  cActGetLiveCategories = 'get_live_categories';
  cActGetLiveStreams = 'get_live_streams';
  cActGetVodCategories = 'get_vod_categories';
  cActGetVodStreams = 'get_vod_streams';
  cActGetSeriesCategories = 'get_series_categories';
  cActGetSeries = 'get_series';
  cActGetShortEpg = 'get_short_epg';
  cActGetSimpleDataTable = 'get_simple_data_table';
  cActGetVodInfo = 'get_vod_info';
  cActGetSeriesInfo = 'get_series_info';

  // Xtream stream_type values
  cStreamTypeLive = 'live';
  cStreamTypeMovie = 'movie';
  cStreamTypeSeries = 'series';
  cStreamTypeRadio = 'radio_streams'; // how real portals list radio

  // JSON fields that are passed around / compared, not just written
  cFieldStreamId = 'stream_id';
  cFieldSeriesId = 'series_id';
  cFieldCategoryId = 'category_id';
  // a panel's full provider URL (with its credentials): never handed to a box
  cFieldDirectSource = 'direct_source';

  // containers
  cExtTs = 'ts';
  cExtM3u8 = 'm3u8';
  cDefaultVodExt = 'mp4'; // a movie/episode URL without an extension

  // URL schemes
  cSchemeHttp = 'http';
  cSchemeHttps = 'https';
  cIgnoreCase = True; // string.StartsWith IgnoreCase

  // we advertise UTC, so a box sends timeshift starts in UTC (see DoTimeshift)
  cServerTimezone = 'UTC';

  cMaxCategoryId = 999999999; // positive and well inside a 32-bit int for every client

  // EPG listings (get_short_epg / get_simple_data_table)
  cShortEpgDefaultLimit = 4; // programmes when the box sends no (or an empty) limit
  cNoEpgLimit = 0;
  cOnlyFuture = True;  // BuildEpgListings AOnlyFuture: skip finished programmes
  cWithPast = False;   // ... keep them (the full table)
  cEpgDateTimeFormat = 'yyyy-mm-dd hh:nn:ss';
  cTimesAreUtc = True; // DateTimeToUnix AInputIsUTC

  // PlayerApiResult.Pick AWantCats
  cWantCategories = True;
  cWantStreams = False;

  // the one season/episode an M3U "series" item is offered as
  cM3uSeason = 1;
  cM3uEpisode = 1;

  // DoRedirect ALive: follow the box's requested container (.ts/.m3u8)
  cLiveStream = True;

  // BuildM3U ASequentialChno: a box keeps the bouquet's own channel numbers
  cBouquetChno = False;

{ ── shared helpers ──────────────────────────────────────────────────────── }

// The service isn't running (starting / stopping, App = nil): answer 503, so a
// box with a correct login neither sees "wrong password" nor counts as a failure.
function ServiceDown(const AResponse: IMARSResponse): Boolean;
begin
  Result := App = nil;
  if Result then
    AResponse.StatusCode := cHttpServiceUnavailable;
end;

// Resolve the list a box authenticates as (empty creds -> default). Caller frees;
// nil = wrong login. Callers check ServiceDown first (App = nil is not a bad login).
function ResolveList(const AUser, APass: string): TCustomList;
begin
  if App = nil then
    Exit(nil);
  // also understands the '-' placeholder and percent-encoding of our own URLs
  Result := FindListForPath(App.Store, AUser, APass);
end;

// a panel's direct_source (the provider URL with its credentials) blanked: in proxy
// mode a box that prefers it would bypass the relay, and it leaks the provider login
procedure BlankDirectSource(const AObject: TJSONObject);
begin
  if AObject.GetValue(cFieldDirectSource) = nil then
    Exit;
  AObject.RemovePair(cFieldDirectSource).Free;
  AObject.AddPair(cFieldDirectSource, '');
end;

// host the box reaches us on (publicBaseUrl; 'localhost' when unset/unparseable)
function PublicHost: string;
begin
  Result := SafeUrlHost(App.Config.PublicBaseUrl, cDefaultPublicHost);
end;

function PublicScheme: string;
begin
  if App.Config.PublicBaseUrl.StartsWith(cSchemeHttps + ':', cIgnoreCase) then
    Result := cSchemeHttps
  else
    Result := cSchemeHttp;
end;

function StreamIdFromParam(const AId: string): Integer;
var
  lValue: string;
  lDot: Integer;
begin
  lValue := AId;
  lDot := lValue.IndexOf('.');
  if lDot >= 0 then
    lValue := lValue.Substring(0, lDot);
  Result := StrToIntDef(lValue, 0);
end;

// the container the box asked for (the bit after the last dot in ":id"), '' if none
function RequestedExt(const AId: string): string;
var
  lDot: Integer;
begin
  lDot := AId.LastIndexOf('.');
  if lDot >= 0 then
    Result := AId.Substring(lDot + 1)
  else
    Result := '';
end;

// user_info.username/password the box builds its stream URLs from (some clients
// take them from here, not from what was typed): '-' for an empty login, which
// FindListForPath maps back
function BoxCred(const AValue: string): string;
begin
  if AValue = '' then
    Result := PathCred('')
  else
    Result := AValue;
end;

function AccountInfo(const AList: TCustomList): TJSONObject;
var
  lUserInfo, lServerInfo: TJSONObject;
  lFormats: TJSONArray;
  lPortNo: Integer;
begin
  Result := TJSONObject.Create;
  lUserInfo := TJSONObject.Create;
  // the fields real panels send; some clients refuse an account without them
  lUserInfo.AddPair('username', BoxCred(AList.OutputUsername));
  lUserInfo.AddPair('password', BoxCred(AList.OutputPassword));
  lUserInfo.AddPair('message', '');
  lUserInfo.AddPair('auth', TJSONNumber.Create(1));
  lUserInfo.AddPair('status', 'Active');
  lUserInfo.AddPair('exp_date', TJSONNull.Create); // no end date
  lUserInfo.AddPair('created_at', '0');
  lUserInfo.AddPair('is_trial', '0');
  lUserInfo.AddPair('active_cons', '0');
  lUserInfo.AddPair('max_connections', '1');
  // m3u8 first: boxes (e.g. MyTVOnline) take the first format; HLS survives
  // providers that drop .ts connections every ~20 s (measured 2026-11-07)
  lFormats := TJSONArray.Create;
  // in proxy mode the relay serves TS only (HLS can't be relayed; it is bounced)
  if not App.Config.ProxyStreams then
    lFormats.Add(cExtM3u8);
  lFormats.Add(cExtTs);
  lUserInfo.AddPair('allowed_output_formats', lFormats);
  Result.AddPair('user_info', lUserInfo);

  // server_info.url must be the HOST ONLY (no scheme, no port) — the box builds
  // {protocol}://{url}:{port}/live/... itself. Putting a full URL here makes the
  // box construct a broken stream URL and silently fail to connect.
  // (never raises: a bad publicBaseUrl must not turn every box login into a 500)
  // in proxy mode the box must stream from the relay port, not the API port
  if App.Config.ProxyStreams then
    lPortNo := App.Config.ProxyPort
  else
  begin
    lPortNo := SafeUrlPort(App.Config.PublicBaseUrl);
    if lPortNo <= 0 then
      lPortNo := App.Config.HttpPort;
  end;
  lServerInfo := TJSONObject.Create;
  lServerInfo.AddPair('url', PublicHost);
  lServerInfo.AddPair('port', lPortNo.ToString);
  // only advertise an https port when we actually serve TLS, else a box that
  // prefers https tries it against a plain-HTTP listener and fails to connect
  // (the relay port in proxy mode is always plain http, also with TLS on the API)
  if App.Config.UseHttps and not App.Config.ProxyStreams then
    lServerInfo.AddPair('https_port', lPortNo.ToString)
  else
    lServerInfo.AddPair('https_port', '0');
  lServerInfo.AddPair('rtmp_port', '0');
  if App.Config.ProxyStreams then
    lServerInfo.AddPair('server_protocol', cSchemeHttp)
  else
    lServerInfo.AddPair('server_protocol', PublicScheme);
  lServerInfo.AddPair('timezone', cServerTimezone);
  Result.AddPair('server_info', lServerInfo);
end;

// a category id that only depends on the group name (1..cMaxCategoryId)
function StableCategoryId(const AGroupName: string): Integer;
begin
  Result := Integer(Cardinal(THashBobJenkins.GetHashValue(AGroupName)) mod cMaxCategoryId) + 1;
end;

// Build categories + streams arrays for one content type, in display order.
procedure BuildContent(const AChannels: TOutputChannelList; ACt: TContentType;
  const AIdField, AStreamType: string; out ACategories, AStreams: TJSONArray);
var
  lChannel: TOutputChannel;
  lGroupToCat: TDictionary<string, Integer>;
  lUsedCatIds: TDictionary<Integer, Byte>;
  lUsed: TDictionary<Integer, Byte>; // num values already taken (operator + auto)
  lCatId, lNum, lNumber: Integer;
  lCat, lStream: TJSONObject;

  // Xtream has no radio actions: radio is part of the live list
  function InType(AC: TOutputChannel): Boolean;
  begin
    Result := (AC.ContentType = ACt) or ((ACt = ctLive) and (AC.ContentType = ctRadio));
  end;

begin
  ACategories := TJSONArray.Create;
  AStreams := TJSONArray.Create;
  lGroupToCat := TDictionary<string, Integer>.Create;
  lUsedCatIds := TDictionary<Integer, Byte>.Create;
  lUsed := TDictionary<Integer, Byte>.Create;
  try
    // Pre-collect the operator's channel numbers so the auto-fallback for
    // unnumbered channels never collides with them — without this, an unnumbered
    // channel could get the running index N that equals a numbered channel's value,
    // producing duplicate 'num's (some Xtream clients key/sort on num).
    for lChannel in AChannels do
      if InType(lChannel) and (lChannel.Number > 0) then
        lUsed.AddOrSetValue(lChannel.Number, 0);
    lNum := 0;
    for lChannel in AChannels do
    begin
      if not InType(lChannel) then
        Continue;
      if not lGroupToCat.TryGetValue(lChannel.GroupName, lCatId) then
      begin
        // derived from the group NAME, not its position: boxes remember hidden /
        // favourite / locked categories by id, and a new or moved group used to
        // renumber every later one
        lCatId := StableCategoryId(lChannel.GroupName);
        while lUsedCatIds.ContainsKey(lCatId) do
          lCatId := lCatId mod cMaxCategoryId + 1; // (rare) hash collision: next free
        lUsedCatIds.Add(lCatId, 0);
        lGroupToCat.Add(lChannel.GroupName, lCatId);
        lCat := TJSONObject.Create;
        lCat.AddPair(cFieldCategoryId, lCatId.ToString);
        lCat.AddPair('category_name', lChannel.GroupName);
        lCat.AddPair('parent_id', TJSONNumber.Create(0));
        ACategories.Add(lCat);
      end;
      if lChannel.Number > 0 then
        lNumber := lChannel.Number // keep the operator's number as-is
      else
      begin
        repeat
          Inc(lNum);
        until not lUsed.ContainsKey(lNum); // next free number
        lNumber := lNum;
        lUsed.AddOrSetValue(lNumber, 0);
      end;
      lStream := TJSONObject.Create;
      lStream.AddPair('num', TJSONNumber.Create(lNumber));
      lStream.AddPair('name', lChannel.Name);
      if lChannel.ContentType = ctRadio then
        lStream.AddPair('stream_type', cStreamTypeRadio)
      else
        lStream.AddPair('stream_type', AStreamType);
      lStream.AddPair(AIdField, TJSONNumber.Create(lChannel.StreamItemId));
      lStream.AddPair('stream_icon', lChannel.Logo);
      // the id xmltv.php publishes it under (iptv-<id> for a channel without tvg-id)
      lStream.AddPair('epg_channel_id', ChannelGuideId(lChannel));
      lStream.AddPair(cFieldCategoryId, lCatId.ToString);
      if ACt = ctMovie then
        // the box builds /movie/u/p/{id}.{container_extension}: give it the real one
        lStream.AddPair('container_extension',
          System.StrUtils.IfThen(UrlExt(lChannel.UpstreamUrl) = '', cDefaultVodExt, UrlExt(lChannel.UpstreamUrl)))
      else if ACt = ctSeries then
        lStream.AddPair('cover', lChannel.Logo);
      if lChannel.ContentType = ctLive then
      begin
        // catch-up: the box shows a rewind icon and asks /timeshift/ (see below)
        lStream.AddPair('tv_archive', TJSONNumber.Create(IfThen(lChannel.ArchiveDays > 0, 1, 0)));
        lStream.AddPair('tv_archive_duration', TJSONNumber.Create(lChannel.ArchiveDays));
      end;
      AStreams.Add(lStream);
    end;
  finally
    FreeAndNil(lGroupToCat);
    FreeAndNil(lUsedCatIds);
    FreeAndNil(lUsed);
  end;
end;

function PlayerApiResult(const AList: TCustomList; const AAction, ACategoryId: string): TJSONValue;
var
  lChannels: TOutputChannelList;
  lCats, lStreams: TJSONArray;

  // only the streams of one category (get_live_streams&category_id=7): clients
  // that load a category at a time got the whole bouquet in every category
  function OnlyCategory(AStreams: TJSONArray): TJSONArray;
  var
    lItem: TJSONValue;
  begin
    if ACategoryId = '' then
      Exit(AStreams);
    Result := TJSONArray.Create;
    try
      for lItem in AStreams do
        if (lItem is TJSONObject) and
           (TJSONObject(lItem).GetValue<string>(cFieldCategoryId, '') = ACategoryId) then
          Result.AddElement(TJSONValue(lItem.Clone));
    finally
      FreeAndNil(AStreams);
    end;
  end;

  function Pick(ACt: TContentType; const AIdField, AStreamType: string; AWantCats: Boolean): TJSONValue;
  begin
    BuildContent(lChannels, ACt, AIdField, AStreamType, lCats, lStreams);
    if AWantCats then
    begin
      FreeAndNil(lStreams);
      Result := lCats;
    end
    else
    begin
      FreeAndNil(lCats);
      Result := OnlyCategory(lStreams);
    end;
  end;

begin
  if (AAction = '') or (AAction = cActGetAccountInfo) then
    Exit(AccountInfo(AList));

  lChannels := App.Store.LoadOutputChannels(AList.Id);
  try
    if AAction = cActGetLiveCategories then
      Result := Pick(ctLive, cFieldStreamId, cStreamTypeLive, cWantCategories)
    else if AAction = cActGetLiveStreams then
      Result := Pick(ctLive, cFieldStreamId, cStreamTypeLive, cWantStreams)
    // (radio is listed with the live channels, stream_type radio_streams - see BuildContent)
    else if AAction = cActGetVodCategories then
      Result := Pick(ctMovie, cFieldStreamId, cStreamTypeMovie, cWantCategories)
    else if AAction = cActGetVodStreams then
      Result := Pick(ctMovie, cFieldStreamId, cStreamTypeMovie, cWantStreams)
    else if AAction = cActGetSeriesCategories then
      Result := Pick(ctSeries, cFieldSeriesId, cStreamTypeSeries, cWantCategories)
    else if AAction = cActGetSeries then
      Result := Pick(ctSeries, cFieldSeriesId, cStreamTypeSeries, cWantStreams)
    else
      Result := TJSONArray.Create;
  finally
    FreeAndNil(lChannels);
  end;
end;

// the source a stream belongs to (caller frees), nil if gone
function FindSource(ASourceId: Integer): TSourceConfig;
var
  lSources: TObjectList<TSourceConfig>;
  i: Integer;
begin
  Result := nil;
  lSources := App.Store.LoadSources;
  try
    for i := 0 to lSources.Count - 1 do
      if lSources[i].Id = ASourceId then
        Exit(lSources.Extract(lSources[i]));
  finally
    FreeAndNil(lSources);
  end;
end;

// get_vod_info: the provider's own info for an Xtream movie (stream_id swapped
// to ours), else a minimal answer built from the catalog row
function VodInfo(const AList: TCustomList; const AId: string): TJSONValue;
var
  lStream: TStreamItem;
  lSrc: TSourceConfig;
  lJson, lMovieData: TJSONValue;
  lExt: string;
begin
  lStream := App.Store.LoadListStreamById(AList.Id, StreamIdFromParam(AId));
  if (lStream = nil) or (lStream.ContentType <> ctMovie) then
  begin
    FreeAndNil(lStream);
    Exit(TJSONArray.Create);
  end;
  try
    lExt := System.StrUtils.IfThen(UrlExt(lStream.UpstreamUrl) = '', cDefaultVodExt, UrlExt(lStream.UpstreamUrl));
    lSrc := FindSource(lStream.SourceId);
    try
      if (lSrc <> nil) and (lSrc.Kind = skXtream) then
      try
        lJson := XtreamApiGet(lSrc,
          'action=' + cActGetVodInfo + '&vod_id=' + TNetEncoding.URL.Encode(lStream.UpstreamId));
        if lJson is TJSONObject then
        begin
          lMovieData := TJSONObject(lJson).GetValue('movie_data');
          if lMovieData is TJSONObject then
          begin
            TJSONObject(lMovieData).RemovePair(cFieldStreamId).Free;
            TJSONObject(lMovieData).AddPair(cFieldStreamId, TJSONNumber.Create(lStream.Id));
            if TJSONObject(lMovieData).GetValue('container_extension') = nil then
              TJSONObject(lMovieData).AddPair('container_extension', lExt);
            BlankDirectSource(TJSONObject(lMovieData));
          end;
          Exit(lJson);
        end;
        FreeAndNil(lJson);
      except
        on E: Exception do
          App.Log(Format('  get_vod_info %d: provider failed (%s) - minimal info',
            [lStream.Id, MaskUrlSecrets(E.Message)]));
      end;
    finally
      FreeAndNil(lSrc);
    end;
    Result := TJSONObject.Create
      .AddPair('info', TJSONObject.Create
        .AddPair('name', lStream.Name)
        .AddPair('movie_image', lStream.Logo))
      .AddPair('movie_data', TJSONObject.Create
        .AddPair(cFieldStreamId, TJSONNumber.Create(lStream.Id))
        .AddPair('name', lStream.Name)
        .AddPair('container_extension', lExt));
  finally
    FreeAndNil(lStream);
  end;
end;

// get_series_info: Xtream series come from the provider (episodes get stable ids
// of our own, cEpisodeIdBase+, that /series/u/p/{id} resolves list-scoped); an
// M3U "series" item is a single playable file, offered as one episode.
function SeriesInfo(const AList: TCustomList; const AId: string): TJSONValue;
var
  lStream: TStreamItem;
  lSrc: TSourceConfig;
  lJson, lEpisodes, lSeason: TJSONValue;
  lEpObjs: TList<TJSONObject>;
  lUpIds, lExts: TArray<string>;
  lIds: TArray<Integer>;
  lEpisode: TJSONValue;
  lEpArr: TJSONArray;
  i: Integer;
  lExt: string;

  procedure Collect(ASeason: TJSONValue);
  var
    lValue: TJSONValue;
  begin
    if ASeason is TJSONArray then
      for lValue in TJSONArray(ASeason) do
        if (lValue is TJSONObject) and (TJSONObject(lValue).GetValue('id') <> nil) then
          lEpObjs.Add(TJSONObject(lValue));
  end;

begin
  lStream := App.Store.LoadListStreamById(AList.Id, StreamIdFromParam(AId));
  if (lStream = nil) or (lStream.ContentType <> ctSeries) or (lStream.Id >= cEpisodeIdBase) then
  begin
    FreeAndNil(lStream);
    Exit(TJSONArray.Create);
  end;
  try
    lSrc := FindSource(lStream.SourceId);
    try
      if (lSrc <> nil) and (lSrc.Kind = skXtream) then
      begin
        try
          lJson := XtreamApiGet(lSrc,
            'action=' + cActGetSeriesInfo + '&series_id=' + TNetEncoding.URL.Encode(lStream.UpstreamId));
        except
          on E: Exception do
          begin
            App.Log(Format('  get_series_info %d: provider failed (%s)', [lStream.Id, MaskUrlSecrets(E.Message)]));
            Exit(TJSONArray.Create);
          end;
        end;
        if not (lJson is TJSONObject) then
        begin
          FreeAndNil(lJson);
          Exit(TJSONArray.Create);
        end;
        lEpObjs := TList<TJSONObject>.Create;
        try
          try
            // episodes: {"1":[...],"2":[...]} or (some panels) [[...],[...]]
            lEpisodes := TJSONObject(lJson).GetValue('episodes');
            if lEpisodes is TJSONObject then
              for i := 0 to TJSONObject(lEpisodes).Count - 1 do
                Collect(TJSONObject(lEpisodes).Pairs[i].JsonValue)
            else if lEpisodes is TJSONArray then
              for lSeason in TJSONArray(lEpisodes) do
                Collect(lSeason);
            SetLength(lUpIds, lEpObjs.Count);
            SetLength(lExts, lEpObjs.Count);
            for i := 0 to lEpObjs.Count - 1 do
            begin
              lUpIds[i] := lEpObjs[i].GetValue('id').Value;
              lExts[i] := lEpObjs[i].GetValue<string>('container_extension', '');
            end;
            lIds := App.Store.EnsureEpisodeIds(lStream.Id, lUpIds, lExts);
            for i := 0 to lEpObjs.Count - 1 do
            begin
              lEpObjs[i].RemovePair('id').Free;
              lEpObjs[i].AddPair('id', lIds[i].ToString);
              BlankDirectSource(lEpObjs[i]);
            end;
          except
            on E: Exception do
            begin
              FreeAndNil(lJson);
              App.Log(Format('  get_series_info %d: %s', [lStream.Id, E.Message]));
              Exit(TJSONArray.Create);
            end;
          end;
        finally
          FreeAndNil(lEpObjs);
        end;
        Exit(lJson);
      end;
    finally
      FreeAndNil(lSrc);
    end;
    // M3U: the item itself is the (only) episode
    lExt := System.StrUtils.IfThen(UrlExt(lStream.UpstreamUrl) = '', cDefaultVodExt, UrlExt(lStream.UpstreamUrl));
    lEpisode := TJSONObject.Create
      .AddPair('id', lStream.Id.ToString)
      .AddPair('episode_num', TJSONNumber.Create(cM3uEpisode))
      .AddPair('title', lStream.Name)
      .AddPair('container_extension', lExt)
      .AddPair('season', TJSONNumber.Create(cM3uSeason))
      .AddPair('info', TJSONObject.Create);
    lEpArr := TJSONArray.Create;
    lEpArr.AddElement(lEpisode);
    Result := TJSONObject.Create
      .AddPair('seasons', TJSONArray.Create)
      .AddPair('info', TJSONObject.Create
        .AddPair('name', lStream.Name)
        .AddPair('cover', lStream.Logo))
      .AddPair('episodes', TJSONObject.Create
        .AddPair(IntToStr(cM3uSeason), lEpArr));
  finally
    FreeAndNil(lStream);
  end;
end;

// Xtream get_short_epg / get_simple_data_table: EPG for one stream_id.
// title/description are base64 (Xtream spec); times as UTC string + unix timestamp.
function BuildEpgListings(const AList: TCustomList; const AStreamId: string;
  ALimit: Integer; AOnlyFuture: Boolean): TJSONObject;
var
  lChannels: TOutputChannelList;
  lChannel: TOutputChannel;
  lProgs: TEpgProgrammeList;
  lArr: TJSONArray;
  lEntry: TJSONObject;
  lProgramme: TEpgProgramme;
  lNowUtc: TDateTime;
  lCount, lStreamId, lArchiveDays: Integer;
  lArchiveFrom: TDateTime;
  lGuideId: string;
  lTvgs: TArray<string>;

  function B64(const AText: string): string;
  begin
    Result := XtreamBase64(AText); // single line: no CR/LF every 76 chars (MyTVOnline rejects those)
  end;

begin
  Result := TJSONObject.Create;
  lArr := TJSONArray.Create;
  Result.AddPair('epg_listings', lArr);

  // Resolve the channel's EFFECTIVE tvg-id from the curated list, not the raw
  // upstream one — a per-item tvg-id override RELABELS the guide, and xmltv.php
  // serves under that effective id. Query BOTH the effective and the upstream id
  // (programmes may be stored under either) so the box's inline now/next matches
  // what xmltv.php shows. Only channels actually on this list get EPG.
  lStreamId := StreamIdFromParam(AStreamId);
  lGuideId := '';
  lArchiveDays := 0;
  lChannels := App.Store.LoadOutputChannels(AList.Id);
  try
    for lChannel in lChannels do
      if lChannel.StreamItemId = lStreamId then
      begin
        // the id xmltv.php / get_live_streams (epg_channel_id) publish it under
        lGuideId := ChannelGuideId(lChannel);
        lArchiveDays := lChannel.ArchiveDays;
        lTvgs := lChannel.EpgReadIds; // own ids, or the matched extra guide
        Break;
      end;
  finally
    FreeAndNil(lChannels);
  end;
  if Length(lTvgs) = 0 then
    Exit; // not on the list, or no tvg-id at all

  lNowUtc := NowUtc;
  lArchiveFrom := IncDay(lNowUtc, -lArchiveDays);
  lProgs := App.Store.LoadEpgForTvgIds(lTvgs, App.Config.EpgMaxDays);
  try
    // the store orders by channel id first: with two ids (upstream + override) the
    // 'next N' must come from both, in time order
    lProgs.Sort(TComparer<TEpgProgramme>.Construct(
      function(const ALeft, ARight: TEpgProgramme): Integer
      begin
        Result := CompareDateTime(ALeft.StartUtc, ARight.StartUtc);
      end));
    lCount := 0;
    for lProgramme in lProgs do
    begin
      if AOnlyFuture and (lProgramme.StopUtc < lNowUtc) then
        Continue;
      lEntry := TJSONObject.Create;
      // real portals send non-empty ids; some players (Formuler/MyTVOnline) key the
      // listing on them — the start time is unique within one channel
      lEntry.AddPair('id', IntToStr(DateTimeToUnix(lProgramme.StartUtc, cTimesAreUtc)));
      lEntry.AddPair('epg_id', '1');
      lEntry.AddPair('title', B64(lProgramme.Title));
      lEntry.AddPair('lang', '');
      lEntry.AddPair('start', FormatDateTime(cEpgDateTimeFormat, lProgramme.StartUtc));
      lEntry.AddPair('end', FormatDateTime(cEpgDateTimeFormat, lProgramme.StopUtc));
      lEntry.AddPair('description', B64(lProgramme.Description));
      lEntry.AddPair('channel_id', lGuideId);
      lEntry.AddPair('start_timestamp', IntToStr(DateTimeToUnix(lProgramme.StartUtc, cTimesAreUtc)));
      lEntry.AddPair('stop_timestamp', IntToStr(DateTimeToUnix(lProgramme.StopUtc, cTimesAreUtc)));
      lEntry.AddPair('now_playing', TJSONNumber.Create(IfThen((lNowUtc >= lProgramme.StartUtc) and
        (lNowUtc < lProgramme.StopUtc), 1, 0)));
      // a finished programme inside the provider's archive window can be replayed
      lEntry.AddPair('has_archive', TJSONNumber.Create(IfThen((lArchiveDays > 0) and
        (lProgramme.StopUtc <= lNowUtc) and (lProgramme.StartUtc >= lArchiveFrom), 1, 0)));
      lArr.Add(lEntry);
      Inc(lCount);
      if (ALimit > 0) and (lCount >= ALimit) then
        Break;
    end;
  finally
    FreeAndNil(lProgs);
  end;
end;

// operator-facing label for the upstream provider a stream belongs to: the
// source name the operator gave it plus the upstream host, e.g. ProviderA (cdn.x.net)
function ProviderLabel(ASourceId: Integer; const AUpstreamUrl: string): string;
var
  lSources: TObjectList<TSourceConfig>;
  lSource: TSourceConfig;
  lName, lHost: string;
begin
  lName := '';
  lSources := App.Store.LoadSources;
  try
    for lSource in lSources do
      if lSource.Id = ASourceId then
      begin
        lName := lSource.Name;
        Break;
      end;
  finally
    FreeAndNil(lSources);
  end;
  lHost := '';
  try
    lHost := TURI.Create(AUpstreamUrl).Host;
  except
    lHost := '';
  end;
  if (lName <> '') and (lHost <> '') then
    Result := Format('"%s" (%s)', [lName, lHost])
  else if lName <> '' then
    Result := Format('"%s"', [lName])
  else if lHost <> '' then
    Result := lHost
  else
    Result := Format('source #%d', [ASourceId]);
end;

// true when the operator ticked "live always as HLS" on this stream's source
function SourceForcesHls(ASourceId: Integer): Boolean;
var
  lSources: TObjectList<TSourceConfig>;
  lSource: TSourceConfig;
begin
  Result := False;
  lSources := App.Store.LoadSources;
  try
    for lSource in lSources do
      if lSource.Id = ASourceId then
        Exit(lSource.ForceHls);
  finally
    FreeAndNil(lSources);
  end;
end;

procedure DoRedirect(const AResponse: IMARSResponse; const AUser, APass, AId: string;
  ALive: Boolean = False);
var
  lList: TCustomList;
  lStream: TStreamItem;
  lTarget, lMasked, lProvider, lExt: string;
  lHls: Boolean;
begin
  if ServiceDown(AResponse) then
    Exit;
  lList := ResolveList(AUser, APass);
  if lList = nil then
  begin
    AResponse.StatusCode := cHttpUnauthorized;
    Exit;
  end;
  try
    // scope the lookup to THIS list: the credentials authorise one list, so a box
    // must not be able to stream an arbitrary catalog id that isn't on it.
    lStream := App.Store.LoadListStreamById(lList.Id, StreamIdFromParam(AId));
    if lStream = nil then
    begin
      AResponse.StatusCode := cHttpNotFound;
      Exit;
    end;
    try
      // Boxes build the live URL against us. In proxy mode bounce them to the
      // relay port; otherwise 302 straight to the raw provider URL.
      // A source with ForceHls hands LIVE out as .m3u8 whatever the box asked for
      // (some providers drop .ts connections every ~20 s; HLS segments survive
      // that). HLS can't be relayed meaningfully, so it always 302s direct.
      // only LIVE follows the box's requested container (.ts/.m3u8): a movie or
      // episode exists in ONE container upstream (.mkv stays .mkv)
      if ALive then
        lExt := RequestedExt(AId)
      else
        lExt := '';
      lHls := ALive and SourceForcesHls(lStream.SourceId);
      if lHls then
        lExt := cExtM3u8;
      if App.Config.ProxyStreams and not lHls then
      begin
        lTarget := Format('http://%s:%d/live/%s/%s/%s', [PublicHost, App.Config.ProxyPort,
          PathCred(lList.OutputUsername), PathCred(lList.OutputPassword), AId]);
      end
      else
        // only an Xtream LIVE .ts/.m3u8 URL follows the box's container choice
        lTarget := LiveUpstreamUrl(App.Store, lStream, lExt);
      // mask both path-style (/live/u/p/) AND query-style (?username=&password=)
      // credentials before logging — upstream M3U URLs often carry query creds
      lMasked := TRegEx.Replace(lTarget, '(/(live|movie|series)/)[^/]+/[^/]+/', '$1***/***/', [roIgnoreCase]);
      lMasked := TRegEx.Replace(lMasked, '([?&](username|password|pass|pw|user|token|auth|mac)=)[^&]*', '$1***',
        [roIgnoreCase]);
      // always name the upstream provider being routed to (in proxy mode Target is
      // our own relay URL, so the provider would otherwise be invisible in the log)
      lProvider := ProviderLabel(lStream.SourceId, lStream.UpstreamUrl);
      if App.Config.ProxyStreams and not lHls then
        App.Log(Format('  proxy stream %s "%s" -> provider %s  [relay %s]',
          [AId, lStream.Name, lProvider, lMasked]))
      else
        App.Log(Format('  redirect stream %s "%s" -> provider %s  [%s]%s',
          [AId, lStream.Name, lProvider, lMasked, System.StrUtils.IfThen(lHls, '  (HLS forced)', '')]));
      AResponse.RedirectTo(lTarget);
    finally
      FreeAndNil(lStream);
    end;
  finally
    FreeAndNil(lList);
  end;
end;

// catch-up: resolve the list stream and 302 to the provider's timeshift URL. In
// proxy mode bounce to the relay port instead (it serves /timeshift/ too), so a
// box that can only reach this server still gets the archive.
procedure DoTimeshift(const AResponse: IMARSResponse; const AUser, APass,
  ADuration, AStart, AId: string);
var
  lList: TCustomList;
  lStream: TStreamItem;
  lStartUtc: TDateTime;
  lDuration: Integer;
  lExt, lTarget, lMasked: string;
begin
  if ServiceDown(AResponse) then
    Exit;
  lDuration := StrToIntDef(ADuration, 0);
  if (lDuration <= 0) or not ParseTimeshiftStart(AStart, lStartUtc) then
  begin
    AResponse.StatusCode := cHttpBadRequest;
    Exit;
  end;
  lList := ResolveList(AUser, APass);
  if lList = nil then
  begin
    AResponse.StatusCode := cHttpUnauthorized;
    Exit;
  end;
  try
    // list-scoped, like the live redirect: only channels on THIS list
    lStream := App.Store.LoadListStreamById(lList.Id, StreamIdFromParam(AId));
    if lStream = nil then
    begin
      AResponse.StatusCode := cHttpNotFound;
      Exit;
    end;
    try
      lExt := RequestedExt(AId);
      if App.Config.ProxyStreams then
      begin
        lTarget := Format('http://%s:%d/timeshift/%s/%s/%d/%s/%d.%s',
          [PublicHost, App.Config.ProxyPort, PathCred(lList.OutputUsername), PathCred(lList.OutputPassword),
           lDuration, FormatTimeshiftStart(lStartUtc),
           lStream.Id, System.StrUtils.IfThen(lExt = '', cExtTs, lExt)]);
      end
      else
        lTarget := TimeshiftUpstreamUrl(App.Store, lStream, lDuration, lStartUtc, lExt);
      if lTarget = '' then
      begin
        // the stream's source isn't an Xtream portal: no timeshift there
        AResponse.StatusCode := cHttpNotFound;
        Exit;
      end;
      lMasked := TRegEx.Replace(lTarget, '(/timeshift/)[^/]+/[^/]+/', '$1***/***/', [roIgnoreCase]);
      App.Log(Format('  timeshift stream %d "%s" %s UTC +%d min -> provider %s  [%s]',
        [lStream.Id, lStream.Name, FormatTimeshiftStart(lStartUtc), lDuration,
         ProviderLabel(lStream.SourceId, lStream.UpstreamUrl), lMasked]));
      AResponse.RedirectTo(lTarget);
    finally
      FreeAndNil(lStream);
    end;
  finally
    FreeAndNil(lList);
  end;
end;

{ TPlayerApiResource }

function TPlayerApiResource.PlayerApi(AUser, APass, AAction, AStreamId: string; ALimit: string;
  AVodId, ASeriesId, ACategoryId: string): TJSONValue;
var
  lList: TCustomList;
  lThrottleKey: string;
begin
  if ServiceDown(Response) then
    Exit(TJSONObject.Create);
  lThrottleKey := GAuthThrottle.ClientKey(cSurfaceBox, Request.RemoteIP,
    Request.GetHeaderParamValue(cHeaderForwardedFor));
  lList := ResolveList(AUser, APass);
  if lList = nil then
  begin
    // counts towards the lockout like a 401 does - but not the server's own
    // warm-up request (username=warmup)
    if Request.GetHeaderParamValue(cWarmupHeader) = '' then
      GAuthThrottle.RegisterFailure(lThrottleKey);
    // 200 + auth:0, like real panels: some boxes show a 401 as "network error"
    // instead of "wrong username/password"
    Exit(TJSONObject.Create.AddPair('user_info',
      TJSONObject.Create.AddPair('auth', TJSONNumber.Create(0))));
  end;
  GAuthThrottle.RegisterSuccess(lThrottleKey);
  try
    if AAction = cActGetShortEpg then
      Result := BuildEpgListings(lList, AStreamId,
        IfThen(StrToIntDef(ALimit, 0) > 0, StrToIntDef(ALimit, 0), cShortEpgDefaultLimit), cOnlyFuture)
    else if AAction = cActGetSimpleDataTable then
      Result := BuildEpgListings(lList, AStreamId, cNoEpgLimit, cWithPast)
    else if AAction = cActGetVodInfo then
      Result := VodInfo(lList, AVodId)
    else if AAction = cActGetSeriesInfo then
      Result := SeriesInfo(lList, ASeriesId)
    else
      Result := PlayerApiResult(lList, AAction, ACategoryId);
  finally
    FreeAndNil(lList);
  end;
end;

{ TGetPhpResource }

function TGetPhpResource.GetPhp(AUser, APass: string): string;
var
  lList: TCustomList;
  lPrefix: string;
begin
  if ServiceDown(Response) then
    Exit('');
  lList := ResolveList(AUser, APass);
  if lList = nil then
  begin
    Response.StatusCode := cHttpUnauthorized;
    Exit('');
  end;
  try
    lPrefix := '';
    if App.Config.ProxyStreams then
    begin
      lPrefix := Format('http://%s:%d/live/%s/%s/',
        [PublicHost, App.Config.ProxyPort, PathCred(lList.OutputUsername), PathCred(lList.OutputPassword)]);
    end;
    // the Media Servers group filter is for the Plex bouquet only — a box gets its
    // whole bouquet (group names of one bouquet mean nothing in another)
    Result := BuildM3U(App.Store, lList.Id, lPrefix, cBouquetChno, nil);
  finally
    FreeAndNil(lList);
  end;
end;

{ TXmltvResource }

function TXmltvResource.Xmltv(AUser, APass: string): string;
var
  lList: TCustomList;
begin
  if ServiceDown(Response) then
    Exit('');
  lList := ResolveList(AUser, APass);
  if lList = nil then
  begin
    Response.StatusCode := cHttpUnauthorized;
    Exit('');
  end;
  try
    Result := BuildXmltv(App.Store, lList.Id, App.Config.EpgMaxDays,
      TDummyEpgOptions.Make(App.Config.DummyEpgEnabled, App.Config.DummyEpgBlockMinutes,
        App.Config.DummyEpgHoursBack, App.Config.DummyEpgHoursAhead),
      nil); // group filter is Plex-only (see get.php)
  finally
    FreeAndNil(lList);
  end;
end;

{ stream resources }

procedure TLiveStreamResource.Redirect(AUser, APass, AId: string);
begin
  DoRedirect(Response, AUser, APass, AId, cLiveStream);
end;

procedure TMovieStreamResource.Redirect(AUser, APass, AId: string);
begin
  DoRedirect(Response, AUser, APass, AId);
end;

procedure TSeriesStreamResource.Redirect(AUser, APass, AId: string);
begin
  DoRedirect(Response, AUser, APass, AId);
end;

procedure TTimeshiftResource.Redirect(AUser, APass, ADuration, AStart, AId: string);
begin
  DoTimeshift(Response, AUser, APass, ADuration, AStart, AId);
end;

procedure TTimeshiftPhpResource.Redirect(AUser, APass, AStream, AStart, ADuration: string);
begin
  DoTimeshift(Response, AUser, APass, ADuration, AStart, AStream);
end;

initialization
  MARSRegister([TPlayerApiResource, TGetPhpResource, TXmltvResource,
    TLiveStreamResource, TMovieStreamResource, TSeriesStreamResource,
    TTimeshiftResource, TTimeshiftPhpResource]);

end.
