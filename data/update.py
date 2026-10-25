# /// script
# requires-python = ">=3.11"
# dependencies = ["requests>=2.31", "pyyaml>=6"]
# ///
"""Rebuild the regions that are due and publish them with a manifest.

    uv run data/update.py --site site                  # regions due per data/regions.yaml
    uv run data/update.py --site site --regions bc,wa  # these regions, due or not

Run by .github/workflows/data.yml with `--site` checked out from the `data`
branch, which the app downloads from. Layout of the site directory:

    manifest.json       what the app reads first; see write_manifest()
    regions/<id>.json   one region's POIs (build.py output)
    context/<id>.json   washroom place-name cache, reused by the next run

A region that fails to build, or fails a check, keeps its previous file. The
script exits non-zero if any region failed, so the workflow run shows as failed
(and GitHub emails about it), but successful regions are still published.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import traceback
from datetime import datetime, timedelta, timezone
from pathlib import Path

import build

# Refuse to publish a region whose POI count drops by more than this fraction.
MAX_DROP = 0.2

# The workflow wakes once a day at about the same time, so a region built three
# days ago is a few minutes short of "3 days old" at the next check. This slack
# stops that from pushing it to the day after.
DUE_SLACK = timedelta(hours=12)


def parse_time(text: str) -> datetime:
    return datetime.strptime(text, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def is_due(entry: dict | None, every_days: float, now: datetime) -> bool:
    if entry is None:
        return True
    return now - parse_time(entry["generated"]) >= timedelta(days=every_days) - DUE_SLACK


def check(output: dict, previous: dict | None, decoder: Path | None, path: Path) -> None:
    """Raise if the freshly written region file at `path` shouldn't be published."""
    count = len(output["pois"])
    if count == 0:
        raise ValueError("no POIs")
    if previous and count < previous["count"] * (1 - MAX_DROP):
        raise ValueError(f"POI count fell from {previous['count']} to {count}")
    if decoder:
        # The app's own model, compiled on Linux: catches anything the app can't decode.
        subprocess.run([str(decoder), str(path)], check=True)


def manifest_entry(region: build.Region, output: dict, path: Path, file: str) -> dict:
    data = path.read_bytes()
    return {
        "id": region.id,
        "name": region.name,
        "file": file,
        "generated": output["generated"],
        "schema": output["schema"],
        "sha256": hashlib.sha256(data).hexdigest(),
        "bytes": len(data),
        "count": len(output["pois"]),
        "sources": output["sources"],
        "boundary": build.region_boundary(region),
    }


def write_manifest(site: Path, entries: dict[str, dict]) -> None:
    """manifest.json: {"schema": 1, "regions": [entry, ...]}, entries sorted by id.

    The app compares each entry's sha256 with what it has and downloads
    `file` (relative to the manifest) when they differ. `boundary` is a GeoJSON
    MultiPolygon used to tell which parts of a route have data.
    """
    build.write_json(site / "manifest.json", {
        "schema": build.SCHEMA_VERSION,
        "regions": [entries[k] for k in sorted(entries)],
    })


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--site", type=Path, required=True, help="checkout of the data branch")
    parser.add_argument("--regions", help="comma-separated region ids to rebuild regardless of schedule")
    parser.add_argument("--decoder", type=Path, help="compiled scripts/check_decode.swift (see scripts/build-decoder.sh)")
    args = parser.parse_args()

    regions = build.load_regions()
    manifest_path = args.site / "manifest.json"
    old = json.loads(manifest_path.read_text()) if manifest_path.exists() else {"regions": []}
    entries = {e["id"]: e for e in old["regions"]}

    # Regions removed from regions.yaml stop being published.
    for rid in set(entries) - set(regions):
        print(f"Removing {rid} (no longer in regions.yaml)")
        (args.site / entries.pop(rid)["file"]).unlink(missing_ok=True)

    now = datetime.now(timezone.utc)
    if args.regions:
        targets = [r.strip() for r in args.regions.split(",") if r.strip()]
        unknown = [r for r in targets if r not in regions]
        if unknown:
            sys.exit(f"unknown regions {unknown}; known: {', '.join(regions)}")
    else:
        targets = [rid for rid, r in regions.items() if is_due(entries.get(rid), r.every_days, now)]
    print(f"Rebuilding: {', '.join(targets) or 'nothing due'}")

    failed = []
    for rid in targets:
        region = regions[rid]
        print(f"\n=== {region.name} ===")
        try:
            with tempfile.TemporaryDirectory() as tmp:
                cache_dir = Path(tmp) / "cache"
                output = build.build_region(region, cache_dir, args.site / "context" / f"{rid}.json",
                                            refresh=True)
                build.print_summary(output)
                staged = Path(tmp) / f"{rid}.json"
                build.write_json(staged, output)
                check(output, entries.get(rid), args.decoder, staged)
                file = f"regions/{rid}.json"
                (args.site / "regions").mkdir(parents=True, exist_ok=True)
                shutil.move(staged, args.site / file)
                entries[rid] = manifest_entry(region, output, args.site / file, file)
        except Exception:
            traceback.print_exc()
            print(f"!! {rid} failed; keeping the previous version")
            failed.append(rid)

    write_manifest(args.site, entries)
    if failed:
        print(f"\nFailed: {', '.join(failed)}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
