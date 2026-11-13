unit IPTV.Api.Mars.Xtream;

{ Outgoing Xtream Codes portal emulation as MARS resources, mounted at the root
  so an IPTV box reaches /player_api.php, /get.php, /xmltv.php and the stream
  paths directly. Credentials are optional (empty -> default list). Video never
  flows through us: stream endpoints 302-redirect to the upstream URL and get.php
  embeds raw upstream URLs. Ordering is the store's canonical order. }

interface

uses
  System.JSON,
  MARS.Core.Attributes, MARS.Core.MediaType,
  MARS.Core.RequestAndResponse.Interfaces;

type
  [Path('player_api.php')]
  TPlayerApiResource = class
  protected
    [Context] Response: IMARSResponse;
  public
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

  [Path('get.php')]
  TGetPhpResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    [GET, Produces('application/x-mpegurl')]
    function GetPhp([QueryParam('username')] AUser: string;
      [QueryParam('password')] APass: string): string;
  end;

  [Path('xmltv.php')]
  TXmltvResource = class
  protected
    [Context] Response: IMARSResponse;
  public
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
    [GET, Path('{user}/{pass}/{id}')]
    procedure Redirect([PathParam('user')] AUser: string;
      [PathParam('pass')] APass: string; [PathParam('id')] AId: string);
  end;

  [Path('movie')]
  TMovieStreamResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    [GET, Path('{user}/{pass}/{id}')]
    procedure Redirect([PathParam('user')] AUser: string;
      [PathParam('pass')] APass: string; [PathParam('id')] AId: string);
  end;

  [Path('series')]
  TSeriesStreamResource = class
  protected
    [Context] Response: IMARSResponse;
  public
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
    [GET, Path('timeshift.php')]
    procedure Redirect([QueryParam('username')] AUser: string;
      [QueryParam('password')] APass: string; [QueryParam('stream')] AStream: string;
      [QueryParam('start')] AStart: string; [QueryParam('duration')] ADuration: string);
  end;

implementation

uses
  System.SysUtils, System.Generics.Collections, System.StrUtils, System.Math, System.RegularExpressions,
  System.Net.URLClient, System.NetEncoding, System.DateUtils,
  MARS.Core.Registry,
  IPTV.Model.Types, IPTV.Model.Catalog, IPTV.Model.Epg, IPTV.Model.CustomList,
  IPTV.Model.Source,
  IPTV.Storage.Intf, IPTV.App.Context, IPTV.Output.Builder, IPTV.Core.Utils,
  IPTV.Source.Xtream;

{ ── shared helpers ──────────────────────────────────────────────────────── }

// Resolve the list a box authenticates as (empty creds -> default). Caller frees.
function ResolveList(const AUser, APass: string): TCustomList;
begin
  if App = nil then
    Exit(nil);
  // also understands the '-' placeholder and percent-encoding of our own URLs
  Result := FindListForPath(App.Store, AUser, APass);
end;

// host the box reaches us on (publicBaseUrl; 'localhost' when unset/unparseable)
function PublicHost: string;
begin
  Result := SafeUrlHost(App.Config.PublicBaseUrl, 'localhost');
end;

function PublicScheme: string;
begin
  if App.Config.PublicBaseUrl.StartsWith('https:', True) then
    Result := 'https'
  else
    Result := 'http';
end;

function StreamIdFromParam(const AId: string): Integer;
var
  S: string;
  Dot: Integer;
begin
  S := AId;
  Dot := S.IndexOf('.');
  if Dot >= 0 then
    S := S.Substring(0, Dot);
  Result := StrToIntDef(S, 0);
end;

// the container the box asked for (the bit after the last dot in ":id"), '' if none
function RequestedExt(const AId: string): string;
var
  Dot: Integer;
begin
  Dot := AId.LastIndexOf('.');
  if Dot >= 0 then
    Result := AId.Substring(Dot + 1)
  else
    Result := '';
end;

function AccountInfo: TJSONObject;
var
  UserInfo, ServerInfo: TJSONObject;
  Formats: TJSONArray;
  Uri: TURI;
  PortNo: Integer;
begin
  Result := TJSONObject.Create;
  UserInfo := TJSONObject.Create;
  UserInfo.AddPair('auth', TJSONNumber.Create(1));
  UserInfo.AddPair('status', 'Active');
  UserInfo.AddPair('is_trial', '0');
  UserInfo.AddPair('active_cons', '0');
  UserInfo.AddPair('max_connections', '1');
  // m3u8 first: boxes (e.g. MyTVOnline) take the first format; HLS survives
  // providers that drop .ts connections every ~20 s (measured 2026-11-07)
  Formats := TJSONArray.Create;
  // in proxy mode the relay serves TS only (HLS can't be relayed; it is bounced)
  if not App.Config.ProxyStreams then
    Formats.Add('m3u8');
  Formats.Add('ts');
  UserInfo.AddPair('allowed_output_formats', Formats);
  Result.AddPair('user_info', UserInfo);

  // server_info.url must be the HOST ONLY (no scheme, no port) — the box builds
  // {protocol}://{url}:{port}/live/... itself. Putting a full URL here makes the
  // box construct a broken stream URL and silently fail to connect.
  // (never raises: a bad publicBaseUrl must not turn every box login into a 500)
  // in proxy mode the box must stream from the relay port, not the API port
  if App.Config.ProxyStreams then
    PortNo := App.Config.ProxyPort
  else
  begin
    PortNo := SafeUrlPort(App.Config.PublicBaseUrl);
    if PortNo <= 0 then
      PortNo := App.Config.HttpPort;
  end;
  ServerInfo := TJSONObject.Create;
  ServerInfo.AddPair('url', PublicHost);
  ServerInfo.AddPair('port', PortNo.ToString);
  // only advertise an https port when we actually serve TLS, else a box that
  // prefers https tries it against a plain-HTTP listener and fails to connect
  // (the relay port in proxy mode is always plain http, also with TLS on the API)
  if App.Config.UseHttps and not App.Config.ProxyStreams then
    ServerInfo.AddPair('https_port', PortNo.ToString)
  else
    ServerInfo.AddPair('https_port', '0');
  ServerInfo.AddPair('rtmp_port', '0');
  if App.Config.ProxyStreams then
    ServerInfo.AddPair('server_protocol', 'http')
  else
    ServerInfo.AddPair('server_protocol', PublicScheme);
  ServerInfo.AddPair('timezone', 'UTC');
  Result.AddPair('server_info', ServerInfo);
end;

// Build categories + streams arrays for one content type, in display order.
procedure BuildContent(const AChannels: TOutputChannelList; ACt: TContentType;
  const AIdField, AStreamType: string; out ACategories, AStreams: TJSONArray);
var
  C: TOutputChannel;
  GroupToCat: TDictionary<string, Integer>;
  Used: TDictionary<Integer, Byte>; // num values already taken (operator + auto)
  CatId, Num, N: Integer;
  Cat, Stream: TJSONObject;

  // Xtream has no radio actions: radio is part of the live list
  function InType(AC: TOutputChannel): Boolean;
  begin
    Result := (AC.ContentType = ACt) or ((ACt = ctLive) and (AC.ContentType = ctRadio));
  end;

begin
  ACategories := TJSONArray.Create;
  AStreams := TJSONArray.Create;
  GroupToCat := TDictionary<string, Integer>.Create;
  Used := TDictionary<Integer, Byte>.Create;
  try
    // Pre-collect the operator's channel numbers so the auto-fallback for
    // unnumbered channels never collides with them — without this, an unnumbered
    // channel could get the running index N that equals a numbered channel's value,
    // producing duplicate 'num's (some Xtream clients key/sort on num).
    for C in AChannels do
      if InType(C) and (C.Number > 0) then
        Used.AddOrSetValue(C.Number, 0);
    Num := 0;
    for C in AChannels do
    begin
      if not InType(C) then
        Continue;
      if not GroupToCat.TryGetValue(C.GroupName, CatId) then
      begin
        CatId := GroupToCat.Count + 1;
        GroupToCat.Add(C.GroupName, CatId);
        Cat := TJSONObject.Create;
        Cat.AddPair('category_id', CatId.ToString);
        Cat.AddPair('category_name', C.GroupName);
        Cat.AddPair('parent_id', TJSONNumber.Create(0));
        ACategories.Add(Cat);
      end;
      if C.Number > 0 then
        N := C.Number // keep the operator's number as-is
      else
      begin
        repeat Inc(Num) until not Used.ContainsKey(Num); // next free number
        N := Num;
        Used.AddOrSetValue(N, 0);
      end;
      Stream := TJSONObject.Create;
      Stream.AddPair('num', TJSONNumber.Create(N));
      Stream.AddPair('name', C.Name);
      if C.ContentType = ctRadio then
        Stream.AddPair('stream_type', 'radio_streams') // how real portals list radio
      else
        Stream.AddPair('stream_type', AStreamType);
      Stream.AddPair(AIdField, TJSONNumber.Create(C.StreamItemId));
      Stream.AddPair('stream_icon', C.Logo);
      // the id xmltv.php publishes it under (iptv-<id> for a channel without tvg-id)
      Stream.AddPair('epg_channel_id', ChannelGuideId(C));
      Stream.AddPair('category_id', CatId.ToString);
      if ACt = ctMovie then
        // the box builds /movie/u/p/{id}.{container_extension}: give it the real one
        Stream.AddPair('container_extension', System.StrUtils.IfThen(UrlExt(C.UpstreamUrl) = '', 'mp4', UrlExt(C.UpstreamUrl)))
      else if ACt = ctSeries then
        Stream.AddPair('cover', C.Logo);
      if C.ContentType = ctLive then
      begin
        // catch-up: the box shows a rewind icon and asks /timeshift/ (see below)
        Stream.AddPair('tv_archive', TJSONNumber.Create(IfThen(C.ArchiveDays > 0, 1, 0)));
        Stream.AddPair('tv_archive_duration', TJSONNumber.Create(C.ArchiveDays));
      end;
      AStreams.Add(Stream);
    end;
  finally
    GroupToCat.Free;
    Used.Free;
  end;
end;

function PlayerApiResult(const AList: TCustomList; const AAction, ACategoryId: string): TJSONValue;
var
  Channels: TOutputChannelList;
  Cats, Streams: TJSONArray;

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
           (TJSONObject(lItem).GetValue<string>('category_id', '') = ACategoryId) then
          Result.AddElement(TJSONValue(lItem.Clone));
    finally
      FreeAndNil(AStreams);
    end;
  end;

  function Pick(ACt: TContentType; const AIdField, AStreamType: string; AWantCats: Boolean): TJSONValue;
  begin
    BuildContent(Channels, ACt, AIdField, AStreamType, Cats, Streams);
    if AWantCats then
    begin
      FreeAndNil(Streams);
      Result := Cats;
    end
    else
    begin
      FreeAndNil(Cats);
      Result := OnlyCategory(Streams);
    end;
  end;

begin
  if (AAction = '') or (AAction = 'get_account_info') then
    Exit(AccountInfo);

  Channels := App.Store.LoadOutputChannels(AList.Id);
  try
    if AAction = 'get_live_categories' then Result := Pick(ctLive, 'stream_id', 'live', True)
    else if AAction = 'get_live_streams' then Result := Pick(ctLive, 'stream_id', 'live', False)
    // (radio is listed with the live channels, stream_type radio_streams - see BuildContent)
    else if AAction = 'get_vod_categories' then Result := Pick(ctMovie, 'stream_id', 'movie', True)
    else if AAction = 'get_vod_streams' then Result := Pick(ctMovie, 'stream_id', 'movie', False)
    else if AAction = 'get_series_categories' then Result := Pick(ctSeries, 'series_id', 'series', True)
    else if AAction = 'get_series' then Result := Pick(ctSeries, 'series_id', 'series', False)
    else Result := TJSONArray.Create;
  finally
    Channels.Free;
  end;
end;

// the source a stream belongs to (caller frees), nil if gone
function FindSource(ASourceId: Integer): TSourceConfig;
var
  Sources: TObjectList<TSourceConfig>;
  I: Integer;
begin
  Result := nil;
  Sources := App.Store.LoadSources;
  try
    for I := 0 to Sources.Count - 1 do
      if Sources[I].Id = ASourceId then
        Exit(Sources.Extract(Sources[I]));
  finally
    Sources.Free;
  end;
end;

// get_vod_info: the provider's own info for an Xtream movie (stream_id swapped
// to ours), else a minimal answer built from the catalog row
function VodInfo(const AList: TCustomList; const AId: string): TJSONValue;
var
  Stream: TStreamItem;
  Src: TSourceConfig;
  JV, MD: TJSONValue;
  Ext: string;
begin
  Stream := App.Store.LoadListStreamById(AList.Id, StreamIdFromParam(AId));
  if (Stream = nil) or (Stream.ContentType <> ctMovie) then
  begin
    Stream.Free;
    Exit(TJSONArray.Create);
  end;
  try
    Ext := System.StrUtils.IfThen(UrlExt(Stream.UpstreamUrl) = '', 'mp4', UrlExt(Stream.UpstreamUrl));
    Src := FindSource(Stream.SourceId);
    try
      if (Src <> nil) and (Src.Kind = skXtream) then
      try
        JV := XtreamApiGet(Src, 'action=get_vod_info&vod_id=' + TNetEncoding.URL.Encode(Stream.UpstreamId));
        if JV is TJSONObject then
        begin
          MD := TJSONObject(JV).GetValue('movie_data');
          if MD is TJSONObject then
          begin
            TJSONObject(MD).RemovePair('stream_id').Free;
            TJSONObject(MD).AddPair('stream_id', TJSONNumber.Create(Stream.Id));
            if TJSONObject(MD).GetValue('container_extension') = nil then
              TJSONObject(MD).AddPair('container_extension', Ext);
          end;
          Exit(JV);
        end;
        JV.Free;
      except
        on E: Exception do
          App.Log(Format('  get_vod_info %d: provider failed (%s) - minimal info', [Stream.Id, MaskUrlSecrets(E.Message)]));
      end;
    finally
      Src.Free;
    end;
    Result := TJSONObject.Create
      .AddPair('info', TJSONObject.Create
        .AddPair('name', Stream.Name)
        .AddPair('movie_image', Stream.Logo))
      .AddPair('movie_data', TJSONObject.Create
        .AddPair('stream_id', TJSONNumber.Create(Stream.Id))
        .AddPair('name', Stream.Name)
        .AddPair('container_extension', Ext));
  finally
    Stream.Free;
  end;
end;

// get_series_info: Xtream series come from the provider (episodes get stable ids
// of our own, cEpisodeIdBase+, that /series/u/p/{id} resolves list-scoped); an
// M3U "series" item is a single playable file, offered as one episode.
function SeriesInfo(const AList: TCustomList; const AId: string): TJSONValue;
var
  Stream: TStreamItem;
  Src: TSourceConfig;
  JV, Eps, Season: TJSONValue;
  EpObjs: TList<TJSONObject>;
  UpIds, Exts: TArray<string>;
  Ids: TArray<Integer>;
  Ep: TJSONValue;
  EpArr: TJSONArray;
  I: Integer;
  Ext: string;

  procedure Collect(ASeason: TJSONValue);
  var
    V: TJSONValue;
  begin
    if ASeason is TJSONArray then
      for V in TJSONArray(ASeason) do
        if (V is TJSONObject) and (TJSONObject(V).GetValue('id') <> nil) then
          EpObjs.Add(TJSONObject(V));
  end;

begin
  Stream := App.Store.LoadListStreamById(AList.Id, StreamIdFromParam(AId));
  if (Stream = nil) or (Stream.ContentType <> ctSeries) or (Stream.Id >= cEpisodeIdBase) then
  begin
    Stream.Free;
    Exit(TJSONArray.Create);
  end;
  try
    Src := FindSource(Stream.SourceId);
    try
      if (Src <> nil) and (Src.Kind = skXtream) then
      begin
        try
          JV := XtreamApiGet(Src, 'action=get_series_info&series_id=' + TNetEncoding.URL.Encode(Stream.UpstreamId));
        except
          on E: Exception do
          begin
            App.Log(Format('  get_series_info %d: provider failed (%s)', [Stream.Id, MaskUrlSecrets(E.Message)]));
            Exit(TJSONArray.Create);
          end;
        end;
        if not (JV is TJSONObject) then
        begin
          JV.Free;
          Exit(TJSONArray.Create);
        end;
        EpObjs := TList<TJSONObject>.Create;
        try
        try
          // episodes: {"1":[...],"2":[...]} or (some panels) [[...],[...]]
          Eps := TJSONObject(JV).GetValue('episodes');
          if Eps is TJSONObject then
            for I := 0 to TJSONObject(Eps).Count - 1 do
              Collect(TJSONObject(Eps).Pairs[I].JsonValue)
          else if Eps is TJSONArray then
            for Season in TJSONArray(Eps) do
              Collect(Season);
          SetLength(UpIds, EpObjs.Count);
          SetLength(Exts, EpObjs.Count);
          for I := 0 to EpObjs.Count - 1 do
          begin
            UpIds[I] := EpObjs[I].GetValue('id').Value;
            Exts[I] := EpObjs[I].GetValue<string>('container_extension', '');
          end;
          Ids := App.Store.EnsureEpisodeIds(Stream.Id, UpIds, Exts);
          for I := 0 to EpObjs.Count - 1 do
          begin
            EpObjs[I].RemovePair('id').Free;
            EpObjs[I].AddPair('id', Ids[I].ToString);
          end;
        except
          on E: Exception do
          begin
            FreeAndNil(JV);
            App.Log(Format('  get_series_info %d: %s', [Stream.Id, E.Message]));
            Exit(TJSONArray.Create);
          end;
        end;
        finally
          FreeAndNil(EpObjs);
        end;
        Exit(JV);
      end;
    finally
      Src.Free;
    end;
    // M3U: the item itself is the (only) episode
    Ext := System.StrUtils.IfThen(UrlExt(Stream.UpstreamUrl) = '', 'mp4', UrlExt(Stream.UpstreamUrl));
    Ep := TJSONObject.Create
      .AddPair('id', Stream.Id.ToString)
      .AddPair('episode_num', TJSONNumber.Create(1))
      .AddPair('title', Stream.Name)
      .AddPair('container_extension', Ext)
      .AddPair('season', TJSONNumber.Create(1))
      .AddPair('info', TJSONObject.Create);
    EpArr := TJSONArray.Create;
    EpArr.AddElement(Ep);
    Result := TJSONObject.Create
      .AddPair('seasons', TJSONArray.Create)
      .AddPair('info', TJSONObject.Create
        .AddPair('name', Stream.Name)
        .AddPair('cover', Stream.Logo))
      .AddPair('episodes', TJSONObject.Create
        .AddPair('1', EpArr));
  finally
    Stream.Free;
  end;
end;

// Xtream get_short_epg / get_simple_data_table: EPG for one stream_id.
// title/description are base64 (Xtream spec); times as UTC string + unix timestamp.
function BuildEpgListings(const AList: TCustomList; const AStreamId: string;
  ALimit: Integer; AOnlyFuture: Boolean): TJSONObject;
var
  Channels: TOutputChannelList;
  Ch: TOutputChannel;
  Progs: TEpgProgrammeList;
  Arr: TJSONArray;
  O: TJSONObject;
  P: TEpgProgramme;
  NowU: TDateTime;
  Cnt, StreamId, ArchiveDays: Integer;
  ArchiveFrom: TDateTime;
  Tvg: string;
  Tvgs: TArray<string>;

  function B64(const S: string): string;
  begin
    Result := XtreamBase64(S); // single line: no CR/LF every 76 chars (MyTVOnline rejects those)
  end;

begin
  Result := TJSONObject.Create;
  Arr := TJSONArray.Create;
  Result.AddPair('epg_listings', Arr);

  // Resolve the channel's EFFECTIVE tvg-id from the curated list, not the raw
  // upstream one — a per-item tvg-id override RELABELS the guide, and xmltv.php
  // serves under that effective id. Query BOTH the effective and the upstream id
  // (programmes may be stored under either) so the box's inline now/next matches
  // what xmltv.php shows. Only channels actually on this list get EPG.
  StreamId := StreamIdFromParam(AStreamId);
  Tvg := '';
  ArchiveDays := 0;
  Channels := App.Store.LoadOutputChannels(AList.Id);
  try
    for Ch in Channels do
      if Ch.StreamItemId = StreamId then
      begin
        Tvg := Ch.TvgId; // effective (override-or-upstream)
        ArchiveDays := Ch.ArchiveDays;
        Tvgs := Ch.EpgReadIds; // own ids, or the matched extra guide
        Break;
      end;
  finally
    Channels.Free;
  end;
  if Length(Tvgs) = 0 then
    Exit; // not on the list, or no tvg-id at all

  NowU := NowUtc;
  ArchiveFrom := IncDay(NowU, -ArchiveDays);
  Progs := App.Store.LoadEpgForTvgIds(Tvgs, App.Config.EpgMaxDays); // sorted by start
  try
    Cnt := 0;
    for P in Progs do
    begin
      if AOnlyFuture and (P.StopUtc < NowU) then
        Continue;
      O := TJSONObject.Create;
      // real portals send non-empty ids; some players (Formuler/MyTVOnline) key the
      // listing on them — the start time is unique within one channel
      O.AddPair('id', IntToStr(DateTimeToUnix(P.StartUtc, True)));
      O.AddPair('epg_id', '1');
      O.AddPair('title', B64(P.Title));
      O.AddPair('lang', '');
      O.AddPair('start', FormatDateTime('yyyy-mm-dd hh:nn:ss', P.StartUtc));
      O.AddPair('end', FormatDateTime('yyyy-mm-dd hh:nn:ss', P.StopUtc));
      O.AddPair('description', B64(P.Description));
      O.AddPair('channel_id', Tvg);
      O.AddPair('start_timestamp', IntToStr(DateTimeToUnix(P.StartUtc, True)));
      O.AddPair('stop_timestamp', IntToStr(DateTimeToUnix(P.StopUtc, True)));
      O.AddPair('now_playing', TJSONNumber.Create(IfThen((NowU >= P.StartUtc) and (NowU < P.StopUtc), 1, 0)));
      // a finished programme inside the provider's archive window can be replayed
      O.AddPair('has_archive', TJSONNumber.Create(IfThen((ArchiveDays > 0) and
        (P.StopUtc <= NowU) and (P.StartUtc >= ArchiveFrom), 1, 0)));
      Arr.Add(O);
      Inc(Cnt);
      if (ALimit > 0) and (Cnt >= ALimit) then
        Break;
    end;
  finally
    Progs.Free;
  end;
end;

// operator-facing label for the upstream provider a stream belongs to: the
// source name the operator gave it plus the upstream host, e.g. ProviderA (cdn.x.net)
function ProviderLabel(ASourceId: Integer; const AUpstreamUrl: string): string;
var
  Sources: TObjectList<TSourceConfig>;
  S: TSourceConfig;
  Name, Host: string;
begin
  Name := '';
  Sources := App.Store.LoadSources;
  try
    for S in Sources do
      if S.Id = ASourceId then
      begin
        Name := S.Name;
        Break;
      end;
  finally
    Sources.Free;
  end;
  Host := '';
  try
    Host := TURI.Create(AUpstreamUrl).Host;
  except
    Host := '';
  end;
  if (Name <> '') and (Host <> '') then
    Result := Format('"%s" (%s)', [Name, Host])
  else if Name <> '' then
    Result := Format('"%s"', [Name])
  else if Host <> '' then
    Result := Host
  else
    Result := Format('source #%d', [ASourceId]);
end;

// true when the operator ticked "live always as HLS" on this stream's source
function SourceForcesHls(ASourceId: Integer): Boolean;
var
  Sources: TObjectList<TSourceConfig>;
  S: TSourceConfig;
begin
  Result := False;
  Sources := App.Store.LoadSources;
  try
    for S in Sources do
      if S.Id = ASourceId then
        Exit(S.ForceHls);
  finally
    Sources.Free;
  end;
end;

procedure DoRedirect(const AResponse: IMARSResponse; const AUser, APass, AId: string;
  ALive: Boolean = False);
var
  List: TCustomList;
  Stream: TStreamItem;
  Target, Masked, Provider, Ext: string;
  Uri: TURI;
  Hls: Boolean;
begin
  List := ResolveList(AUser, APass);
  if List = nil then
  begin
    AResponse.StatusCode := 401;
    Exit;
  end;
  try
    // scope the lookup to THIS list: the credentials authorise one list, so a box
    // must not be able to stream an arbitrary catalog id that isn't on it.
    Stream := App.Store.LoadListStreamById(List.Id, StreamIdFromParam(AId));
    if Stream = nil then
    begin
      AResponse.StatusCode := 404;
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
        Ext := RequestedExt(AId)
      else
        Ext := '';
      Hls := ALive and SourceForcesHls(Stream.SourceId);
      if Hls then
        Ext := 'm3u8';
      if App.Config.ProxyStreams and not Hls then
      begin
        Target := Format('http://%s:%d/live/%s/%s/%s', [PublicHost, App.Config.ProxyPort,
          PathCred(List.OutputUsername), PathCred(List.OutputPassword), AId]);
      end
      else
        // only an Xtream LIVE .ts/.m3u8 URL follows the box's container choice
        Target := LiveUpstreamUrl(App.Store, Stream, Ext);
      // mask both path-style (/live/u/p/) AND query-style (?username=&password=)
      // credentials before logging — upstream M3U URLs often carry query creds
      Masked := TRegEx.Replace(Target, '(/(live|movie|series)/)[^/]+/[^/]+/', '$1***/***/', [roIgnoreCase]);
      Masked := TRegEx.Replace(Masked, '([?&](username|password|pass|pw|user|token|auth|mac)=)[^&]*', '$1***', [roIgnoreCase]);
      // always name the upstream provider being routed to (in proxy mode Target is
      // our own relay URL, so the provider would otherwise be invisible in the log)
      Provider := ProviderLabel(Stream.SourceId, Stream.UpstreamUrl);
      if App.Config.ProxyStreams and not Hls then
        App.Log(Format('  proxy stream %s "%s" -> provider %s  [relay %s]',
          [AId, Stream.Name, Provider, Masked]))
      else
        App.Log(Format('  redirect stream %s "%s" -> provider %s  [%s]%s',
          [AId, Stream.Name, Provider, Masked, System.StrUtils.IfThen(Hls, '  (HLS forced)', '')]));
      AResponse.RedirectTo(Target);
    finally
      Stream.Free;
    end;
  finally
    List.Free;
  end;
end;

// catch-up: resolve the list stream and 302 to the provider's timeshift URL. In
// proxy mode bounce to the relay port instead (it serves /timeshift/ too), so a
// box that can only reach this server still gets the archive.
procedure DoTimeshift(const AResponse: IMARSResponse; const AUser, APass,
  ADuration, AStart, AId: string);
var
  List: TCustomList;
  Stream: TStreamItem;
  StartUtc: TDateTime;
  Dur: Integer;
  Ext, Target, Masked: string;
  Uri: TURI;
begin
  Dur := StrToIntDef(ADuration, 0);
  if (Dur <= 0) or not ParseTimeshiftStart(AStart, StartUtc) then
  begin
    AResponse.StatusCode := 400;
    Exit;
  end;
  List := ResolveList(AUser, APass);
  if List = nil then
  begin
    AResponse.StatusCode := 401;
    Exit;
  end;
  try
    // list-scoped, like the live redirect: only channels on THIS list
    Stream := App.Store.LoadListStreamById(List.Id, StreamIdFromParam(AId));
    if Stream = nil then
    begin
      AResponse.StatusCode := 404;
      Exit;
    end;
    try
      Ext := RequestedExt(AId);
      if App.Config.ProxyStreams then
      begin
        Target := Format('http://%s:%d/timeshift/%s/%s/%d/%s/%d.%s',
          [PublicHost, App.Config.ProxyPort, PathCred(List.OutputUsername), PathCred(List.OutputPassword),
           Dur, FormatTimeshiftStart(StartUtc),
           Stream.Id, System.StrUtils.IfThen(Ext = '', 'ts', Ext)]);
      end
      else
        Target := TimeshiftUpstreamUrl(App.Store, Stream, Dur, StartUtc, Ext);
      if Target = '' then
      begin
        // the stream's source isn't an Xtream portal: no timeshift there
        AResponse.StatusCode := 404;
        Exit;
      end;
      Masked := TRegEx.Replace(Target, '(/timeshift/)[^/]+/[^/]+/', '$1***/***/', [roIgnoreCase]);
      App.Log(Format('  timeshift stream %d "%s" %s UTC +%d min -> provider %s  [%s]',
        [Stream.Id, Stream.Name, FormatTimeshiftStart(StartUtc), Dur,
         ProviderLabel(Stream.SourceId, Stream.UpstreamUrl), Masked]));
      AResponse.RedirectTo(Target);
    finally
      Stream.Free;
    end;
  finally
    List.Free;
  end;
end;

{ TPlayerApiResource }

function TPlayerApiResource.PlayerApi(AUser, APass, AAction, AStreamId: string; ALimit: string;
  AVodId, ASeriesId, ACategoryId: string): TJSONValue;
var
  List: TCustomList;
begin
  List := ResolveList(AUser, APass);
  if List = nil then
  begin
    Response.StatusCode := 401;
    Exit(TJSONObject.Create.AddPair('user_info',
      TJSONObject.Create.AddPair('auth', TJSONNumber.Create(0))));
  end;
  try
    if AAction = 'get_short_epg' then
      Result := BuildEpgListings(List, AStreamId, IfThen(StrToIntDef(ALimit, 0) > 0, StrToIntDef(ALimit, 0), 4), True)
    else if AAction = 'get_simple_data_table' then
      Result := BuildEpgListings(List, AStreamId, 0, False)
    else if AAction = 'get_vod_info' then
      Result := VodInfo(List, AVodId)
    else if AAction = 'get_series_info' then
      Result := SeriesInfo(List, ASeriesId)
    else
      Result := PlayerApiResult(List, AAction, ACategoryId);
  finally
    List.Free;
  end;
end;

{ TGetPhpResource }

function TGetPhpResource.GetPhp(AUser, APass: string): string;
var
  List: TCustomList;
  Prefix: string;
  Uri: TURI;
begin
  List := ResolveList(AUser, APass);
  if List = nil then
  begin
    Response.StatusCode := 401;
    Exit('');
  end;
  try
    Prefix := '';
    if App.Config.ProxyStreams then
    begin
      Prefix := Format('http://%s:%d/live/%s/%s/',
        [PublicHost, App.Config.ProxyPort, PathCred(List.OutputUsername), PathCred(List.OutputPassword)]);
    end;
    // the Media Servers group filter is for the Plex bouquet only — a box gets its
    // whole bouquet (group names of one bouquet mean nothing in another)
    Result := BuildM3U(App.Store, List.Id, Prefix, False, nil);
  finally
    List.Free;
  end;
end;

{ TXmltvResource }

function TXmltvResource.Xmltv(AUser, APass: string): string;
var
  List: TCustomList;
begin
  List := ResolveList(AUser, APass);
  if List = nil then
  begin
    Response.StatusCode := 401;
    Exit('');
  end;
  try
    Result := BuildXmltv(App.Store, List.Id, App.Config.EpgMaxDays,
      TDummyEpgOptions.Make(App.Config.DummyEpgEnabled, App.Config.DummyEpgBlockMinutes,
        App.Config.DummyEpgHoursBack, App.Config.DummyEpgHoursAhead),
      nil); // group filter is Plex-only (see get.php)
  finally
    List.Free;
  end;
end;

{ stream resources }

procedure TLiveStreamResource.Redirect(AUser, APass, AId: string);
begin
  DoRedirect(Response, AUser, APass, AId, True);
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
