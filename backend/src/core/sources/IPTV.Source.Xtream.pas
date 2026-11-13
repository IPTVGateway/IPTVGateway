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
  System.JSON,
  IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Source.Intf;

type
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
  System.SysUtils, System.Generics.Collections,
  System.NetEncoding, System.DateUtils, System.Math,
  IPTV.Model.Types, IPTV.Source.Http, IPTV.Core.Utils;

function TXtreamReader.ApiUrl(const ASource: TSourceConfig; const AAction: string): string;
begin
  // Trim whitespace too (a stray leading/trailing space in the URL would make
  // the request malformed → WinHTTP 12152 / "connection closed"), not just '/'.
  Result := Format('%s/player_api.php?username=%s&password=%s&action=%s',
    [ASource.Url.Trim.TrimRight(['/']),
     TNetEncoding.URL.Encode(ASource.Username.Trim),
     TNetEncoding.URL.Encode(ASource.Password.Trim),
     AAction]);
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
  JV: TJSONValue;
  Item: TJSONValue;
  Obj: TJSONObject;
  Cat: TCategory;
begin
  JV := TJSONValue(FetchJson(ApiUrl(ASource, AAction), ASource.UserAgent, ASource.Referer));
  try
    if not (JV is TJSONArray) then
      Exit;
    for Item in TJSONArray(JV) do
    begin
      if not (Item is TJSONObject) then Continue;
      Obj := TJSONObject(Item);
      Cat := TCategory.Create;
      ASnapshot.Categories.Add(Cat); // own immediately so a GetValue type-mismatch can't leak it
      Cat.SourceId := ASource.Id;
      Cat.ContentType := TContentType(AContentType);
      Cat.UpstreamId := Obj.GetValue<string>('category_id', '');
      Cat.Name := Obj.GetValue<string>('category_name', '');
    end;
  finally
    JV.Free;
  end;
end;

procedure TXtreamReader.LoadStreams(const ASource: TSourceConfig; ASnapshot: TSourceSnapshot;
  AContentType: Integer; const AAction, AStreamPath: string);
var
  JV: TJSONValue;
  Item: TJSONValue;
  Obj: TJSONObject;
  S: TStreamItem;
  StreamId, Ext: string;
begin
  JV := TJSONValue(FetchJson(ApiUrl(ASource, AAction), ASource.UserAgent, ASource.Referer));
  try
    if not (JV is TJSONArray) then
      Exit;
    for Item in TJSONArray(JV) do
    begin
      if not (Item is TJSONObject) then Continue;
      Obj := TJSONObject(Item);
      StreamId := Obj.GetValue<string>('stream_id', Obj.GetValue<string>('series_id', ''));

      S := TStreamItem.Create;
      ASnapshot.Streams.Add(S); // own immediately so a GetValue type-mismatch can't leak it
      S.SourceId := ASource.Id;
      S.ContentType := TContentType(AContentType);
      // radio arrives in get_live_streams, flagged stream_type=radio_streams
      if (S.ContentType = ctLive) and SameText(Obj.GetValue<string>('stream_type', ''), 'radio_streams') then
        S.ContentType := ctRadio;
      // live and radio share one call: drop the type the operator switched off
      if not ASource.EnabledFor(S.ContentType) then
      begin
        ASnapshot.Streams.Remove(S); // owned list: frees it
        Continue;
      end;
      S.UpstreamId := StreamId;
      S.Name := Obj.GetValue<string>('name', '');
      S.Logo := Obj.GetValue<string>('stream_icon', Obj.GetValue<string>('cover', ''));
      S.TvgId := Obj.GetValue<string>('epg_channel_id', '');
      S.CategoryUpstreamId := Obj.GetValue<string>('category_id', '');
      // catch-up: tv_archive=1 + tv_archive_duration (days); numbers or strings
      if (AContentType = Ord(ctLive)) and
         (StrToIntDef(Obj.GetValue<string>('tv_archive', '0'), 0) = 1) then
        S.ArchiveDays := Max(1, StrToIntDef(Obj.GetValue<string>('tv_archive_duration', '1'), 1))
      else
        S.ArchiveDays := 0;
      // Real provider URL the box is redirected to. The extension differs per type:
      // VOD/movies carry a container_extension (mkv/mp4/…) and a .ts guess 404s on
      // players that don't negotiate; live has none, so .ts is the safe default.
      Ext := Obj.GetValue<string>('container_extension', '').Trim;
      if Ext = '' then
        Ext := 'ts';
      S.UpstreamUrl := Format('%s/%s/%s/%s/%s.%s',
        [ASource.Url.Trim.TrimRight(['/']), AStreamPath, ASource.Username.Trim, ASource.Password.Trim, StreamId, Ext]);
    end;
  finally
    JV.Free;
  end;
end;

// player_api.php without an action answers the account: user_info.status,
// exp_date (unix seconds as string, or null = no end date), max_connections.
// Best effort: a portal that refuses it must not fail the catalog refresh.
procedure TXtreamReader.LoadAccountInfo(const ASource: TSourceConfig; ASnapshot: TSourceSnapshot);
var
  JV, UI, SI, V: TJSONValue;
  Exp, UnixNow: Int64;
  Offs: Integer;
begin
  try
    JV := TJSONValue(FetchJson(Format('%s/player_api.php?username=%s&password=%s',
      [ASource.Url.Trim.TrimRight(['/']),
       TNetEncoding.URL.Encode(ASource.Username.Trim),
       TNetEncoding.URL.Encode(ASource.Password.Trim)]), ASource.UserAgent, ASource.Referer));
    try
      if not (JV is TJSONObject) then Exit;
      UI := TJSONObject(JV).GetValue('user_info');
      if not (UI is TJSONObject) then Exit;
      ASnapshot.HasAccountInfo := True;
      ASnapshot.AccountStatus := TJSONObject(UI).GetValue<string>('status', '');
      V := TJSONObject(UI).GetValue('exp_date');
      ASnapshot.ExpiresUtc := 0;
      if (V <> nil) and not (V is TJSONNull) and TryStrToInt64(V.Value, Exp) and (Exp > 0) then
        ASnapshot.ExpiresUtc := UnixToDateTime(Exp, True);
      ASnapshot.MaxConnections := StrToIntDef(TJSONObject(UI).GetValue<string>('max_connections', '0'), 0);
      // the portal's clock: timeshift start times are in its local time
      SI := TJSONObject(JV).GetValue('server_info');
      if SI is TJSONObject then
      begin
        UnixNow := StrToInt64Def(TJSONObject(SI).GetValue<string>('timestamp_now', '0'), 0);
        if XtreamTzOffsetMin(TJSONObject(SI).GetValue<string>('time_now', ''), UnixNow, Offs) then
        begin
          ASnapshot.HasTzOffset := True;
          ASnapshot.TzOffsetMin := Offs;
        end;
      end;
    finally
      JV.Free;
    end;
  except
    // account info is a nicety; keep the previous values when it fails
    ASnapshot.HasAccountInfo := False;
  end;
end;

function XtreamApiGet(const ASource: TSourceConfig; const AQuery: string): TJSONValue;
begin
  Result := TJSONObject.ParseJSONValue(HttpGetString(
    Format('%s/player_api.php?username=%s&password=%s&%s',
      [ASource.Url.Trim.TrimRight(['/']),
       TNetEncoding.URL.Encode(ASource.Username.Trim),
       TNetEncoding.URL.Encode(ASource.Password.Trim), AQuery]),
    ASource.UserAgent, TimeoutPortalMs, ASource.Referer));
end;

procedure ApplyCategoryNames(ASnapshot: TSourceSnapshot);
var
  Cat: TCategory;
  S: TStreamItem;
  Names: TDictionary<string, string>;
  Key, N: string;
begin
  // Xtream streams only carry a category_id; copy the category NAME into
  // group_title so downstream M3U/output shows proper groups.
  Names := TDictionary<string, string>.Create;
  try
    for Cat in ASnapshot.Categories do
      Names.AddOrSetValue(ContentTypeNames[Cat.ContentType] + '|' + Cat.UpstreamId, Cat.Name);
    for S in ASnapshot.Streams do
    begin
      Key := ContentTypeNames[S.ContentType] + '|' + S.CategoryUpstreamId;
      if Names.TryGetValue(Key, N) then
        S.GroupTitle := N
      else if (S.ContentType = ctRadio) and
        Names.TryGetValue(ContentTypeNames[ctLive] + '|' + S.CategoryUpstreamId, N) then
        S.GroupTitle := N; // radio sits in the live categories
    end;
  finally
    Names.Free;
  end;
end;

function TXtreamReader.Read(const ASource: TSourceConfig): TSourceSnapshot;
begin
  Result := TSourceSnapshot.Create(ASource.Id);
  try
    LoadAccountInfo(ASource, Result);
    if ASource.EnabledFor(ctLive) or ASource.EnabledFor(ctRadio) then
    begin
      LoadCategories(ASource, Result, Ord(ctLive), 'get_live_categories');
      LoadStreams(ASource, Result, Ord(ctLive), 'get_live_streams', 'live');
    end;
    if ASource.EnabledFor(ctMovie) then
    begin
      LoadCategories(ASource, Result, Ord(ctMovie), 'get_vod_categories');
      LoadStreams(ASource, Result, Ord(ctMovie), 'get_vod_streams', 'movie');
    end;
    if ASource.EnabledFor(ctSeries) then
    begin
      LoadCategories(ASource, Result, Ord(ctSeries), 'get_series_categories');
      LoadStreams(ASource, Result, Ord(ctSeries), 'get_series', 'series');
    end;
    ApplyCategoryNames(Result);
  except
    Result.Free;
    raise;
  end;
end;

end.
