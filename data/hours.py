"""Parse opening-hours text from each source into one weekly schedule format.

A schedule is a list of 7 days (Monday first). Each day is a list of
[start, end] intervals in minutes after local midnight. `end` can go past 1440
for spans that run past midnight (e.g. 18:00-02:00 is [1080, 1560]).

Sun-relative times use negative sentinels (DAWN, DUSK, SUNRISE, SUNSET
below) that the app resolves for the place's location and date.
"""

from __future__ import annotations

import re
from copy import deepcopy as _copy

DAWN, DUSK, SUNRISE, SUNSET = -1, -2, -3, -4
SUN_EVENTS = {"dawn": DAWN, "dusk": DUSK, "sunrise": SUNRISE, "sunset": SUNSET}

FULL_DAY = [0, 1440]
ALWAYS = [[FULL_DAY] for _ in range(7)]

DAYS = ["Mo", "Tu", "We", "Th", "Fr", "Sa", "Su"]
HOLIDAYS = ("PH", "SH")
MONTHS = ("Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec")

Schedule = list[list[list[int]]]

_DAY_TOKEN = r"(?:Mo|Tu|We|Th|Fr|Sa|Su|PH|SH)"
_RULE = re.compile(rf"^({_DAY_TOKEN}(?:\s*[-,]\s*{_DAY_TOKEN})*)?\s*(.*)$")
_TIME = r"(?:\d{1,2}:\d{2}|dawn|dusk|sunrise|sunset)"
_SPAN = re.compile(rf"^({_TIME})\s*-\s*({_TIME})$")


# --------------------------------------------------------------------------
# OpenStreetMap `opening_hours`
# https://wiki.openstreetmap.org/wiki/Key:opening_hours
# --------------------------------------------------------------------------

def parse_osm(text: str | None) -> Schedule | None:
    """Parse the common subset of OSM opening_hours; None if unsupported.

    Supported: 24/7; weekday ranges and lists; several time spans per rule;
    spans past midnight; dawn/dusk/sunrise/sunset; later rules overriding
    earlier ones; "off"/"closed". Public-holiday and date-specific closures
    are ignored. Seasonal rules ("May-Sep ...") are not supported.
    """
    if not text:
        return None
    s = text.strip()
    if s == "24/7":
        return _copy(ALWAYS)
    if "||" in s or '"' in s:
        return None

    # A comma after a time often separates rules, as in
    # "Su-Th 11:00-24:00, Fr,Sa 11:00-01:00".
    s = re.sub(r"(\d{2}:\d{2}|dusk|sunset|off|closed)\s*,\s*(?=[A-Z][a-z])", r"\1;", s)

    week: Schedule = [[] for _ in range(7)]
    applied = False
    for rule in (r.strip() for r in s.split(";")):
        if not rule:
            continue
        if _is_date_rule(rule):
            if rule.endswith(("off", "closed")):
                continue  # a holiday closure; ignore
            return None

        match = _RULE.match(rule)
        days_part, times_part = match.group(1), match.group(2).strip()
        days = _parse_days(days_part) if days_part else set(range(7))
        if days is None:
            return None
        if not days:
            continue  # only PH/SH

        if times_part in ("off", "closed"):
            intervals = []
        else:
            intervals = _parse_spans(times_part)
            if intervals is None:
                return None
        for d in days:
            week[d] = _copy(intervals)
        applied = True
    return week if applied else None


def _is_date_rule(rule: str) -> bool:
    return (rule.startswith(MONTHS) or "[" in rule or "easter" in rule
            or rule.startswith("week") or bool(re.match(r"^\d{4}", rule)))


def _parse_days(part: str) -> set[int] | None:
    days: set[int] = set()
    for token in (t.strip() for t in part.split(",")):
        if token in HOLIDAYS:
            continue
        if "-" in token:
            a, b = (x.strip() for x in token.split("-", 1))
            if a not in DAYS or b not in DAYS:
                return None
            i, j = DAYS.index(a), DAYS.index(b)
            days.update(range(i, j + 1) if i <= j else [*range(i, 7), *range(0, j + 1)])
        elif token in DAYS:
            days.add(DAYS.index(token))
        else:
            return None
    return days


def _parse_spans(part: str) -> list[list[int]] | None:
    intervals = []
    for span in (x.strip() for x in part.split(",")):
        m = _SPAN.match(span)
        if not m:
            return None
        start, end = _osm_time(m.group(1)), _osm_time(m.group(2))
        if start is None or end is None:
            return None
        intervals.append(_interval(start, end))
    return intervals


def _osm_time(t: str) -> int | None:
    if t in SUN_EVENTS:
        return SUN_EVENTS[t]
    h, m = t.split(":")
    minutes = int(h) * 60 + int(m)
    # Up to 48:00 is allowed: "Fr 11:00-25:00" closes at 1am Saturday.
    if minutes > 2880 or int(m) >= 60:
        return None
    return minutes


def _interval(start: int, end: int) -> list[int]:
    if start < 0 or end < 0:
        return [start, end]  # sun-relative; resolved by the app
    if end == 1439:
        end = 1440  # "23:59" means until midnight
    if end == start:
        return [start, start + 1440]  # "00:00-00:00": round the clock
    if end < start:
        end += 1440  # runs past midnight
    return [start, end]


# --------------------------------------------------------------------------
# AFDC `access_days_time`
# --------------------------------------------------------------------------

_AFDC_DAYS = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
_AFDC_SPAN = re.compile(r"^(\d{1,2}:\d{2}\s*[ap]m)\s*-\s*(\d{1,2}:\d{2}\s*[ap]m)$", re.I)


def parse_afdc(text: str | None) -> Schedule | None:
    """Handles "24 hours daily..." and "Mon: 6:00am-6:00pm; Tue: ..."."""
    if not text:
        return None
    s = text.strip()
    if s.lower().startswith("24 hours daily"):
        return _copy(ALWAYS)
    if not s.startswith(tuple(_AFDC_DAYS)):
        return None

    week: Schedule = [[] for _ in range(7)]
    for part in (p.strip() for p in s.split(";")):
        day, _, spans = part.partition(":")
        if day not in _AFDC_DAYS:
            return None
        intervals = []
        for span in (x.strip() for x in spans.split(",")):
            m = _AFDC_SPAN.match(span)
            if not m:
                return None
            intervals.append(_interval(_clock(m.group(1)), _clock(m.group(2))))
        week[_AFDC_DAYS.index(day)] = intervals
    return week


# --------------------------------------------------------------------------
# City of Vancouver washrooms
# --------------------------------------------------------------------------

def parse_vancouver(summer: str | None, winter: str | None) -> Schedule | None:
    """Only handles washrooms whose summer and winter hours are the same."""
    if not summer or summer != winter:
        return None
    s = summer.strip().lower()
    if s in ("24hrs - 24hrs", "24 hrs", "24 hours"):
        return _copy(ALWAYS)
    if s == "closed":
        return [[] for _ in range(7)]
    if s == "dawn to dusk":
        return [[[DAWN, DUSK]] for _ in range(7)]
    m = re.match(r"^(.+?)\s*-\s*(.+)$", s)
    if not m:
        return None
    start, end = _vancouver_time(m.group(1)), _vancouver_time(m.group(2))
    if start is None or end is None:
        return None
    return [[_interval(start, end)] for _ in range(7)]


def _vancouver_time(t: str) -> int | None:
    t = t.strip()
    if t in ("dawn", "dusk"):
        return SUN_EVENTS[t]
    if t == "midnight":
        return 1440
    if t == "noon":
        return 720
    m = re.match(r"^(\d{1,2})(?::(\d{2}))?\s*([ap]m)$", t)
    if not m:
        return None
    return _clock(f"{m.group(1)}:{m.group(2) or '00'}{m.group(3)}")


def _clock(t: str) -> int:
    """'6:30pm' -> 1110. '11:59pm' becomes 1439 (rounded to 1440 by _interval)."""
    t = t.replace(" ", "").lower()
    h, rest = t.split(":")
    minutes, ampm = int(rest[:2]), rest[2:]
    hour = int(h) % 12 + (12 if ampm == "pm" else 0)
    return hour * 60 + minutes


