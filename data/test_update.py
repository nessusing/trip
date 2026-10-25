"""Run: uv run --with pytest --with pyyaml --with requests pytest data"""

import sys
from datetime import datetime, timezone
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).parent))
import update  # noqa: E402

NOW = datetime(2026, 10, 25, 11, 17, tzinfo=timezone.utc)


def test_new_region_is_due():
    assert update.is_due(None, 3, NOW)


def test_region_built_three_days_ago_at_a_later_minute_is_due():
    assert update.is_due({"generated": "2026-10-22T11:40:00Z"}, 3, NOW)


def test_region_built_two_days_ago_is_not_due():
    assert not update.is_due({"generated": "2026-10-23T11:10:00Z"}, 3, NOW)


def test_check_rejects_large_drop(tmp_path):
    output = {"pois": [{}] * 79}
    with pytest.raises(ValueError, match="fell from 100 to 79"):
        update.check(output, {"count": 100}, None, tmp_path / "x.json")


def test_check_accepts_small_drop_and_first_build(tmp_path):
    update.check({"pois": [{}] * 81}, {"count": 100}, None, tmp_path / "x.json")
    update.check({"pois": [{}]}, None, None, tmp_path / "x.json")


def test_check_rejects_empty(tmp_path):
    with pytest.raises(ValueError, match="no POIs"):
        update.check({"pois": []}, None, None, tmp_path / "x.json")
