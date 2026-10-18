#!/usr/bin/env bash
# Build, sign, install and launch the app on the USB-connected iPhone.
set -euo pipefail
cd "$(dirname "$0")"
UDID="${UDID:-00008110-000A3138026B801E}"
exec xtool dev run --usb --udid "$UDID" "$@"
