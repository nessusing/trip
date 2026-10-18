# /// script
# requires-python = ">=3.11"
# dependencies = ["requests>=2.31", "pyyaml>=6"]
# ///
"""Build the app's POI data file from open data sources.

    uv run data/build.py            # reuse cached downloads in data/cache/
    uv run data/build.py --refresh  # download everything again (except washroom
                                    # locations, see --refresh-context)

Optional environment variables:
    AFDC_API_KEY  key for developer.nlr.gov (defaults to the rate-limited DEMO_KEY)
    OCM_API_KEY   key for Open Charge Map; skipped when unset

Output: Sources/Trip/Resources/pois.json
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import requests
import yaml

from hours import ALWAYS, parse_afdc, parse_osm, parse_vancouver

ROOT = Path(__file__).resolve().parent.parent
CACHE_DIR = ROOT / "data" / "cache"
RULES_PATH = ROOT / "data" / "brands.yaml"
OUTPUT_PATH = ROOT / "Sources" / "Trip" / "Resources" / "pois.json"

USER_AGENT = "TripApp/0.1 (personal iOS app; data build script)"

# Bounding box around British Columbia: (south, west, north, east).
BC_BBOX = (48.2, -139.1, 60.0, -114.0)

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
]

# Unnamed washrooms looked up per Overpass query when finding nearby park and
# street names. Each batch takes a minute or two.
CONTEXT_BATCH = 300

DEDUP_RADIUS_M = {"restArea": 300}
DEFAULT_DEDUP_RADIUS_M = 50


# --------------------------------------------------------------------------
# Downloading
# --------------------------------------------------------------------------

def get_json(url: str, *, params: dict | None = None, data: dict | None = None,
             timeout: int = 120) -> object:
    headers = {"User-Agent": USER_AGENT}
    if data is not None:
        resp = requests.post(url, data=data, headers=headers, timeout=timeout)
    else:
        resp = requests.get(url, params=params, headers=headers, timeout=timeout)
    resp.raise_for_status()
    return resp.json()


def cached(name: str, fetch, refresh: bool) -> object:
    """Return the cached download `name`, fetching it first if needed."""
    path = CACHE_DIR / f"{name}.json"
    if path.exists() and not refresh:
        print(f"  {name}: using cache")
        return json.loads(path.read_text())
    print(f"  {name}: downloading...")
    result = fetch()
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(result))
    return result


def overpass_query(rules: dict) -> str:
    brands = "|".join(_regex_escape(b["name"]) for b in rules["brands"])
    category_lines = "\n".join(
        "  nwr" + "".join(
            f'["{k}"="{v}"]' for k, v in {c["tag"]: c["value"], **c.get("require", {})}.items()
        ) + "(area.bc);"
        for c in rules["categories"]
    )
    return f"""
[out:json][timeout:600];
area["ISO3166-2"="CA-BC"]["admin_level"="4"]->.bc;
(
  nwr["amenity"="fuel"](area.bc);
  nwr["amenity"="toilets"](area.bc);
  nwr["highway"~"^(rest_area|services)$"](area.bc);
  nwr["toilets"="yes"](area.bc);
  nwr["brand"~"^({brands})$",i](area.bc);
{category_lines}
);
out center tags;
"""


def _regex_escape(s: str) -> str:
    return "".join("\\\\" + c if c in ".^$*+?()[]{}|\\" else c for c in s)


def fetch_overpass(query: str) -> dict:
    delay = 15
    for attempt in range(8):
        url = OVERPASS_ENDPOINTS[attempt % len(OVERPASS_ENDPOINTS)]
        try:
            return get_json(url, data={"data": query}, timeout=900)
        except (requests.RequestException, ValueError) as err:
            print(f"    {url} failed ({err}); retrying in {delay}s")
            time.sleep(delay)
            delay = min(delay * 2, 240)
    raise RuntimeError("all Overpass endpoints failed")


def context_query(keys: list[str]) -> str:
    """For each washroom, find the named park/facility it's in and a nearby street."""
    nodes = ",".join(k[1:] for k in keys if k[0] == "n")
    ways = ",".join(k[1:] for k in keys if k[0] == "w")
    targets = (f"node(id:{nodes});" if nodes else "") + (f"way(id:{ways});" if ways else "")
    return f"""
[out:json][timeout:900];
({targets})->.t;
foreach.t->.x(
  .x out ids;
  (.x; node(w.x);)->.pts;
  .pts is_in->.a;
  (
    area.a["leisure"]["name"];
    area.a["natural"="beach"]["name"];
    area.a["tourism"]["name"];
    area.a["amenity"]["name"];
    area.a["landuse"="recreation_ground"]["name"];
  );
  out tags;
  way(around.x:60)["highway"]["name"];
  out tags 1;
);
"""


def _place_rank(tags: dict) -> int:
    """Lower is better: prefer the most specific named area."""
    if "amenity" in tags or "tourism" in tags:
        return 0
    if tags.get("natural") == "beach":
        return 1
    if "leisure" in tags and tags["leisure"] != "park":
        return 2
    if tags.get("leisure") == "park":
        return 3
    return 4


def parse_context(elements: list[dict]) -> dict[str, dict]:
    """Turn the foreach output stream into {"n123": {"place": ..., "street": ...}}.

    Each washroom appears untagged (`out ids`), followed by the tagged areas
    and road found for it.
    """
    result: dict[str, dict] = {}
    current = None
    best_rank = 99
    for el in elements:
        tags = el.get("tags")
        if not tags:
            current = f"{el['type'][0]}{el['id']}"
            result[current] = {}
            best_rank = 99
        elif current is None:
            continue
        elif "highway" in tags:
            result[current].setdefault("street", tags["name"])
        elif _place_rank(tags) < best_rank:
            best_rank = _place_rank(tags)
            result[current]["place"] = tags["name"]
    return result


def load_context(keys: list[str], refresh: bool) -> dict[str, dict]:
    """Nearby park/street names for unnamed washrooms, cached per washroom.

    Only washrooms missing from the cache are looked up, so after the first
    run (about half an hour for BC) only new ones cost anything.
    """
    path = CACHE_DIR / "osm_context.json"
    context = {} if refresh or not path.exists() else json.loads(path.read_text())
    missing = [k for k in keys if k not in context]
    if not missing:
        print("  osm_context: using cache")
        return context
    batches = [missing[i:i + CONTEXT_BATCH] for i in range(0, len(missing), CONTEXT_BATCH)]
    print(f"  osm_context: looking up {len(missing)} washrooms in {len(batches)} batches...")
    for n, batch in enumerate(batches, 1):
        found = parse_context(fetch_overpass(context_query(batch))["elements"])
        for key in batch:
            context[key] = found.get(key, {})
        CACHE_DIR.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(context))
        print(f"    batch {n}/{len(batches)} done")
    return context


def fetch_afdc() -> dict:
    return get_json(
        "https://developer.nlr.gov/api/alt-fuel-stations/v1.json",
        params={
            "api_key": os.environ.get("AFDC_API_KEY", "DEMO_KEY"),
            "fuel_type": "ELEC",
            "country": "CA",
            "state": "BC",
            "status": "E",
            "access": "public",
            "limit": "all",
        },
    )


def fetch_ocm(key: str) -> list:
    s, w, n, e = BC_BBOX
    return get_json(
        "https://api.openchargemap.io/v3/poi/",
        params={
            "key": key,
            "output": "json",
            "countrycode": "CA",
            "boundingbox": f"({n},{w}),({s},{e})",
            "maxresults": 20000,
            "compact": "false",
            "verbose": "false",
        },
    )


def fetch_vancouver() -> list:
    return get_json(
        "https://opendata.vancouver.ca/api/explore/v2.1/catalog/datasets/"
        "public-washrooms/exports/json"
    )


def fetch_rest_areas() -> dict:
    return get_json(
        "https://openmaps.gov.bc.ca/geo/pub/wfs",
        params={
            "service": "WFS",
            "version": "2.0.0",
            "request": "GetFeature",
            "typeName": "pub:WHSE_IMAGERY_AND_BASE_MAPS.MOT_REST_AREAS_SP",
            "outputFormat": "application/json",
            "srsName": "EPSG:4326",
        },
    )


# --------------------------------------------------------------------------
# Normalising: every source becomes a list of POI dicts (see SPEC.md)
# --------------------------------------------------------------------------

def yes_no(value: str | None) -> bool | None:
    if value is None:
        return None
    value = value.strip().lower()
    if value in ("yes", "true", "1", "designated", "limited"):
        return True
    if value in ("no", "false", "0"):
        return False
    return None


def osm_access(value: str | None, default: str) -> str:
    if value is None:
        return default
    value = value.lower()
    if value in ("yes", "public", "permissive", "designated"):
        return "public"
    if value in ("customers", "customer"):
        return "customers"
    return "unknown"


def osm_address(tags: dict) -> str | None:
    street = " ".join(p for p in (tags.get("addr:housenumber"), tags.get("addr:street")) if p)
    parts = [p for p in (street, tags.get("addr:city")) if p]
    return ", ".join(parts) or None


class ToiletRules:
    def __init__(self, rules: dict):
        self.brands = {b["name"].casefold(): b["access"] for b in rules["brands"]}
        self.categories = rules["categories"]

    def match(self, tags: dict) -> str | None:
        """Return the inferred access for a place, or None if no rule applies."""
        for key in ("brand", "name"):
            access = self.brands.get(tags.get(key, "").casefold())
            if access:
                return access
        for cat in self.categories:
            if tags.get(cat["tag"]) != cat["value"]:
                continue
            if all(tags.get(k) == v for k, v in cat.get("require", {}).items()):
                return cat["access"]
        return None


def osm_kind(tags: dict) -> str:
    if tags.get("amenity") == "fuel":
        return "fuel"
    if tags.get("highway") in ("rest_area", "services"):
        return "restArea"
    if tags.get("amenity") == "toilets":
        return "toilet"
    return "venue"


def osm_toilet(kind: str, tags: dict, rules: ToiletRules) -> dict | None:
    if kind == "toilet":
        if tags.get("access") in ("private", "no"):
            return None
        info = {
            "access": osm_access(tags.get("access"), "public"),
            "confidence": "osm",
            "wheelchair": yes_no(tags.get("wheelchair")),
            "fee": yes_no(tags.get("fee")),
        }
    else:
        flag = tags.get("toilets")
        inferred = rules.match(tags)
        if flag == "no":
            return None
        if flag == "yes":
            info = {
                "access": osm_access(tags.get("toilets:access"), inferred or "unknown"),
                "confidence": "osm",
                "wheelchair": yes_no(tags.get("toilets:wheelchair")),
                "fee": yes_no(tags.get("toilets:fee")),
            }
        elif inferred:
            info = {"access": inferred, "confidence": "inferred"}
        else:
            return None
    info["changingTable"] = yes_no(tags.get("changing_table") or tags.get("toilets:changing_table"))
    return info


def osm_key(el: dict) -> str:
    return f"{el['type'][0]}{el['id']}"


def needs_context(el: dict) -> bool:
    tags = el.get("tags", {})
    return tags.get("amenity") == "toilets" and not tags.get("name")


def osm_element_to_poi(el: dict, rules: ToiletRules, context: dict | None = None) -> dict | None:
    tags = el.get("tags", {})
    lat = el.get("lat", el.get("center", {}).get("lat"))
    lon = el.get("lon", el.get("center", {}).get("lon"))
    if lat is None or lon is None:
        return None

    kind = osm_kind(tags)
    toilet = osm_toilet(kind, tags, rules)
    if kind in ("toilet", "venue") and toilet is None:
        return None

    poi = {
        "id": f"osm:{osm_key(el)}",
        "kind": kind,
        "name": tags.get("name") or tags.get("brand"),
        "lat": round(lat, 6),
        "lon": round(lon, 6),
        "address": osm_address(tags),
        "hours": tags.get("opening_hours"),
        "open": parse_osm(tags.get("opening_hours")),
        "source": "osm",
        "toilet": toilet,
    }
    if context and kind == "toilet":
        found = context.get(osm_key(el), {})
        poi["place"] = found.get("place")
        poi["street"] = found.get("street")
    if kind == "venue":
        poi["sub"] = tags.get("amenity") or tags.get("shop") or tags.get("tourism")
    if kind == "fuel":
        poi["fuel"] = {
            "brand": tags.get("brand") or tags.get("name"),
            "diesel": yes_no(tags.get("fuel:diesel")),
            "shop": True if tags.get("shop") else None,
        }
    if kind == "restArea" and tags.get("highway") == "services":
        poi["sub"] = "services"
    return poi


AFDC_CONNECTORS = {
    "J1772": "J1772",
    "J1772COMBO": "CCS",
    "CHADEMO": "CHAdeMO",
    "TESLA": "NACS",
    "J3400": "NACS",
}


AFDC_NETWORKS = {
    "ChargePoint Network": "ChargePoint",
    "BCHYDRO": "BC Hydro",
    "PLUGEV": "PlugEV",
    "SHELL_RECHARGE": "Shell Recharge",
    "ON_THE_RUN_EV": "On the Run EV",
    "CHARGELAB": "ChargeLab",
    "EVSTART": "EVStart",
    "MERCEDES_BENZ": "Mercedes-Benz",
    "HONEY_BADGER": "Honey Badger",
    "7CHARGE": "7Charge",
    "COUCHE_TARD": "Circle K",
    "EVGATEWAY": "EVgateway",
    "NOODOE": "Noodoe",
    "CHARGEUP": "ChargeUp",
    "CHAEVI": "Chaevi",
    "Non-Networked": None,
}


def afdc_to_poi(st: dict) -> dict:
    connectors = sorted({AFDC_CONNECTORS.get(c, c) for c in st.get("ev_connector_types") or []})
    powers = [
        conn.get("power_kw")
        for unit in st.get("ev_charging_units") or []
        for conn in (unit.get("connectors") or {}).values()
        if conn.get("port_count") and conn.get("power_kw")
    ]
    network = st.get("ev_network")
    network = AFDC_NETWORKS.get(network, network)
    return {
        "id": f"afdc:{st['id']}",
        "kind": "ev",
        "name": st.get("station_name"),
        "lat": round(st["latitude"], 6),
        "lon": round(st["longitude"], 6),
        "address": ", ".join(p for p in (st.get("street_address"), st.get("city")) if p) or None,
        "hours": st.get("access_days_time"),
        "open": parse_afdc(st.get("access_days_time")),
        "source": "afdc",
        "ev": {
            "connectors": connectors,
            "maxKW": max(powers) if powers else None,
            "network": network,
            "dcFast": st.get("ev_dc_fast_num"),
            "level2": st.get("ev_level2_evse_num"),
            "pricing": st.get("ev_pricing"),
        },
    }


OCM_CONNECTORS = {
    "Type 1 (J1772)": "J1772",
    "CCS (Type 1)": "CCS",
    "CHAdeMO": "CHAdeMO",
    "Tesla (Model S/X)": "NACS",
    "NACS / SAE J3400": "NACS",
}


def ocm_to_poi(p: dict) -> dict | None:
    if (p.get("StatusType") or {}).get("IsOperational") is False:
        return None
    addr = p.get("AddressInfo") or {}
    conns = p.get("Connections") or []
    connectors = sorted({
        OCM_CONNECTORS.get((c.get("ConnectionType") or {}).get("Title"), "Other") for c in conns
    })
    powers = [c["PowerKW"] for c in conns if c.get("PowerKW")]
    return {
        "id": f"ocm:{p['ID']}",
        "kind": "ev",
        "name": addr.get("Title"),
        "lat": round(addr["Latitude"], 6),
        "lon": round(addr["Longitude"], 6),
        "address": ", ".join(x for x in (addr.get("AddressLine1"), addr.get("Town")) if x) or None,
        "source": "ocm",
        "ev": {
            "connectors": connectors,
            "maxKW": max(powers) if powers else None,
            "network": (p.get("OperatorInfo") or {}).get("Title"),
            "pricing": p.get("UsageCost"),
        },
    }


def vancouver_to_poi(row: dict) -> dict | None:
    point = row.get("geo_point_2d") or {}
    if point.get("lat") is None:
        return None
    lat, lon = round(point["lat"], 6), round(point["lon"], 6)
    summer, winter = row.get("summer_hours"), row.get("winter_hours")
    if summer and summer == winter:
        hours = summer
    else:
        hours = " · ".join(f"{label}: {h}" for label, h in (("Summer", summer), ("Winter", winter)) if h) or None
    return {
        "id": f"van:{lat:.5f},{lon:.5f}",
        "kind": "toilet",
        "name": None,
        "place": row.get("park_name"),
        "lat": lat,
        "lon": lon,
        "address": row.get("location"),
        "hours": hours,
        "open": parse_vancouver(summer, winter),
        "source": "vancouver",
        "toilet": {
            "access": "public",
            "confidence": "official",
            "wheelchair": yes_no(row.get("wheelchair_access")),
        },
    }


def rest_area_to_poi(feature: dict) -> dict:
    p = feature["properties"]
    lon, lat = feature["geometry"]["coordinates"][:2]
    toilets = p.get("NUMBER_OF_TOILETS") or 0
    year_round = yes_no(p.get("OPEN_YEAR_ROUND_IND"))
    if year_round:
        hours = "Open year-round"
    elif p.get("OPEN_DATE") or p.get("CLOSE_DATE"):
        hours = f"Seasonal: {p.get('OPEN_DATE') or '?'} – {p.get('CLOSE_DATE') or '?'}"
    else:
        hours = None
    highway = p.get("HIGHWAY_NUMBER") or p.get("ASSOCIATED_NUMBERED_ROUTE")
    return {
        "id": f"databc:{p['REST_AREA_ID']}",
        "kind": "restArea",
        "name": (p.get("REST_AREA_NAME") or "Rest area").title(),
        "lat": round(lat, 6),
        "lon": round(lon, 6),
        "address": p.get("DISTANCE_FROM_MUNICIPALITY", "").title() or None,
        "hours": hours,
        "open": ALWAYS if year_round else None,
        "source": "databc",
        "toilet": {
            "access": "public",
            "confidence": "official",
            "wheelchair": yes_no(p.get("WHEELCHAIR_ACCESS_TOILET_IND")),
        } if toilets else None,
        "restArea": {
            "highway": highway,
            "direction": p.get("DIRECTION_OF_TRAFFIC"),
            "toilets": toilets,
            "toiletType": p.get("TOILET_TYPE"),
            "yearRound": year_round,
            "trucks": yes_no(p.get("ACCOM_COMMERCIAL_TRUCKS_IND")),
            "tables": p.get("NUMBER_OF_TABLES"),
        },
    }


# --------------------------------------------------------------------------
# Merging
# --------------------------------------------------------------------------

def distance_m(a: dict, b: dict) -> float:
    lat1, lon1, lat2, lon2 = map(math.radians, (a["lat"], a["lon"], b["lat"], b["lon"]))
    h = (math.sin((lat2 - lat1) / 2) ** 2
         + math.cos(lat1) * math.cos(lat2) * math.sin((lon2 - lon1) / 2) ** 2)
    return 6_371_000 * 2 * math.asin(math.sqrt(h))


class Grid:
    """Spatial hash for finding POIs within a few hundred metres."""

    CELL = 0.005  # degrees (~550 m north-south)

    def __init__(self):
        self.cells: dict[tuple[int, int], list[dict]] = {}

    def _key(self, poi: dict) -> tuple[int, int]:
        return (int(poi["lat"] // self.CELL), int(poi["lon"] // self.CELL))

    def add(self, poi: dict) -> None:
        self.cells.setdefault(self._key(poi), []).append(poi)

    def near(self, poi: dict, radius_m: float):
        y, x = self._key(poi)
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                for other in self.cells.get((y + dy, x + dx), ()):
                    if distance_m(poi, other) <= radius_m:
                        yield other


def fill_missing(target: dict, extra: dict) -> None:
    """Copy fields from `extra` that `target` lacks, recursing into sub-dicts."""
    for key, value in extra.items():
        if value is None or key in ("id", "source", "lat", "lon"):
            continue
        current = target.get(key)
        if current is None:
            target[key] = value
        elif isinstance(current, dict) and isinstance(value, dict):
            fill_missing(current, value)


def merge(pois: list[dict], same) -> list[dict]:
    """Merge nearby duplicates. Earlier POIs win; `same(a, b)` decides matches.

    Pass POIs ordered by priority (official sources first).
    """
    grid = Grid()
    kept: list[dict] = []
    for poi in pois:
        radius = DEDUP_RADIUS_M.get(poi["kind"], DEFAULT_DEDUP_RADIUS_M)
        match = next((o for o in grid.near(poi, radius) if same(o, poi)), None)
        if match:
            fill_missing(match, poi)
        else:
            grid.add(poi)
            kept.append(poi)
    return kept


def _name_key(poi: dict) -> str:
    return (poi.get("name") or "").casefold()


def same_place(a: dict, b: dict) -> bool:
    if a["kind"] != b["kind"]:
        return False
    if a["source"] != b["source"]:
        # Different datasets name things differently; trust location alone.
        return True
    if a["source"] != "osm":
        # Official datasets have one record per place already. Rest areas on
        # opposite sides of a highway often share a name.
        return False
    # Within OSM, nearby things with different names are distinct (e.g. a Tim
    # Hortons next to a Starbucks). The same name nearby is usually one place
    # mapped twice (node + building outline). Unnamed toilets are merged.
    return _name_key(a) == _name_key(b)


SOURCE_PRIORITY = {"databc": 0, "vancouver": 0, "afdc": 1, "osm": 2, "ocm": 3}


def strip_nones(value):
    if isinstance(value, dict):
        cleaned = {k: strip_nones(v) for k, v in value.items()}
        return {k: v for k, v in cleaned.items() if v not in (None, [], {})}
    if isinstance(value, list):
        return [strip_nones(v) for v in value]
    return value


# --------------------------------------------------------------------------

def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--refresh", action="store_true", help="ignore cached downloads")
    parser.add_argument("--refresh-context", action="store_true",
                        help="look up park/street names for unnamed washrooms again (slow)")
    args = parser.parse_args()

    rules_yaml = yaml.safe_load(RULES_PATH.read_text())
    rules = ToiletRules(rules_yaml)

    print("Fetching sources:")
    osm = cached("osm", lambda: fetch_overpass(overpass_query(rules_yaml)), args.refresh)
    afdc = cached("afdc", fetch_afdc, args.refresh)
    vancouver = cached("vancouver", fetch_vancouver, args.refresh)
    rest_areas = cached("databc_rest_areas", fetch_rest_areas, args.refresh)
    ocm_key = os.environ.get("OCM_API_KEY")
    ocm = cached("ocm", lambda: fetch_ocm(ocm_key), args.refresh) if ocm_key else []
    if not ocm_key:
        print("  ocm: skipped (set OCM_API_KEY to include Open Charge Map)")

    context = load_context(
        [osm_key(el) for el in osm["elements"] if needs_context(el)], args.refresh_context
    )

    pois: list[dict] = []
    pois += [p for el in osm["elements"] if (p := osm_element_to_poi(el, rules, context))]
    pois += [afdc_to_poi(st) for st in afdc["fuel_stations"]]
    pois += [p for row in vancouver if (p := vancouver_to_poi(row))]
    pois += [rest_area_to_poi(f) for f in rest_areas["features"]]
    pois += [p for item in ocm if (p := ocm_to_poi(item))]

    raw_count = len(pois)
    pois.sort(key=lambda p: SOURCE_PRIORITY[p["source"]])
    pois = merge(pois, same_place)
    pois = [strip_nones(p) for p in pois]
    pois.sort(key=lambda p: p["id"])

    counts: dict[str, int] = {}
    for p in pois:
        counts[p["kind"]] = counts.get(p["kind"], 0) + 1
    with_toilet = sum(1 for p in pois if "toilet" in p)

    output = {
        "generated": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "region": "British Columbia",
        "pois": pois,
    }
    OUTPUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT_PATH.write_text(json.dumps(output, ensure_ascii=False, separators=(",", ":")))

    print(f"\n{raw_count} records -> {len(pois)} POIs after merging duplicates")
    for kind, n in sorted(counts.items()):
        print(f"  {kind:9} {n}")
    print(f"  with a washroom: {with_toilet}")
    print(f"Wrote {OUTPUT_PATH.relative_to(ROOT)} ({OUTPUT_PATH.stat().st_size / 1e6:.1f} MB)")


if __name__ == "__main__":
    sys.exit(main())
