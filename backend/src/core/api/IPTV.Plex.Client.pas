unit IPTV.Plex.Client;

{ Tiny client for the Plex Media Server Live-TV/DVR API, used by the admin
  "rescan Plex" action: list the DVRs and tell each to reload its guide (which
  also re-reads the M3U/HDHomeRun lineup), so a bouquet change shows up in Plex
  without manually re-scanning there. Best-effort; raises on connection/HTTP error. }

interface

// Reload the guide/lineup of every DVR on the Plex server. Returns how many DVRs
// were reloaded. AServerUrl e.g. http://192.168.1.10:32400 ; AToken = X-Plex-Token.
function ReloadPlexGuides(const AServerUrl, AToken: string): Integer;

implementation

uses
  // RTL
  System.SysUtils,
  System.Classes,
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
