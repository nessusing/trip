#!/usr/bin/env bash
# Check that the bundled pois.json decodes with the app's Swift model.
set -euo pipefail
cd "$(dirname "$0")/.."
out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT
# `main.swift` is the only file allowed top-level code.
cp scripts/check_decode.swift "$out/main.swift"
swiftc -O Sources/Trip/POIModel.swift "$out/main.swift" -o "$out/check"
"$out/check" Sources/Trip/Resources/pois.json
