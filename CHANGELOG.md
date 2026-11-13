# Changelog

All notable changes to IPTV Gateway. Released versions are also on the
[GitHub releases](https://github.com/IPTVGateway/IPTVGateway/releases) page.

## [Unreleased]

Fixes from a five-part bug hunt (output, storage, ingest/EPG, web app, app/security).

### Security
- The **Log** endpoint (`/api/logs`) now requires the admin password, also while
  the service is still starting.
- Provider credentials are masked in HTTP error messages, so a failed download
  can't leak `username=`/`password=` into the log.
- A box without a login only gets a bouquet **that itself has no login**. A bouquet
  with a username and password is no longer reachable with empty credentials.

### Fixed
- `tools/update-mars.ps1` called itself recursively (PowerShell command names are
  case-insensitive) and never ran.
- The daily refresh could stop for good after an unexpected error (the scheduler
  thread ended); errors are now logged and scheduling continues.
- An empty or garbage EPG download (a panel answering 200 with no data) no longer
  wipes the stored guide; the previous guide is kept. This applies to provider
  guides and extra EPG sources.
- An EPG failure no longer skips saving the source's refresh time, account
  status and clock offset after a successful catalog refresh.
- "Update EPG" now waits for a running refresh's guide parse (one guide in memory
  at a time).
- `config.json` is written safely: temp file and swap, one save at a time. A file
  that can't be parsed is kept as `config.json.corrupt-<time>` instead of being
  replaced by defaults, and the problem is logged.
- `ADMIN_PASSWORD` from the environment is no longer written into `config.json`.
- Web app, Settings: only changed fields are saved, so saving no longer switches
  the stream proxy back off after it was toggled from the header.
- Web app: clearing a source's User-Agent, Referer, EPG URL, username or password,
  or a channel's name or logo override, now really clears it.
- Web app: after a source refresh the bouquet panel no longer empties or shows
  another list (stale callback).
- Web app: closing the include/exclude filter dialog saves only the filters, not
  other unsaved edits in the source form.
- **Series** play on boxes: `get_series_info` now returns the seasons and episodes.
  For Xtream sources they come from the provider; each episode gets a stable id
  of our own that only resolves through a bouquet that has the series. An M3U
  series item is offered as one episode. **Movies**: `get_vod_info` answers, and
  `get_vod_streams` carries the real `container_extension`. A movie or episode
  keeps its own container (`.mkv` stays `.mkv`); only live follows the box's
  `.ts`/`.m3u8` choice.
- A **disabled source**, or a content type switched off on a source, is no longer
  offered to boxes (lists, redirects, relay, failover). The channels stay in the
  bouquet and come back when it is switched on again.
- Catalog with **"All sources"**: opening a group shows that group's streams from
  its own source. A group with an empty id (M3U entries without a group) opens too.
- Proxy mode with HTTPS: boxes are told the relay port is plain `http`
  (`https_port=0`), so streams connect.
- The relay also serves catch-up in the query form (`streaming/timeshift.php`).
- Stream failover (proxy mode) now also switches source when the provider answers
  with an HTTP error (4xx/5xx), not only when it can't be reached.
- **Radio**: Xtream `radio_streams` are recognised as radio (and follow the radio
  switch of the source). Radio channels on a bouquet are listed for boxes with the
  live channels, the way Xtream portals do it.
- M3U content type: the `/live/`, `/movie/` and `/series/` URL path decides first,
  and group names count as whole words only. "NL| FILM" (live) and "VODAFONE" are
  no longer taken for movies.
- Dummy EPG no longer fails at the spring daylight-saving change (blocks are
  computed in UTC).
- XMLTV output drops control characters that strict guide parsers reject.
- XMLTV input: single-quoted attributes, a time zone without a space
  (`20261113120000+0100`), encoded channel ids (`&amp;`) and programmes without a
  `stop` (they end at the next programme) are understood.
- Extra EPG sources are filtered while reading, so a big guide no longer sits in
  memory as a whole.
- Extra EPG matching: an id's last part is only dropped when it is a real country
  code (`bbc.one` stays `bbcone`, `sport.hd` stays `sporthd`). Ties between guide
  channels are resolved deterministically. The "prefer own EPG" check reads only
  the guide ids of the bouquet's own channels.
- Plex / HDHomeRun and relay URLs encode the bouquet login. An empty login is
  written as `-`, instead of an empty path segment (`/live///12`) that players
  drop. `lineup.post` also accepts POST.
- Catalog paging is stable with equal names (no repeated or skipped rows).
- Deleting a source, bouquet or group happens in one transaction. Deleting a
  source also removes its guide channel list.
- Windows Service: a relative `databasePath` is placed under
  `C:\ProgramData\IPTVGateway`, not in the service's working folder.
- Web app: drag-reordering a channel **down** drops it after the target row, so
  dropping on the next row moves it.
- Web app: a dialog only closes on a click that started on the backdrop, so
  selecting text and releasing outside no longer closes it.
- Web app: the Log tab skips a poll while the previous one is still running, so no
  duplicate lines.
- Web app: after a settings import the sources, bouquets and the open bouquet are
  reloaded.
- Build: the WSL Docker step fails properly when `docker save` fails.

Second bug hunt (five separate runs):
- Streams whose content type is now recognised differently (Xtream radio, M3U groups
  such as "NL| FILM") keep their id and their place in the bouquet; before, the
  first refresh created duplicates and left the bouquet on the old row.
- A guide with single-quoted attributes no longer makes the EPG parse crawl.
- `publicBaseUrl` is checked when saved (`http://` is added when missing). A
  wrong value can no longer break every box login or the service start.
- Linux: the default database path no longer has a backslash in it. It used to
  end up outside the data folder. A config file that fails to load is no longer
  overwritten with defaults at start.
- Relay: a `/` in a bouquet password works, and `-` stands for any empty login
  field (also a bouquet with only a username).
- Stream extensions: only Xtream live `.ts`/`.m3u8` URLs follow the box's choice.
  M3U HLS playlists, radio `.mp3` and `play.php` URLs stay as they are. In proxy
  mode boxes are offered `ts` only, and an HLS request is redirected to the
  provider.
- `player_api` honours `category_id`; `epg_channel_id` matches `xmltv.php` for
  channels without a tvg-id.
- Series and movies no longer appear as channels in the Plex/HDHomeRun lineup
  and the guide. Series containers are left out of `get.php`.
- `get_series_info` answers from the read side (it no longer waits for a running
  refresh) and frees the provider's answer on errors.
- Login-free bouquet: the login cache keeps one entry, not one per password tried.
- Windows: bouquet passwords and filter tokens with characters outside Windows-1252
  (Cyrillic, emoji) work.
- Replacing channels by another quality/provider never picks a switched-off source.
- The login cache is also cleared when a save fails halfway.
- Faster EPG cleanup and stream failover (new indexes).
- Startup errors in schema upgrades are no longer hidden.
- EPG: the guide URL is trimmed. A `url-tvg` list uses its first URL. Matching tvg-ids
  is case-insensitive end to end. Latin-1 guides and playlists are no longer read as
  Cyrillic, and UTF-16 files are recognised. Times without seconds and `+01` zones
  are understood. A failed download no longer leaks memory. Large extra guides load
  faster.
- An http source that redirects to https now works.
- Adopting an M3U `url-tvg` no longer undoes edits made to the source during the
  refresh.
- Extra EPG URLs are masked in the log.
- No empty live categories are stored when only radio is switched on; radio gets its
  own categories.
- A failed start (for example a port in use) now really fails:
  - the API port is released;
  - the Windows Service reports the error in the Event Log;
  - the daemon exits with code 1, so systemd and Docker restart it.
- `config.json` is replaced in one step. A save that was cut off is recovered on
  the next start.
- Stopping during the daily refresh no longer waits for all sources: the refresh
  stops after the current one.
- Settings: out-of-range values (hour 24, port 0, the same port as the web
  interface) are refused with a message. A failed relay restart no longer leaves
  half-applied settings behind.
- Settings import also restores the extra EPG sources and the Plex bouquet.
- Daemon log lines from several threads no longer get mixed up.
- Web app:
  - unsaved edits in other bouquet rows survive a save or refresh (no more
    "Loading…" flash);
  - deleting a source or a group asks for confirmation;
  - a wrong admin password is reported;
  - pasting several filter tokens keeps all of them;
  - a failed "new bouquet" shows its error;
  - the EPG view handles very large guides and shows lanes in bouquet order;
  - after an import the settings and bouquet editors show the imported values;
  - a cancelled drag no longer sticks;
  - add-on languages load after login;
  - the proxy port field can be cleared while typing;
  - "only new" hides items once they are marked as seen.

### Added
- **Media servers: allowed clients** (Settings): the Plex/Jellyfin tuner and
  HDHomeRun endpoints have no login. They can now be limited to known IP addresses
  or a network prefix such as `192.168.1.`. Empty = every client, as before.

### Changed
- Xtream category ids are derived from the group name, not its position, so boxes
  keep hidden, favourite or locked categories after groups are added or moved.
  Boxes may forget those settings once after the update.
- `player_api` account info carries `username`, `password`, `exp_date` and
  `created_at` like real panels. A wrong login answers `auth: 0` with HTTP 200
  instead of a 401 (some boxes showed that as a network error).
- The admin password is compared in constant time. `?pw=` in the URL is only
  accepted on the M3U/XMLTV download links.
- A request during startup answers 503 "service not started" (was 500).
- `docker-compose.yml` no longer ships an example admin password. A warning is
  logged while `publicBaseUrl` still holds the template's placeholder.
- Times: "now" comes straight from the system UTC clock, so it is no longer an hour
  off in the autumn daylight-saving hour. On the spring daylight-saving day, a
  daily refresh time that falls inside the skipped hour now still runs.
- Faster "replace by another quality": the candidate search is filtered in SQL first.
- Relay: a stream that fails on every source answers 502 instead of an empty reply.
  HEAD requests are answered without pulling the stream.
- Removing duplicates keeps the copy that comes first in the bouquet as the box
  sees it.
- An extra EPG guide is stored in one transaction.
- Deleting a bouquet marks the lineup as changed for Plex.
- The quality probe also finds variants whose names use decorative letters.
- The daemon's stop signal handler only sets a flag. The main loop does the rest,
  because a signal handler must not take locks.
- Internal: the code base now follows one coding style (named constants instead of
  magic values; uniform naming, `uses` and formatting). No functional change.

## [1.2.35] - 2026-11-13

- `config.json` lives in the data folder and is created on first start; older
  installs are migrated automatically. One volume is enough.
- Unraid Community Apps: `ca_profile.xml` and complete template metadata.
- Release binaries no longer contain the build machine's Windows user path.

## [1.2.34] - 2026-11-13

- Log tab in the web app; zap cache; MARS-Curiosity 2.0.3; extra EPG sources with
  automatic channel matching; one-click Unraid updates via ghcr.io.
