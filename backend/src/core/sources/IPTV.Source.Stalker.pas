unit IPTV.Source.Stalker;

{ Reader for Stalker / Ministra (MAG) portals.

  Unlike Xtream (a clean JSON API) a Stalker portal emulates a MAG set-top box:
  it authenticates by MAC address + a handshake token and gates every call on
  MAG-style headers (X-User-Agent with the model, a Cookie carrying the mac /
  stb_lang / timezone, and a Bearer token after the handshake).

  Credential mapping onto TSourceConfig:
    - Url      = portal base (we normalise to .../portal.php or .../server/load.php)
    - Username = the device MAC (e.g. 00:1A:79:AA:BB:CC)
    - UserAgent / Referer = optional per-provider overrides (as for other kinds)

  EXPERIMENTAL: the handshake + header + URL building below is unit-tested and
  matches the documented MAG protocol, but the live catalog mapping (genres /
  ordered_list / create_link) needs a real portal to validate — channel URLs may
  require a per-channel create_link call on some panels. The public helpers are
  exposed so they can be tested without a network. }

interface

uses
  // Own units
  IPTV.Model.Source,
  IPTV.Model.Catalog,
  IPTV.Source.Intf;

const
  // A MAG-250 emulating User-Agent — the default unless the source overrides it.
  StalkerUserAgent =
    'Mozilla/5.0 (QtEmbedded; U; Linux; C) AppleWebKit/533.3 (KHTML, like Gecko) ' +
    'MAG200 stbapp ver: 2 rev: 250 Safari/533.3';
  StalkerXUserAgent = 'Model: MAG250; Link: WiFi';

/// Normalise a portal base URL to its load endpoint. Accepts a bare host, a
/// `/c/` console URL, or an explicit portal.php/load.php and returns the API
/// endpoint we should hit.
function StalkerPortalUrl(const ABaseUrl: string): string;
/// Build a portal action URL: <portal>?type=<type>&action=<action><extra>&JsHttpRequest=1-xml
function StalkerActionUrl(const APortal, AType, AAction, AExtra: string): string;
/// The Cookie header value carrying the MAC and locale a portal expects.
function StalkerCookie(const AMac: string): string;

type
  /// Source reader for Stalker / Ministra (MAG) portals (experimental).
  TStalkerReader = class(TInterfacedObject, ISourceReader)
  private
    FMac: string;
    FToken: string;
    FUserAgent: string;
    FReferer: string;
    FPortal: string;
    function Fetch(const AUrl: string): string;
    function Handshake: Boolean;
    procedure LoadGenresAndChannels(ASource: TSourceConfig; ASnapshot: TSourceSnapshot);
  public
    function Read(const ASource: TSourceConfig): TSourceSnapshot;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
  System.JSON,
  // Indy
  IdHTTP,
  IdGlobal,
  IdCookieManager,
  // Own units
  IPTV.Model.Types;

const
  // portal endpoints
  cPortalPhp = 'portal.php';
  cLoadPhp = 'load.php';
  cConsolePath = '/c';               // the MAG web console, stripped from the base

  // HTTP client
  cMaxRedirects = 5;
  cTimeoutConnectMs = 15000;
  cTimeoutReadMs = 30000;
  cHeaderXUserAgent = 'X-User-Agent';
  cHeaderCookie = 'Cookie';
  cHeaderAuthorization = 'Authorization';
  cBearerPrefix = 'Bearer ';

  // portal request types / actions
  cTypeStb = 'stb';
  cTypeItv = 'itv';
  cActionHandshake = 'handshake';
  cActionGetGenres = 'get_genres';
  cActionGetOrderedList = 'get_ordered_list';

  // JSON fields
  cJsonJs = 'js';                    // every answer is wrapped in {"js": ...}
  cJsonData = 'data';
  cJsonId = 'id';
  cJsonName = 'name';

  // channel cmd "ffmpeg http://.../ch/<id>": player prefix to strip
  cCmdPlayerPrefix = 'ffmpeg ';
  cIgnoreCase = True;                // string.StartsWith AIgnoreCase

  cMaxPages = 100;                   // hard safety cap on pagination

type
  // IPVersion is protected on TIdHTTP — a same-unit descendant exposes it.
  TIdHTTPAccess = class(TIdHTTP);

function StalkerPortalUrl(const ABaseUrl: string): string;
var
  lUrl: string;
begin
  lUrl := ABaseUrl.Trim.TrimRight(['/']);
  if lUrl.ToLower.EndsWith(cPortalPhp) or lUrl.ToLower.EndsWith(cLoadPhp) then
    Exit(lUrl);
  if lUrl.ToLower.EndsWith(cConsolePath) then
    lUrl := lUrl.Substring(0, lUrl.Length - Length(cConsolePath));
  Result := lUrl + '/' + cPortalPhp;
end;

function StalkerActionUrl(const APortal, AType, AAction, AExtra: string): string;
begin
  Result := Format('%s?type=%s&action=%s%s&JsHttpRequest=1-xml',
    [APortal, AType, AAction, AExtra]);
end;

function StalkerCookie(const AMac: string): string;
begin
  // mac must be URL-safe in the cookie; portals expect colons as %3A is optional,
  // most accept the raw mac. stb_lang/timezone are required by stricter panels.
  Result := Format('mac=%s; stb_lang=en; timezone=Europe/Amsterdam', [AMac]);
end;

{ TStalkerReader }

function TStalkerReader.Fetch(const AUrl: string): string;
var
  lHttp: TIdHTTP;
begin
  lHttp := TIdHTTP.Create(nil);
  try
    lHttp.HandleRedirects := True;
    lHttp.RedirectMaximum := cMaxRedirects;
    lHttp.AllowCookies := True;
    lHttp.CookieManager := TIdCookieManager.Create(lHttp);
    TIdHTTPAccess(lHttp).IPVersion := Id_IPv4;
    lHttp.ConnectTimeout := cTimeoutConnectMs;
    lHttp.ReadTimeout := cTimeoutReadMs;
    if FUserAgent <> '' then
      lHttp.Request.UserAgent := FUserAgent
    else
      lHttp.Request.UserAgent := StalkerUserAgent;
    if FReferer <> '' then
      lHttp.Request.Referer := FReferer;
    lHttp.Request.CustomHeaders.Values[cHeaderXUserAgent] := StalkerXUserAgent;
    lHttp.Request.CustomHeaders.Values[cHeaderCookie] := StalkerCookie(FMac);
    if FToken <> '' then
      lHttp.Request.CustomHeaders.Values[cHeaderAuthorization] := cBearerPrefix + FToken;
    Result := lHttp.Get(AUrl);
  finally
    FreeAndNil(lHttp);
  end;
end;

function TStalkerReader.Handshake: Boolean;
var
  lResp: string;
  lJson, lJs: TJSONValue;
begin
  Result := False;
  lResp := Fetch(StalkerActionUrl(FPortal, cTypeStb, cActionHandshake, '&token='));
  lJson := TJSONObject.ParseJSONValue(lResp);
  try
    if lJson is TJSONObject then
    begin
      lJs := TJSONObject(lJson).GetValue(cJsonJs);
      if lJs is TJSONObject then
      begin
        FToken := TJSONObject(lJs).GetValue<string>('token', '');
        Result := FToken <> '';
      end;
    end;
  finally
    FreeAndNil(lJson);
  end;
end;

procedure TStalkerReader.LoadGenresAndChannels(ASource: TSourceConfig;
  ASnapshot: TSourceSnapshot);
var
  lResp, lCmd: string;
  lJson, lJs: TJSONValue;
  lArr, lData: TJSONArray;
  lItem: TJSONValue;
  lObj: TJSONObject;
  lCat: TCategory;
  lStream: TStreamItem;
  lPage: Integer;
begin
  // genres → categories (live tv)
  lResp := Fetch(StalkerActionUrl(FPortal, cTypeItv, cActionGetGenres, ''));
  lJson := TJSONObject.ParseJSONValue(lResp);
  try
    if (lJson is TJSONObject) and (TJSONObject(lJson).GetValue(cJsonJs) is TJSONArray) then
    begin
      lArr := TJSONArray(TJSONObject(lJson).GetValue(cJsonJs));
      for lItem in lArr do
        if lItem is TJSONObject then
        begin
          lObj := TJSONObject(lItem);
          lCat := TCategory.Create;
          lCat.SourceId := ASource.Id;
          lCat.ContentType := ctLive;
          lCat.UpstreamId := lObj.GetValue<string>(cJsonId, '');
          lCat.Name := lObj.GetValue<string>('title', lObj.GetValue<string>(cJsonName, ''));
          ASnapshot.Categories.Add(lCat);
        end;
    end;
  finally
    FreeAndNil(lJson);
  end;

  // channels (paged) → streams
  lPage := 1;
  repeat
    lResp := Fetch(StalkerActionUrl(FPortal, cTypeItv, cActionGetOrderedList,
      Format('&genre=*&p=%d', [lPage])));
    lJson := TJSONObject.ParseJSONValue(lResp);
    try
      lData := nil;
      if lJson is TJSONObject then
      begin
        lJs := TJSONObject(lJson).GetValue(cJsonJs);
        if (lJs is TJSONObject) and (TJSONObject(lJs).GetValue(cJsonData) is TJSONArray) then
          lData := TJSONArray(TJSONObject(lJs).GetValue(cJsonData));
      end;
      if (lData = nil) or (lData.Count = 0) then
        Break;
      for lItem in lData do
        if lItem is TJSONObject then
        begin
          lObj := TJSONObject(lItem);
          lStream := TStreamItem.Create;
          lStream.SourceId := ASource.Id;
          lStream.ContentType := ctLive;
          lStream.UpstreamId := lObj.GetValue<string>(cJsonId, '');
          lStream.Name := lObj.GetValue<string>(cJsonName, '');
          lStream.Logo := lObj.GetValue<string>('logo', '');
          lStream.TvgId := lObj.GetValue<string>('xmltv_id', '');
          lStream.CategoryUpstreamId := lObj.GetValue<string>('tv_genre_id', '');
          // cmd is usually "ffmpeg http://.../ch/<id>" — strip the player prefix.
          // NOTE: some panels need a per-channel create_link call instead; that
          // refinement is pending a live portal to validate against.
          lCmd := lObj.GetValue<string>('cmd', '');
          if lCmd.StartsWith(cCmdPlayerPrefix, cIgnoreCase) then
            lCmd := lCmd.Substring(Length(cCmdPlayerPrefix)).Trim;
          lStream.UpstreamUrl := lCmd;
          ASnapshot.Streams.Add(lStream);
        end;
      Inc(lPage);
    finally
      FreeAndNil(lJson);
    end;
  until lPage > cMaxPages;
end;

function TStalkerReader.Read(const ASource: TSourceConfig): TSourceSnapshot;
begin
  FMac := ASource.Username.Trim;
  FUserAgent := ASource.UserAgent;
  FReferer := ASource.Referer;
  FPortal := StalkerPortalUrl(ASource.Url);
  FToken := '';

  if not Handshake then
    raise Exception.Create(
      'Stalker handshake mislukt — controleer portal-URL en MAC (Username).');

  Result := TSourceSnapshot.Create(ASource.Id);
  try
    if ASource.EnabledFor(ctLive) then
      LoadGenresAndChannels(ASource, Result);
  except
    Result.Free;
    raise;
  end;
end;

end.
