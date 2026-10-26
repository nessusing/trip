#!/usr/bin/env bash
# Run the Foundation-only Swift code on Linux: hours, data-sync and route tests, then
# a decode check of each region file given.
#   scripts/test-swift.sh [data/out/bc.json ...]
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
model=(Sources/Trip/POIModel.swift Sources/Trip/OpeningHours.swift Sources/Trip/DataSync.swift Sources/Trip/RouteMath.swift)

# Only a file named main.swift may contain top-level code.
for t in hours sync route; do
  mkdir -p "$out/$t"
  cp "scripts/test_$t.swift" "$out/$t/main.swift"
  swiftc "${model[@]}" "$out/$t/main.swift" -o "$out/test_$t"
  "$out/test_$t"
done

if [ $# -gt 0 ]; then
  scripts/build-decoder.sh "$out/check_decode"
  for f in "$@"; do "$out/check_decode" "$f"; done
fi
