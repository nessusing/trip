#!/usr/bin/env bash
# Build, sign, install and launch the app on the USB-connected iPhone.
set -euo pipefail
cd "$(dirname "$0")"
UDID="${UDID:-00008110-000A3138026B801E}"
# Release by default: route calculations are ~15x faster than in a debug build.
# CONFIG=debug ./deploy.sh for a debug build.
exec xtool dev run --configuration "${CONFIG:-release}" --usb --udid "$UDID" "$@"
