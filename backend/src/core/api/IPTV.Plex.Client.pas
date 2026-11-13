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
  System.SysUtils, System.Classes, System.Generics.Collections,
  System.JSON, System.Net.HttpClient, System.Net.URLClient;

function ReloadPlexGuides(const AServerUrl, AToken: string): Integer;
var
  Client: THTTPClient;
  Resp: IHTTPResponse;
  Root, MC: TJSONObject;
  RootVal, DvrsVal: TJSONValue;
  Dvrs: TJSONArray;
  Empty: TStringStream;
  Base: string; // declared before ReloadOne so the nested proc can see it

  procedure ReloadOne(const AKey: string);
  var
    R: IHTTPResponse;
  begin
    if AKey = '' then
      Exit;
    Empty := TStringStream.Create('');
    try
      // use Base (trailing slash stripped) — AServerUrl may end in '/', which
      // would make '//livetv/...' that Plex 404s; and only count a real success
      R := Client.Post(Format('%s/livetv/dvrs/%s/reloadGuide', [Base, AKey]), Empty);
      if (R.StatusCode >= 200) and (R.StatusCode < 300) then
        Inc(Result);
    finally
      Empty.Free;
    end;
  end;

var
  I: Integer;
begin
  Result := 0;
  if (AServerUrl.Trim = '') or (AToken.Trim = '') then
    raise Exception.Create('Plex server URL and token must be set first');
  Base := AServerUrl.TrimRight(['/']);

  Client := THTTPClient.Create;
  try
    Client.ConnectionTimeout := 8000;
    Client.ResponseTimeout := 15000;
    Client.CustomHeaders['Accept'] := 'application/json';
    Client.CustomHeaders['X-Plex-Token'] := AToken;

    Resp := Client.Get(Base + '/livetv/dvrs');
    if Resp.StatusCode = 401 then
      raise Exception.Create('Plex rejected the token (401)');
    if Resp.StatusCode <> 200 then
      raise Exception.CreateFmt('Plex returned %d listing DVRs', [Resp.StatusCode]);

    RootVal := TJSONObject.ParseJSONValue(Resp.ContentAsString);
    if not (RootVal is TJSONObject) then
    begin
      RootVal.Free; // nil-safe; frees a non-object reply without leaking
      raise Exception.Create('Plex DVR list was not valid JSON');
    end;
    Root := TJSONObject(RootVal);
    try
      if not (Root.GetValue('MediaContainer') is TJSONObject) then
        Exit; // no DVRs configured in Plex (or an unexpected shape) — nothing to reload
      MC := TJSONObject(Root.GetValue('MediaContainer'));
      DvrsVal := MC.GetValue('Dvr');
      if DvrsVal is TJSONArray then
      begin
        Dvrs := TJSONArray(DvrsVal);
        for I := 0 to Dvrs.Count - 1 do
          if Dvrs.Items[I] is TJSONObject then
            ReloadOne(TJSONObject(Dvrs.Items[I]).GetValue<string>('key', ''));
      end
      else if DvrsVal is TJSONObject then
        ReloadOne(TJSONObject(DvrsVal).GetValue<string>('key', ''));
    finally
      Root.Free;
    end;
  finally
    Client.Free;
  end;
end;

end.
