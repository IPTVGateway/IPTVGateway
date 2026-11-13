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
  APP_VERSION = '1.2.35';

  // settings file + default database location (<exe dir>\data\iptvplay.sqlite)
  cConfigFileName = 'config.json';
  cDataDirName = 'data';
  cDatabaseFileName = 'iptvplay.sqlite';
  // default listen ports (configurable: httpPort / proxyPort)
  cDefaultHttpPort = 7777;
  cDefaultProxyPort = 7778;
  // environment variables read at startup
  cEnvConfigPath = 'IPTV_CONFIG';        // where the daemon keeps config.json (Docker)
  cEnvAdminPassword = 'ADMIN_PASSWORD';  // overrides adminPassword from config.json

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
    /// The adminPassword as stored in config.json. AdminPassword may be overridden
    /// by the ADMIN_PASSWORD environment variable; Save writes THIS value, so the
    /// env secret never ends up in the file.
    AdminPasswordFile: string;
    /// Set by Load when config.json existed but could not be parsed (a backup copy
    /// was made); the host logs it. Never saved.
    LoadWarning: string;
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
    /// Extra (third-party) XMLTV guides, e.g. a country file. First = highest
    /// priority. Fetched with every refresh; used before a provider's own guide
    /// unless that source has PreferOwnEpg.
    ExtraEpgUrls: TArray<string>;
    /// Clients allowed on the Plex/HDHomeRun endpoints (they have no login): exact
    /// IPs ("192.168.1.20") or prefixes ending in a dot ("192.168.1."). Empty = all.
    MediaAllowedClients: TArray<string>;
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

/// Where the console daemon keeps config.json. With the environment variable
/// IPTV_CONFIG set (the Docker image sets /opt/iptvplay/data/config.json) the
/// config lives in the persistent data folder, so a container needs only ONE
/// volume - no single-file mount that Docker turns into a directory when the file
/// doesn't exist yet. On first start that file is created: copied from a
/// config.json next to the exe when that is a real file (the image's template, or
/// an older install's mounted config = automatic migration), else written with
/// defaults. Without IPTV_CONFIG: config.json next to the exe, as before.
/// ANote describes what happened (for the log; '' = nothing special).
function ResolveDaemonConfigPath(const AExeDir: string; out ANote: string): string;

implementation

uses
{$IFDEF MSWINDOWS}
  Winapi.Windows,
{$ENDIF}
  System.SysUtils,
  System.IOUtils,
  System.JSON,
  System.Generics.Collections,
  System.SyncObjs;

const
  // atomic save: written to <path>.tmp first, then swapped in
  cTempSuffix = '.tmp';
  // an unreadable config.json is kept as <path>.corrupt-<timestamp>
  cCorruptSuffix = '.corrupt-';
  cCorruptStampFormat = 'yyyymmdd-hhnnss';
  // indentation of the written JSON
  cJsonIndent = 2;

  // defaults (TAppConfig.Default)
  cDefaultRefreshHour = 4;
  cDefaultRefreshMinute = 0;
  cDefaultEpgMaxDays = 7;
  cDefaultPublicBaseUrl = 'http://localhost:7777'; // port = cDefaultHttpPort
  cDefaultClientUrl = 'http://localhost:5173';     // Vite dev server
  cDefaultPlexTunerCount = 4;
  cDefaultDummyEpgBlockMinutes = 120;
  cDefaultDummyEpgHoursBack = 12;
  cDefaultDummyEpgHoursAhead = 48;

  // valid ranges TAppConfig.Load clamps numeric fields to
  cMinPort = 1;
  cMaxPort = 65535;
  cMaxRefreshHour = 23;
  cMaxRefreshMinute = 59;
  cMaxEpgMaxDays = 366;
  cMinPlexTunerCount = 1;
  cMaxPlexTunerCount = 100;
  cMinDummyEpgBlockMinutes = 5;
  cMaxDummyEpgBlockMinutes = 720;   // 12 h
  cMaxDummyEpgHoursBack = 168;      // 1 week
  cMinDummyEpgHoursAhead = 1;
  cMaxDummyEpgHoursAhead = 336;     // 2 weeks

  // config.json keys (one definition for Save and Load)
  cKeyHttpPort = 'httpPort';
  cKeyDatabasePath = 'databasePath';
  cKeySeparateReadConnection = 'separateReadConnection';
  cKeyRefreshHour = 'refreshHour';
  cKeyRefreshMinute = 'refreshMinute';
  cKeyEpgMaxDays = 'epgMaxDays';
  cKeyPublicBaseUrl = 'publicBaseUrl';
  cKeyClientUrl = 'clientUrl';
  cKeyUseHttps = 'useHttps';
  cKeyTlsCertFile = 'tlsCertFile';
  cKeyTlsKeyFile = 'tlsKeyFile';
  cKeyTlsRootCertFile = 'tlsRootCertFile';
  cKeyProxyStreams = 'proxyStreams';
  cKeyProxyPort = 'proxyPort';
  cKeyStreamFailover = 'streamFailover';
  cKeyAdminPassword = 'adminPassword';
  cKeyPlexM3uEnabled = 'plexM3uEnabled';
  cKeyPlexM3uProxy = 'plexM3uProxy';
  cKeyPlexHdhrEnabled = 'plexHdhrEnabled';
  cKeyPlexHdhrProxy = 'plexHdhrProxy';
  cKeyPlexTunerCount = 'plexTunerCount';
  cKeyPlexListId = 'plexListId';
  cKeyPlexDeviceId = 'plexDeviceId';
  cKeyPlexServerUrl = 'plexServerUrl';
  cKeyPlexToken = 'plexToken';
  cKeyDummyEpgEnabled = 'dummyEpgEnabled';
  cKeyDummyEpgBlockMinutes = 'dummyEpgBlockMinutes';
  cKeyDummyEpgHoursBack = 'dummyEpgHoursBack';
  cKeyDummyEpgHoursAhead = 'dummyEpgHoursAhead';
  cKeyNameShowGroup = 'nameShowGroup';
  cKeyNameShowNumber = 'nameShowNumber';
  cKeyNameShowSource = 'nameShowSource';
  cKeyIdSortPrefix = 'idSortPrefix';
  cKeyVisibleGroups = 'visibleGroups';
  cKeyExtraEpgUrls = 'extraEpgUrls';
  cKeyMediaAllowedClients = 'mediaAllowedClients';

var
  GConfigSaveLock: TCriticalSection;

// Put ASource in place of ATarget in ONE step (no window where neither exists, as
// with Delete + Move): MoveFileEx(REPLACE_EXISTING) on Windows, rename() on POSIX.
procedure ReplaceFileAtomic(const ASource, ATarget: string);
begin
{$IFDEF MSWINDOWS}
  if not MoveFileEx(PChar(ASource), PChar(ATarget), MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
{$ELSE}
  if not RenameFile(ASource, ATarget) then // POSIX rename() replaces atomically
    RaiseLastOSError;
{$ENDIF}
end;

// A save that was cut off between writing the temp file and swapping it in (older
// versions deleted config.json first) leaves only config.json.tmp: take that one.
procedure RecoverInterruptedSave(const APath: string);
begin
  if (APath <> '') and not TFile.Exists(APath) and TFile.Exists(APath + cTempSuffix) then
    try
      ReplaceFileAtomic(APath + cTempSuffix, APath);
    except
      // best effort: Load then runs on defaults and reports it
    end;
end;

class function TAppConfig.Default: TAppConfig;
begin
  Result.HttpPort := cDefaultHttpPort;
  // two Combines, no 'data\...': on Linux a backslash is part of the FILE NAME
  // (the DB ended up as "/opt/iptvplay/data\iptvplay.sqlite", outside the volume)
  Result.DatabasePath := TPath.Combine(TPath.Combine(TPath.GetDirectoryName(ParamStr(0)), cDataDirName),
    cDatabaseFileName);
  Result.SeparateReadConnection := False; // single connection by default (robust on FUSE)
  Result.RefreshHour := cDefaultRefreshHour;
  Result.RefreshMinute := cDefaultRefreshMinute;
  Result.EpgMaxDays := cDefaultEpgMaxDays;
  Result.PublicBaseUrl := cDefaultPublicBaseUrl;
  Result.ClientUrl := cDefaultClientUrl;
  Result.UseHttps := False;        // dev default; enable in production config.json
  Result.TlsCertFile := '';
  Result.TlsKeyFile := '';
  Result.TlsRootCertFile := '';
  Result.ProxyStreams := False;
  Result.ProxyPort := cDefaultProxyPort;
  Result.StreamFailover := False;
  Result.AdminPassword := '';      // open by default; set to lock the admin UI/API
  Result.AdminPasswordFile := '';
  Result.LoadWarning := '';
  Result.PlexM3uEnabled := False;
  Result.PlexM3uProxy := False;
  Result.PlexHdhrEnabled := False;
  Result.PlexHdhrProxy := False;
  Result.PlexTunerCount := cDefaultPlexTunerCount;
  Result.PlexListId := 0;
  Result.PlexDeviceId := '';       // filled in by the API server on first start
  Result.PlexServerUrl := '';
  Result.PlexToken := '';
  Result.VisibleGroups := [];
  Result.ExtraEpgUrls := [];
  Result.MediaAllowedClients := [];
  Result.DummyEpgEnabled := True;
  Result.DummyEpgBlockMinutes := cDefaultDummyEpgBlockMinutes;
  Result.DummyEpgHoursBack := cDefaultDummyEpgHoursBack;
  Result.DummyEpgHoursAhead := cDefaultDummyEpgHoursAhead;
  Result.NameShowGroup := False;
  Result.NameShowNumber := False;
  Result.NameShowSource := False;
  Result.IdSortPrefix := False;
end;

function ResolveDaemonConfigPath(const AExeDir: string; out ANote: string): string;
var
  Legacy: string;
begin
  ANote := '';
  Legacy := TPath.Combine(AExeDir, cConfigFileName);
  Result := GetEnvironmentVariable(cEnvConfigPath).Trim;
  if Result = '' then
    Exit(Legacy);
  RecoverInterruptedSave(Result);
  if TFile.Exists(Result) then
    Exit;
  ForceDirectories(ExtractFileDir(Result));
  // TFile.Exists is False for a directory: a config.json that Docker created as a
  // folder (missing single-file mount) is ignored, not copied
  if TFile.Exists(Legacy) then
  begin
    TFile.Copy(Legacy, Result);
    ANote := Format('config: created %s from %s (settings now live in the data folder)', [Result, Legacy]);
  end
  else
  begin
    TAppConfig.Default.Save(Result);
    ANote := Format('config: created %s with defaults', [Result]);
  end;
end;

procedure TAppConfig.Save(const APath: string);
var
  Json: TJSONObject;
  GroupArr: TJSONArray;
  G: string;
begin
  Json := TJSONObject.Create;
  try
    Json.AddPair(cKeyHttpPort, TJSONNumber.Create(HttpPort));
    Json.AddPair(cKeyDatabasePath, DatabasePath);
    Json.AddPair(cKeySeparateReadConnection, TJSONBool.Create(SeparateReadConnection));
    Json.AddPair(cKeyRefreshHour, TJSONNumber.Create(RefreshHour));
    Json.AddPair(cKeyRefreshMinute, TJSONNumber.Create(RefreshMinute));
    Json.AddPair(cKeyEpgMaxDays, TJSONNumber.Create(EpgMaxDays));
    Json.AddPair(cKeyPublicBaseUrl, PublicBaseUrl);
    Json.AddPair(cKeyClientUrl, ClientUrl);
    Json.AddPair(cKeyUseHttps, TJSONBool.Create(UseHttps));
    Json.AddPair(cKeyTlsCertFile, TlsCertFile);
    Json.AddPair(cKeyTlsKeyFile, TlsKeyFile);
    Json.AddPair(cKeyTlsRootCertFile, TlsRootCertFile);
    Json.AddPair(cKeyProxyStreams, TJSONBool.Create(ProxyStreams));
    Json.AddPair(cKeyProxyPort, TJSONNumber.Create(ProxyPort));
    Json.AddPair(cKeyStreamFailover, TJSONBool.Create(StreamFailover));
    Json.AddPair(cKeyAdminPassword, AdminPasswordFile); // never the env override
    Json.AddPair(cKeyPlexM3uEnabled, TJSONBool.Create(PlexM3uEnabled));
    Json.AddPair(cKeyPlexM3uProxy, TJSONBool.Create(PlexM3uProxy));
    Json.AddPair(cKeyPlexHdhrEnabled, TJSONBool.Create(PlexHdhrEnabled));
    Json.AddPair(cKeyPlexHdhrProxy, TJSONBool.Create(PlexHdhrProxy));
    Json.AddPair(cKeyPlexTunerCount, TJSONNumber.Create(PlexTunerCount));
    Json.AddPair(cKeyPlexListId, TJSONNumber.Create(PlexListId));
    Json.AddPair(cKeyPlexDeviceId, PlexDeviceId);
    Json.AddPair(cKeyPlexServerUrl, PlexServerUrl);
    Json.AddPair(cKeyPlexToken, PlexToken);
    Json.AddPair(cKeyDummyEpgEnabled, TJSONBool.Create(DummyEpgEnabled));
    Json.AddPair(cKeyDummyEpgBlockMinutes, TJSONNumber.Create(DummyEpgBlockMinutes));
    Json.AddPair(cKeyDummyEpgHoursBack, TJSONNumber.Create(DummyEpgHoursBack));
    Json.AddPair(cKeyDummyEpgHoursAhead, TJSONNumber.Create(DummyEpgHoursAhead));
    Json.AddPair(cKeyNameShowGroup, TJSONBool.Create(NameShowGroup));
    Json.AddPair(cKeyNameShowNumber, TJSONBool.Create(NameShowNumber));
    Json.AddPair(cKeyNameShowSource, TJSONBool.Create(NameShowSource));
    Json.AddPair(cKeyIdSortPrefix, TJSONBool.Create(IdSortPrefix));
    GroupArr := TJSONArray.Create;
    for G in VisibleGroups do
      GroupArr.Add(G);
    Json.AddPair(cKeyVisibleGroups, GroupArr);
    GroupArr := TJSONArray.Create;
    for G in ExtraEpgUrls do
      GroupArr.Add(G);
    Json.AddPair(cKeyExtraEpgUrls, GroupArr);
    GroupArr := TJSONArray.Create;
    for G in MediaAllowedClients do
      GroupArr.Add(G);
    Json.AddPair(cKeyMediaAllowedClients, GroupArr);
    // atomic-ish: write a temp file, then swap it in, so a crash or a concurrent
    // save never leaves a truncated config.json (which would load as defaults:
    // admin open, Plex token gone); one save at a time
    GConfigSaveLock.Acquire;
    try
      TFile.WriteAllText(APath + cTempSuffix, Json.Format(cJsonIndent), TEncoding.UTF8);
      ReplaceFileAtomic(APath + cTempSuffix, APath);
    finally
      GConfigSaveLock.Release;
    end;
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
  lCorruptCopy: string;
begin
  Result := Default;
  Json := nil;
  RecoverInterruptedSave(APath);
  if TFile.Exists(APath) then
  begin
    // parse to a value first: a malformed OR non-object (e.g. a bare array) file
    // must fall back to defaults without raising EInvalidCast or leaking the node
    Val := TJSONObject.ParseJSONValue(TFile.ReadAllText(APath));
    if Val is TJSONObject then
      Json := TJSONObject(Val)
    else
    begin
      Val.Free; // nil-safe; frees a non-object value
      // keep the broken file instead of letting the first save overwrite it
      // with defaults (that would silently drop the admin password / Plex token)
      lCorruptCopy := APath + cCorruptSuffix + FormatDateTime(cCorruptStampFormat, Now);
      Result.LoadWarning := Format('config: %s could not be read - kept a copy as %s; ' +
        'running with defaults', [APath, lCorruptCopy]);
      try
        TFile.Copy(APath, lCorruptCopy, True);
      except
        // best effort
      end;
    end;
  end;
  if Json <> nil then
  try
    // numeric fields are clamped to valid ranges: an out-of-range refreshHour/Minute
    // would otherwise overflow the Word fields (range error / silent wrap), and a
    // 0/negative port can't bind.
    Result.HttpPort := Clamp(JInt(Json, cKeyHttpPort, Result.HttpPort), cMinPort, cMaxPort);
    Result.DatabasePath := JStr(Json, cKeyDatabasePath, Result.DatabasePath);
    Result.SeparateReadConnection := JBool(Json, cKeySeparateReadConnection, Result.SeparateReadConnection);
    Result.RefreshHour := Clamp(JInt(Json, cKeyRefreshHour, Result.RefreshHour), 0, cMaxRefreshHour);
    Result.RefreshMinute := Clamp(JInt(Json, cKeyRefreshMinute, Result.RefreshMinute), 0, cMaxRefreshMinute);
    Result.EpgMaxDays := Clamp(JInt(Json, cKeyEpgMaxDays, Result.EpgMaxDays), 0, cMaxEpgMaxDays);
    Result.PublicBaseUrl := JStr(Json, cKeyPublicBaseUrl, Result.PublicBaseUrl);
    Result.ClientUrl := JStr(Json, cKeyClientUrl, Result.ClientUrl);
    Result.UseHttps := JBool(Json, cKeyUseHttps, Result.UseHttps);
    Result.TlsCertFile := JStr(Json, cKeyTlsCertFile, Result.TlsCertFile);
    Result.TlsKeyFile := JStr(Json, cKeyTlsKeyFile, Result.TlsKeyFile);
    Result.TlsRootCertFile := JStr(Json, cKeyTlsRootCertFile, Result.TlsRootCertFile);
    Result.ProxyStreams := JBool(Json, cKeyProxyStreams, Result.ProxyStreams);
    Result.ProxyPort := Clamp(JInt(Json, cKeyProxyPort, Result.ProxyPort), cMinPort, cMaxPort);
    Result.StreamFailover := JBool(Json, cKeyStreamFailover, Result.StreamFailover);
    Result.AdminPassword := JStr(Json, cKeyAdminPassword, Result.AdminPassword);
    Result.AdminPasswordFile := Result.AdminPassword;
    Result.PlexM3uEnabled := JBool(Json, cKeyPlexM3uEnabled, Result.PlexM3uEnabled);
    Result.PlexM3uProxy := JBool(Json, cKeyPlexM3uProxy, Result.PlexM3uProxy);
    Result.PlexHdhrEnabled := JBool(Json, cKeyPlexHdhrEnabled, Result.PlexHdhrEnabled);
    Result.PlexHdhrProxy := JBool(Json, cKeyPlexHdhrProxy, Result.PlexHdhrProxy);
    Result.PlexTunerCount := Clamp(JInt(Json, cKeyPlexTunerCount, Result.PlexTunerCount), cMinPlexTunerCount,
      cMaxPlexTunerCount);
    Result.PlexListId := JInt(Json, cKeyPlexListId, Result.PlexListId);
    Result.PlexDeviceId := JStr(Json, cKeyPlexDeviceId, Result.PlexDeviceId);
    Result.PlexServerUrl := JStr(Json, cKeyPlexServerUrl, Result.PlexServerUrl);
    Result.PlexToken := JStr(Json, cKeyPlexToken, Result.PlexToken);
    Result.DummyEpgEnabled := JBool(Json, cKeyDummyEpgEnabled, Result.DummyEpgEnabled);
    Result.DummyEpgBlockMinutes := Clamp(JInt(Json, cKeyDummyEpgBlockMinutes, Result.DummyEpgBlockMinutes), cMinDummyEpgBlockMinutes,
      cMaxDummyEpgBlockMinutes);
    Result.DummyEpgHoursBack := Clamp(JInt(Json, cKeyDummyEpgHoursBack, Result.DummyEpgHoursBack), 0, cMaxDummyEpgHoursBack);
    Result.DummyEpgHoursAhead := Clamp(JInt(Json, cKeyDummyEpgHoursAhead, Result.DummyEpgHoursAhead), cMinDummyEpgHoursAhead,
      cMaxDummyEpgHoursAhead);
    Result.NameShowGroup := JBool(Json, cKeyNameShowGroup, Result.NameShowGroup);
    Result.NameShowNumber := JBool(Json, cKeyNameShowNumber, Result.NameShowNumber);
    Result.NameShowSource := JBool(Json, cKeyNameShowSource, Result.NameShowSource);
    Result.IdSortPrefix := JBool(Json, cKeyIdSortPrefix, Result.IdSortPrefix);
    // visibleGroups[] — the global group filter (array of strings)
    GroupsVal := Json.GetValue(cKeyVisibleGroups);
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
    // extraEpgUrls[] — third-party XMLTV guides
    GroupsVal := Json.GetValue(cKeyExtraEpgUrls);
    if GroupsVal is TJSONArray then
    begin
      Groups := TList<string>.Create;
      try
        for GV in TJSONArray(GroupsVal) do
          if (GV is TJSONString) and (TJSONString(GV).Value.Trim <> '') then
            Groups.Add(TJSONString(GV).Value.Trim);
        Result.ExtraEpgUrls := Groups.ToArray;
      finally
        Groups.Free;
      end;
    end;
    GroupsVal := Json.GetValue(cKeyMediaAllowedClients);
    if GroupsVal is TJSONArray then
    begin
      Groups := TList<string>.Create;
      try
        for GV in TJSONArray(GroupsVal) do
          if (GV is TJSONString) and (TJSONString(GV).Value.Trim <> '') then
            Groups.Add(TJSONString(GV).Value.Trim);
        Result.MediaAllowedClients := Groups.ToArray;
      finally
        Groups.Free;
      end;
    end;
  finally
    Json.Free;
  end;
  // ADMIN_PASSWORD from the environment wins over config.json — the Docker/Unraid
  // way to set it without editing a mounted file.
  if GetEnvironmentVariable(cEnvAdminPassword) <> '' then
    Result.AdminPassword := GetEnvironmentVariable(cEnvAdminPassword);
end;

initialization
  GConfigSaveLock := TCriticalSection.Create;

finalization
  GConfigSaveLock.Free;

end.
