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
# Usage:  either edit the CONFIG block below, or pass values as env vars, then:
#           ./install-and-add-server.sh
#
# CREDENTIALS: prefer env vars so this tracked file stays free of secrets, e.g.:
#   SERVER_HOST=my.host SERVER_USERNAME=me SERVER_PASSWORD=secret \
#     ./install-and-add-server.sh
#   If you edit the values inline below instead, do NOT commit that change.
#
set -euo pipefail

# ===========================================================================
# CONFIG — edit these, or override any of them via environment variables.
# ===========================================================================
SERVER_NAME="${SERVER_NAME:-My Mumble Server}"      # label shown in the favourites list
SERVER_HOST="${SERVER_HOST:-mumble.example.com}"    # server address or IP
SERVER_PORT="${SERVER_PORT:-64738}"                 # Mumble default port is 64738
SERVER_USERNAME="${SERVER_USERNAME:-myname}"        # your Mumble nickname (REQUIRED to connect)
SERVER_PASSWORD="${SERVER_PASSWORD:-}"              # server password (leave empty if none)

# Which app + APK to install. Defaults to the freshly-built fossDebug APK.
PKG="se.lublin.mumla.s12"
APK_PATH="${APK_PATH:-app/build/outputs/apk/foss/debug/mumla-foss-debug.apk}"

# adb location (installed with the Android SDK; not on PATH by default).
ADB="${ADB:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
# ===========================================================================

DB="databases/mumble.db"   # relative to the app data dir (run-as runs there)

log(){ printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }

# Run from the script's own directory so the default APK_PATH resolves.
cd "$(dirname "$0")"

# --- sanity checks ---------------------------------------------------------
if [ ! -x "$ADB" ]; then
  if command -v adb >/dev/null 2>&1; then ADB=adb; else
    err "adb not found. Set ADB=/path/to/adb"; exit 1; fi
fi
[ -f "$APK_PATH" ] || { err "APK not found: $APK_PATH  (build it, or set APK_PATH=...)"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { err "sqlite3 not found on this Mac"; exit 1; }
case "$SERVER_PORT" in ''|*[!0-9]*) err "SERVER_PORT must be a number"; exit 1;; esac

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
