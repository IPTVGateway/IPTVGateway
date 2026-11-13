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
  // RTL
  System.JSON,
  // third-party
  MARS.Core.Attributes,
  MARS.Core.MediaType,
  MARS.Core.RequestAndResponse.Interfaces;

type
  /// <summary>Plex M3U tuner surface: playlist.m3u + epg.xml.</summary>
  [Path('plex')]
  TPlexPlaylistResource = class
  protected
    [Context] Response: IMARSResponse;
    [Context] Request: IMARSRequest;
  public
    /// <summary>M3U of the Plex bouquet (sequential channel numbers).</summary>
    [GET, Path('playlist.m3u'), Produces('audio/x-mpegurl')]
    function Playlist: string;
    /// <summary>XMLTV guide of the Plex bouquet (either surface enabled).</summary>
    [GET, Path('epg.xml'), Produces(TMediaType.APPLICATION_XML)]
    function Epg: string;
  end;

  /// <summary>HDHomeRun emulation: device description.</summary>
  [Path('discover.json')]
  THdhrDiscoverResource = class
  protected
    [Context] Response: IMARSResponse;
    [Context] Request: IMARSRequest;
  public
    /// <summary>The emulated device's discover.json.</summary>
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function Discover: TJSONObject;
  end;

  /// <summary>HDHomeRun emulation: scan status.</summary>
  [Path('lineup_status.json')]
  THdhrLineupStatusResource = class
  protected
    [Context] Response: IMARSResponse;
    [Context] Request: IMARSRequest;
  public
    /// <summary>Fixed "no scan running" status.</summary>
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function Status: TJSONObject;
  end;

  /// <summary>HDHomeRun emulation: channel lineup.</summary>
  [Path('lineup.json')]
  THdhrLineupResource = class
  protected
    [Context] Response: IMARSResponse;
    [Context] Request: IMARSRequest;
  public
    /// <summary>Linear channels of the Plex bouquet with number, name and stream URL.</summary>
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function Lineup: TJSONArray;
  end;

  /// <summary>HDHomeRun emulation: (re)scan trigger.</summary>
  [Path('lineup.post')]
  THdhrLineupPostResource = class
  protected
    [Context] Response: IMARSResponse;
    [Context] Request: IMARSRequest;
  public
    // Plex/HDHomeRun hits this to (re)scan; we have nothing to scan, just say OK.
    // Real tuners take POST (lineup.post?scan=start); some clients use GET.
    [GET, Produces(TMediaType.APPLICATION_JSON)]
    function Scan: TJSONObject;
    /// <summary>POST variant of Scan.</summary>
    [POST, Produces(TMediaType.APPLICATION_JSON)]
    function ScanPost: TJSONObject;
  end;

implementation

uses
  // RTL
  System.SysUtils,
  System.Net.URLClient,
  // third-party
  MARS.Core.Registry,
  // own units
  IPTV.Model.CustomList,
  IPTV.Storage.Intf,
  IPTV.App.Context,
  IPTV.Output.Builder,
  IPTV.Core.Utils,
  IPTV.Model.Types,
  IPTV.Api.Serializers;

const
  // the emulated HDHomeRun device (discover.json / lineup_status.json)
  cHdhrFriendlyName = 'IPTV Gateway';
  cHdhrManufacturer = 'IPTVPlay';
  cHdhrModelNumber = 'HDTC-2US';
  cHdhrFirmwareName = 'hdhomerun3_atsc';
  cHdhrFirmwareVersion = '20200101';
  cHdhrDeviceAuth = 'iptvplay';
  cHdhrFallbackDeviceId = '12345678'; // only when no device id is configured yet
  cHdhrSource = 'Cable';
  cHdhrLineupPath = '/lineup.json';

  // BuildM3U ASequentialChno: Plex's M3U tuner needs unique numbers 1,2,3...
  cSequentialChno = True;

{ shared helpers }

// the Plex/HDHomeRun endpoints have no login: optionally limited to known clients
function ClientAllowed(const ARequest: IMARSRequest): Boolean;
begin
  Result := (App = nil) or App.IsMediaClientAllowed(ARequest.RemoteIP);
end;

// the single default output list Plex serves (nil if none/ no app)
function ServedList: TCustomList;
begin
  Result := nil;
  if App <> nil then
    Result := App.PlexList; // chosen Plex bouquet (else the first enabled)
end;

function PlexHost: string;
begin
  Result := cDefaultPublicHost;
  if App <> nil then
    Result := SafeUrlHost(App.Config.PublicBaseUrl, cDefaultPublicHost);
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
    Result := cHdhrFallbackDeviceId;
end;

// base URL Plex uses to reach us (the admin/portal port). That port serves TLS
// when UseHttps is on, so the scheme must follow — otherwise Plex fetches
// discover.json/lineup.json over http:// against a TLS-only listener and fails.
function BaseUrl: string;
const
  cSchemes: array[Boolean] of string = ('http', 'https');
begin
  Result := Format('%s://%s:%d', [cSchemes[App.Config.UseHttps], PlexHost, App.Config.HttpPort]);
end;

// prefix for M3U stream URLs when the M3U surface relays through the proxy
function M3uProxyPrefix(const AList: TCustomList): string;
begin
  if App.Config.PlexM3uProxy then
    Result := Format('http://%s:%d/live/%s/%s/',
      [PlexHost, App.Config.ProxyPort, PathCred(AList.OutputUsername), PathCred(AList.OutputPassword)])
  else
    Result := ''; // BuildM3U then emits the raw upstream URL
end;

// one stream's URL for the HDHomeRun lineup (relay vs our 302-redirect endpoint)
function HdhrStreamUrl(const AList: TCustomList; AStreamItemId: Integer): string;
begin
  if App.Config.PlexHdhrProxy then
    Result := Format('http://%s:%d/live/%s/%s/%d.ts',
      [PlexHost, App.Config.ProxyPort, PathCred(AList.OutputUsername), PathCred(AList.OutputPassword),
       AStreamItemId])
  else
    Result := Format('%s/live/%s/%s/%d',
      [BaseUrl, PathCred(AList.OutputUsername), PathCred(AList.OutputPassword), AStreamItemId]);
end;

{ TPlexPlaylistResource }

function TPlexPlaylistResource.Playlist: string;
var
  lList: TCustomList;
begin
  if not ClientAllowed(Request) then
  begin
    Response.StatusCode := cHttpForbidden;
    Exit('');
  end;
  if (App = nil) or (not App.Config.PlexM3uEnabled) then
  begin
    Response.StatusCode := cHttpNotFound;
    Exit('');
  end;
  lList := ServedList;
  if lList = nil then
  begin
    Response.StatusCode := cHttpNotFound;
    Exit('');
  end;
  try
    // sequential, globally-unique tvg-chno — Plex's M3U tuner rejects duplicate
    // channel numbers (per-group numbering collides across groups)
    Result := BuildM3U(App.Store, lList.Id, M3uProxyPrefix(lList), cSequentialChno, App.Config.VisibleGroups,
      NameOpts);
  finally
    FreeAndNil(lList);
  end;
end;

function TPlexPlaylistResource.Epg: string;
var
  lList: TCustomList;
begin
  if not ClientAllowed(Request) then
  begin
    Response.StatusCode := cHttpForbidden;
    Exit('');
  end;
  // The XMLTV guide is shared by BOTH surfaces (Plex HDHomeRun and the Jellyfin/
  // Plex M3U tuner), so serve it whenever EITHER is enabled — an HDHomeRun-only
  // setup must not need the M3U toggle just to get a guide.
  if (App = nil) or not (App.Config.PlexM3uEnabled or App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := cHttpNotFound;
    Exit('');
  end;
  lList := ServedList;
  if lList = nil then
  begin
    Response.StatusCode := cHttpNotFound;
    Exit('');
  end;
  try
    Result := BuildXmltv(App.Store, lList.Id, App.Config.EpgMaxDays,
      TDummyEpgOptions.Make(App.Config.DummyEpgEnabled, App.Config.DummyEpgBlockMinutes,
        App.Config.DummyEpgHoursBack, App.Config.DummyEpgHoursAhead),
      App.Config.VisibleGroups, NameOpts);
  finally
    FreeAndNil(lList);
  end;
end;

{ THdhrDiscoverResource }

function THdhrDiscoverResource.Discover: TJSONObject;
begin
  if not ClientAllowed(Request) then
  begin
    Response.StatusCode := cHttpForbidden;
    Exit(TJSONObject.Create);
  end;
  if (App = nil) or (not App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := cHttpNotFound;
    Exit(TJSONObject.Create);
  end;
  Result := TJSONObject.Create;
  Result.AddPair('FriendlyName', cHdhrFriendlyName);
  Result.AddPair('Manufacturer', cHdhrManufacturer);
  Result.AddPair('ModelNumber', cHdhrModelNumber);
  Result.AddPair('FirmwareName', cHdhrFirmwareName);
  Result.AddPair('FirmwareVersion', cHdhrFirmwareVersion);
  Result.AddPair('DeviceID', DeviceId);
  Result.AddPair('DeviceAuth', cHdhrDeviceAuth);
  Result.AddPair('TunerCount', TJSONNumber.Create(App.Config.PlexTunerCount));
  Result.AddPair('BaseURL', BaseUrl);
  Result.AddPair('LineupURL', BaseUrl + cHdhrLineupPath);
end;

{ THdhrLineupStatusResource }

function THdhrLineupStatusResource.Status: TJSONObject;
begin
  if not ClientAllowed(Request) then
  begin
    Response.StatusCode := cHttpForbidden;
    Exit(TJSONObject.Create);
  end;
  if (App = nil) or (not App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := cHttpNotFound;
    Exit(TJSONObject.Create);
  end;
  Result := TJSONObject.Create;
  Result.AddPair('ScanInProgress', TJSONNumber.Create(0));
  Result.AddPair('ScanPossible', TJSONNumber.Create(1));
  Result.AddPair('Source', cHdhrSource);
  Result.AddPair('SourceList', TJSONArray.Create.Add(cHdhrSource));
end;

{ THdhrLineupResource }

function THdhrLineupResource.Lineup: TJSONArray;
var
  lList: TCustomList;
  lChannels: TOutputChannelList;
  lNames: TArray<string>;
  lChannel: TOutputChannel;
  lPos: Integer;
  lNums: TArray<Integer>;
  lGuideName: string;
begin
  if not ClientAllowed(Request) then
  begin
    Response.StatusCode := cHttpForbidden;
    Exit(TJSONArray.Create);
  end;
  Result := TJSONArray.Create;
  if (App = nil) or (not App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := cHttpNotFound;
    Exit;
  end;
  lList := ServedList;
  if lList = nil then
    Exit;
  try
    // same global group filter as the M3U/XMLTV, so all three agree
    lChannels := SelectOutputChannels(App.Store, lList.Id, App.Config.VisibleGroups);
    try
      KeepContentTypes(lChannels, cLinearContentTypes); // a tuner lineup: linear channels only
      // one decorated-name computation, shared shape with the M3U/XMLTV. (The id-sort
      // prefix lives in the channel-id, not the HDHomeRun GuideName, so key on AnyName.)
      lNames := nil;
      if NameOpts.AnyName then
        lNames := ComputeDisplayNames(App.Store, lChannels, NameOpts);
      // bouquet numbers when unique, else the running position (Plex needs unique)
      lNums := OutputNumbers(lChannels);
      lPos := 0;
      for lChannel in lChannels do
      begin
        Inc(lPos);
        if (Length(lNames) > 0) and (lPos - 1 <= High(lNames)) then
          lGuideName := lNames[lPos - 1]
        else
          lGuideName := lChannel.Name;
        Result.Add(TJSONObject.Create
          .AddPair('GuideNumber', lNums[lPos - 1].ToString)
          .AddPair('GuideName', lGuideName)
          .AddPair('URL', HdhrStreamUrl(lList, lChannel.StreamItemId)));
      end;
    finally
      FreeAndNil(lChannels);
    end;
  finally
    FreeAndNil(lList);
  end;
end;

{ THdhrLineupPostResource }

function THdhrLineupPostResource.Scan: TJSONObject;
begin
  if not ClientAllowed(Request) then
  begin
    Response.StatusCode := cHttpForbidden;
    Exit(TJSONObject.Create);
  end;
  if (App = nil) or (not App.Config.PlexHdhrEnabled) then
  begin
    Response.StatusCode := cHttpNotFound;
    Exit(TJSONObject.Create);
  end;
  Result := TJSONObject.Create.AddPair('ScanInProgress', TJSONNumber.Create(0));
end;

function THdhrLineupPostResource.ScanPost: TJSONObject;
begin
  Result := Scan;
end;

initialization
  MARSRegister([TPlexPlaylistResource, THdhrDiscoverResource,
    THdhrLineupStatusResource, THdhrLineupResource, THdhrLineupPostResource]);

end.
