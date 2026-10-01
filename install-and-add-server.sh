#!/usr/bin/env bash
#
# install-and-add-server.sh — thin wrapper around setup-device.sh.
#
# Historically this script did ONLY "install the APK + add the server". All of
# the provisioning now lives in ONE place, setup-device.sh, so this wrapper just
# forwards to it (keeping a single source of truth). Running it gives the full,
# current setup:
#   • install the S12 Mumla APK + add the Mumble server (username = radio number)
#   • generate the client certificate
#   • push-to-talk on F12, hide the on-screen button
#   • mic = voice_comm (noise reduction) at 100%, handset mode + force loudspeaker
#   • background-PTT accessibility service + battery whitelist
#   • turn off the device lock screen
#   • neutralize rival PTT apps (Xin POC, HyTalk Pro)
#   • optional GPS -> Traccar reporting
#
# Config is unchanged: it still reads server-config.sh / SERVER_* env vars, and
# every setup-device.sh override works here too. Examples:
#   ./install-and-add-server.sh
#   SERVER_USERNAME=065 ./install-and-add-server.sh
#   GPS_TRACKING=true TRACCAR_HOST=174.138.20.49 SERVER_USERNAME=065 ./install-and-add-server.sh
#
# To get the OLD light behaviour (no clean wipe / keep lock screen / leave rival
# apps alone), pass the matching overrides, e.g.:
#   CLEAN_REINSTALL=false DISABLE_SCREEN_LOCK=false NEUTRALIZE_RIVAL_PTT=false \
#     ENABLE_BG_PTT=false ./install-and-add-server.sh
#
# See setup-device.sh's header for the full list of overridable variables.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TARGET="$SCRIPT_DIR/setup-device.sh"

if [ ! -x "$TARGET" ]; then
  printf '\033[1;31m[!]\033[0m %s\n' "setup-device.sh not found or not executable at $TARGET" >&2
  exit 1
fi

printf '\033[1;36m[*]\033[0m %s\n' "install-and-add-server.sh now delegates to setup-device.sh (full provisioning)."
exec "$TARGET" "$@"
