#!/usr/bin/env bash
#
# install-and-add-server.sh
#
# Waits (polls) until the Android device is connected over adb, then:
#   1. installs the S12 Mumla APK, and
#   2. adds a Mumble server to the app's favourites list automatically
#      (by inserting into the app's SQLite DB via run-as; works because the
#       debug build is debuggable).
#
# Your server details (including credentials) go in a SEPARATE file so they
# stay out of git:  copy  server-config.example.sh  ->  server-config.sh  and
# edit it.  server-config.sh is gitignored.  Environment variables of the same
# name also work and take precedence over the config file.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

log(){ printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }

# --- load server details ---------------------------------------------------
# Precedence: environment variable > server-config.sh > built-in default.
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/server-config.sh}"
if [ -f "$CONFIG_FILE" ]; then
  # Preserve anything already set in the environment so it wins over the file.
  _n="${SERVER_NAME-}"; _h="${SERVER_HOST-}"; _p="${SERVER_PORT-}"
  _u="${SERVER_USERNAME-}"; _w="${SERVER_PASSWORD-}"
  # shellcheck disable=SC1090
  . "$CONFIG_FILE"
  [ -n "$_n" ] && SERVER_NAME="$_n";     [ -n "$_h" ] && SERVER_HOST="$_h"
  [ -n "$_p" ] && SERVER_PORT="$_p";     [ -n "$_u" ] && SERVER_USERNAME="$_u"
  [ -n "$_w" ] && SERVER_PASSWORD="$_w"
fi
SERVER_NAME="${SERVER_NAME:-My Mumble Server}"
SERVER_HOST="${SERVER_HOST:-mumble.example.com}"
SERVER_PORT="${SERVER_PORT:-64738}"
SERVER_USERNAME="${SERVER_USERNAME:-myname}"
SERVER_PASSWORD="${SERVER_PASSWORD:-}"

# App / APK / adb (not secret).
PKG="se.lublin.mumla.s12"
APK_PATH="${APK_PATH:-app/build/outputs/apk/foss/debug/mumla-foss-debug.apk}"
ADB="${ADB:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"

DB="databases/mumble.db"   # relative to the app data dir (run-as runs there)

# --- sanity checks ---------------------------------------------------------
if [ ! -x "$ADB" ]; then
  if command -v adb >/dev/null 2>&1; then ADB=adb; else
    err "adb not found. Set ADB=/path/to/adb"; exit 1; fi
fi
[ -f "$APK_PATH" ] || { err "APK not found: $APK_PATH  (build it, or set APK_PATH=...)"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { err "sqlite3 not found on this Mac"; exit 1; }
case "$SERVER_PORT" in ''|*[!0-9]*) err "SERVER_PORT must be a number"; exit 1;; esac
if [ -z "$SERVER_HOST" ] || [ "$SERVER_HOST" = "mumble.example.com" ]; then
  err "No server configured — copy server-config.example.sh to server-config.sh and edit it (or set SERVER_HOST/SERVER_USERNAME/... as env vars)."
  exit 1
fi

# --- 1) wait for an authorized device -------------------------------------
log "Waiting for device over adb — plug in USB, enable USB debugging, tap 'Allow'..."
"$ADB" start-server >/dev/null 2>&1 || true
warned_unauth=0
while :; do
  if [ "$("$ADB" get-state 2>/dev/null || true)" = "device" ]; then break; fi
  st="$("$ADB" devices | awk 'NR>1 && $1!="" {print $2; exit}')"
  if [ "$st" = "unauthorized" ] && [ "$warned_unauth" = 0 ]; then
    err "Device is 'unauthorized' — tap 'Allow USB debugging' on the device screen."
    warned_unauth=1
  fi
  sleep 2
done
log "Device connected: $("$ADB" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"

# --- 2) install ------------------------------------------------------------
log "Installing $APK_PATH ..."
"$ADB" install -r "$APK_PATH"

# --- 3) ensure the app DB exists (created on first run) --------------------
log "Launching the app once so it creates its database..."
"$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
ok=0
for _ in $(seq 1 20); do
  if "$ADB" shell run-as "$PKG" test -f "$DB" 2>/dev/null; then ok=1; break; fi
  sleep 1
done
"$ADB" shell am force-stop "$PKG" >/dev/null 2>&1 || true
[ "$ok" = 1 ] || { err "App database not created ($DB). Open the app manually once, then re-run."; exit 1; }
sleep 1

# --- build the SQL (dedupe on host+port+name, then insert) ----------------
esc(){ printf '%s' "$1" | sed "s/'/''/g"; }   # escape single quotes for sqlite
N="$(esc "$SERVER_NAME")"; H="$(esc "$SERVER_HOST")"
U="$(esc "$SERVER_USERNAME")"; P="$(esc "$SERVER_PASSWORD")"
SQL="DELETE FROM server WHERE host='$H' AND port=$SERVER_PORT AND name='$N';
INSERT INTO server (name, host, port, username, password)
VALUES ('$N', '$H', $SERVER_PORT, '$U', '$P');"

log "Adding server '$SERVER_NAME' ($SERVER_HOST:$SERVER_PORT) as user '$SERVER_USERNAME'..."

if "$ADB" shell run-as "$PKG" sh -c 'command -v sqlite3' >/dev/null 2>&1; then
  # Fast path: the device has sqlite3 — edit the DB in place.
  printf '%s\n' "$SQL" | "$ADB" shell run-as "$PKG" sqlite3 "$DB"
else
  # Portable path: pull the DB, edit it here (macOS has sqlite3), write it back.
  TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
  log "  (device has no sqlite3 — editing a pulled copy)"
  "$ADB" exec-out run-as "$PKG" cat "$DB" > "$TMP/mumble.db"
  # Fold any WAL into the main file so a single file carries all data.
  "$ADB" exec-out run-as "$PKG" sh -c "cat ${DB}-wal 2>/dev/null" > "$TMP/mumble.db-wal" 2>/dev/null || true
  [ -s "$TMP/mumble.db-wal" ] || rm -f "$TMP/mumble.db-wal"
  printf 'PRAGMA journal_mode=DELETE;\n%s\n' "$SQL" | sqlite3 "$TMP/mumble.db"
  # Write back within the app's own domain, then verify the byte count.
  "$ADB" shell run-as "$PKG" rm -f "${DB}-wal" "${DB}-shm" 2>/dev/null || true
  "$ADB" shell run-as "$PKG" sh -c "cat > $DB" < "$TMP/mumble.db"
  lsz="$(wc -c < "$TMP/mumble.db" | tr -d ' ')"
  dsz="$("$ADB" exec-out run-as "$PKG" sh -c "wc -c < $DB" | tr -d ' \r')"
  [ "$lsz" = "$dsz" ] || { err "DB write size mismatch (local=$lsz device=$dsz)"; exit 1; }
fi

# --- 4) show result + launch ----------------------------------------------
log "Favourite servers now stored in the app:"
if "$ADB" shell run-as "$PKG" sh -c 'command -v sqlite3' >/dev/null 2>&1; then
  "$ADB" shell run-as "$PKG" sqlite3 "$DB" 'SELECT _id, name, host, port, username FROM server;' | sed 's/^/    /'
else
  sqlite3 "$TMP/mumble.db" 'SELECT _id, name, host, port, username FROM server;' | sed 's/^/    /'
fi

log "Launching S12 Mumla..."
"$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true

cat <<EOF

[✓] Done — '$SERVER_NAME' should now be in the favourites list.

Reminders for background PTT (once):
  • Settings > Accessibility > "S12 Mumla background PTT key"  -> ON
  • Settings > Apps > S12 Mumla > Battery                      -> Unrestricted
  • Settings > Audio > Push-to-talk key                        -> set your button
EOF
