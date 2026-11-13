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
  IPTV.Model.Source, IPTV.Model.Catalog, IPTV.Source.Intf;

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
  System.SysUtils, System.Classes, System.JSON,
  IdHTTP, IdGlobal, IdCookieManager,
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
  U: string;
begin
  U := ABaseUrl.Trim.TrimRight(['/']);
  if U.ToLower.EndsWith(cPortalPhp) or U.ToLower.EndsWith(cLoadPhp) then
    Exit(U);
  if U.ToLower.EndsWith(cConsolePath) then
    U := U.Substring(0, U.Length - Length(cConsolePath));
  Result := U + '/' + cPortalPhp;
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
  H: TIdHTTP;
begin
  H := TIdHTTP.Create(nil);
  try
    H.HandleRedirects := True;
    H.RedirectMaximum := cMaxRedirects;
    H.AllowCookies := True;
    H.CookieManager := TIdCookieManager.Create(H);
    TIdHTTPAccess(H).IPVersion := Id_IPv4;
    H.ConnectTimeout := cTimeoutConnectMs;
    H.ReadTimeout := cTimeoutReadMs;
    if FUserAgent <> '' then
      H.Request.UserAgent := FUserAgent
    else
      H.Request.UserAgent := StalkerUserAgent;
    if FReferer <> '' then
      H.Request.Referer := FReferer;
    H.Request.CustomHeaders.Values[cHeaderXUserAgent] := StalkerXUserAgent;
    H.Request.CustomHeaders.Values[cHeaderCookie] := StalkerCookie(FMac);
    if FToken <> '' then
      H.Request.CustomHeaders.Values[cHeaderAuthorization] := cBearerPrefix + FToken;
    Result := H.Get(AUrl);
  finally
    H.Free;
  end;
end;

function TStalkerReader.Handshake: Boolean;
var
  Resp: string;
  JV, Js: TJSONValue;
begin
  Result := False;
  Resp := Fetch(StalkerActionUrl(FPortal, cTypeStb, cActionHandshake, '&token='));
  JV := TJSONObject.ParseJSONValue(Resp);
  try
    if JV is TJSONObject then
    begin
      Js := TJSONObject(JV).GetValue(cJsonJs);
      if Js is TJSONObject then
      begin
        FToken := TJSONObject(Js).GetValue<string>('token', '');
        Result := FToken <> '';
      end;
    end;
  finally
    JV.Free;
  end;
end;

procedure TStalkerReader.LoadGenresAndChannels(ASource: TSourceConfig;
  ASnapshot: TSourceSnapshot);
var
  Resp, Cmd: string;
  JV, Js: TJSONValue;
  Arr, Data: TJSONArray;
  Item: TJSONValue;
  O: TJSONObject;
  Cat: TCategory;
  S: TStreamItem;
  Page: Integer;
begin
  // genres → categories (live tv)
  Resp := Fetch(StalkerActionUrl(FPortal, cTypeItv, cActionGetGenres, ''));
  JV := TJSONObject.ParseJSONValue(Resp);
  try
    if (JV is TJSONObject) and (TJSONObject(JV).GetValue(cJsonJs) is TJSONArray) then
    begin
      Arr := TJSONArray(TJSONObject(JV).GetValue(cJsonJs));
      for Item in Arr do
        if Item is TJSONObject then
        begin
          O := TJSONObject(Item);
          Cat := TCategory.Create;
          Cat.SourceId := ASource.Id;
          Cat.ContentType := ctLive;
          Cat.UpstreamId := O.GetValue<string>(cJsonId, '');
          Cat.Name := O.GetValue<string>('title', O.GetValue<string>(cJsonName, ''));
          ASnapshot.Categories.Add(Cat);
        end;
    end;
  finally
    JV.Free;
  end;

  // channels (paged) → streams
  Page := 1;
  repeat
    Resp := Fetch(StalkerActionUrl(FPortal, cTypeItv, cActionGetOrderedList,
      Format('&genre=*&p=%d', [Page])));
    JV := TJSONObject.ParseJSONValue(Resp);
    try
      Data := nil;
      if JV is TJSONObject then
      begin
        Js := TJSONObject(JV).GetValue(cJsonJs);
        if (Js is TJSONObject) and (TJSONObject(Js).GetValue(cJsonData) is TJSONArray) then
          Data := TJSONArray(TJSONObject(Js).GetValue(cJsonData));
      end;
      if (Data = nil) or (Data.Count = 0) then
        Break;
      for Item in Data do
        if Item is TJSONObject then
        begin
          O := TJSONObject(Item);
          S := TStreamItem.Create;
          S.SourceId := ASource.Id;
          S.ContentType := ctLive;
          S.UpstreamId := O.GetValue<string>(cJsonId, '');
          S.Name := O.GetValue<string>(cJsonName, '');
          S.Logo := O.GetValue<string>('logo', '');
          S.TvgId := O.GetValue<string>('xmltv_id', '');
          S.CategoryUpstreamId := O.GetValue<string>('tv_genre_id', '');
          // cmd is usually "ffmpeg http://.../ch/<id>" — strip the player prefix.
          // NOTE: some panels need a per-channel create_link call instead; that
          // refinement is pending a live portal to validate against.
          Cmd := O.GetValue<string>('cmd', '');
          if Cmd.StartsWith(cCmdPlayerPrefix, cIgnoreCase) then
            Cmd := Cmd.Substring(Length(cCmdPlayerPrefix)).Trim;
          S.UpstreamUrl := Cmd;
          ASnapshot.Streams.Add(S);
        end;
      Inc(Page);
    finally
      JV.Free;
    end;
  until Page > cMaxPages;
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
