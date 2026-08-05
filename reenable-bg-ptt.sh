#!/usr/bin/env bash
#
# reenable-bg-ptt.sh — re-bind the S12 Mumla background-PTT accessibility service
# (and battery-whitelist the app) over adb.
#
# Android REVOKES / unbinds an app's accessibility service every time the app is
# (re)installed — including a quick `adb install -r` — so after any such update
# the hardware PTT key stops working with the screen off/locked until the service
# is re-enabled. Run this to fix it in one step.
#
# setup-device.sh already does this as part of full provisioning (step 7); this
# helper is just the same action on its own, for the quick dev-update loop.
#
set -euo pipefail

PKG="se.lublin.mumla.s12"
A11Y_SVC="$PKG/se.lublin.mumla.service.MumlaPTTAccessibilityService"
ADB="${ADB:-/opt/homebrew/share/android-commandlinetools/platform-tools/adb}"

[ -x "$ADB" ] || { command -v adb >/dev/null 2>&1 && ADB=adb \
  || { echo "adb not found; set ADB=/path/to/adb" >&2; exit 1; }; }
"$ADB" shell pm path "$PKG" >/dev/null 2>&1 || { echo "$PKG not installed" >&2; exit 1; }

# Append our service (keep any others), then toggle accessibility off->on to force
# a clean rebind — merely re-writing the list doesn't reliably rebind after a revoke.
cur="$("$ADB" shell settings get secure enabled_accessibility_services 2>/dev/null | tr -d '\r')"
case "$cur" in null|'') cur='';; esac
case ":$cur:" in *":$A11Y_SVC:"*) : ;; *) cur="${cur:+$cur:}$A11Y_SVC";; esac
"$ADB" shell settings put secure accessibility_enabled 0 >/dev/null 2>&1
"$ADB" shell settings put secure enabled_accessibility_services "$cur" >/dev/null 2>&1
"$ADB" shell settings put secure accessibility_enabled 1 >/dev/null 2>&1
"$ADB" shell dumpsys deviceidle whitelist +"$PKG" >/dev/null 2>&1 || true
sleep 2

# Verify it actually bound (label shows as "Mumla background PTT key" or the class name).
if "$ADB" shell dumpsys accessibility 2>/dev/null | grep -qiE "MumlaPTT|Mumla background PTT"; then
  echo "[✓] Background-PTT accessibility service bound + app battery-whitelisted."
else
  echo "[!] Did not bind — enable by hand: Settings > Accessibility > S12 Mumla." >&2
  exit 1
fi
