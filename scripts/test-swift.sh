#!/usr/bin/env bash
# Run the Foundation-only Swift code on Linux: hours logic tests, then a
# decode check of each region file given (default: the bundled pois.json).
#   scripts/test-swift.sh [data/out/bc.json ...]
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# Only a file named main.swift may contain top-level code.
mkdir -p "$out/hours"
cp scripts/test_hours.swift "$out/hours/main.swift"
swiftc Sources/Trip/POIModel.swift Sources/Trip/OpeningHours.swift "$out/hours/main.swift" -o "$out/test_hours"
"$out/test_hours"

scripts/build-decoder.sh "$out/check_decode"
files=("$@")
[ ${#files[@]} -gt 0 ] || files=(Sources/Trip/Resources/pois.json)
for f in "${files[@]}"; do "$out/check_decode" "$f"; done
