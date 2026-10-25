#!/usr/bin/env bash
# Compile scripts/check_decode.swift with the app's model into the binary $1.
# Run the binary with a region file to check the app can decode it.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# Only a file named main.swift may contain top-level code.
cp scripts/check_decode.swift "$out/main.swift"
swiftc -O Sources/Trip/POIModel.swift Sources/Trip/OpeningHours.swift "$out/main.swift" -o "$1"
