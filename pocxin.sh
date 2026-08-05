#!/usr/bin/env bash
#
# pocxin.sh — enable/disable the rival POC push-to-talk app(s) over adb.
#
# On no-touch Hytera radios these apps auto-start on every boot and fight our S12
# Mumla for the PTT key / audio / battery. There is no no-root way to keep them
# launchable-on-device while blocking auto-start, so the reliable option is to
# disable the whole app (it then never auto-starts) and re-enable it only when you
# actually want to use it.
#
#   ./pocxin.sh off   # disable: no auto-start, icon hidden until re-enabled
#   ./pocxin.sh on    # re-enable: launchable again (will auto-start on next boot)
#   ./pocxin.sh status
#
set -euo pipefail

ADB="${ADB:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"
RIVAL_PTT="${RIVAL_PTT:-com.pocxin.ptt com.hytalkpro.ocean}"
[ -x "$ADB" ] || { command -v adb >/dev/null 2>&1 && ADB=adb \
  || { echo "adb not found; set ADB=/path/to/adb" >&2; exit 1; }; }

case "${1:-}" in
  off)
    for p in $RIVAL_PTT; do
      "$ADB" shell pm path "$p" >/dev/null 2>&1 || continue
      "$ADB" shell am force-stop "$p" >/dev/null 2>&1 || true
      "$ADB" shell pm disable-user --user 0 "$p" >/dev/null 2>&1 \
        && echo "[✓] $p disabled (no auto-start)" \
        || echo "[!] $p: could not disable" >&2
    done
    ;;
  on)
    for p in $RIVAL_PTT; do
      "$ADB" shell pm path "$p" >/dev/null 2>&1 || continue
      "$ADB" shell pm enable "$p" >/dev/null 2>&1 \
        && echo "[✓] $p enabled (launchable again)" \
        || echo "[!] $p: could not enable" >&2
    done
    ;;
  status)
    for p in $RIVAL_PTT; do
      "$ADB" shell pm path "$p" >/dev/null 2>&1 || { echo "  $p: not installed"; continue; }
      if "$ADB" shell pm list packages -d 2>/dev/null | grep -q "$p"; then
        echo "  $p: disabled"
      else
        echo "  $p: enabled"
      fi
    done
    ;;
  *)
    echo "usage: $0 on|off|status" >&2; exit 1;;
esac
