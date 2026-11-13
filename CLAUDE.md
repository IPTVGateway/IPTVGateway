# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.
Machine- and maintainer-specific notes (paths, deploy targets, working agreements)
live in a local, git-ignored `CLAUDE.local.md`.

## What this project is

IPTVPlay aggregates several upstream IPTV providers into one **curated output list**
and republishes that list as its own Xtream Codes portal, so a standard IPTV box
can point at *this* service and see a clean, merged, renamed, sorted line-up.

Pipeline: **ingest** (read providers) → **curate** (merge / filter / rename / group /
sort) → **publish** (serve as an Xtream portal + XMLTV EPG).

The product goal that drives UX decisions: *a very easy interface to merge,
filter, rename and sort multiple IPTV providers.*

## Core domain rules (don't regress these)

- **Sources** are Xtream portals or M3U / M3U_plus playlists. Per source, each
  **content type** (Live / Movies / Series / Radio) can be toggled on/off; a
  disabled type is never ingested nor offered. See `TSourceConfig.EnabledFor`.
- **Streaming never flows through this service.** The box always reaches the
  provider directly: M3U output (`get.php`) embeds the **raw upstream URL**, and
  the Xtream `live/movie/series` endpoints answer with an **HTTP 302 redirect**
  to the upstream URL. We only ever hand out / redirect to URLs.
- **Change tracking:** every refresh diffs against the stored snapshot and flags
  genuinely new categories/streams with `is_new`. The operator can mark items
  **seen** (`seen_at_utc`) to clear the badge, and can add new items to a list.
- **Custom groups** are first-class and operator-created; a group can be a
  **favorite**. Canonical ordering everywhere (output + UI):
  **favorite groups first → groups A→Z → channels A→Z**, all **case-insensitive**.
- **EPG** is fetched by us from the origin portals as XMLTV (Xtream `xmltv.php`,
  or the M3U `url-tvg` attribute) per source and stored per `tvg-id`. We build
  **our own** guide and re-serve it via our `xmltv.php`, **restricted to the
  channels chosen onto the list** — only the list items' distinct `tvg-id`s are
  included. Channels link to guide data by `tvg-id` ↔ `TStreamItem.TvgId`.
- **The output portal is served over HTTPS** (`TAppConfig.UseHttps` + cert/key;
  MARS engine `PortSSL` + Indy OpenSSL `Indy.SSL.*` params). Dev defaults to plain HTTP.
- **Output credentials are optional**: a list may have an empty username; an
  unauthenticated box then resolves to the single enabled default list.
- The service **refreshes channels + EPG daily** at a configured time, in both
  hosts, via `TDailyScheduler`.
- Output is **multi-list capable** in the schema (each list has its own
  output credentials); v1 builds/tests a single list.

## Architecture: one core, three thin hosts, one worker thread

All behaviour lives in `backend/src/core`. The real work runs on a dedicated
worker thread **`TAppRunner`** (`core/app/IPTV.App.Runner.pas`) which owns the
`TAppContext` for its whole lifetime. A host never runs work itself — it only
*controls* the runner (create = start; `SignalStop`/`StopAndWait` = stop). This
is the service rule: keep the control thread free, do the work on its own thread.

- `backend/src/host_vcl` — **dev** host: a VCL form (`TMainForm`) with Start/Stop,
  port, "refresh all", "open client in browser" (opens `TAppConfig.ClientUrl`,
  default the Vite dev server) and a log memo. Holds a `TAppRunner`.
- `backend/src/host_service` — **prod** host: a cross-platform **console daemon**
  (`IPTVPlayService.dpr`). Owns a `TAppRunner`; a stop signal (SIGTERM from
  systemd / Ctrl+C / Windows console) calls `SignalStop`. Builds for **Win32 and
  Linux64** (Ubuntu/Debian under systemd — see `deploy/iptvplay.service`). No
  `Vcl.SvcMgr`, so it is genuinely portable. This is what the Docker image runs.
- `backend/src/host_winsvc` — **prod** host: a native **Windows Service**
  (`IPTVGateway_svc.dpr` + `Svc.IPTVService.pas`, **Win32 only**). A thin
  `TService` (`Vcl.SvcMgr`) that owns a `TAppRunner`: `ServiceStart` creates it,
  `ServiceStop` = `StopAndWait`, `ServiceShutdown` = `SignalStop`. Because it runs
  as LocalSystem with a read-only exe dir, **all writable state lives under
  `C:\ProgramData\IPTVGateway`** (never next to the exe): `config.json` (seeded
  from a `config.json` next to the exe on first run if present, then persisted
  here), `Data\iptvplay.sqlite` (unless `databasePath` is set), and
  `Logs\iptvgateway-svc.log`. This is why `TAppRunner`/`TAppContext.Create` take an
  optional `AConfigPath` (the daemon/dev host pass none → config.json next to the
  exe). Lifecycle/errors also go to the Windows Event Log. Install/manage with
  `IPTVGateway_svc.exe /install|/uninstall` then `sc start|stop IPTVGatewayService`.
  For running on Windows without Docker; same core.

**Put new behaviour in the core, never in a host.**

### `TAppContext` (composition root — `core/app/IPTV.App.Context.pas`)

Wires and owns everything; publishes a global `App` so the stateless MARS
resources can reach the store/ingest. Created and Started by `TAppRunner`:

```
TAppContext.Start:
  TSQLiteStore (IStore)  → Init (schema)
  TIngestService(store)
  TApiServer(config)     → MARS engine + Indy HTTP server (HTTPS when configured)
  TDailyScheduler        → calls Ingest.RefreshAll daily
  App := Self
```

### Core module map (`backend/src/core`)

| Folder       | Unit(s)                          | Responsibility |
|--------------|----------------------------------|----------------|
| `model`      | `IPTV.Model.*`                   | Plain data classes: Types, Source, Catalog (Category/StreamItem/Snapshot), Epg, CustomList (List/Group/Item) |
| `sources`    | `IPTV.Source.Intf` + M3U/Xtream/Epg/Factory | Read a source → `TSourceSnapshot`; read XMLTV → programmes |
| `ingest`     | `IPTV.Ingest.Service`            | Per-source refresh: read → `MergeSnapshot` → `ReplaceEpg`; serialised by a lock |
| `storage`    | `IPTV.Storage.Intf` + `.SQLite`  | FireDAC/SQLite persistence; **`IStore` is the contract** |
| `api`        | `IPTV.Api.Server`, `IPTV.Api.Mars.Admin/Xtream`, `IPTV.Api.Serializers`, `IPTV.Output.Builder` | MARS engine bootstrap (+TLS); `/api/*` admin resource; Xtream-portal resources; model⇄JSON; M3U/XMLTV builders |
| `scheduler`  | `IPTV.Scheduler`                 | `TDailyScheduler` background thread |
| `app`        | `IPTV.App.Config/Context/Runner` + `IPTV.Core.Utils` | config.json; composition root + global `App`; worker thread; CSV/date helpers |

### Two HTTP surfaces, one MARS engine (mounted at site root, `BasePath=''`)

REST framework is **MARS-Curiosity** (git submodule `backend/3thParty/MARS`).
Resources self-register via `MARSRegister` in their `initialization`; the engine
discovers them with the `IPTV.Api.Mars.*` wildcard. `IPTV.Api.Server` sets up the
engine + `TMARShttpServerIndy` and keeps the `Create(config)/Start/Stop` surface.

- **Admin REST** (`IPTV.Api.Mars.Admin`, `[Path('api')]`) — drives the React app:
  sources CRUD + content toggles + filter-prefix discovery (`sources/{id}/prefixes`),
  catalog browse (`sourceId/type/onlyNew/search/prefix`), mark-seen (streams + categories),
  lists/groups/items CRUD (incl. list delete) + bulk add, EPG, exports, and runtime
  settings (`GET/POST config` → reschedule refresh + toggle the relay, persisted to
  config.json). One method per route with `[GET]/[POST]/[DELETE]`,
  `[PathParam]/[QueryParam]/[BodyParam]`, `[Produces]`.
- **Xtream emulation** (`IPTV.Api.Mars.Xtream`) — what boxes talk to, as root-level
  resources: `player_api.php`, `get.php`, `xmltv.php`, and `live|movie|series`
  (`[Path('{user}/{pass}/{id}')]` → `Response.RedirectTo` the upstream URL).
  Each resolves a `TCustomList` by output credentials (empty → default); unknown → 401.

### Data flow

```
Providers ──read──> TSourceSnapshot ──MergeSnapshot──> SQLite catalog (is_new flags)
   │                                                        │
   └── XMLTV ──ReplaceEpg──> epg table                      │ curate (merge/rename/group/sort)
                                                            ▼
                                          lists / list_groups / list_items
                                                            │
                          player_api.php · get.php · xmltv.php · 302 redirect
                                                            ▼
                                                      IPTV box
```

## Implementation status

The backend is implemented end-to-end (no remaining `ENotImplemented`/501 stubs):
- **sources**: M3U/M3U_plus parser (+url-tvg), Xtream reader (live/vod/series,
  per-type), XMLTV EPG reader.
- **ingest**: per-source refresh with diff/`is_new`, EPG replace, last-refresh stamp.
- **storage** (`IPTV.Storage.SQLite`): full FireDAC/SQLite — sources/catalog/EPG/
  lists/groups/items CRUD, `MergeSnapshot` upsert+new-detection, filtered
  `LoadStreams` (search/prefix/onlyNew), mark-seen, `LoadOutputChannels` (the
  resolved, ordered join), bulk `AddItems`.
- **api/admin**: every route in the map below is wired to the store/ingest.
- **api/xtream**: `player_api.php` (account + live/vod/series categories+streams),
  302 stream redirect, `xmltv.php` (chosen channels only), `get.php` (raw URLs).
- **hosts**: VCL dev form + console daemon + native Windows Service, all via `TAppRunner`.
- **project files**: `.dproj` exist for all four (`IPTVPlayDev` Win32,
  `IPTVPlayService` Win32+Linux64, `IPTVGateway_svc` Win32, `IPTVPlayTests`). On
  Windows everything is **Win32** (32-bit is enough); the daemon's other target is
  Linux64. Verified: full backend + all hosts compile (Delphi 13.1).
- **frontend**: 3-panel workbench + an **EPG view** (Workbench/EPG header tabs) —
  source EPG per channel (`/api/epg?tvgId`) and curated EPG (`/api/lists/:id/epg`).
- **deploy**: `deploy/iptvplay.service` (systemd) and `deploy/docker/` (Dockerfile +
  compose for Unraid; packages the prebuilt Linux64 binary on debian-slim).

When extending, keep the ordering rule and the "no video through us" rule.

## Commands

> Requires RAD Studio 13. Run dependency install before first build.

**Backend** (`backend/`): MARS-Curiosity is a git submodule in
`3thParty/MARS` (clone with `--recursive`) and already on each host project's unit + include search
path — no package install needed. Copy `config.sample.json` to `config.json`
next to the exe and edit it.
Build via the IDE (open `IPTVGateway_Group.groupproj`, or a `.dproj` directly) or
command line:
```powershell
# adjust the RAD Studio rsvars path to your install
& "$env:BDS\bin\rsvars.bat"
msbuild backend\src\host_vcl\IPTVPlayDev.dproj /p:Config=Debug /p:Platform=Win32
msbuild backend\src\host_service\IPTVPlayService.dproj /p:Config=Release /p:Platform=Win32
# Native Windows Service (Win32 only):
msbuild backend\src\host_winsvc\IPTVGateway_svc.dproj /p:Config=Release /p:Platform=Win32
# Linux daemon (PAServer to an Ubuntu/Debian box must be configured):
msbuild backend\src\host_service\IPTVPlayService.dproj /p:Config=Release /p:Platform=Linux64
```
Run the console daemon: run it foreground (Ctrl+C to stop), or on Linux install
`deploy/iptvplay.service` (systemd; SIGTERM stops it cleanly, logs go to
`journalctl -u iptvplay`). The **Windows Service** instead installs into the SCM:
`IPTVGateway_svc.exe /install` (elevated), then `sc start IPTVGatewayService` /
`services.msc`; `/uninstall` removes it. Both read `config.json` next to the exe.

**Verified compiled AND run** with Delphi 13.1 (Studio 37.0): the whole backend
(core + MARS API + both hosts) builds clean, the 26 tests pass, and the daemon
was smoke-tested over HTTP — `/api/health`, POST/GET `/api/lists`,
`/player_api.php` (default-list fallback) and `/get.php` all return correctly.

**Three non-obvious MARS wiring requirements** (all in `IPTV.Api.Server`; getting
any wrong yields 404 "unknown application" or 500 at runtime, not a compile error):
1. **Root routing**: MARS picks the application by the first URL segment. Our
   endpoints sit at many roots (`/api`, `/player_api.php`, `/live`...), so the app
   uses an **empty base path** and an `OnGetApplication` handler that returns the
   single app for every request; resources then match by their `[Path]` from root.
2. **`[Context]` injection** of `IMARSResponse`/`IMARSRequest` requires
   `MARS.Core.Activation.InjectionService` in the uses (it self-registers).
3. **A JWT Token implementation must be linked** even though we don't authenticate
   (MARS injects a token per activation): `MARS.mORMotJWT.Token` on Windows,
   `MARS.JOSEJWT.Token` on Linux. These pull `ThirdParty\mORMot\Source` /
   `ThirdParty\delphi-jose-jwt\Source` — both are on the host projects' search +
   include paths.

The IDE generates each project's `.res` (a CLI build needs a stub `.res`).

**Tests** — DUnitX in `backend/tests` (`Test.M3U`, `Test.Utils`, `Test.Storage`
(temp-DB integration), `Test.OutputBuilder`, `Test.Serializers`, plus the opt-in
`Test.Integration.Live` which hits a REAL portal — it self-skips via `Assert.Pass`
unless `test.credentials.json` (gitignored) has a non-empty `xtream.url`).
Fixtures register explicitly in each unit's `initialization` (runner `UseRTTI := False`).
HTTP readers go through `IPTV.Source.Http.NewHttpClient` (browser User-Agent +
redirects + timeouts) — portals often reject default UAs with WinHTTP error 12152.
Build/run via the IDE, or from the CLI (run from **PowerShell** in `backend\tests`,
not Git-Bash — MSYS mangles `D:/…` args; no MARS needed, storage links SQLite
statically). The unit path must include `ingest` + `scheduler`; pass `-U` as ONE
quoted `;`-list (separate `-U..\x` args get misparsed by PowerShell):
```powershell
$BDS="<RAD Studio 13 dir>"; $LIB="$BDS\lib\Win32\release"
$DCU="<a DCU folder>"; $EXE="..\..\.Output\Win32\Debug"
$U="..\src\core\model;..\src\core\sources;..\src\core\storage;..\src\core\app;..\src\core\api;..\src\core\ingest;..\src\core\scheduler"
& "$BDS\bin\dcc32.exe" -B "-U$LIB;$U" "-NSSystem;Winapi;Data;Xml;Web;Soap;FireDAC" "-NU$DCU" "-N0$DCU" "-E$EXE" IPTVPlayTests.dpr
& "$EXE\IPTVPlayTests.exe"   # exits non-zero on failure (175 tests as of 1.2.36)
```
Compile-check the service host (incl. MARS/admin API) without running it:
`cmd /c "call "<BDS>\bin\rsvars.bat" && msbuild backend\src\host_service\IPTVPlayService.dproj /t:Build /p:Config=Release /p:Platform=Win32"`.

**Testing against real data:** don't point tools at a live database; build a
small scratch console program that uses `TSQLiteStore` on a COPY of it.

**Frontend** (`frontend/`; Node.js 20+):
```powershell
npm install
npm run dev        # http://localhost:5173, proxies /api -> :7777
npx vitest run     # 122 tests as of 1.2.36
npm run build      # tsc -b && vite build
```

**Release / deploy:** bump `APP_VERSION` in `backend\src\core\app\IPTV.App.Config.pas`,
then `deploy\docker\build.ps1`: Linux64 build (with a neutral temp dir, so no Windows
user path ends up in the binary) + Docker image (via WSL when docker isn't on PATH)
+ `iptvplay.tar.gz` bundle. Optional: copy the bundle to a share
(`-PublishTo` / gitignored `deploy\docker\publish-target.local.txt`, MD5-verified,
previous release archived in `backups\`) and push `:latest` + `:<version>` to a
registry (`-Repo` / gitignored `deploy\docker\push-registry.local.txt`). Push
**Docker v2** manifests: Unraid's update check can't read OCI ("not available"), so
the Docker used for builds must not use the containerd image store.

## Project files (.dproj)

All four `.dproj` exist and set, in their Base PropertyGroup:
- `DCC_DcuOutput` = a DCU folder outside the repo (per project/platform/config;
  adjust it to your machine)
- `DCC_ExeOutput` = a shared repo-root `.Output\$(Platform)\$(Config)` (relative
  prefix per project depth: `..\..\..` for `host_*`, `..\..` for `tests`)
- `DCC_UnitSearchPath` (+ `DCC_IncludePath`) for the `core` subfolders and the
  MARS submodule's `Source` (host projects only; tests don't need MARS).

MARS comes as a git submodule, so no package install is needed. `IPTVGateway_Group.groupproj`
in `backend/src` groups the projects; you can also open a `.dproj` directly.
`$(ProductVersion)` resolves to `37.0` in the IDE (RAD Studio 13.1) but is empty
on a bare `dcc64`/`msbuild` CLI run — pass `/p:ProductVersion=37.0` for CLI builds.

## Conventions

- **SQL / long literals:** Delphi multiline strings (`'''` … `'''`), not chains of
  `'...' +` lines; a dynamic fragment (e.g. `cSqlSourceActive`) is appended with `+`.
- **Code style:** the omonien DelphiStandards guide combined with Embarcadero's Object
  Pascal Style Guide, with two house rules: local variables get a **lowercase `l`**
  prefix (`lQuery`; loop counters `i`/`j`/`k` plain) and **no inline variables**.
  Fields `F`, parameters `A`, constants `c` (ALL_CAPS only for build/system values like
  `APP_VERSION`), `FreeAndNil` for owned objects, `begin`/`end` on their own lines, max
  120 chars. **uses: one unit per line**, grouped `// RTL` / `// third-party` / `// own units`.
  No magic numbers/strings/booleans: named constants (shared HTTP status codes live in
  `IPTV.Api.Serializers`, config.json keys in `IPTV.App.Config`).
- **Unit naming:** dotted namespaces `IPTV.<Layer>.<Name>` for core; hosts use
  `Form.*` / `Svc.*`. One responsibility per unit.
- **Times are UTC** throughout storage and EPG; convert only at the edges.
- **Frontend mirrors core models** in `frontend/src/types.ts` — keep the two in
  sync when you change a model or an API shape.
- Adding a provider type = a new `ISourceReader` + a `CreateSourceReader` branch;
  nothing else in the pipeline should need to know about it.

## Optional stream proxy mode (built)

**Implemented** (`IPTV.Api.ProxyServer` + `TApiServer`); for use abroad, where the
provider geo-blocks or the box can only reach the home server. A `proxyStreams`
toggle in `TAppConfig` (with `proxyPort`, default 7778):
- OFF (default): output (get.php / Xtream redirect) hands out the RAW upstream
  provider URL — video flows box ↔ provider, never through us.
- ON: output URLs point back at us (`/live|movie|series/{user}/{pass}/{id}.ts` on
  `proxyPort`); the service fetches the upstream (VLC User-Agent, follows the
  provider's own redirects) and **relays** the bytes to the box. Video then flows
  box ↔ this service ↔ provider — the box only needs to reach the home server.
- How it works: a **dedicated `TIdHTTPServer` on `proxyPort`** (NOT MARS — its
  response model assumes a finite body), started by `TApiServer` alongside MARS
  when `proxyStreams` is on. Its `OnCommandGet` resolves the list by credentials,
  looks up the upstream URL, **writes a minimal close-delimited HTTP header
  (`video/mp2t`) straight to the socket** — bypassing `AResponseInfo`, which would
  otherwise emit Indy's default `text/html`/`Content-Length` and corrupt the
  stream — then pumps bytes via a `TForwardStream` into the client connection
  until either side closes. `get.php`/`player_api` emit the proxy URL instead of
  the raw one when proxy mode is on. MARS keeps `httpPort` for catalog/EPG/admin;
  two ports total in proxy mode. Bandwidth + CPU cost per active stream is
  inherent. Requires the host reachable from abroad (port-forward/VPN), ideally
  over HTTPS. Verified: clean `video/mp2t` relay (~9 Mbps live TS) through the proxy port.

## Series, VOD info and disabled sources (1.2.36)

- `get_series_info`: Xtream series are fetched from the provider (`XtreamApiGet`);
  each upstream episode gets a stable box-facing id `cEpisodeIdBase` (1e9) +
  `series_episodes.id` (`IStore.EnsureEpisodeIds`). `LoadListStreamById` resolves
  such an id only when its series is on the list, building the URL from the
  source's CURRENT url/creds. An M3U series item is offered as one episode.
- `get_vod_info` proxies the provider (stream_id swapped to ours); `get_vod_streams`
  carries `container_extension`. Only LIVE swaps the extension the box asks for.
- `cSqlSourceActive`: a disabled source or switched-off content type is never
  offered (LoadOutputChannels, LoadListStreamById, failover siblings).
- Box URLs with a login use `PathCred` (percent-encoded, `-` = empty login);
  `FindListForPath` maps them back.

## Channel names, strip rules and quality variants (1.2.19–1.2.20)

- `list_items.display_name` holds the cleaned name ('' = follow upstream); the
  ORIGINAL provider name is always `streams.name` (JSON `streamName`) and is shown
  under the display name in the group list. Match/replace logic must use the
  upstream name, never the display name.
- Per source: `StripPrefixes` + `StripSuffixes` (`;`-separated tokens, columns
  `strip_prefixes`/`strip_suffixes`); `CleanChannelName` in `IPTV.Core.Utils`
  applies both. `FoldDecorativeLetters` maps small caps / superscript / fullwidth
  letters (providers write `ʀᴀᴡ`, `ʳᵉᶜ`) to ASCII, 1:1 per char.
- Quality vocab (`CanonicalQuality`): SD/HD/FHD/UHD/4K/4K+/8K/8K+/QHD/2K/RAW —
  mirrored in `ListPanel.tsx` `QUALITIES`; keep in sync. `FindQualityVariants`
  keys the source-cleaned name (base key, fallback head key = tokens before the
  quality word), prefers the same source and the shortest name.
- Group header: ⎘± = replace channels by another quality/provider **in this group**
  (`ReplaceItemStreams`, `POST /api/lists/{id}/items/replace`; keeps channel no.,
  logo/tvg-id overrides) or as a copy in a new group; ✂ = clean names after the
  fact (`RestripGroupItems`, `POST /api/lists/{id}/groups/{gid}/restrip`, dry-run
  preview first; source rules + one-off extra tokens).

## Quality probe — measure one channel in all qualities (after 1.2.20)

- 📊 on a live row in the catalog and in the bouquet opens `QualityProbeModal`:
  `GET /api/catalog/streams/{id}/variants?allSources=0|1&listId=N`
  (`IStore.FindStreamVariants`: own source unless allSources; self + same base/head
  key of the source-cleaned name, then a 2nd pass on the tvg-ids of those matches;
  SQL prefilter on the longest ASCII head token, ~15 ms own source / ~100 ms all),
  then `POST /api/catalog/streams/{id}/probe?seconds=8` per variant, strictly one
  after another (also `GProbeLock` server-side — provider connection limits).
- `IPTV.Source.Probe` (pure Delphi, no ffmpeg): Indy GET (VLC UA, redirects, TLS
  handler), `TTsAnalyzer` parses PAT/PMT (codecs, audio languages), PES PTS (fps,
  media seconds, bitrate = TS bytes over the PTS span), H.264/HEVC SPS + MPEG-2
  sequence header (resolution, interlaced, bit depth, profile). HLS: highest-
  bandwidth variant, newest 3 segments; fMP4 HLS only playlist CODECS/RESOLUTION.
  `realtime` = media s / wall s (< 1 = buffering). Read-only; nothing relayed.
- From the bouquet, "Use this" swaps the item via the existing `items/replace`.
  UI hints (`probeHints`) are rules of thumb: 2160p below 10 (HEVC) / 16 (H.264)
  Mbps = "possibly upscaled".

## Bouquet-wide renumber

"Renumber bouquet" (list toolbar) numbers ALL channels of a list across groups:
groups in display order (`compareGroups`, upstream group last), channels in their
shown order; each group starts on the next hundred (100, 200, …), or the next
thousand when it has > 99 channels (`planBouquetNumbers` in `lib/ordering.ts`,
preview modal first). Written in one transaction via `POST /api/lists/{id}/renumber`
(`IStore.SetItemNumbers`). Per-group drag-reorder / A→Z sort now number from the
group's lowest existing number (`GroupNumberBase`, 1 if none), so the blocks survive.
Plex surfaces (HDHomeRun GuideNumber, Plex M3U `tvg-chno`, id-sort prefix,
number-in-name) use these bouquet numbers via `OutputNumbers` when all are > 0 and
unique, else fall back to the running position 1,2,3 (Plex rejects duplicates).

## Catch-up / timeshift (1.2.26)

- Ingest stores Xtream `tv_archive`/`tv_archive_duration` as `streams.archive_days`
  (0 = none) and the portal clock offset as `sources.tz_offset_min` (from
  `server_info.time_now` vs `timestamp_now`, rounded to 15 min, refreshed daily).
- Output: `player_api` live streams carry `tv_archive`/`tv_archive_duration`;
  `get_short_epg`/`get_simple_data_table` set `has_archive=1` for finished
  programmes inside the window; box M3U gets `catchup="xc" catchup-days="N"` (not Plex).
- Routes `timeshift/{u}/{p}/{min}/{YYYY-MM-DD:HH-MM}/{id}.ts` and
  `streaming/timeshift.php?…` resolve the stream **list-scoped** and 302 to the
  provider's `/timeshift/` (start: we advertise timezone UTC, so the box sends UTC;
  `XtreamTimeshiftUrl` shifts it to the portal clock). Proxy mode bounces to the
  relay port, whose `/timeshift/` relays it (no failover for archives). Only
  Xtream sources (`TimeshiftUpstreamUrl` returns '' otherwise → 404).
- UI: `ArchiveBadge` "⟲ 3d" on catalog and bouquet rows.

## Extra EPG sources (1.2.31)

- `config.json` `extraEpgUrls[]` (Settings → "Extra EPG sources"): third-party
  XMLTV guides (.xml/.xml.gz; `HttpGetText` gunzips by magic bytes). Fetched by
  `TIngestService.RefreshExtraEpg` after RefreshAll / RefreshEpgAll. URL i is slot
  source_id = -(i+1) in `epg` (channel ids prefixed `extra:`) + `epg_channels`
  (id, display-name). Only guide channels matching some list channel are stored.
- Matching (`TSQLiteStore.ApplyExtraGuides`, run inside LoadOutputChannels):
  `EpgNameKey` of the channel's display name first, else `EpgIdKey` of its tvg-ids
  (must agree). Only guide channels with upcoming programmes count; slot -1 beats
  -2; a key mapping to two channels of one guide is ambiguous and unused. Sets
  `TOutputChannel.ExtraGuideId`; every EPG reader uses `EpgReadIds` (extra id, else
  upstream + override id). Published channel ids never change.
- Per source `prefer_own_epg` (`PreferOwnEpg`): keep the provider's own guide
  when it has upcoming programmes; the extra guide only fills gaps.
- Several providers per tvg-id: `KeepOneSourcePerChannel` (most upcoming wins).

## MARS 2.0.3 as a git submodule

- `backend/3thParty/MARS` is a **shallow git submodule** of andrea-magni/MARS, pinned
  to a release tag; its own submodule delphi-jose-jwt (v4: search paths `Source`,
  `Source\Common`, `Source\JOSE`) is needed for Linux64. Clone with `--recursive`
  (or `git submodule update --init --recursive --depth 1`); `build.ps1` refuses to
  build when the folder is empty. Pins: `backend/3thParty/DEPENDENCIES.md`.
- Upgrade ONLY with `tools/update-mars.ps1 -Tag v.x.y.z` (checkout tag + nested
  submodules, updates DEPENDENCIES.md, prints the upgrade notes), clear the
  project's DCU folder, rebuild Win32 + Linux64, run the tests, and commit the new
  submodule pointer on its own.
- MARS 2.x: invalid/empty typed params give 400 -> box-facing params are `string`
  (e.g. player_api `limit`); string results need `[Produces]` (all ours have it).

## Config in the data volume (1.2.35)

The console daemon resolves its config via `ResolveDaemonConfigPath`: with env
`IPTV_CONFIG` (the Docker image sets `/opt/iptvplay/data/config.json`) it lives in
the data volume and is created on first start - copied from a real `config.json`
next to the exe (image template, or an older install's single-file mount =
migration), else defaults; a directory Docker made for a missing file mount is
ignored. Without the variable: next to the exe, as before. The Unraid template and
compose therefore only need the data volume.

## Log tab (1.2.34)

`TAppContext` wraps the host's log proc: every line also goes to the global
`LogRing` (`TLogRing`, last 2000 lines in memory, nothing on disk). `GET /api/logs?since=<seq>`
(admin auth, works even when App failed to start) returns newer lines; the web
app's Log tab polls it every 3 s (pause, text filter, "only problems", download).
A client cursor ahead of the server (= service restarted) gets everything again.

## Zap cache (1.2.32)

`TLockingStore` answers FindListByCredentials + LoadListStreamById (redirect,
timeshift, relay) from memory; cleared AFTER writes that can change lists/items/
streams/sources (not EPG/seen/state). A zap never waits on the DB connection.

## Docker image format

Push **Docker v2 schema 2** manifests. Docker 29's containerd image store pushes OCI
manifests; Unraid's update check asks the registry for v2 only (404 → "not
available"). Disable it in the build Docker's `/etc/docker/daemon.json`:
`"features": {"containerd-snapshotter": false}`.

## MARS startup warm-up (1.2.20)

After a restart, two API requests in the same millisecond (an open admin tab)
once left EVERY MARS request hanging (even `/api/health`, which touches no DB)
while static files still worked; a restart without the tab fixed it. Suspected:
non-thread-safe lazy first-use init in the activation path (JWT token / JOSE +
OpenSSL on Linux) — not proven. `IPTV.Api.Server` therefore closes `GWarmGate`
before the listener opens, GETs a few endpoints to itself serially (header
`X-IPTV-Warmup`), then opens it; external backend requests wait ≤30 s. Log line:
`warm-up done in N ms - API open`. Don't remove it unless the root cause is fixed.

## Operational notes (discovered while testing against a real portal)

- Upstream stream URLs typically **302-redirect** (provider load-balancer →
  streaming node), sometimes twice; players must follow redirects.
- Some providers **gate on User-Agent** — `IPTV.Source.Http` sends a browser UA
  for ingest; for playback the box/player may need a `VLC/...` UA.
- A provider's first alphabetical channels are often `### … ###` placeholders that
  don't stream — test with a real channel (e.g. `NL| NPO 1 HD`).
- One shared FireDAC SQLite connection is NOT thread-safe; all store access is
  serialised via `TLockingStore` (a refresh + a box request hit it concurrently).
