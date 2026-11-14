unit IPTV.Plex.Client;

{ Tiny client for the Plex Media Server Live-TV/DVR API, used by the admin
  "rescan Plex" action: list the DVRs and tell each to reload its guide (which
  also re-reads the M3U/HDHomeRun lineup), so a bouquet change shows up in Plex
  without manually re-scanning there. Best-effort; raises on connection/HTTP error. }

interface

uses
  // RTL
  System.SysUtils;

type
  /// <summary>One channel of our HDHomeRun lineup and the XMLTV channel id its guide
  /// is published under (/plex/epg.xml) - Plex maps the two in the DVR.</summary>
  TPlexChannelMapping = record
    Number: string;   // HDHomeRun GuideNumber
    GuideId: string;  // XMLTV <channel id>
  end;

/// <summary>Set up (or repair) the gateway in Plex Live TV &amp; DVR via the Plex API,
/// step by step, re-using what already exists: register our HDHomeRun tuner
/// (ATunerUrl, matched by ADeviceId or the URL), create a DVR for it with our XMLTV
/// guide (AGuideUrl) when Plex has none, map every lineup channel to its guide id and
/// reload the guide. Each step is reported through ALog. Returns the DVR key. Raises
/// on a connection/HTTP error. NOTE: Plex doesn't document this API; the calls follow
/// what other tuner projects use.</summary>
function SetupPlexDvr(const AServerUrl, AToken, ATunerUrl, AGuideUrl, ADeviceId, ATitle,
  ALanguage: string; const AChannels: TArray<TPlexChannelMapping>; const ALog: TProc<string>): string;

// Reload the guide/lineup of every DVR on the Plex server. Returns how many DVRs
// were reloaded. AServerUrl e.g. http://192.168.1.10:32400 ; AToken = X-Plex-Token.
function ReloadPlexGuides(const AServerUrl, AToken: string): Integer;

implementation

uses
  // RTL
  System.Classes,
  System.NetEncoding,
  System.Generics.Collections,
  System.JSON,
  System.Net.HttpClient,
  System.Net.URLClient,
  // own units
  IPTV.Api.Serializers;

const
  // timeouts (ms)
  cConnectTimeoutMs = 8000;
  cResponseTimeoutMs = 15000;

  // Plex API: headers, paths and the JSON shape of the DVR list
  cHeaderAccept = 'Accept';
  cHeaderPlexToken = 'X-Plex-Token';
  cMimeJson = 'application/json';
  cDvrsPath = '/livetv/dvrs';
  cKeyMediaContainer = 'MediaContainer';
  cKeyDvr = 'Dvr';
  cKeyDvrKey = 'key';

  cHttpSuccessLast = 299; // 2xx = success
  cHttpConflict = 409;    // "already registered" on a device POST

  // DVR setup: grabber devices + their JSON shape, the XMLTV lineup scheme
  cDevicesPath = '/media/grabbers/devices';
  cKeyDevice = 'Device';
  cKeyUuid = 'uuid';
  cKeyUri = 'uri';
  cLineupXmltvScheme = 'lineup://tv.plex.providers.epg.xmltv/';

// the elements under AKey: Plex sends one element as an object, several as an array
function JsonItems(const AParent: TJSONObject; const AKey: string): TArray<TJSONObject>;
var
  lValue: TJSONValue;
  i: Integer;
begin
  Result := nil;
  if AParent = nil then
    Exit;
  lValue := AParent.GetValue(AKey);
  if lValue is TJSONObject then
    Result := [TJSONObject(lValue)]
  else if lValue is TJSONArray then
    for i := 0 to TJSONArray(lValue).Count - 1 do
      if TJSONArray(lValue).Items[i] is TJSONObject then
        Result := Result + [TJSONObject(TJSONArray(lValue).Items[i])];
end;

function IsHttpSuccess(AStatus: Integer): Boolean;
begin
  Result := (AStatus >= cHttpOk) and (AStatus <= cHttpSuccessLast);
end;

function SetupPlexDvr(const AServerUrl, AToken, ATunerUrl, AGuideUrl, ADeviceId, ATitle,
  ALanguage: string; const AChannels: TArray<TPlexChannelMapping>; const ALog: TProc<string>): string;
var
  lClient: THTTPClient;
  lBase, lTuner, lDeviceUuid, lDeviceKey, lQuery, lEnabled: string;
  lEmpty: TStringStream;
  lResp: IHTTPResponse;
  i: Integer;

  procedure Say(const AText: string);
  begin
    if Assigned(ALog) then
      ALog('Plex setup: ' + AText);
  end;

  // GET a Plex path as JSON; the caller frees the result
  function GetJson(const APath: string): TJSONObject;
  var
    lValue: TJSONValue;
    lR: IHTTPResponse;
  begin
    lR := lClient.Get(lBase + APath);
    if lR.StatusCode = cHttpUnauthorized then
      raise Exception.Create('Plex rejected the token (401)');
    if not IsHttpSuccess(lR.StatusCode) then
      raise Exception.CreateFmt('Plex returned %d for %s', [lR.StatusCode, APath]);
    lValue := TJSONObject.ParseJSONValue(lR.ContentAsString);
    if not (lValue is TJSONObject) then
    begin
      FreeAndNil(lValue);
      raise Exception.CreateFmt('Plex answer for %s was not JSON', [APath]);
    end;
    Result := TJSONObject(lValue);
  end;

  // a grabber device is ours: same device id at the end of its uuid, or same address
  function IsOurDevice(const ADevice: TJSONObject): Boolean;
  var
    lUuid: string;
  begin
    lUuid := ADevice.GetValue<string>(cKeyUuid, '');
    Result := ((ADeviceId <> '') and lUuid.EndsWith('/' + ADeviceId, True)) or
      SameText(ADevice.GetValue<string>(cKeyUri, '').TrimRight(['/']), lTuner);
  end;

  // find our tuner among Plex's grabber devices (uuid + key), '' when absent
  function FindOurDevice(out AKey: string): string;
  var
    lRoot: TJSONObject;
    lDevice: TJSONObject;
  begin
    Result := '';
    AKey := '';
    lRoot := GetJson(cDevicesPath);
    try
      for lDevice in JsonItems(lRoot.GetValue(cKeyMediaContainer) as TJSONObject, cKeyDevice) do
        if IsOurDevice(lDevice) then
        begin
          AKey := lDevice.GetValue<string>(cKeyDvrKey, '');
          Exit(lDevice.GetValue<string>(cKeyUuid, ''));
        end;
    finally
      FreeAndNil(lRoot);
    end;
  end;

  // the key of a DVR that uses our tuner, '' when none
  function FindOurDvr: string;
  var
    lRoot: TJSONObject;
    lDvr, lDevice: TJSONObject;
  begin
    Result := '';
    lRoot := GetJson(cDvrsPath);
    try
      for lDvr in JsonItems(lRoot.GetValue(cKeyMediaContainer) as TJSONObject, cKeyDvr) do
        for lDevice in JsonItems(lDvr, cKeyDevice) do
          if SameText(lDevice.GetValue<string>(cKeyUuid, ''), lDeviceUuid) or IsOurDevice(lDevice) then
            Exit(lDvr.GetValue<string>(cKeyDvrKey, ''));
    finally
      FreeAndNil(lRoot);
    end;
  end;

  function Post(const APathAndQuery: string): IHTTPResponse;
  begin
    lEmpty.Clear;
    Result := lClient.Post(lBase + APathAndQuery, lEmpty);
  end;

  function Enc(const AValue: string): string;
  begin
    Result := TNetEncoding.URL.Encode(AValue);
  end;

begin
  Result := '';
  if (AServerUrl.Trim = '') or (AToken.Trim = '') then
    raise Exception.Create('Plex server URL and token must be set first');
  lBase := AServerUrl.Trim.TrimRight(['/']);
  lTuner := ATunerUrl.Trim.TrimRight(['/']);
  lClient := nil;
  lEmpty := nil;
  try
    lClient := THTTPClient.Create;
    lEmpty := TStringStream.Create('');
    lClient.ConnectionTimeout := cConnectTimeoutMs;
    lClient.ResponseTimeout := cResponseTimeoutMs;
    lClient.CustomHeaders[cHeaderAccept] := cMimeJson;
    lClient.CustomHeaders[cHeaderPlexToken] := AToken;

    // 1. the tuner: re-use it when Plex already knows it, else register it (Plex
    //    then reads our discover.json; 409 = it knew it after all)
    lDeviceUuid := FindOurDevice(lDeviceKey);
    if lDeviceUuid = '' then
    begin
      lResp := Post(cDevicesPath + '?uri=' + Enc(lTuner));
      if not IsHttpSuccess(lResp.StatusCode) and (lResp.StatusCode <> cHttpConflict) then
        raise Exception.CreateFmt('Plex returned %d registering the tuner %s', [lResp.StatusCode, lTuner]);
      lDeviceUuid := FindOurDevice(lDeviceKey);
      if lDeviceUuid = '' then
        raise Exception.Create('Plex did not list the tuner after registering it - can Plex reach ' +
          lTuner + '/discover.json? (HDHomeRun tuner enabled, allowed clients)');
      Say('tuner registered (' + lDeviceUuid + ')');
    end
    else
      Say('tuner already known (' + lDeviceUuid + ')');

    // 2. the DVR with our XMLTV guide, unless one already uses this tuner
    Result := FindOurDvr;
    if Result = '' then
    begin
      lResp := Post(Format('%s?language=%s&device=%s&lineup=%s&lineupTitle=%s',
        [cDvrsPath, Enc(ALanguage), Enc(lDeviceUuid),
         Enc(cLineupXmltvScheme + Enc(AGuideUrl) + '#' + Enc(ATitle)), Enc(ATitle)]));
      if not IsHttpSuccess(lResp.StatusCode) then
        raise Exception.CreateFmt('Plex returned %d creating the DVR', [lResp.StatusCode]);
      Result := FindOurDvr;
      if Result = '' then
        raise Exception.Create('Plex did not list the new DVR');
      Say('DVR created with guide ' + AGuideUrl + ' (DVR ' + Result + ')');
    end
    else
      Say('DVR already exists (DVR ' + Result + ')');

    // 3. channel map: every lineup number -> its XMLTV channel id, all enabled
    if (lDeviceKey <> '') and (Length(AChannels) > 0) then
    begin
      lEnabled := '';
      lQuery := '';
      for i := 0 to High(AChannels) do
      begin
        if i > 0 then
          lEnabled := lEnabled + ',';
        lEnabled := lEnabled + AChannels[i].Number;
        lQuery := lQuery + Format('&channelMapping%%5B%s%%5D=%s&channelMappingByKey%%5B%s%%5D=%s',
          [Enc(AChannels[i].Number), Enc(AChannels[i].GuideId), Enc(AChannels[i].Number), Enc(AChannels[i].GuideId)]);
      end;
      lEmpty.Clear;
      lResp := lClient.Put(Format('%s%s/%s/channelmap?channelsEnabled=%s%s',
        [lBase, cDevicesPath, lDeviceKey, Enc(lEnabled), lQuery]), lEmpty);
      if not IsHttpSuccess(lResp.StatusCode) then
        raise Exception.CreateFmt('Plex returned %d setting the channel map', [lResp.StatusCode]);
      Say(Format('%d channels mapped to the guide', [Length(AChannels)]));
    end
    else
      Say('channel map skipped (no device key or no channels)');

    // 4. have Plex read the lineup + guide now
    lResp := Post(Format('%s/%s/reloadGuide', [cDvrsPath, Result]));
    if IsHttpSuccess(lResp.StatusCode) then
      Say('guide reload started')
    else
      Say(Format('guide reload returned %d (Plex reloads it on its own schedule too)', [lResp.StatusCode]));
  finally
    FreeAndNil(lEmpty);
    FreeAndNil(lClient);
  end;
end;

function ReloadPlexGuides(const AServerUrl, AToken: string): Integer;
var
  lClient: THTTPClient;
  lResp: IHTTPResponse;
  lRoot, lMC: TJSONObject;
  lRootVal, lDvrsVal: TJSONValue;
  lDvrs: TJSONArray;
  lEmpty: TStringStream;
  lBase: string; // declared before ReloadOne so the nested proc can see it

  procedure ReloadOne(const AKey: string);
  var
    lR: IHTTPResponse;
  begin
    if AKey = '' then
      Exit;
    lEmpty := TStringStream.Create('');
    try
      // use lBase (trailing slash stripped) — AServerUrl may end in '/', which
      // would make '//livetv/...' that Plex 404s; and only count a real success
      lR := lClient.Post(Format('%s%s/%s/reloadGuide', [lBase, cDvrsPath, AKey]), lEmpty);
      if (lR.StatusCode >= cHttpOk) and (lR.StatusCode <= cHttpSuccessLast) then
        Inc(Result);
    finally
      FreeAndNil(lEmpty);
    end;
  end;

var
  i: Integer;
begin
  Result := 0;
  if (AServerUrl.Trim = '') or (AToken.Trim = '') then
    raise Exception.Create('Plex server URL and token must be set first');
  lBase := AServerUrl.TrimRight(['/']);

  lClient := THTTPClient.Create;
  try
    lClient.ConnectionTimeout := cConnectTimeoutMs;
    lClient.ResponseTimeout := cResponseTimeoutMs;
    lClient.CustomHeaders[cHeaderAccept] := cMimeJson;
    lClient.CustomHeaders[cHeaderPlexToken] := AToken;

    lResp := lClient.Get(lBase + cDvrsPath);
    if lResp.StatusCode = cHttpUnauthorized then
      raise Exception.Create('Plex rejected the token (401)');
    if lResp.StatusCode <> cHttpOk then
      raise Exception.CreateFmt('Plex returned %d listing DVRs', [lResp.StatusCode]);

    lRootVal := TJSONObject.ParseJSONValue(lResp.ContentAsString);
    if not (lRootVal is TJSONObject) then
    begin
      FreeAndNil(lRootVal); // nil-safe; frees a non-object reply without leaking
      raise Exception.Create('Plex DVR list was not valid JSON');
    end;
    lRoot := TJSONObject(lRootVal);
    try
      if not (lRoot.GetValue(cKeyMediaContainer) is TJSONObject) then
        Exit; // no DVRs configured in Plex (or an unexpected shape) — nothing to reload
      lMC := TJSONObject(lRoot.GetValue(cKeyMediaContainer));
      lDvrsVal := lMC.GetValue(cKeyDvr);
      if lDvrsVal is TJSONArray then
      begin
        lDvrs := TJSONArray(lDvrsVal);
        for i := 0 to lDvrs.Count - 1 do
          if lDvrs.Items[i] is TJSONObject then
            ReloadOne(TJSONObject(lDvrs.Items[i]).GetValue<string>(cKeyDvrKey, ''));
      end
      else if lDvrsVal is TJSONObject then
        ReloadOne(TJSONObject(lDvrsVal).GetValue<string>(cKeyDvrKey, ''));
    finally
      FreeAndNil(lRoot);
    end;
  finally
    FreeAndNil(lClient);
  end;
end;

end.
