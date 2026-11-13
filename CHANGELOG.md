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

## [1.2.35] - 2026-11-13

- `config.json` lives in the data folder and is created on first start; older
  installs are migrated automatically. One volume is enough.
- Unraid Community Apps: `ca_profile.xml` and complete template metadata.
- Release binaries no longer contain the build machine's Windows user path.

## [1.2.34] - 2026-11-13

- Log tab in the web app; zap cache; MARS-Curiosity 2.0.3; extra EPG sources with
  automatic channel matching; one-click Unraid updates via ghcr.io.
