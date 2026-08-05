#!/usr/bin/env bash
#
# setup-device.sh — full one-shot provisioning for S12 Mumla on a fresh device.
#
# Waits for the device over adb, then:
#   1. removes the stock upstream Mumla, then (clean) installs the S12 Mumla APK,
#   2. generates a client certificate and sets it as the default
#      (needed on first connect; also initializes the app database),
#   3. adds a Mumble server to the favourites,
#   4. sets input method = push-to-talk (PTT key = F12), hides the on-screen
#      talk button, sets the microphone volume, and enables handset mode,
#   5. turns off the device lock screen (Screen lock = None),
#   6. launches the app,
#   7. enables the background-PTT accessibility service + battery whitelist so
#      the hardware PTT key works with the screen off/locked, and
#   8. neutralizes rival PTT apps (e.g. com.pocxin.ptt) so they don't grab the
#      key/audio/battery: by default disables them entirely (reliable — they never
#      auto-start again; re-enable with ./pocxin.sh on). Set DISABLE_RIVAL_PTT=false
#      to only appops-restrict + force-stop instead (keeps them launchable, but
#      does not reliably stop boot auto-start on Android 7.1).
#
# Server details come from server-config.sh (or env vars), same as
# install-and-add-server.sh. Overridable: PTT_KEYCODE (default 142 = F12),
# HIDE_ONSCREEN_PTT (default true), MIC_VOLUME (default 25, in %),
# HANDSET_MODE (default true), DISABLE_SCREEN_LOCK (default true),
# ENABLE_BG_PTT (default true), CLEAN_REINSTALL (default true),
# REMOVE_STOCK_MUMLA (default true), NEUTRALIZE_RIVAL_PTT (default true),
# DISABLE_RIVAL_PTT (default true).
#
# NB: with CLEAN_REINSTALL=true (default) the app is uninstalled before install,
# so a fresh certificate is generated on every run. Set CLEAN_REINSTALL=false to
# keep the existing app data (and certificate) across runs.
#
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"; cd "$SCRIPT_DIR"
log(){ printf '\033[1;36m[*]\033[0m %s\n' "$*"; }
err(){ printf '\033[1;31m[!]\033[0m %s\n' "$*" >&2; }

# --- config (env var > server-config.sh > default) -------------------------
CONFIG_FILE="${CONFIG_FILE:-$SCRIPT_DIR/server-config.sh}"
if [ -f "$CONFIG_FILE" ]; then
  _n="${SERVER_NAME-}"; _h="${SERVER_HOST-}"; _p="${SERVER_PORT-}"; _u="${SERVER_USERNAME-}"; _w="${SERVER_PASSWORD-}"
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
PTT_KEYCODE="${PTT_KEYCODE:-142}"        # 142 = KEYCODE_F12
HIDE_ONSCREEN_PTT="${HIDE_ONSCREEN_PTT:-true}"  # hide the on-screen talk button
MIC_VOLUME="${MIC_VOLUME:-25}"           # microphone volume % (100 = 1.0x gain)
HANDSET_MODE="${HANDSET_MODE:-true}"     # handset (phone earpiece) mode
DISABLE_SCREEN_LOCK="${DISABLE_SCREEN_LOCK:-true}"  # set device Screen lock = None
ENABLE_BG_PTT="${ENABLE_BG_PTT:-true}"   # auto-enable accessibility svc + battery whitelist (PTT with screen off)
CLEAN_REINSTALL="${CLEAN_REINSTALL:-true}"        # uninstall our app first, then install fresh (wipes cert/prefs)
REMOVE_STOCK_MUMLA="${REMOVE_STOCK_MUMLA:-true}"  # uninstall the stock upstream Mumla if present
NEUTRALIZE_RIVAL_PTT="${NEUTRALIZE_RIVAL_PTT:-true}" # deal with rival PTT apps (see DISABLE_RIVAL_PTT)
DISABLE_RIVAL_PTT="${DISABLE_RIVAL_PTT:-true}"   # true = disable them (reliable no-autostart); false = appops-only (keeps launchable, best-effort)

PKG="se.lublin.mumla.s12"
STOCK_MUMLA="se.lublin.mumla"            # upstream Mumla (a different package from ours)
RIVAL_PTT="${RIVAL_PTT:-com.pocxin.ptt com.hytalkpro.ocean}"  # competing PTT apps to force-stop
APK_PATH="${APK_PATH:-app/build/outputs/apk/foss/debug/mumla-foss-debug.apk}"
ADB="${ADB:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
DB="databases/mumble.db"
PREFS="shared_prefs/${PKG}_preferences.xml"
GEN_ACT="$PKG/se.lublin.mumla.preference.CertificateGenerateActivity"
A11Y_SVC="$PKG/se.lublin.mumla.service.MumlaPTTAccessibilityService"

# --- sanity ----------------------------------------------------------------
[ -x "$ADB" ] || { command -v adb >/dev/null 2>&1 && ADB=adb || { err "adb not found; set ADB=/path/to/adb"; exit 1; }; }
[ -f "$APK_PATH" ] || { err "APK not found: $APK_PATH (build it or set APK_PATH=...)"; exit 1; }
command -v sqlite3 >/dev/null 2>&1 || { err "sqlite3 not found on this Mac"; exit 1; }
case "$SERVER_PORT" in ''|*[!0-9]*) err "SERVER_PORT must be numeric"; exit 1;; esac
case "$PTT_KEYCODE" in ''|*[!0-9]*) err "PTT_KEYCODE must be numeric"; exit 1;; esac
case "$HIDE_ONSCREEN_PTT" in true|false) ;; *) err "HIDE_ONSCREEN_PTT must be true or false"; exit 1;; esac
case "$MIC_VOLUME" in ''|*[!0-9]*) err "MIC_VOLUME must be numeric"; exit 1;; esac
case "$HANDSET_MODE" in true|false) ;; *) err "HANDSET_MODE must be true or false"; exit 1;; esac
case "$DISABLE_SCREEN_LOCK" in true|false) ;; *) err "DISABLE_SCREEN_LOCK must be true or false"; exit 1;; esac
case "$ENABLE_BG_PTT" in true|false) ;; *) err "ENABLE_BG_PTT must be true or false"; exit 1;; esac
case "$CLEAN_REINSTALL" in true|false) ;; *) err "CLEAN_REINSTALL must be true or false"; exit 1;; esac
case "$REMOVE_STOCK_MUMLA" in true|false) ;; *) err "REMOVE_STOCK_MUMLA must be true or false"; exit 1;; esac
case "$NEUTRALIZE_RIVAL_PTT" in true|false) ;; *) err "NEUTRALIZE_RIVAL_PTT must be true or false"; exit 1;; esac
case "$DISABLE_RIVAL_PTT" in true|false) ;; *) err "DISABLE_RIVAL_PTT must be true or false"; exit 1;; esac
if [ -z "$SERVER_HOST" ] || [ "$SERVER_HOST" = "mumble.example.com" ]; then
  err "No server configured — copy server-config.example.sh to server-config.sh and edit it (or set SERVER_HOST etc.)."; exit 1
fi

# --- helpers ---------------------------------------------------------------
# `run-as PKG test/sh -c ...` is unreliable (SELinux exec denial + adb arg
# re-splitting), so we only use plain binaries (cat/ls/cp/rm) under run-as.
pull(){ "$ADB" exec-out run-as "$PKG" cat "$1"; }          # $1 = path in app dir
have(){ "$ADB" shell run-as "$PKG" ls "$1" >/dev/null 2>&1; }
push_in(){ # $1 = local file, $2 = destination path in app dir
  "$ADB" push "$1" /data/local/tmp/.mumla_push >/dev/null
  "$ADB" shell chmod 644 /data/local/tmp/.mumla_push
  "$ADB" shell run-as "$PKG" cp /data/local/tmp/.mumla_push "$2" 2>/dev/null \
    || "$ADB" shell run-as "$PKG" dd "of=$2" < "$1" >/dev/null 2>&1
  "$ADB" shell rm -f /data/local/tmp/.mumla_push 2>/dev/null || true
}
# Force-stop AND wait for the process to actually die. Critical before editing
# shared_prefs: a still-alive process holds the old prefs in memory and will
# flush them back over our file the next time it writes (seen on slow devices).
stop_app(){
  "$ADB" shell am force-stop "$PKG" >/dev/null 2>&1 || true
  for _ in $(seq 1 15); do
    [ -z "$("$ADB" shell pidof "$PKG" 2>/dev/null | tr -d '\r\n ')" ] && return 0
    sleep 1
  done
  return 0
}
# Rewrite the three PTT prefs in a pulled prefs file (in $TMP), keeping the rest.
set_ptt_prefs(){ # $1 = local prefs xml — rewrite our audio prefs, keep the rest
  sed -i '' -e '/name="audioInputMethod"/d' -e '/name="talkKey"/d' -e '/name="hidePtt"/d' -e '/name="inputVolume"/d' -e '/name="handset_mode"/d' "$1"
  sed -i '' -e 's#</map>#    <string name="audioInputMethod">ptt</string>\
    <int name="talkKey" value="'"$PTT_KEYCODE"'" />\
    <boolean name="hidePtt" value="'"$HIDE_ONSCREEN_PTT"'" />\
    <int name="inputVolume" value="'"$MIC_VOLUME"'" />\
    <boolean name="handset_mode" value="'"$HANDSET_MODE"'" />\
</map>#' "$1"
}

# --- 1) wait for device ----------------------------------------------------
log "Waiting for device over adb — plug in USB, enable USB debugging, tap 'Allow'..."
"$ADB" start-server >/dev/null 2>&1 || true
warned=0
while [ "$("$ADB" get-state 2>/dev/null || true)" != "device" ]; do
  [ "$("$ADB" devices | awk 'NR>1&&$1!=""{print $2;exit}')" = "unauthorized" ] && [ "$warned" = 0 ] \
    && { err "Device 'unauthorized' — tap 'Allow USB debugging' on the device."; warned=1; }
  sleep 2
done
log "Device: $("$ADB" shell getprop ro.product.model 2>/dev/null | tr -d '\r')"

# --- 2) install ------------------------------------------------------------
# Remove the stock upstream Mumla (se.lublin.mumla) — a different package we
# don't use; keeps only our se.lublin.mumla.s12 on the device.
if [ "$REMOVE_STOCK_MUMLA" = true ] && "$ADB" shell pm path "$STOCK_MUMLA" >/dev/null 2>&1; then
  log "Removing stock Mumla ($STOCK_MUMLA)..."
  "$ADB" uninstall "$STOCK_MUMLA" >/dev/null 2>&1 || true
fi
# SKIP_INSTALL=1 skips the adb install step — for devices (e.g. Xiaomi/MIUI)
# that block "Install via USB", where you side-load the APK by hand first.
if [ "${SKIP_INSTALL:-0}" = 1 ]; then
  log "SKIP_INSTALL=1 — skipping APK install; expecting $PKG already installed."
  "$ADB" shell pm path "$PKG" >/dev/null 2>&1 \
    || { err "$PKG is not installed yet. Side-load the APK first, then re-run."; exit 1; }
else
  # Clean (re)install: uninstall any existing copy first so the new build goes
  # in fresh. NB: this wipes the old cert/DB/prefs — they are re-created below,
  # so a fresh certificate is generated each run.
  if [ "$CLEAN_REINSTALL" = true ] && "$ADB" shell pm path "$PKG" >/dev/null 2>&1; then
    log "Removing existing $PKG for a clean install..."
    "$ADB" uninstall "$PKG" >/dev/null 2>&1 || true
  fi
  log "Installing $APK_PATH ..."
  "$ADB" install -r "$APK_PATH"
fi

# Grant the microphone runtime permission so the app can transmit without a
# permission dialog — the keypad "radio" UI on no-touch devices can't easily show
# one. Harmless on API < 23 (granted at install time). Runtime perms survive
# install -r, but granting again is idempotent.
"$ADB" shell pm grant "$PKG" android.permission.RECORD_AUDIO >/dev/null 2>&1 || true
# Grant WRITE_SECURE_SETTINGS (a development permission) so the app's BootPTTReceiver
# can re-enable the background-PTT accessibility service on every boot — these radios
# wipe enabled_accessibility_services on boot, which otherwise kills screen-off PTT.
"$ADB" shell pm grant "$PKG" android.permission.WRITE_SECURE_SETTINGS >/dev/null 2>&1 || true

# --- 2b) device: turn off the lock screen (Screen lock = None) -------------
# Device-level setting (not an app pref). `locksettings set-disabled true` maps
# to Screen lock = None; it has no effect if a secure PIN/pattern/password is
# already set, so we verify and tell the user to remove it by hand if so.
LOCK_STATUS="left as-is"
if [ "$DISABLE_SCREEN_LOCK" = true ]; then
  log "Turning off the device lock screen (Screen lock = None)..."
  "$ADB" shell locksettings set-disabled true >/dev/null 2>&1 || true
  if "$ADB" shell locksettings get-disabled 2>/dev/null | grep -qi true; then
    log "  Lock screen is now off."; LOCK_STATUS="off"
  else
    err "  Could not turn off the lock screen — a PIN/pattern/password is probably set."
    err "  Remove it by hand: Settings > Security > Screen lock > None."
    LOCK_STATUS="UNCHANGED (a PIN/pattern is set — remove it by hand)"
  fi
fi

# --- 3) certificate (+ DB init) -------------------------------------------
if pull "$PREFS" 2>/dev/null | grep -q 'name="certificateId"'; then
  log "Certificate already present — keeping it."
  if ! have "$DB"; then
    "$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
  fi
else
  log "Generating client certificate (sets it as default, creates the database)..."
  "$ADB" shell am start -n "$GEN_ACT" >/dev/null 2>&1 || true
fi
ok=0
for _ in $(seq 1 30); do
  if have "$DB" && pull "$PREFS" 2>/dev/null | grep -q 'name="certificateId"'; then ok=1; break; fi
  sleep 1
done
stop_app   # wait until the process is really gone before touching the DB / prefs
[ "$ok" = 1 ] || { err "Certificate/database not initialized. Open the app once, then re-run."; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# --- 4) add server ---------------------------------------------------------
log "Adding server '$SERVER_NAME' ($SERVER_HOST:$SERVER_PORT) as '$SERVER_USERNAME'..."
esc(){ printf '%s' "$1" | sed "s/'/''/g"; }
N="$(esc "$SERVER_NAME")"; H="$(esc "$SERVER_HOST")"; U="$(esc "$SERVER_USERNAME")"; P="$(esc "$SERVER_PASSWORD")"
pull "$DB" > "$TMP/mumble.db"; [ -s "$TMP/mumble.db" ] || { err "could not read app DB"; exit 1; }
sqlite3 "$TMP/mumble.db" "PRAGMA journal_mode=DELETE;
DELETE FROM server WHERE host='$H' AND port=$SERVER_PORT AND name='$N';
INSERT INTO server (name,host,port,username,password) VALUES ('$N','$H',$SERVER_PORT,'$U','$P');"
push_in "$TMP/mumble.db" "$DB"
"$ADB" shell run-as "$PKG" rm -f "${DB}-journal" "${DB}-wal" "${DB}-shm" 2>/dev/null || true

# --- 5) push-to-talk + PTT key --------------------------------------------
log "Setting push-to-talk (key $PTT_KEYCODE=F12), hide button = $HIDE_ONSCREEN_PTT, mic volume = $MIC_VOLUME%, handset mode = $HANDSET_MODE..."
pull "$PREFS" > "$TMP/p.xml"
set_ptt_prefs "$TMP/p.xml"
push_in "$TMP/p.xml" "$PREFS"

# --- 6) launch fresh, then make sure the prefs stuck ----------------------
stop_app   # guarantee a clean process so the launch reads our file, not a stale map
"$ADB" shell monkey -p "$PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1 || true
sleep 4
if [ "$(pull "$PREFS" 2>/dev/null | grep -cE 'name="audioInputMethod"|name="talkKey"|name="hidePtt"|name="inputVolume"|name="handset_mode"')" != 5 ]; then
  log "App re-flushed prefs on launch — re-applying and leaving the app closed."
  stop_app
  pull "$PREFS" > "$TMP/p.xml"; set_ptt_prefs "$TMP/p.xml"; push_in "$TMP/p.xml" "$PREFS"
fi

# --- 7) background PTT: accessibility service + battery whitelist ----------
# So the hardware PTT key toggles talk even with the screen off/locked. The
# MumlaPTTAccessibilityService captures the key globally; without it enabled PTT
# only works while the app is in the foreground. Doing it over adb saves the
# manual "Settings > Accessibility" + "Battery: unrestricted" steps.
#
# IMPORTANT: a (re)install REVOKES / unbinds the accessibility service on Android
# (a security measure), and merely re-writing the list doesn't reliably rebind it.
# So we APPEND our service (keeping any others), then TOGGLE accessibility_enabled
# off->on to force a clean rebind, and finally verify it is actually BOUND via
# dumpsys (not just present in the settings string).
BG_PTT_STATUS="left as-is"
if [ "$ENABLE_BG_PTT" = true ]; then
  log "Enabling background PTT (accessibility service + battery whitelist)..."
  cur="$("$ADB" shell settings get secure enabled_accessibility_services 2>/dev/null | tr -d '\r')"
  case "$cur" in null|'') cur='';; esac
  case ":$cur:" in *":$A11Y_SVC:"*) : ;; *) cur="${cur:+$cur:}$A11Y_SVC";; esac
  "$ADB" shell settings put secure accessibility_enabled 0 >/dev/null 2>&1
  "$ADB" shell settings put secure enabled_accessibility_services "$cur" >/dev/null 2>&1
  "$ADB" shell settings put secure accessibility_enabled 1 >/dev/null 2>&1
  "$ADB" shell dumpsys deviceidle whitelist +"$PKG" >/dev/null 2>&1 || true
  sleep 2
  # The bound service's label shows as "Mumla background PTT key" or the raw class name.
  if "$ADB" shell dumpsys accessibility 2>/dev/null | grep -qiE "MumlaPTT|Mumla background PTT"; then
    log "  Accessibility service ON (bound), app battery-whitelisted."
    BG_PTT_STATUS="on (accessibility bound + battery whitelist)"
  else
    err "  Accessibility service did not bind — enable by hand: Settings > Accessibility > S12 Mumla."
    BG_PTT_STATUS="FAILED — enable Accessibility by hand"
  fi
fi

# --- 8) neutralize rival PTT apps -----------------------------------------
# Competing PTT apps (e.g. com.pocxin.ptt) auto-start on every boot and grab the
# hardware PTT key / audio focus / battery. We can't disable just their boot
# receiver without root (SELinux blocks changing another app's component state), so:
#   DISABLE_RIVAL_PTT=true (default) -> `pm disable-user` the whole app: reliable,
#     it never auto-starts again (re-enable with ./pocxin.sh on, or `pm enable`),
#     but it is then not launchable on-device until re-enabled.
#   DISABLE_RIVAL_PTT=false -> only appops-restrict RUN_IN_BACKGROUND + force-stop:
#     keeps the app launchable, but on Android 7.1 this does NOT reliably stop the
#     boot auto-start (best-effort only).
RIVAL_PTT_STATUS="skipped"
if [ "$NEUTRALIZE_RIVAL_PTT" = true ]; then
  done_list=''
  for rp in $RIVAL_PTT; do
    "$ADB" shell pm path "$rp" >/dev/null 2>&1 || continue
    "$ADB" shell am force-stop "$rp" >/dev/null 2>&1 || true
    if [ "$DISABLE_RIVAL_PTT" = true ]; then
      "$ADB" shell pm disable-user --user 0 "$rp" >/dev/null 2>&1 || true
    else
      "$ADB" shell cmd appops set "$rp" RUN_IN_BACKGROUND ignore >/dev/null 2>&1 || true
    fi
    done_list="${done_list:+$done_list, }$rp"
  done
  if [ -z "$done_list" ]; then
    RIVAL_PTT_STATUS="none installed"
  elif [ "$DISABLE_RIVAL_PTT" = true ]; then
    log "Rival PTT apps disabled (no auto-start): $done_list."
    RIVAL_PTT_STATUS="$done_list (disabled — re-enable with ./pocxin.sh on)"
  else
    log "Rival PTT apps background-restricted + stopped: $done_list."
    RIVAL_PTT_STATUS="$done_list (bg-restricted + stopped, best-effort)"
  fi
fi

# --- report ---------------------------------------------------------------
pull "$DB" > "$TMP/v.db"
log "Result:"
sqlite3 "$TMP/v.db" 'SELECT "    server: "||name||"  "||host||":"||port||"  user="||username FROM server;'
sqlite3 "$TMP/v.db" 'SELECT "    cert:   id "||_id||"  "||name FROM certificates;'
echo "    prefs:"; pull "$PREFS" | grep -E 'audioInputMethod|talkKey|hidePtt|inputVolume|handset_mode|certificateId' | sed 's/^/      /'

cat <<EOF

[✓] Device provisioned: server + certificate + push-to-talk on F12
    (on-screen talk button $([ "$HIDE_ONSCREEN_PTT" = true ] && echo hidden || echo shown),
     mic volume ${MIC_VOLUME}%, handset mode ${HANDSET_MODE}, lock screen ${LOCK_STATUS}).
    Background PTT (screen off/locked): ${BG_PTT_STATUS}.
    Rival PTT apps: ${RIVAL_PTT_STATUS}.

If background PTT shows FAILED above, enable it by hand (once):
  • Settings > Accessibility > "S12 Mumla background PTT key" -> ON
  • Settings > Apps > S12 Mumla > Battery                     -> Unrestricted
EOF
