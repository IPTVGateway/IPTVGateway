#!/bin/bash
# Update the IPTV-Gateway container on Unraid from the locally-built image tar.
#
# There is no registry, so Unraid's "Check for updates" can't see a new build
# (it reports "0 B"). This script does the real update: load the tar, then
# recreate the container ON the new image while preserving its exact settings
# (ports/volumes/env/network) via `runlike`.
#
# Usage:  ./update-on-nas.sh
# Safe:   if anything goes wrong BEFORE the recreate, the running container is
#         left untouched and the script aborts.

set -euo pipefail

# ── config ───────────────────────────────────────────────────────────────
NAME="IPTV-Gateway"
TAR="/mnt/user/Media/Docker/CustomDockers/IPTV Gateway/iptvplay.tar.gz"
CONTAINER_HTTP_PORT="7777"   # the port INSIDE the container (config httpPort)
# ─────────────────────────────────────────────────────────────────────────

say()  { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
die()  { printf '\n\033[31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

[ -f "$TAR" ] || die "tar not found: $TAR"
command -v docker >/dev/null || die "docker not on PATH"

say "Loading image from $(basename "$TAR") ..."
docker load -i "$TAR"

# note the host port mapped to the container's HTTP port, for the health check
HOSTPORT=""
if docker inspect "$NAME" >/dev/null 2>&1; then
  HOSTPORT=$(docker port "$NAME" "${CONTAINER_HTTP_PORT}/tcp" 2>/dev/null | head -1 | sed 's/.*://')
fi

if ! docker inspect "$NAME" >/dev/null 2>&1; then
  say "No container named '$NAME' yet."
  echo "  The new image is loaded. Create the container once from the Unraid"
  echo "  template (Docker tab -> Add Container / your saved template), then this"
  echo "  script will handle every future update."
  exit 0
fi

say "Reconstructing the run command for '$NAME' (via runlike) ..."
# runlike reads the LIVE container and prints the exact `docker run ...` for it.
RUNCMD=$(docker run --rm -v /var/run/docker.sock:/var/run/docker.sock \
           assaflavie/runlike "$NAME") \
  || die "runlike failed (needs internet to pull assaflavie/runlike). Nothing changed — use Unraid 'Force Update' instead."

case "$RUNCMD" in
  docker\ run*) : ;;   # sane
  *) die "unexpected runlike output; not touching the container. Use Unraid 'Force Update'." ;;
esac

say "Recreating '$NAME' on the new image ..."
docker stop "$NAME"
docker rm "$NAME"
eval "$RUNCMD"

say "Waiting for it to come up ..."
sleep 3
docker ps --filter "name=$NAME" --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

if [ -n "$HOSTPORT" ]; then
  say "Health check (http://localhost:$HOSTPORT/api/health) ..."
  curl -fsS "http://localhost:$HOSTPORT/api/health" || echo "  (couldn't reach health endpoint — check the container log)"
  echo
else
  echo "  Could not detect the host port; check manually: curl http://<nas-ip>:<port>/api/health"
fi

say "Done. The web UI header should now show v1.2.0 and a 'Media Servers' tab."
