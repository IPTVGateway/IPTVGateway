IPTV Gateway - Docker deploy bundle
===================================

This folder is a ready-to-ship bundle (produced by deploy\docker\build.ps1):

  iptvplay.tar.gz     the Docker image (debian-slim + the Linux64 service binary)
  docker-compose.yml  compose file (ports 7777 admin/portal, 7778 stream proxy)
  iptv-gateway.xml     Unraid Community-Applications template
  config.json         default config baked into the image (edit per-deploy via env/volume)

----------------------------------------------------------------------
Load the image on the target host (Unraid / any Docker host)
----------------------------------------------------------------------
1. Copy iptvplay.tar.gz to the host.
2. Load it:
       docker load -i iptvplay.tar.gz
   -> creates image  iptvplay:latest

----------------------------------------------------------------------
Run it
----------------------------------------------------------------------
A) docker compose (copy docker-compose.yml to the host):
       docker compose up -d

B) plain docker:
       docker run -d --name iptvplay \
         -p 7777:7777 -p 7778:7778 \
         -e ADMIN_PASSWORD=changeme \
         -v /mnt/user/appdata/iptvplay:/opt/iptvplay/data \
         iptvplay:latest

C) Unraid: Plugins > Community Applications, or add the template
   iptv-gateway.xml under /boot/config/plugins/dockerMan/templates-user/,
   then add the container from the Docker tab.

Ports: 7777 = admin UI + Xtream/M3U portal + Plex endpoints (always);
7778 = optional stream proxy (only when proxyStreams is enabled);
UDP 1900 = SSDP for Plex HDHomeRun auto-discovery (LAN-only, host networking).
Both TCP ports are configurable in Settings. HTTPS needs no extra port (the
same port serves TLS when useHttps is on). The SQLite DB and state live in the
mounted /opt/iptvplay/data volume; extra UI languages go in /opt/iptvplay/lang.

Health check:  curl http://<host>:7777/api/health  -> {"status":"ok",...}

----------------------------------------------------------------------
Plex Live TV (enable in Settings -> Plex Live TV)
----------------------------------------------------------------------
Option A (M3U tuner):   add in Plex as M3U tuner  http://<host>:7777/plex/playlist.m3u
                        + XMLTV guide             http://<host>:7777/plex/epg.xml
Option B (HDHomeRun):   Plex auto-detects it via SSDP, or add it by URL
                        http://<host>:7777  (discover.json / lineup.json)

NETWORKING / SSDP: Plex HDHomeRun auto-discovery uses SSDP multicast on UDP 1900,
which does NOT cross Docker bridge NAT. On bridge the HTTP endpoints work fine but
Plex won't auto-find the tuner -> add it manually by URL, OR run the container with
host networking (Unraid: Network Type = host). Set publicBaseUrl to the real host
(e.g. http://192.168.1.48:7777) so Plex can fetch the lineup.

Plex does not refresh the channel lineup in real time: EPG/guide refreshes on
Plex's own schedule, but adding/removing channels needs a manual re-scan in Plex
(Settings -> Live TV & DVR -> device -> Scan Channels), or use the "Rescan Plex"
button in Settings once you set the Plex server URL + token.

GOING PUBLIC (internet exposure): never port-forward UDP 1900 (LAN-only); serve
over HTTPS (useHttps + cert/key) and set a strong ADMIN_PASSWORD before exposing
the /api admin surface. Ideally only the output portal is public; keep admin/proxy
behind a firewall/VPN.

NOTE: built against glibc; the binary needs at most GLIBC_2.34, so any
glibc >= 2.34 base runs it (debian bookworm = 2.36, used here).

Built ~99% with Claude Code (Anthropic's agentic coding tool), human in the loop.
