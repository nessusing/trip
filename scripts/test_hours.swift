// Tests for OpeningHours.swift that run on Linux. Run: scripts/test-swift.sh
import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

var calendar = Calendar(identifier: .gregorian)
calendar.timeZone = TimeZone(identifier: "America/Vancouver")!

func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int = 0, _ mi: Int = 0) -> Date {
    calendar.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
}

func status(_ week: [[[Int]]], _ now: Date) -> OpenStatus? {
    OpeningHours.status(week, at: now, latitude: 49.28, longitude: -123.12, calendar: calendar)
}

let weekdays9to5: [[[Int]]] = [[[540, 1020]], [[540, 1020]], [[540, 1020]], [[540, 1020]], [[540, 1020]], [], []]

// 2026-10-21 is a Wednesday.
check(status(weekdays9to5, date(2026, 10, 21, 10)) == .open(until: date(2026, 10, 21, 17)), "open midweek")
check(status(weekdays9to5, date(2026, 10, 21, 18)) == .closed(opensAt: date(2026, 10, 22, 9)), "closed evening")
check(status(weekdays9to5, date(2026, 10, 24, 12)) == .closed(opensAt: date(2026, 10, 26, 9)), "closed weekend")

let always = Array(repeating: [[0, 1440]], count: 7)
check(status(always, date(2026, 10, 21, 3)) == .alwaysOpen, "24/7")

// Friday 18:00 to 02:00 Saturday.
var lateFriday: [[[Int]]] = Array(repeating: [], count: 7)
lateFriday[4] = [[1080, 1560]]
check(status(lateFriday, date(2026, 10, 24, 1)) == .open(until: date(2026, 10, 24, 2)), "past midnight from yesterday")

// Monday 18:00-24:00 then Tuesday 00:00-02:00 join into one span.
var joined: [[[Int]]] = Array(repeating: [], count: 7)
joined[0] = [[1080, 1440]]
joined[1] = [[0, 120]]
check(status(joined, date(2026, 10, 19, 23)) == .open(until: date(2026, 10, 20, 2)), "touching spans merge")

let closedAllWeek: [[[Int]]] = Array(repeating: [], count: 7)
check(status(closedAllWeek, date(2026, 10, 21, 12)) == .closed(opensAt: nil), "never opens")

// Dawn to dusk.
let dawnDusk = Array(repeating: [[OpeningHours.dawn, OpeningHours.dusk]], count: 7)
check(status(dawnDusk, date(2026, 6, 21, 12))?.isOpen == true, "dawn-dusk open at noon")
check(status(dawnDusk, date(2026, 6, 21, 23, 30))?.isOpen == false, "dawn-dusk closed at night")
check(status(dawnDusk, date(2026, 12, 21, 17, 30))?.isOpen == false, "dawn-dusk closed on a winter evening")

// Sun times for Vancouver (published: Jun 21 sunrise 5:07, sunset 21:21 PDT;
// Dec 21 sunrise 8:05, sunset 16:16 PST).
func sun(_ event: Sun.Event, _ day: Date) -> Int {
    Sun.minutes(event, on: day, latitude: 49.28, longitude: -123.12, calendar: calendar) ?? -999
}
check(abs(sun(.sunrise, date(2026, 6, 21)) - (5 * 60 + 7)) <= 4, "June sunrise \(sun(.sunrise, date(2026, 6, 21)))")
check(abs(sun(.sunset, date(2026, 6, 21)) - (21 * 60 + 21)) <= 4, "June sunset \(sun(.sunset, date(2026, 6, 21)))")
check(abs(sun(.sunrise, date(2026, 12, 21)) - (8 * 60 + 5)) <= 4, "December sunrise \(sun(.sunrise, date(2026, 12, 21)))")
check(abs(sun(.sunset, date(2026, 12, 21)) - (16 * 60 + 16)) <= 4, "December sunset \(sun(.sunset, date(2026, 12, 21)))")
check(sun(.dawn, date(2026, 6, 21)) < sun(.sunrise, date(2026, 6, 21)), "dawn before sunrise")
check(sun(.dusk, date(2026, 6, 21)) > sun(.sunset, date(2026, 6, 21)), "dusk after sunset")

// Labels.
let now = date(2026, 10, 21, 10)
check(OpenStatus.alwaysOpen.label(now: now, calendar: calendar) == "Open 24 hours", "always label")
let openLabel = OpenStatus.open(until: date(2026, 10, 21, 17)).label(now: now, calendar: calendar)
check(openLabel.hasPrefix("Open until 5") && !openLabel.contains("Wed"), "same-day label: \(openLabel)")
let closedLabel = OpenStatus.closed(opensAt: date(2026, 10, 22, 9)).label(now: now, calendar: calendar)
check(closedLabel.hasPrefix("Closed · opens Thu"), "next-day label: \(closedLabel)")
let midnightLabel = OpenStatus.open(until: date(2026, 10, 22, 0)).label(now: now, calendar: calendar)
check(!midnightLabel.contains("Thu"), "midnight label: \(midnightLabel)")

if failures == 0 {
    print("All hours tests passed")
} else {
    print("\(failures) failure(s)")
    exit(1)
}
