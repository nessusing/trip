import Foundation

// GasBuddy data and how it is matched to our gas stations. Foundation only, so
// scripts/test-swift.sh can run it on Linux. The network side is in GasBuddy.swift.

/// One station from GasBuddy's GraphQL `locationBySearchTerm`. Only the fields Trip uses.
struct GBStation: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let latitude: Double
    let longitude: Double
    /// `cents_per_liter` in Canada, dollars per gallon in the US.
    let priceUnit: String?
    let address: Address?
    let brands: [Brand]?
    let prices: [FuelPrice]?
    let hours: Hours?

    struct Address: Decodable, Sendable {
        let line1: String?
        let locality: String?
    }

    struct Brand: Decodable, Sendable {
        let name: String?
    }

    struct Hours: Decodable, Sendable {
        /// "24/7", or free text.
        let openingHours: String?
    }

    struct FuelPrice: Decodable, Sendable {
        let fuelProduct: String
        let credit: Report?
        let cash: Report?
    }

    struct Report: Decodable, Sendable {
        /// 0 means "no price", not free.
        let price: Double?
        /// When a user reported it (RFC 3339), not when we fetched it.
        let postedTime: String?
    }

    var brand: String? { brands?.first?.name.flatMap { $0.isEmpty ? nil : $0 } }
}

/// The page of stations inside a GraphQL reply.
struct GBPage: Decodable, Sendable {
    let cursor: Cursor?
    let results: [GBStation]

    struct Cursor: Decodable, Sendable {
        let next: String?
    }

    /// Unwraps `{"data": {"locationBySearchTerm": {"stations": …}}}`.
    static func decode(_ payload: Data) throws -> GBPage {
        struct Envelope: Decodable {
            let data: DataField?
            struct DataField: Decodable { let locationBySearchTerm: Location? }
            struct Location: Decodable { let stations: GBPage? }
        }
        guard let page = try JSONDecoder().decode(Envelope.self, from: payload).data?.locationBySearchTerm?.stations
        else { throw DecodingError.valueNotFound(GBPage.self, .init(codingPath: [], debugDescription: "no stations")) }
        return page
    }
}

/// The fuel grades the app shows, in display order.
enum FuelGrade: String, CaseIterable, Identifiable, Sendable {
    case regular = "regular_gas"
    case midgrade = "midgrade_gas"
    case premium = "premium_gas"
    case diesel
    case e85

    var id: String { rawValue }

    var label: String {
        switch self {
        case .regular: "Regular"
        case .midgrade: "Mid-grade"
        case .premium: "Premium"
        case .diesel: "Diesel"
        case .e85: "E85"
        }
    }
}

/// A price as the app shows it.
struct FuelQuote: Equatable, Sendable {
    let price: Double
    /// `cents_per_liter`, or anything else for dollars per gallon.
    let unit: String?
    /// When it was reported.
    let posted: Date
    /// Only when it differs from `price` (rare in Canada).
    let cash: Double?

    /// Older than this is shown faded; older than `tooOld` isn't shown.
    static let stale: TimeInterval = 24 * 3600
    static let tooOld: TimeInterval = 7 * 24 * 3600

    /// "178.9¢/L" or "$4.29/gal", in the local convention, no conversion.
    static func format(_ price: Double, unit: String?) -> String {
        unit == "cents_per_liter" ? String(format: "%.1f¢/L", price) : String(format: "$%.2f/gal", price)
    }

    var text: String { Self.format(price, unit: unit) }
    /// For map labels: "185.9¢" or "$4.29".
    var shortText: String {
        unit == "cents_per_liter" ? String(format: "%.1f¢", price) : String(format: "$%.2f", price)
    }
    var cashText: String? { cash.map { "cash " + Self.format($0, unit: unit) } }

    func isStale(now: Date) -> Bool { now.timeIntervalSince(posted) > Self.stale }

    /// "12m ago", "5h ago", "3d ago".
    func age(now: Date) -> String { compactAge(now: now) + " ago" }

    /// "12m", "5h", "3d".
    func compactAge(now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(posted) / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }

    /// The label under a gas station's map marker; the age only once it's stale.
    func mapLabel(now: Date) -> String {
        isStale(now: now) ? "\(shortText) · \(compactAge(now: now))" : shortText
    }
}

extension GBStation {
    /// The credit price for a grade; nil if there is none or it is older than a week.
    func quote(_ grade: FuelGrade, now: Date) -> FuelQuote? {
        guard let entry = prices?.first(where: { $0.fuelProduct == grade.rawValue }),
              let credit = entry.credit, let price = credit.price, price > 0,
              let posted = credit.postedTime.flatMap(Self.parseDate),
              now.timeIntervalSince(posted) <= FuelQuote.tooOld
        else { return nil }
        let cash = entry.cash?.price.flatMap { $0 > 0 && abs($0 - price) > 0.001 ? $0 : nil }
        return FuelQuote(price: price, unit: priceUnit, posted: posted, cash: cash)
    }

    static func parseDate(_ text: String) -> Date? {
        // Formatters aren't Sendable; making them per call is cheap at this volume.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    /// A gas station GasBuddy knows and OpenStreetMap doesn't, shown as a live-only place.
    func asPOI() -> POI {
        let allDay = [[0, 1440]]
        let isAllDay = hours?.openingHours?.trimmingCharacters(in: .whitespaces) == "24/7"
        let place = [address?.line1, address?.locality]
            .compactMap { $0?.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return POI(
            id: Self.poiPrefix + id,
            kind: .fuel,
            name: brand ?? name,
            lat: latitude,
            lon: longitude,
            address: place.isEmpty ? nil : place.joined(separator: ", "),
            hours: isAllDay ? "24 hours" : nil,
            open: isAllDay ? Array(repeating: allDay, count: 7) : nil,
            place: nil,
            street: nil,
            source: "gasbuddy",
            sub: nil,
            toilet: nil,
            ev: nil,
            fuel: FuelInfo(
                brand: brand,
                diesel: prices?.contains { $0.fuelProduct == FuelGrade.diesel.rawValue } == true ? true : nil,
                shop: nil
            ),
            restArea: nil
        )
    }

    static let poiPrefix = "gb:"
}

/// Pairs GasBuddy stations with our (OpenStreetMap) gas stations.
enum FuelMatcher {
    /// Same brand this close counts as the same station.
    static let brandRadius = 100.0
    /// This close counts whatever the brand (OSM often has none, or "Gas Station").
    static let anyRadius = 30.0
    /// How far apart two places with the same street address may be.
    static let addressRadius = 1000.0

    /// GasBuddy station id → POI id. Each POI gets at most one station, the closest.
    static func match(_ stations: [GBStation], to pois: [POI]) -> [String: String] {
        let fuel = pois.filter { $0.kind == .fuel }
        var best: [String: (station: String, metres: Double)] = [:]  // POI id → closest claim
        for station in stations {
            guard let (poi, metres) = candidate(for: station, in: fuel) else { continue }
            if let current = best[poi.id], current.metres <= metres { continue }
            best[poi.id] = (station.id, metres)
        }
        var result: [String: String] = [:]
        for (poi, claim) in best { result[claim.station] = poi }
        return result
    }

    private static func candidate(for station: GBStation, in pois: [POI]) -> (POI, Double)? {
        let here = LatLon(lat: station.latitude, lon: station.longitude)
        // Cheap box (~1 km) before exact distances.
        let latDelta = addressRadius / 111_000
        let lonDelta = latDelta / max(cos(station.latitude * .pi / 180), 0.01)
        let near = pois.compactMap { poi -> (POI, Double)? in
            guard abs(poi.lat - station.latitude) <= latDelta, abs(poi.lon - station.longitude) <= lonDelta
            else { return nil }
            return (poi, RouteLine.distance(here, LatLon(lat: poi.lat, lon: poi.lon)))
        }.sorted { $0.1 < $1.1 }

        if let key = addressKey(station.address?.line1),
           let hit = near.first(where: { addressKey($0.0.address) == key }) {
            return hit
        }
        let brands = [station.brand, station.name].compactMap(normalizedBrand)
        if let hit = near.first(where: { $0.1 <= brandRadius && sameBrand(brands, $0.0) }) {
            return hit
        }
        if let nearest = near.first, nearest.1 <= anyRadius { return nearest }
        return nil
    }

    private static func sameBrand(_ brands: [String], _ poi: POI) -> Bool {
        let theirs = [poi.fuel?.brand, poi.name].compactMap(normalizedBrand)
        return brands.contains { mine in theirs.contains { $0.contains(mine) || mine.contains($0) } }
    }

    /// "Petro-Canada" → "petrocanada"; nil for empty or generic names.
    static func normalizedBrand(_ text: String?) -> String? {
        guard let text else { return nil }
        let letters = String(text.lowercased().unicodeScalars.filter(CharacterSet.alphanumerics.contains))
        return letters.count < 3 || letters == "gasstation" ? nil : letters
    }

    private static let abbreviations = [
        "street": "st", "avenue": "ave", "road": "rd", "highway": "hwy", "drive": "dr",
        "boulevard": "blvd", "crescent": "cres", "place": "pl", "court": "ct", "parkway": "pkwy",
        "west": "w", "east": "e", "north": "n", "south": "s",
    ]

    /// "1234 West Broadway, Vancouver" → "1234 w broadway". Nil without a house number.
    static func addressKey(_ address: String?) -> String? {
        guard let first = address?.split(separator: ",").first else { return nil }
        let words = first.lowercased()
            .replacingOccurrences(of: ".", with: "")
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .map(String.init)
        guard let number = words.first, let digit = number.first, digit.isNumber, words.count > 1 else { return nil }
        let houseNumber = number.prefix { $0.isNumber }
        let street = words.dropFirst().map { abbreviations[$0] ?? $0 }
        return ([String(houseNumber)] + street).joined(separator: " ")
    }
}

extension FuelGrade {
    /// The grade whose price the list shows, remembered between launches.
    static let storageKey = "fuelGrade"
}
