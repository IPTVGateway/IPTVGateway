unit IPTV.Source.Xtream;

{ Reads an upstream Xtream Codes portal through player_api.php.

  Endpoints used (per enabled content type):
    action=get_live_categories / get_live_streams
    action=get_vod_categories  / get_vod_streams
    action=get_series_categories / get_series
  Radio, where the portal exposes it, arrives as live streams flagged radio.

  Stream URLs are stored as the *real upstream* URL; downstream we redirect the
  box straight to them (video never flows through our service). }

interface

uses
  // RTL
  System.JSON,
  // Own units
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Source.Intf;

type
  /// Source reader for an upstream Xtream Codes portal (player_api.php).
  TXtreamReader = class(TInterfacedObject, ISourceReader)
  private
    function ApiUrl(const ASource: TSourceConfig; const AAction: string): string;
    function FetchJson(const AUrl, AUserAgent, AReferer: string): TObject; // returns TJSONValue (caller frees)
    procedure LoadCategories(const ASource: TSourceConfig; ASnapshot: TSourceSnapshot;
      AContentType: Integer; const AAction: string);
    procedure LoadAccountInfo(const ASource: TSourceConfig; ASnapshot: TSourceSnapshot);
    procedure LoadStreams(const ASource: TSourceConfig; ASnapshot: TSourceSnapshot;
      AContentType: Integer; const AAction, AStreamPath: string);
  public
    function Read(const ASource: TSourceConfig): TSourceSnapshot;
  end;

/// One player_api.php call on an upstream Xtream portal, e.g. AQuery =
/// 'action=get_series_info&series_id=12'. Caller frees; nil when the answer
/// isn't JSON. Raises on network errors.
function XtreamApiGet(const ASource: TSourceConfig; const AQuery: string): TJSONValue;

implementation

uses
  // RTL
  System.SysUtils,
  System.Generics.Collections,
  System.NetEncoding,
  System.DateUtils,
  System.Math,
  // Own units
  IPTV.Model.Types,
  IPTV.Source.Http,
  IPTV.Core.Utils;

const
  // player_api.php actions
  cActionLiveCategories = 'get_live_categories';
  cActionLiveStreams = 'get_live_streams';
  cActionVodCategories = 'get_vod_categories';
  cActionVodStreams = 'get_vod_streams';
  cActionSeriesCategories = 'get_series_categories';
  cActionSeries = 'get_series';

  // stream URL path segments (<base>/<segment>/<user>/<pass>/<id>.<ext>)
  cPathLive = 'live';
  cPathMovie = 'movie';
  cPathSeries = 'series';
  cExtTs = 'ts';                       // live has no container_extension

  // JSON fields
  cJsonCategoryId = 'category_id';
  cJsonStreamType = 'stream_type';
  cStreamTypeRadio = 'radio_streams';

  // key separator of the content-type|category-id lookup
  cCategoryKeySep = '|';

  cReturnUtc = True;                   // UnixToDateTime AReturnUTC

// <base>/player_api.php?username=U&password=P (URL-encoded, trimmed)
function PlayerApiBaseUrl(const ASource: TSourceConfig): string;
begin
  Result := Format('%s/player_api.php?username=%s&password=%s',
    [ASource.Url.Trim.TrimRight(['/']),
     TNetEncoding.URL.Encode(ASource.Username.Trim),
     TNetEncoding.URL.Encode(ASource.Password.Trim)]);
end;

function TXtreamReader.ApiUrl(const ASource: TSourceConfig; const AAction: string): string;
begin
  // Trim whitespace too (a stray leading/trailing space in the URL would make
  // the request malformed → WinHTTP 12152 / "connection closed"), not just '/'.
  Result := PlayerApiBaseUrl(ASource) + '&action=' + AAction;
end;

function TXtreamReader.FetchJson(const AUrl, AUserAgent, AReferer: string): TObject;
begin
  // http via Indy / https via WinHTTP — see IPTV.Source.Http. Portal API calls
  // answer fast, so use the short timeout.
  Result := TJSONObject.ParseJSONValue(HttpGetString(AUrl, AUserAgent, TimeoutPortalMs, AReferer));
end;

procedure TXtreamReader.LoadCategories(const ASource: TSourceConfig; ASnapshot: TSourceSnapshot;
  AContentType: Integer; const AAction: string);
var
  lJson: TJSONValue;
  lItem: TJSONValue;
  lObj: TJSONObject;
  lCat: TCategory;
begin
  lJson := TJSONValue(FetchJson(ApiUrl(ASource, AAction), ASource.UserAgent, ASource.Referer));
  try
    if not (lJson is TJSONArray) then
      Exit;
    for lItem in TJSONArray(lJson) do
    begin
      if not (lItem is TJSONObject) then
        Continue;
      lObj := TJSONObject(lItem);
      lCat := TCategory.Create;
      ASnapshot.Categories.Add(lCat); // own immediately so a GetValue type-mismatch can't leak it
      lCat.SourceId := ASource.Id;
      lCat.ContentType := TContentType(AContentType);
      lCat.UpstreamId := lObj.GetValue<string>(cJsonCategoryId, '');
      lCat.Name := lObj.GetValue<string>('category_name', '');
    end;
  finally
    FreeAndNil(lJson);
  end;
end;

procedure TXtreamReader.LoadStreams(const ASource: TSourceConfig; ASnapshot: TSourceSnapshot;
  AContentType: Integer; const AAction, AStreamPath: string);
var
  lJson: TJSONValue;
  lItem: TJSONValue;
  lObj: TJSONObject;
  lStream: TStreamItem;
  lStreamId, lExt: string;
begin
  lJson := TJSONValue(FetchJson(ApiUrl(ASource, AAction), ASource.UserAgent, ASource.Referer));
  try
    if not (lJson is TJSONArray) then
      Exit;
    for lItem in TJSONArray(lJson) do
    begin
      if not (lItem is TJSONObject) then
        Continue;
      lObj := TJSONObject(lItem);
      lStreamId := lObj.GetValue<string>('stream_id', lObj.GetValue<string>('series_id', ''));

      lStream := TStreamItem.Create;
      ASnapshot.Streams.Add(lStream); // own immediately so a GetValue type-mismatch can't leak it
      lStream.SourceId := ASource.Id;
      lStream.ContentType := TContentType(AContentType);
      // radio arrives in get_live_streams, flagged stream_type=radio_streams
      if (lStream.ContentType = ctLive) and SameText(lObj.GetValue<string>(cJsonStreamType, ''), cStreamTypeRadio) then
        lStream.ContentType := ctRadio;
      // live and radio share one call: drop the type the operator switched off
      if not ASource.EnabledFor(lStream.ContentType) then
      begin
        ASnapshot.Streams.Remove(lStream); // owned list: frees it
        Continue;
      end;
      lStream.UpstreamId := lStreamId;
      lStream.Name := lObj.GetValue<string>('name', '');
      lStream.Logo := lObj.GetValue<string>('stream_icon', lObj.GetValue<string>('cover', ''));
      lStream.TvgId := lObj.GetValue<string>('epg_channel_id', '');
      lStream.CategoryUpstreamId := lObj.GetValue<string>(cJsonCategoryId, '');
      // catch-up: tv_archive=1 + tv_archive_duration (days); numbers or strings
      if (AContentType = Ord(ctLive)) and
         (StrToIntDef(lObj.GetValue<string>('tv_archive', '0'), 0) = 1) then
        lStream.ArchiveDays := Max(1, StrToIntDef(lObj.GetValue<string>('tv_archive_duration', '1'), 1))
      else
        lStream.ArchiveDays := 0;
      // Real provider URL the box is redirected to. The extension differs per type:
      // VOD/movies carry a container_extension (mkv/mp4/…) and a .ts guess 404s on
      // players that don't negotiate; live has none, so .ts is the safe default.
      lExt := lObj.GetValue<string>('container_extension', '').Trim;
      if lExt = '' then
        lExt := cExtTs;
      lStream.UpstreamUrl := Format('%s/%s/%s/%s/%s.%s',
        [ASource.Url.Trim.TrimRight(['/']), AStreamPath, ASource.Username.Trim, ASource.Password.Trim,
         lStreamId, lExt]);
    end;
  finally
    FreeAndNil(lJson);
  end;
end;

// player_api.php without an action answers the account: user_info.status,
// exp_date (unix seconds as string, or null = no end date), max_connections.
// Best effort: a portal that refuses it must not fail the catalog refresh.
procedure TXtreamReader.LoadAccountInfo(const ASource: TSourceConfig; ASnapshot: TSourceSnapshot);
var
  lJson, lUserInfo, lServerInfo, lExpValue: TJSONValue;
  lExp, lUnixNow: Int64;
  lOffset: Integer;
begin
  try
    lJson := TJSONValue(FetchJson(PlayerApiBaseUrl(ASource), ASource.UserAgent, ASource.Referer));
    try
      if not (lJson is TJSONObject) then
        Exit;
      lUserInfo := TJSONObject(lJson).GetValue('user_info');
      if not (lUserInfo is TJSONObject) then
        Exit;
      ASnapshot.HasAccountInfo := True;
      ASnapshot.AccountStatus := TJSONObject(lUserInfo).GetValue<string>('status', '');
      lExpValue := TJSONObject(lUserInfo).GetValue('exp_date');
      ASnapshot.ExpiresUtc := 0;
      if (lExpValue <> nil) and not (lExpValue is TJSONNull) and TryStrToInt64(lExpValue.Value, lExp) and
         (lExp > 0) then
        ASnapshot.ExpiresUtc := UnixToDateTime(lExp, cReturnUtc);
      ASnapshot.MaxConnections := StrToIntDef(TJSONObject(lUserInfo).GetValue<string>('max_connections', '0'), 0);
      // the portal's clock: timeshift start times are in its local time
      lServerInfo := TJSONObject(lJson).GetValue('server_info');
      if lServerInfo is TJSONObject then
      begin
        lUnixNow := StrToInt64Def(TJSONObject(lServerInfo).GetValue<string>('timestamp_now', '0'), 0);
        if XtreamTzOffsetMin(TJSONObject(lServerInfo).GetValue<string>('time_now', ''), lUnixNow, lOffset) then
        begin
          ASnapshot.HasTzOffset := True;
          ASnapshot.TzOffsetMin := lOffset;
        end;
      end;
    finally
      FreeAndNil(lJson);
    end;
  except
    // account info is a nicety; keep the previous values when it fails
    ASnapshot.HasAccountInfo := False;
  end;
end;

function XtreamApiGet(const ASource: TSourceConfig; const AQuery: string): TJSONValue;
begin
  Result := TJSONObject.ParseJSONValue(HttpGetString(
    PlayerApiBaseUrl(ASource) + '&' + AQuery,
    ASource.UserAgent, TimeoutPortalMs, ASource.Referer));
end;

procedure ApplyCategoryNames(ASnapshot: TSourceSnapshot);
var
  lCat, lRadioCat: TCategory;
  lStream: TStreamItem;
  lNames: TDictionary<string, string>;
  lKey, lName: string;
begin
  // Xtream streams only carry a category_id; copy the category NAME into
  // group_title so downstream M3U/output shows proper groups.
  lNames := TDictionary<string, string>.Create;
  try
    for lCat in ASnapshot.Categories do
      lNames.AddOrSetValue(ContentTypeNames[lCat.ContentType] + cCategoryKeySep + lCat.UpstreamId, lCat.Name);
    for lStream in ASnapshot.Streams do
    begin
      lKey := ContentTypeNames[lStream.ContentType] + cCategoryKeySep + lStream.CategoryUpstreamId;
      if lNames.TryGetValue(lKey, lName) then
        lStream.GroupTitle := lName
      else if (lStream.ContentType = ctRadio) and
        lNames.TryGetValue(ContentTypeNames[ctLive] + cCategoryKeySep + lStream.CategoryUpstreamId, lName) then
      begin
        lStream.GroupTitle := lName; // radio sits in the live categories ...
        // ... so give radio its own copy of that category (browsable as radio,
        // and kept when only radio is switched on)
        if not lNames.ContainsKey(ContentTypeNames[ctRadio] + cCategoryKeySep + lStream.CategoryUpstreamId) then
        begin
          lRadioCat := TCategory.Create;
          ASnapshot.Categories.Add(lRadioCat);
          lRadioCat.SourceId := ASnapshot.SourceId;
          lRadioCat.ContentType := ctRadio;
          lRadioCat.UpstreamId := lStream.CategoryUpstreamId;
          lRadioCat.Name := lName;
          lNames.Add(ContentTypeNames[ctRadio] + cCategoryKeySep + lStream.CategoryUpstreamId, lName);
        end;
      end;
    end;
  finally
    FreeAndNil(lNames);
  end;
end;

function TXtreamReader.Read(const ASource: TSourceConfig): TSourceSnapshot;
begin
  Result := TSourceSnapshot.Create(ASource.Id);
  try
    LoadAccountInfo(ASource, Result);
    if ASource.EnabledFor(ctLive) or ASource.EnabledFor(ctRadio) then
    begin
      LoadCategories(ASource, Result, Ord(ctLive), cActionLiveCategories);
      LoadStreams(ASource, Result, Ord(ctLive), cActionLiveStreams, cPathLive);
    end;
    if ASource.EnabledFor(ctMovie) then
    begin
      LoadCategories(ASource, Result, Ord(ctMovie), cActionVodCategories);
      LoadStreams(ASource, Result, Ord(ctMovie), cActionVodStreams, cPathMovie);
    end;
    if ASource.EnabledFor(ctSeries) then
    begin
      LoadCategories(ASource, Result, Ord(ctSeries), cActionSeriesCategories);
      LoadStreams(ASource, Result, Ord(ctSeries), cActionSeries, cPathSeries);
    end;
    ApplyCategoryNames(Result);
  except
    Result.Free;
    raise;
  end;
end;

end.
