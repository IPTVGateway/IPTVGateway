unit IPTV.Api.Mars.Plex;

{ Plex Live TV integration, two independent surfaces (each gated by config):

  A) M3U + XMLTV tuner  -> GET /plex/playlist.m3u , GET /plex/epg.xml
     (point Plex's "M3U tuner" + "XMLTV guide" at these.)

  B) HDHomeRun emulation -> GET /discover.json , /lineup.json , /lineup_status.json
     POST/GET /lineup.post  (so Plex auto-detects us as a network tuner; paired
     with the SSDP responder in IPTV.Api.SsdpServer.)

  Both serve the Plex bouquet (App.PlexList: the chosen one, else the first enabled). Stream
  URLs use that list's output credentials and go either via the relay (:ProxyPort)
  or straight to our 302-redirect endpoint, per the per-surface proxy toggle. }

interface

uses
  System.JSON,
  MARS.Core.Attributes, MARS.Core.MediaType,
  MARS.Core.RequestAndResponse.Interfaces;

type
  [Path('plex')]
  TPlexPlaylistResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    [GET, Path('playlist.m3u'), Produces('audio/x-mpegurl')]
    function Playlist: string;
    [GET, Path('epg.xml'), Produces(TMediaType.APPLICATION_XML)]
    function Epg: string;
  end;

  [Path('discover.json')]
  THdhrDiscoverResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function Discover: TJSONObject;
  end;

  [Path('lineup_status.json')]
  THdhrLineupStatusResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function Status: TJSONObject;
  end;

  [Path('lineup.json')]
  THdhrLineupResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function Lineup: TJSONArray;
  end;

  [Path('lineup.post')]
  THdhrLineupPostResource = class
  protected
    [Context] Response: IMARSResponse;
  public
    // Plex/HDHomeRun hits this to (re)scan; we have nothing to scan, just say OK.
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function Scan: TJSONObject;
  end;

implementation

uses
  System.SysUtils, System.Net.URLClient,
  MARS.Core.Registry,
  IPTV.Model.CustomList, IPTV.Storage.Intf, IPTV.App.Context, IPTV.Output.Builder;

{ shared helpers }

// the single default output list Plex serves (nil if none/ no app)
function ServedList: TCustomList;
begin
  Result := nil;
  if App <> nil then
    Result := App.PlexList; // chosen Plex bouquet (else the first enabled)
end;

function PlexHost: string;
begin
  Result := 'localhost';
  if App <> nil then
    try
      Result := TURI.Create(App.Config.PublicBaseUrl).Host;
    except
      Result := 'localhost';
    end;
end;

// how channel names are decorated on the Plex surfaces (group / number / source letter)
function NameOpts: TNameOptions;
begin
  Result := TNameOptions.Make(App.Config.NameShowGroup, App.Config.NameShowNumber,
    App.Config.NameShowSource, App.Config.IdSortPrefix);
end;

// device id for the emulated HDHomeRun (stable; generated at server start)
function DeviceId: string;
begin
  if (App <> nil) and (App.Config.PlexDeviceId <> '') then
    Result := App.Config.PlexDeviceId
  else
    Result := '12345678';
end;

// base URL Plex uses to reach us (the admin/portal port). That port serves TLS
// when UseHttps is on, so the scheme must follow — otherwise Plex fetches
// discover.json/lineup.json over http:// against a TLS-only listener and fails.
function BaseUrl: string;
const
  Schemes: array[Boolean] of string = ('http', 'https');
begin
  Result := Format('%s://%s:%d', [Schemes[App.Config.UseHttps], PlexHost, App.Config.HttpPort]);
end;

// prefix for M3U stream URLs when the M3U surface relays through the proxy
function M3uProxyPrefix(const AList: TCustomList): string;
begin
  if App.Config.PlexM3uProxy then
    Result := Format('http://%s:%d/live/%s/%s/',
      [PlexHost, App.Config.ProxyPort, AList.OutputUsername, AList.OutputPassword])
  else
    Result := ''; // BuildM3U then emits the raw upstream URL
end;

// one stream's URL for the HDHomeRun lineup (relay vs our 302-redirect endpoint)
function HdhrStreamUrl(const AList: TCustomList; AStreamItemId: Integer): string;
begin
  if App.Config.PlexHdhrProxy then
    Result := Format('http://%s:%d/live/%s/%s/%d.ts',
      [PlexHost, App.Config.ProxyPort, AList.OutputUsername, AList.OutputPassword, AStreamItemId])
  else
    Result := Format('%s/live/%s/%s/%d',
      [BaseUrl, AList.OutputUsername, AList.OutputPassword, AStreamItemId]);
end;

{ TPlexPlaylistResource }

function TPlexPlaylistResource.Playlist: string;
var
  L: TCustomList;
begin
  if (App = nil) or (not App.Config.PlexM3uEnabled) then
  begin
    Response.StatusCode := 404;
    Exit('');
  end;
  L := ServedList;
  if L = nil then
  begin
    Response.StatusCode := 404;
    Exit('');
  end;
  try
    // sequential, globally-unique tvg-chno — Plex's M3U tuner rejects duplicate
    // channel numbers (per-group numbering collides across groups)
    Result := BuildM3U(App.Store, L.Id, M3uProxyPrefix(L), True, App.Config.VisibleGroups, NameOpts);
  finally
    L.Free;
  end;
end;

function TPlexPlaylistResource.Epg: string;
var
  L: TCustomList;
begin
  // The XMLTV guide is shared by BOTH surfaces (Plex HDHomeRun and the Jellyfin/
  // Plex M3U tuner), so serve it whenever EITHER is enabled — an HDHomeRun-only
  // setup must not need the M3U toggle just to get a guide.
  if (App = nil) or not (App.Config.PlexM3uEnabled or App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := 404;
    Exit('');
  end;
  L := ServedList;
  if L = nil then
  begin
    Response.StatusCode := 404;
    Exit('');
  end;
  try
    Result := BuildXmltv(App.Store, L.Id, App.Config.EpgMaxDays,
      TDummyEpgOptions.Make(App.Config.DummyEpgEnabled, App.Config.DummyEpgBlockMinutes,
        App.Config.DummyEpgHoursBack, App.Config.DummyEpgHoursAhead),
      App.Config.VisibleGroups, NameOpts);
  finally
    L.Free;
  end;
end;

{ THdhrDiscoverResource }

function THdhrDiscoverResource.Discover: TJSONObject;
begin
  if (App = nil) or (not App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := 404;
    Exit(TJSONObject.Create);
  end;
  Result := TJSONObject.Create;
  Result.AddPair('FriendlyName', 'IPTV Gateway');
  Result.AddPair('Manufacturer', 'IPTVPlay');
  Result.AddPair('ModelNumber', 'HDTC-2US');
  Result.AddPair('FirmwareName', 'hdhomerun3_atsc');
  Result.AddPair('FirmwareVersion', '20200101');
  Result.AddPair('DeviceID', DeviceId);
  Result.AddPair('DeviceAuth', 'iptvplay');
  Result.AddPair('TunerCount', TJSONNumber.Create(App.Config.PlexTunerCount));
  Result.AddPair('BaseURL', BaseUrl);
  Result.AddPair('LineupURL', BaseUrl + '/lineup.json');
end;

{ THdhrLineupStatusResource }

function THdhrLineupStatusResource.Status: TJSONObject;
begin
  if (App = nil) or (not App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := 404;
    Exit(TJSONObject.Create);
  end;
  Result := TJSONObject.Create;
  Result.AddPair('ScanInProgress', TJSONNumber.Create(0));
  Result.AddPair('ScanPossible', TJSONNumber.Create(1));
  Result.AddPair('Source', 'Cable');
  Result.AddPair('SourceList', TJSONArray.Create.Add('Cable'));
end;

{ THdhrLineupResource }

function THdhrLineupResource.Lineup: TJSONArray;
var
  L: TCustomList;
  Channels: TOutputChannelList;
  Names: TArray<string>;
  C: TOutputChannel;
  N: Integer;
  Nums: TArray<Integer>;
  GuideName: string;
begin
  Result := TJSONArray.Create;
  if (App = nil) or (not App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := 404;
    Exit;
  end;
  L := ServedList;
  if L = nil then
    Exit;
  try
    // same global group filter as the M3U/XMLTV, so all three agree
    Channels := SelectOutputChannels(App.Store, L.Id, App.Config.VisibleGroups);
    try
      // one decorated-name computation, shared shape with the M3U/XMLTV. (The id-sort
      // prefix lives in the channel-id, not the HDHomeRun GuideName, so key on AnyName.)
      Names := nil;
      if NameOpts.AnyName then
        Names := ComputeDisplayNames(App.Store, Channels, NameOpts);
      // bouquet numbers when unique, else the running position (Plex needs unique)
      Nums := OutputNumbers(Channels);
      N := 0;
      for C in Channels do
      begin
        Inc(N);
        if (Length(Names) > 0) and (N - 1 <= High(Names)) then
          GuideName := Names[N - 1]
        else
          GuideName := C.Name;
        Result.Add(TJSONObject.Create
          .AddPair('GuideNumber', Nums[N - 1].ToString)
          .AddPair('GuideName', GuideName)
          .AddPair('URL', HdhrStreamUrl(L, C.StreamItemId)));
      end;
    finally
      Channels.Free;
    end;
  finally
    L.Free;
  end;
end;

{ THdhrLineupPostResource }

function THdhrLineupPostResource.Scan: TJSONObject;
begin
  if (App = nil) or (not App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := 404;
    Exit(TJSONObject.Create);
  end;
  Result := TJSONObject.Create.AddPair('ScanInProgress', TJSONNumber.Create(0));
end;

initialization
  MARSRegister([TPlexPlaylistResource, THdhrDiscoverResource,
    THdhrLineupStatusResource, THdhrLineupResource, THdhrLineupPostResource]);

end.
