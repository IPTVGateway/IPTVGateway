# Minimal runtime image for the IPTV Gateway Linux64 service.
#
# Delphi cannot be compiled inside Docker — build the Linux64 binary in RAD
# Studio 13 first (Target Platform = Linux64, via PAServer to a Linux host),
# then drop the produced "IPTVPlayService" binary next to this Dockerfile and
# build the image (deploy/docker/build.ps1 does both). See README.md.
#
# Why debian-slim and not Alpine/distroless:
#   - Delphi Linux64 output is glibc-linked → Alpine (musl) won't run it.
#   - distroless has no libcurl, which System.Net.HttpClient needs for HTTPS
#     ingest on Linux → so we use the smallest glibc base that ships a package
#     manager and trim it hard.
#
# Runtime deps (kept to the strict minimum):
#   - libcurl4               : System.Net.HttpClient (HTTPS Xtream/M3U/EPG fetches);
#                              pulls libssl3/libcrypto3 transitively (TLS + Indy SSL)
#   - ca-certificates        : TLS trust roots
#   - tzdata                 : correct local time for the daily scheduler

FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates tzdata libcurl4 \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/* /var/cache/apt/* \
           /usr/share/doc/* /usr/share/man/* /usr/share/info/* /usr/share/locale/*

WORKDIR /opt/iptvplay

# the pre-built (and stripped) Linux64 binary + default config
COPY IPTVPlayService /opt/iptvplay/IPTVPlayService
COPY config.json /opt/iptvplay/config.json
# the built React admin UI (served at / by the service when this dir exists)
COPY webui /opt/iptvplay/webui

# lang/ holds optional add-on UI translation files (<code>.json); en/nl ship
# inside the webui bundle, so this starts empty. Mount it to add more languages.
RUN chmod +x /opt/iptvplay/IPTVPlayService && mkdir -p /opt/iptvplay/data /opt/iptvplay/lang

# SQLite db + state live here; mount as a volume so they survive restarts
VOLUME ["/opt/iptvplay/data"]

# 7777 = admin API + Xtream/M3U portal + Plex endpoints (always);
# 7778 = stream proxy (only when enabled);
# 1900/udp = SSDP for Plex HDHomeRun auto-discovery (LAN-only; needs host networking)
EXPOSE 7777 7778 1900/udp

# Cap glibc malloc to a couple of arenas and make it return freed memory to the OS
# sooner. libcurl/OpenSSL (HTTPS ingest) malloc on several threads, and glibc's
# default of up to 8×CPU-cores arenas — each holding freed-but-not-returned memory —
# is a major source of high RSS on a many-core host. This trims the steady-state
# footprint substantially with no functional change.
ENV MALLOC_ARENA_MAX=2 \
    MALLOC_TRIM_THRESHOLD_=131072

# Unraid reads these labels to show a WebUI button on the Docker tab even when
# the container was added via `docker run` (not the template). Unraid applies its
# own [IP]/[PORT:xxxx] substitution to the value.
LABEL net.unraid.docker.webui="http://[IP]:[PORT:7777]/" \
      org.opencontainers.image.title="IPTV Gateway"

# console daemon: SIGTERM (docker stop) shuts it down cleanly
ENTRYPOINT ["/opt/iptvplay/IPTVPlayService"]
