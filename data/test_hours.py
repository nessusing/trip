"""Run: uv run --with pytest --with pyyaml --with requests pytest data"""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from hours import ALWAYS, DAWN, DUSK, parse_afdc, parse_osm, parse_vancouver  # noqa: E402

MO, TU, WE, TH, FR, SA, SU = range(7)


def test_24_7():
    assert parse_osm("24/7") == ALWAYS


def test_every_day_without_weekdays():
    assert parse_osm("06:00-22:00") == [[[360, 1320]]] * 7


def test_weekday_ranges_and_unlisted_days_closed():
    week = parse_osm("Mo-Fr 09:00-17:00; Sa 10:00-14:00")
    assert week[MO] == [[540, 1020]]
    assert week[FR] == [[540, 1020]]
    assert week[SA] == [[600, 840]]
    assert week[SU] == []


def test_later_rule_overrides_earlier_days():
    week = parse_osm("Mo-Su 10:00-18:00; Tu-Th 10:00-19:00")
    assert week[MO] == [[600, 1080]]
    assert week[WE] == [[600, 1140]]


def test_weekday_list_with_spaces_and_wraparound():
    week = parse_osm("Mo, We, Fr-Sa 10:00-18:00; Su-Tu 08:00-09:00")
    assert week[WE] == [[600, 1080]]
    assert week[SU] == week[MO] == week[TU] == [[480, 540]]


def test_past_midnight_and_comma_separated_rules():
    week = parse_osm("Su-Th 11:00-24:00, Fr,Sa 11:00-01:00")
    assert week[MO] == [[660, 1440]]
    assert week[FR] == [[660, 1500]]


def test_hours_past_24():
    assert parse_osm("Fr 11:00-25:00")[FR] == [[660, 1500]]


def test_split_shift():
    assert parse_osm("Mo 07:00-12:00,13:00-18:00")[MO] == [[420, 720], [780, 1080]]


def test_2359_means_midnight_and_0000_0000_means_all_day():
    assert parse_osm("Mo-Su 06:00-23:59")[MO] == [[360, 1440]]
    assert parse_osm("Mo-Su,PH 00:00-00:00") == ALWAYS


def test_dawn_dusk():
    assert parse_osm("dawn-dusk") == [[[DAWN, DUSK]]] * 7
    assert parse_osm("Mo-Su dawn-dusk")[SU] == [[DAWN, DUSK]]


def test_holiday_closures_are_ignored():
    week = parse_osm("Mo-Fr 09:00-20:30; Sa 09:00-18:00; Jan 01 off; Feb Mo[3] off; easter off; PH off")
    assert week[MO] == [[540, 1230]]
    assert week[SU] == []


def test_unsupported_forms_return_none():
    for text in ("unknown", "May-Sep 08:00-20:00", "Mo-Fr 08:00+", "(sunset-01:00)-24:00",
                 'Mo-Fr 08:00-17:00 "by appointment"', "", None):
        assert parse_osm(text) is None, text


def test_afdc():
    assert parse_afdc("24 hours daily; for guest use only") == ALWAYS
    week = parse_afdc("Mon: 12:00am-6:00am, 7:00pm-11:59pm; Sat: 7:00am-9:00pm")
    assert week[MO] == [[0, 360], [1140, 1440]]
    assert week[SA] == [[420, 1260]]
    assert week[SU] == []
    assert parse_afdc("Open to all EV drivers") is None


def test_vancouver():
    assert parse_vancouver("Dawn to Dusk", "Dawn to Dusk") == [[[DAWN, DUSK]]] * 7
    assert parse_vancouver("24hrs - 24hrs", "24hrs - 24hrs") == ALWAYS
    assert parse_vancouver("7:30 am - 9:00 pm", "7:30 am - 9:00 pm")[MO] == [[450, 1260]]
    assert parse_vancouver("6:00am - Midnight", "6:00am - Midnight")[MO] == [[360, 1440]]
    assert parse_vancouver("7:00 am - Dusk", "7:00 am - Dusk")[MO] == [[420, DUSK]]
    assert parse_vancouver("Dawn to Dusk", "Closed") is None
    assert parse_vancouver("as per CC operating hours", "as per CC operating hours") is None
