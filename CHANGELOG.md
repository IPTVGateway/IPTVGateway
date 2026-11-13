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

## [1.2.35] - 2026-11-13

- `config.json` lives in the data folder and is created on first start; older
  installs are migrated automatically. One volume is enough.
- Unraid Community Apps: `ca_profile.xml` and complete template metadata.
- Release binaries no longer contain the build machine's Windows user path.

## [1.2.34] - 2026-11-13

- Log tab in the web app; zap cache; MARS-Curiosity 2.0.3; extra EPG sources with
  automatic channel matching; one-click Unraid updates via ghcr.io.
