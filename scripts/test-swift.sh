#!/usr/bin/env bash
# Run the Foundation-only Swift code on Linux: hours logic tests, then a
# decode check of the bundled pois.json.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
model=(Sources/Trip/POIModel.swift Sources/Trip/OpeningHours.swift)

# Only a file named main.swift may contain top-level code.
mkdir -p "$out/hours" "$out/decode"
cp scripts/test_hours.swift "$out/hours/main.swift"
swiftc "${model[@]}" "$out/hours/main.swift" -o "$out/test_hours"
"$out/test_hours"

cp scripts/check_decode.swift "$out/decode/main.swift"
swiftc -O "${model[@]}" "$out/decode/main.swift" -o "$out/check_decode"
"$out/check_decode" Sources/Trip/Resources/pois.json
