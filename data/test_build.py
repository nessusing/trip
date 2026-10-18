"""Run: uv run --with pytest --with pyyaml --with requests pytest data"""

import sys
from pathlib import Path

import yaml

sys.path.insert(0, str(Path(__file__).parent))
import build  # noqa: E402

RULES = build.ToiletRules(yaml.safe_load(build.RULES_PATH.read_text()))


def osm(tags, lat=49.28, lon=-123.12, id=1, type="node"):
    return build.osm_element_to_poi(
        {"type": type, "id": id, "lat": lat, "lon": lon, "tags": tags}, RULES
    )


def test_public_toilet_defaults_to_public_access():
    poi = osm({"amenity": "toilets", "wheelchair": "yes"})
    assert poi["kind"] == "toilet"
    assert poi["toilet"]["access"] == "public"
    assert poi["toilet"]["confidence"] == "osm"
    assert poi["toilet"]["wheelchair"] is True


def test_private_toilet_is_dropped():
    assert osm({"amenity": "toilets", "access": "private"}) is None


def test_chain_cafe_without_toilet_tag_is_inferred():
    poi = osm({"amenity": "cafe", "brand": "Tim Hortons", "name": "Tim Hortons"})
    assert poi["kind"] == "venue"
    assert poi["toilet"] == {"access": "customers", "confidence": "inferred", "changingTable": None}


def test_explicit_toilets_no_beats_brand_rule():
    assert osm({"amenity": "cafe", "brand": "Starbucks", "toilets": "no"}) is None


def test_unknown_venue_without_toilets_is_dropped():
    assert osm({"amenity": "cafe", "name": "Some Indie Cafe"}) is None


def test_library_is_inferred_public():
    poi = osm({"amenity": "library", "name": "Central Library"})
    assert poi["toilet"]["access"] == "public"
    assert poi["toilet"]["confidence"] == "inferred"


def test_fuel_station_keeps_brand_and_inferred_toilet():
    poi = osm({"amenity": "fuel", "brand": "Shell", "fuel:diesel": "yes"})
    assert poi["kind"] == "fuel"
    assert poi["fuel"]["brand"] == "Shell"
    assert poi["fuel"]["diesel"] is True
    assert poi["toilet"]["confidence"] == "inferred"


def test_official_record_wins_and_gains_missing_fields():
    official = {"id": "van:1", "kind": "toilet", "source": "vancouver", "name": "Park",
                "lat": 49.28, "lon": -123.12, "hours": None,
                "toilet": {"access": "public", "confidence": "official", "wheelchair": None}}
    from_osm = {"id": "osm:n1", "kind": "toilet", "source": "osm", "name": None,
                "lat": 49.2801, "lon": -123.12, "hours": "24/7",
                "toilet": {"access": "public", "confidence": "osm", "wheelchair": True}}
    merged = build.merge([official, from_osm], build.same_place)
    assert len(merged) == 1
    assert merged[0]["id"] == "van:1"
    assert merged[0]["hours"] == "24/7"
    assert merged[0]["toilet"] == {"access": "public", "confidence": "official", "wheelchair": True}


def test_differently_named_osm_neighbours_stay_separate():
    a = osm({"amenity": "cafe", "brand": "Starbucks", "name": "Starbucks"}, id=1)
    b = osm({"amenity": "cafe", "brand": "Tim Hortons", "name": "Tim Hortons"}, id=2, lat=49.2801)
    assert len(build.merge([a, b], build.same_place)) == 2


def test_same_name_osm_node_and_way_merge():
    a = osm({"amenity": "fuel", "name": "Chevron"}, id=1)
    b = osm({"amenity": "fuel", "name": "Chevron"}, id=2, type="way", lat=49.2802)
    assert len(build.merge([a, b], build.same_place)) == 1


def test_official_rest_areas_with_same_name_stay_separate():
    def rest(id, lat):
        return {"id": f"databc:{id}", "kind": "restArea", "source": "databc",
                "name": "Bulkley View", "lat": lat, "lon": -127.0}
    assert len(build.merge([rest(1, 54.0), rest(2, 54.001)], build.same_place)) == 2


def test_far_apart_toilets_are_not_merged():
    a = osm({"amenity": "toilets"}, id=1)
    b = osm({"amenity": "toilets"}, id=2, lat=49.29)
    assert len(build.merge([a, b], build.same_place)) == 2
