unit IPTV.App.Config;

{ Runtime configuration, loaded from config.json next to the executable.
  Sensible defaults are applied when the file or a field is missing. }

interface

const
  // Single source of truth for the app version. Bump per release. Surfaced via
  // /api/health (shown in the web UI header) and read by deploy\docker\build.ps1
  // to tag the image + name the backup, so what runs == what was shipped.
  //   1.0.0  baseline (published 2026-06-18)
  //   1.1.0  M3U credential-swap fix + "duplicate group (quality/provider)"
  //   1.2.0  global group filter (Media Servers) + dummy EPG + group-title categories
  //   1.2.1  serve /plex/epg.xml when EITHER tuner surface is on (HDHomeRun-only guide)
  //   1.2.2  clipboard copy on http; optional group-in-channel-name for Plex surfaces
  //   1.2.3  optional zero-padded sort-number in the channel name (forces Plex order)
  //   1.2.4  "reset tuner DeviceID" so Plex re-imports the lineup as a fresh device
  //   1.2.5  idempotent sort-number in the EPG display-name (== lineup GuideNumber)
  //   1.2.6  optional per-source letter prefix (A/B/…) so Plex groups+sorts by provider
  //   1.2.7  optional zero-padded sort prefix in the channel-id (Plex sorts by id)
  //   1.2.8  player_api lists m3u8 before ts in allowed_output_formats (boxes pick HLS)
  //   1.2.9  per-source "live always as HLS": live redirects go out as .m3u8
  //   1.2.10 request log shows the client IP
  //   1.2.11 log slow (>=1 s) / failed requests with duration + the exception behind a 500
  //   1.2.12 name filters: categories filtered in memory (was a ~20 s SQL LIKE tree),
  //          oversized/pasted-list filter items split or refused (SQLite LIKE limit)
  //   1.2.13 name filters precomputed into a per-row `hidden` flag (on ingest / filter change);
  //          catalog queries test hidden=0 — stream count/search went from minutes to ms
  //   1.2.14 sources cached in memory (instant source list on page load); provider expiry /
  //          status / max connections fetched on refresh and shown per source; one-click
  //          'Clear filters'; refresh no longer overwrites edits made during it
  //   1.2.15 filter tokens no longer quote-doubled on every save (StrArrayToCsv plain join);
  //          Init strips stored quotes / oversized items once and VACUUMs (302 MB row)
  //   1.2.16 bouquet shows each channel's source (badge; red '?' when the upstream stream is gone)
  //   1.2.17 a group stays visible when it holds a visible channel (include 'UFC' shows the
  //          UFC channels' group), unless an exclude token names the group
  //   1.2.18 choose the bouquet Plex/Jellyfin get (plexListId); Media Servers group filter is
  //          Plex-only (boxes get their whole bouquet); XMLTV <channel> carries <icon> (Plex logos)
  APP_VERSION = '1.2.28';

type
  TAppConfig = record
    HttpPort: Integer;        // Horse listen port (admin + output portal)
    DatabasePath: string;     // SQLite file
    // Open a SEPARATE read connection (SQLite WAL) so UI reads don't wait on the
    // daily refresh writer. OFF by default: one serialised connection, which works
    // on every filesystem. Only turn ON when the DB is on a real (non-FUSE) path —
    // on an Unraid /mnt/user share WAL silently breaks and the UI hangs. Move the
    // DB to /mnt/cache/... before enabling.
    SeparateReadConnection: Boolean;
    RefreshHour: Word;        // daily refresh local time
    RefreshMinute: Word;
    EpgMaxDays: Integer;      // cap the served guide to this many days ahead (0 = unlimited)
    PublicBaseUrl: string;    // how boxes reach us, e.g. https://nas.local:7777 (used in get.php / xmltv)
    ClientUrl: string;        // React client URL (dev: Vite on :5173) — opened from the VCL dev form
    // TLS — the output portal is served over HTTPS in production.
    UseHttps: Boolean;        // when true, Horse listens with TLS (requires OpenSSL libs deployed)
    TlsCertFile: string;      // PEM certificate (full chain)
    TlsKeyFile: string;       // PEM private key
    TlsRootCertFile: string;  // optional CA/root bundle
    // stream proxy: relay the video through this server (handy abroad). OFF => box
    // gets the raw provider URL directly. ON => a dedicated Indy server on ProxyPort
    // relays the bytes. See IPTV.Api.ProxyServer.
    ProxyStreams: Boolean;
    ProxyPort: Integer;
    // Stream failover: when a relayed channel's upstream can't be reached, try the
    // SAME channel from another source (matched by tvg-id, else exact name). OFF by
    // default. Only works in proxy/relay mode (a single 302 redirect can't fail over).
    StreamFailover: Boolean;
    // Admin API password. Empty => the /api admin surface is open (dev). When set,
    // every /api/* call must send it (header X-Admin-Password or ?pw=). The Xtream
    // box endpoints are unaffected — they use their own output credentials.
    AdminPassword: string;
    // Plex Live TV integration. Two independent tuner surfaces, each on/off and
    // each with its own proxy choice (whether stream URLs go via the relay :ProxyPort
    // or are the raw/302 upstream):
    //   A) M3U + XMLTV tuner   -> /plex/playlist.m3u + /plex/epg.xml
    //   B) HDHomeRun emulation -> /discover.json + /lineup.json (+ SSDP on UDP 1900)
    PlexM3uEnabled: Boolean;
    PlexM3uProxy: Boolean;
    PlexHdhrEnabled: Boolean;
    PlexHdhrProxy: Boolean;
    PlexTunerCount: Integer;  // concurrent streams advertised by the HDHomeRun tuner
    PlexListId: Integer;      // bouquet served to Plex/Jellyfin; 0 = first enabled bouquet
    PlexDeviceId: string;     // stable HDHomeRun device id (generated once if empty)
    // Optional Plex server link, so the admin "rescan Plex" button can tell Plex
    // to reload its DVR guide/lineup after a bouquet change.
    PlexServerUrl: string;    // e.g. http://192.168.1.10:32400
    PlexToken: string;        // X-Plex-Token
    // Global group filter for the box/media-server output (get.php M3U, xmltv.php,
    // Plex/HDHomeRun playlist + guide + lineup): only these group-titles are
    // published. EMPTY => everything (current behaviour). Case-insensitive.
    VisibleGroups: TArray<string>;
    // Dummy EPG: when a channel has NO real guide data, emit filler programmes so
    // Plex/Jellyfin show a proper line-up instead of "Unknown airing". Channels
    // WITH real EPG are untouched. Applied to the tuner + Plex/root XMLTV output.
    DummyEpgEnabled: Boolean;    // default on — this is the whole point
    DummyEpgBlockMinutes: Integer; // block length, aligned to whole hours (default 120)
    DummyEpgHoursBack: Integer;   // window start, hours before now (default 12)
    DummyEpgHoursAhead: Integer;  // window end, hours after now (default 48)
    // Prefix each channel name with its group on the PLEX surfaces only (Plex's
    // HDHomeRun tuner can't show groups, so folding the group into the name is the
    // only way to see the provider there). e.g. "Sport · NPO 1". Default off; the
    // plain box output (get.php / xmltv.php) keeps clean names either way.
    NameShowGroup: Boolean;
    // Prefix each channel name with a zero-padded sort number in output order
    // ("010 NPO 1") on the PLEX surfaces — so Plex, which usually sorts Live TV by
    // name, ends up in the exact bouquet order. Combinable with NameShowGroup
    // ("010 Sport · NPO 1"). Default off; box output stays clean.
    NameShowNumber: Boolean;
    // Prefix each channel name with a per-SOURCE letter (A = 1st provider, B = 2nd,
    // …) on the PLEX surfaces, so Plex groups channels by provider and — because a
    // leading letter isn't stripped like a leading digit — actually sorts on it.
    // Combined with NameShowNumber the number resets per source ("A 018 NPO 1",
    // "B 001 HBO"). Default off; box output stays clean.
    NameShowSource: Boolean;
    // Plex sorts its Live TV guide by the (XMLTV) channel-id, NOT the display name —
    // so a name prefix can't reorder it. This prefixes the published channel-id with
    // a zero-padded sort number in bouquet order ("0001_animalplanet.nl") on the PLEX
    // surfaces, so Plex's id-sort follows your bouquet. The M3U tvg-id and the XMLTV
    // channel/programme ids are re-keyed together, so EPG coupling still works; the
    // plain box output (get.php / xmltv.php) keeps the real tvg-ids. Default off.
    IdSortPrefix: Boolean;
    class function Default: TAppConfig; static;
    class function Load(const APath: string): TAppConfig; static;
    procedure Save(const APath: string);
  end;

implementation

uses
  System.SysUtils, System.IOUtils, System.JSON, System.Generics.Collections;

class function TAppConfig.Default: TAppConfig;
begin
  Result.HttpPort := 7777;
  Result.DatabasePath := TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), 'data\iptvplay.sqlite');
  Result.SeparateReadConnection := False; // single connection by default (robust on FUSE)
  Result.RefreshHour := 4;
  Result.RefreshMinute := 0;
  Result.EpgMaxDays := 7;
  Result.PublicBaseUrl := 'http://localhost:7777';
  Result.ClientUrl := 'http://localhost:5173';
  Result.UseHttps := False;        // dev default; enable in production config.json
  Result.TlsCertFile := '';
  Result.TlsKeyFile := '';
  Result.TlsRootCertFile := '';
  Result.ProxyStreams := False;
  Result.ProxyPort := 7778;
  Result.StreamFailover := False;
  Result.AdminPassword := '';      // open by default; set to lock the admin UI/API
  Result.PlexM3uEnabled := False;
  Result.PlexM3uProxy := False;
  Result.PlexHdhrEnabled := False;
  Result.PlexHdhrProxy := False;
  Result.PlexTunerCount := 4;
  Result.PlexListId := 0;
  Result.PlexDeviceId := '';       // filled in by the API server on first start
  Result.PlexServerUrl := '';
  Result.PlexToken := '';
  Result.VisibleGroups := [];
  Result.DummyEpgEnabled := True;
  Result.DummyEpgBlockMinutes := 120;
  Result.DummyEpgHoursBack := 12;
  Result.DummyEpgHoursAhead := 48;
  Result.NameShowGroup := False;
  Result.NameShowNumber := False;
  Result.NameShowSource := False;
  Result.IdSortPrefix := False;
end;

procedure TAppConfig.Save(const APath: string);
var
  Json: TJSONObject;
  GroupArr: TJSONArray;
  G: string;
begin
  Json := TJSONObject.Create;
  try
    Json.AddPair('httpPort', TJSONNumber.Create(HttpPort));
    Json.AddPair('databasePath', DatabasePath);
    Json.AddPair('separateReadConnection', TJSONBool.Create(SeparateReadConnection));
    Json.AddPair('refreshHour', TJSONNumber.Create(RefreshHour));
    Json.AddPair('refreshMinute', TJSONNumber.Create(RefreshMinute));
    Json.AddPair('epgMaxDays', TJSONNumber.Create(EpgMaxDays));
    Json.AddPair('publicBaseUrl', PublicBaseUrl);
    Json.AddPair('clientUrl', ClientUrl);
    Json.AddPair('useHttps', TJSONBool.Create(UseHttps));
    Json.AddPair('tlsCertFile', TlsCertFile);
    Json.AddPair('tlsKeyFile', TlsKeyFile);
    Json.AddPair('tlsRootCertFile', TlsRootCertFile);
    Json.AddPair('proxyStreams', TJSONBool.Create(ProxyStreams));
    Json.AddPair('proxyPort', TJSONNumber.Create(ProxyPort));
    Json.AddPair('streamFailover', TJSONBool.Create(StreamFailover));
    Json.AddPair('adminPassword', AdminPassword);
    Json.AddPair('plexM3uEnabled', TJSONBool.Create(PlexM3uEnabled));
    Json.AddPair('plexM3uProxy', TJSONBool.Create(PlexM3uProxy));
    Json.AddPair('plexHdhrEnabled', TJSONBool.Create(PlexHdhrEnabled));
    Json.AddPair('plexHdhrProxy', TJSONBool.Create(PlexHdhrProxy));
    Json.AddPair('plexTunerCount', TJSONNumber.Create(PlexTunerCount));
    Json.AddPair('plexListId', TJSONNumber.Create(PlexListId));
    Json.AddPair('plexDeviceId', PlexDeviceId);
    Json.AddPair('plexServerUrl', PlexServerUrl);
    Json.AddPair('plexToken', PlexToken);
    Json.AddPair('dummyEpgEnabled', TJSONBool.Create(DummyEpgEnabled));
    Json.AddPair('dummyEpgBlockMinutes', TJSONNumber.Create(DummyEpgBlockMinutes));
    Json.AddPair('dummyEpgHoursBack', TJSONNumber.Create(DummyEpgHoursBack));
    Json.AddPair('dummyEpgHoursAhead', TJSONNumber.Create(DummyEpgHoursAhead));
    Json.AddPair('nameShowGroup', TJSONBool.Create(NameShowGroup));
    Json.AddPair('nameShowNumber', TJSONBool.Create(NameShowNumber));
    Json.AddPair('nameShowSource', TJSONBool.Create(NameShowSource));
    Json.AddPair('idSortPrefix', TJSONBool.Create(IdSortPrefix));
    GroupArr := TJSONArray.Create;
    for G in VisibleGroups do
      GroupArr.Add(G);
    Json.AddPair('visibleGroups', GroupArr);
    TFile.WriteAllText(APath, Json.Format(2));
  finally
    Json.Free;
  end;
end;

class function TAppConfig.Load(const APath: string): TAppConfig;

  // Per-field readers that fall back to the default not only when the key is
  // ABSENT but also when it's present with the WRONG type. A hand-edited config
  // typo like "httpPort": "7777" (a string) must NOT crash startup — the file's
  // contract is "defaults when a field is missing"; we extend that to "or unparseable".
  function JInt(AJson: TJSONObject; const AKey: string; ADef: Integer): Integer;
  begin
    try Result := AJson.GetValue<Integer>(AKey, ADef); except Result := ADef; end;
  end;
  function JStr(AJson: TJSONObject; const AKey, ADef: string): string;
  begin
    try Result := AJson.GetValue<string>(AKey, ADef); except Result := ADef; end;
  end;
  function JBool(AJson: TJSONObject; const AKey: string; ADef: Boolean): Boolean;
  begin
    try Result := AJson.GetValue<Boolean>(AKey, ADef); except Result := ADef; end;
  end;
  function Clamp(V, Lo, Hi: Integer): Integer;
  begin
    if V < Lo then Result := Lo else if V > Hi then Result := Hi else Result := V;
  end;

var
  Val: TJSONValue;
  Json: TJSONObject;
  GroupsVal, GV: TJSONValue;
  Groups: TList<string>;
begin
  Result := Default;
  Json := nil;
  if TFile.Exists(APath) then
  begin
    // parse to a value first: a malformed OR non-object (e.g. a bare array) file
    // must fall back to defaults without raising EInvalidCast or leaking the node
    Val := TJSONObject.ParseJSONValue(TFile.ReadAllText(APath));
    if Val is TJSONObject then
      Json := TJSONObject(Val)
    else
      Val.Free; // nil-safe; frees a non-object value
  end;
  if Json <> nil then
  try
    // numeric fields are clamped to valid ranges: an out-of-range refreshHour/Minute
    // would otherwise overflow the Word fields (range error / silent wrap), and a
    // 0/negative port can't bind.
    Result.HttpPort := Clamp(JInt(Json, 'httpPort', Result.HttpPort), 1, 65535);
    Result.DatabasePath := JStr(Json, 'databasePath', Result.DatabasePath);
    Result.SeparateReadConnection := JBool(Json, 'separateReadConnection', Result.SeparateReadConnection);
    Result.RefreshHour := Clamp(JInt(Json, 'refreshHour', Result.RefreshHour), 0, 23);
    Result.RefreshMinute := Clamp(JInt(Json, 'refreshMinute', Result.RefreshMinute), 0, 59);
    Result.EpgMaxDays := Clamp(JInt(Json, 'epgMaxDays', Result.EpgMaxDays), 0, 366);
    Result.PublicBaseUrl := JStr(Json, 'publicBaseUrl', Result.PublicBaseUrl);
    Result.ClientUrl := JStr(Json, 'clientUrl', Result.ClientUrl);
    Result.UseHttps := JBool(Json, 'useHttps', Result.UseHttps);
    Result.TlsCertFile := JStr(Json, 'tlsCertFile', Result.TlsCertFile);
    Result.TlsKeyFile := JStr(Json, 'tlsKeyFile', Result.TlsKeyFile);
    Result.TlsRootCertFile := JStr(Json, 'tlsRootCertFile', Result.TlsRootCertFile);
    Result.ProxyStreams := JBool(Json, 'proxyStreams', Result.ProxyStreams);
    Result.ProxyPort := Clamp(JInt(Json, 'proxyPort', Result.ProxyPort), 1, 65535);
    Result.StreamFailover := JBool(Json, 'streamFailover', Result.StreamFailover);
    Result.AdminPassword := JStr(Json, 'adminPassword', Result.AdminPassword);
    Result.PlexM3uEnabled := JBool(Json, 'plexM3uEnabled', Result.PlexM3uEnabled);
    Result.PlexM3uProxy := JBool(Json, 'plexM3uProxy', Result.PlexM3uProxy);
    Result.PlexHdhrEnabled := JBool(Json, 'plexHdhrEnabled', Result.PlexHdhrEnabled);
    Result.PlexHdhrProxy := JBool(Json, 'plexHdhrProxy', Result.PlexHdhrProxy);
    Result.PlexTunerCount := Clamp(JInt(Json, 'plexTunerCount', Result.PlexTunerCount), 1, 100);
    Result.PlexListId := JInt(Json, 'plexListId', Result.PlexListId);
    Result.PlexDeviceId := JStr(Json, 'plexDeviceId', Result.PlexDeviceId);
    Result.PlexServerUrl := JStr(Json, 'plexServerUrl', Result.PlexServerUrl);
    Result.PlexToken := JStr(Json, 'plexToken', Result.PlexToken);
    Result.DummyEpgEnabled := JBool(Json, 'dummyEpgEnabled', Result.DummyEpgEnabled);
    Result.DummyEpgBlockMinutes := Clamp(JInt(Json, 'dummyEpgBlockMinutes', Result.DummyEpgBlockMinutes), 5, 720);
    Result.DummyEpgHoursBack := Clamp(JInt(Json, 'dummyEpgHoursBack', Result.DummyEpgHoursBack), 0, 168);
    Result.DummyEpgHoursAhead := Clamp(JInt(Json, 'dummyEpgHoursAhead', Result.DummyEpgHoursAhead), 1, 336);
    Result.NameShowGroup := JBool(Json, 'nameShowGroup', Result.NameShowGroup);
    Result.NameShowNumber := JBool(Json, 'nameShowNumber', Result.NameShowNumber);
    Result.NameShowSource := JBool(Json, 'nameShowSource', Result.NameShowSource);
    Result.IdSortPrefix := JBool(Json, 'idSortPrefix', Result.IdSortPrefix);
    // visibleGroups[] — the global group filter (array of strings)
    GroupsVal := Json.GetValue('visibleGroups');
    if GroupsVal is TJSONArray then
    begin
      Groups := TList<string>.Create;
      try
        for GV in TJSONArray(GroupsVal) do
          if GV is TJSONString then
            Groups.Add(TJSONString(GV).Value);
        Result.VisibleGroups := Groups.ToArray;
      finally
        Groups.Free;
      end;
    end;
  finally
    Json.Free;
  end;
  // ADMIN_PASSWORD from the environment wins over config.json — the Docker/Unraid
  // way to set it without editing a mounted file.
  if GetEnvironmentVariable('ADMIN_PASSWORD') <> '' then
    Result.AdminPassword := GetEnvironmentVariable('ADMIN_PASSWORD');
end;

end.
