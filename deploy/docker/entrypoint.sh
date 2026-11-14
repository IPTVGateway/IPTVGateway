#!/bin/sh
# Start the IPTV Gateway as an unprivileged user instead of root.
#
# PUID / PGID choose the user (default 99:100 = Unraid's nobody:users, the owner
# Unraid expects for appdata). Started as root (the default), this script first
# hands the writable folders to that user - older releases ran as root, so their
# files in the data volume are root-owned - then drops root for good with setpriv
# and execs the service, which stays PID 1 (docker stop / SIGTERM reach it).
# Started with --user already, it just runs the service.
#
# When the hand-over can't take effect (an SMB/NFS share with root_squash, a
# read-only volume, ...) the run user couldn't write its database: instead of
# crash-looping, the script says so loudly and keeps running as root.
#
# Not handled here (document / config): files that config.json points at OUTSIDE
# the volumes (TLS cert/key, a databasePath elsewhere) must be readable (the
# database: writable) by PUID:PGID, and ports below 1024 need PUID=0.
set -eu

PUID="${PUID:-99}"
PGID="${PGID:-100}"
APP=/opt/iptvplay/IPTVPlayService
DATA_DIR=/opt/iptvplay/data
LANG_DIR=/opt/iptvplay/lang

# run_as_user CMD...: run CMD as PUID:PGID (no supplementary groups)
run_as_user() {
  setpriv --reuid="$PUID" --regid="$PGID" --clear-groups "$@"
}

# first_denied DIR TEST: the first entry of DIR (itself or a direct child) that the
# run user fails TEST on (-writable / -readable); DIR itself when it can't be checked
first_denied() {
  run_as_user find "$1" -maxdepth 1 ! "$2" -print -quit 2>/dev/null || echo "$1"
}

if [ "$(id -u)" = "0" ] && [ "$PUID" != "0" ]; then
  for dir in "$DATA_DIR" "$LANG_DIR"; do
    if [ -d "$dir" ]; then
      # only what isn't owned yet (cheap on every start after the first); -h: a
      # symlink itself, never what it points at (could be outside the volume)
      find "$dir" \( ! -user "$PUID" -o ! -group "$PGID" \) -exec chown -h "$PUID:$PGID" {} + 2>/dev/null || \
        echo "entrypoint: could not hand $dir to $PUID:$PGID - check the volume permissions" >&2
    fi
  done

  # the chown may have been ignored (root_squash, read-only mount): check that the
  # run user really can use the folders - data must be writable, lang readable
  denied=""
  if [ -d "$DATA_DIR" ]; then
    denied="$(first_denied "$DATA_DIR" -writable)"
  fi
  if [ -z "$denied" ] && [ -d "$LANG_DIR" ]; then
    denied="$(first_denied "$LANG_DIR" -readable)"
  fi

  if [ -z "$denied" ]; then
    exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups --inh-caps=-all "$APP" "$@"
  fi

  echo "################################################################################" >&2
  echo "entrypoint: WARNING - user $PUID:$PGID cannot use $denied" >&2
  echo "entrypoint: the owner change did not take effect (SMB/NFS share with root_squash," >&2
  echo "entrypoint: read-only volume, ...). Running as ROOT instead so the service works." >&2
  echo "entrypoint: Fix: make the volume writable for $PUID:$PGID (or set PUID/PGID to its" >&2
  echo "entrypoint: owner), or set PUID=0 to run as root on purpose and silence this." >&2
  echo "################################################################################" >&2
fi

exec "$APP" "$@"
