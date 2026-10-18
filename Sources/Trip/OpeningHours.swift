import Foundation

// Foundation only, so scripts/test-swift.sh can run it on Linux.

enum OpenStatus: Equatable {
    case alwaysOpen
    /// `until` is nil when the place stays open beyond the week we look at.
    case open(until: Date?)
    /// `opensAt` is nil when it doesn't open again within the next week.
    case closed(opensAt: Date?)

    var isOpen: Bool {
        if case .closed = self { false } else { true }
    }

    /// "Open 24 hours", "Open until 10:00 PM", "Closed · opens Tue 7:00 AM".
    func label(now: Date, calendar: Calendar = .current) -> String {
        switch self {
        case .alwaysOpen:
            return "Open 24 hours"
        case .open(let until):
            guard let until else { return "Open" }
            return "Open until \(Self.format(until, now: now, calendar: calendar))"
        case .closed(let opensAt):
            guard let opensAt else { return "Closed" }
            return "Closed · opens \(Self.format(opensAt, now: now, calendar: calendar))"
        }
    }

    private static func format(_ date: Date, now: Date, calendar: Calendar) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = calendar.timeZone
        guard !calendar.isDate(date, inSameDayAs: now) else { return date.formatted(style) }
        // Something closing at exactly midnight tonight reads better as a time.
        if let midnight = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)),
           date == midnight {
            return date.formatted(style)
        }
        return date.formatted(style.weekday(.abbreviated))
    }
}

/// Evaluates the weekly schedules produced by `data/hours.py`.
///
/// A schedule has 7 days, Monday first. Each day holds [start, end] pairs in
/// minutes after local midnight; `end` may pass 1440 for spans that run past
/// midnight. Negative values are sun events, resolved for the place's location.
enum OpeningHours {
    static let dawn = -1, dusk = -2, sunrise = -3, sunset = -4

    static func status(
        _ week: [[[Int]]],
        at now: Date,
        latitude: Double,
        longitude: Double,
        calendar: Calendar = .current
    ) -> OpenStatus? {
        guard week.count == 7 else { return nil }
        if week.allSatisfy({ $0 == [[0, 1440]] }) { return .alwaysOpen }

        let today = calendar.startOfDay(for: now)
        var intervals: [(start: Date, end: Date)] = []
        // Yesterday too, for spans that run past midnight into today.
        for offset in -1...7 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            // Calendar weekdays are Sunday = 1 ... Saturday = 7.
            let index = (calendar.component(.weekday, from: day) + 5) % 7
            for span in week[index] where span.count == 2 {
                guard let s = minutes(span[0], on: day, latitude, longitude, calendar),
                      let e = minutes(span[1], on: day, latitude, longitude, calendar),
                      let start = wallClock(s, on: day, calendar),
                      let end = wallClock(e, on: day, calendar),
                      end > start
                else { continue }
                intervals.append((start, end))
            }
        }

        // Join touching intervals so "Mo 18:00-24:00; Tu 00:00-02:00" is one span.
        var merged: [(start: Date, end: Date)] = []
        for interval in intervals.sorted(by: { $0.start < $1.start }) {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1].end = max(last.end, interval.end)
            } else {
                merged.append(interval)
            }
        }

        if let current = merged.first(where: { $0.start <= now && now < $0.end }) {
            let horizon = calendar.date(byAdding: .day, value: 7, to: today) ?? now
            return .open(until: current.end >= horizon ? nil : current.end)
        }
        return .closed(opensAt: merged.first(where: { $0.start > now })?.start)
    }

    /// Resolves a sun sentinel to minutes after midnight; plain minutes pass through.
    private static func minutes(
        _ value: Int, on day: Date, _ latitude: Double, _ longitude: Double, _ calendar: Calendar
    ) -> Int? {
        let event: Sun.Event
        switch value {
        case dawn: event = .dawn
        case dusk: event = .dusk
        case sunrise: event = .sunrise
        case sunset: event = .sunset
        case ..<0: return nil
        default: return value
        }
        return Sun.minutes(event, on: day, latitude: latitude, longitude: longitude, calendar: calendar)
    }

    /// The moment `minutes` after midnight on `day`, on the wall clock (DST-safe).
    private static func wallClock(_ minutes: Int, on day: Date, _ calendar: Calendar) -> Date? {
        guard let base = calendar.date(byAdding: .day, value: minutes / 1440, to: day) else { return nil }
        let rest = minutes % 1440
        return calendar.date(bySettingHour: rest / 60, minute: rest % 60, second: 0, of: base)
    }
}

extension POI {
    func openStatus(at now: Date, calendar: Calendar = .current) -> OpenStatus? {
        guard let open else { return nil }
        return OpeningHours.status(open, at: now, latitude: lat, longitude: lon, calendar: calendar)
    }
}

/// Sunrise, sunset and civil twilight, using the NOAA "Almanac for Computers" method.
/// Accurate to a minute or two, which is plenty for park washroom hours.
enum Sun {
    enum Event {
        case dawn, sunrise, sunset, dusk

        var rising: Bool { self == .dawn || self == .sunrise }

        /// Sun's zenith angle at the event, in degrees.
        var zenith: Double {
            switch self {
            case .sunrise, .sunset: 90.833
            case .dawn, .dusk: 96 // civil twilight
            }
        }
    }

    /// Local minutes after midnight, or nil if the event doesn't happen that day.
    static func minutes(
        _ event: Event, on day: Date, latitude: Double, longitude: Double, calendar: Calendar
    ) -> Int? {
        guard let dayOfYear = calendar.ordinality(of: .day, in: .year, for: day) else { return nil }
        let rad = Double.pi / 180
        let lngHour = longitude / 15
        let t = Double(dayOfYear) + ((event.rising ? 6 : 18) - lngHour) / 24

        let m = 0.9856 * t - 3.289
        let l = normalize(m + 1.916 * sin(m * rad) + 0.020 * sin(2 * m * rad) + 282.634, 360)
        var ra = normalize(atan(0.91764 * tan(l * rad)) / rad, 360)
        ra += floor(l / 90) * 90 - floor(ra / 90) * 90
        ra /= 15

        let sinDec = 0.39782 * sin(l * rad)
        let cosDec = cos(asin(sinDec))
        let cosH = (cos(event.zenith * rad) - sinDec * sin(latitude * rad)) / (cosDec * cos(latitude * rad))
        guard (-1...1).contains(cosH) else { return nil }

        let h = (event.rising ? 360 - acos(cosH) / rad : acos(cosH) / rad) / 15
        let localMeanTime = h + ra - 0.06571 * t - 6.622
        let utc = normalize(localMeanTime - lngHour, 24)

        let noon = calendar.date(bySettingHour: 12, minute: 0, second: 0, of: day) ?? day
        let offset = Double(calendar.timeZone.secondsFromGMT(for: noon)) / 3600
        let local = normalize(utc + offset, 24)
        return Int((local * 60).rounded())
    }

    private static func normalize(_ value: Double, _ range: Double) -> Double {
        let r = value.truncatingRemainder(dividingBy: range)
        return r < 0 ? r + range : r
    }
}
