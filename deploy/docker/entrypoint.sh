#!/bin/sh
# Start the IPTV Gateway as an unprivileged user instead of root.
#
# PUID / PGID choose the user (default 99:100 = Unraid's nobody:users, the owner
# Unraid expects for appdata). Started as root (the default), this script first
# hands the writable folders to that user - older releases ran as root, so their
# files in the data volume are root-owned - then drops root for good with setpriv
# and execs the service, which stays PID 1 (docker stop / SIGTERM reach it).
# Started with --user already, it just runs the service.
set -eu

PUID="${PUID:-99}"
PGID="${PGID:-100}"
APP=/opt/iptvplay/IPTVPlayService

if [ "$(id -u)" = "0" ] && [ "$PUID" != "0" ]; then
  for dir in /opt/iptvplay/data /opt/iptvplay/lang; do
    if [ -d "$dir" ]; then
      # only what isn't owned yet (cheap on every start after the first)
      find "$dir" \( ! -user "$PUID" -o ! -group "$PGID" \) -exec chown "$PUID:$PGID" {} + 2>/dev/null || \
        echo "entrypoint: could not hand $dir to $PUID:$PGID - check the volume permissions" >&2
    fi
  done
  exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups --inh-caps=-all "$APP" "$@"
fi

exec "$APP" "$@"
