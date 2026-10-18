import CoreLocation
import SwiftUI

/// Everything the filter chips control.
struct Filters: Equatable {
    static let allConnectors = ["NACS", "CCS", "CHAdeMO", "J1772"]

    var categories: Set<Category>
    var publicToiletsOnly = false
    /// Hide places known to be closed right now. Places with unknown hours stay.
    var openNow = false
    var fastChargingOnly = false
    /// EV plug types to show; empty means any.
    var connectors: Set<String> = []
}

/// The four filter chips. A POI can match more than one: a gas station with a
/// washroom shows up under both Gas and Washrooms.
enum Category: String, CaseIterable, Identifiable {
    case fuel, ev, restArea, toilet

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fuel: "Gas"
        case .ev: "EV"
        case .restArea: "Rest areas"
        case .toilet: "Washrooms"
        }
    }

    var symbol: String {
        switch self {
        case .fuel: "fuelpump.fill"
        case .ev: "bolt.fill"
        case .restArea: "signpost.right.fill"
        case .toilet: "toilet.fill"
        }
    }

    var color: Color {
        switch self {
        case .fuel: .orange
        case .ev: .green
        case .restArea: .blue
        case .toilet: .teal
        }
    }
}

extension POI {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    /// The category that decides this POI's icon and colour.
    var primaryCategory: Category {
        switch kind {
        case .fuel: .fuel
        case .ev: .ev
        case .restArea: .restArea
        case .toilet, .venue: .toilet
        }
    }

    func matches(_ category: Category, _ filters: Filters) -> Bool {
        switch category {
        case .fuel:
            return kind == .fuel
        case .ev:
            guard kind == .ev else { return false }
            if filters.fastChargingOnly && !isFastCharger { return false }
            if !filters.connectors.isEmpty {
                return !filters.connectors.isDisjoint(with: ev?.connectors ?? [])
            }
            return true
        case .restArea:
            return kind == .restArea
        case .toilet:
            guard let toilet else { return false }
            return !filters.publicToiletsOnly || toilet.access == .public
        }
    }

    /// DC fast charging: CCS and CHAdeMO are always DC; Tesla/NACS only at Superchargers.
    var isFastCharger: Bool {
        guard let ev else { return false }
        return (ev.dcFast ?? 0) > 0
            || (ev.maxKW ?? 0) >= 50
            || ev.connectors?.contains(where: { $0 == "CCS" || $0 == "CHAdeMO" }) == true
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        switch kind {
        case .fuel: return "Gas station"
        case .ev: return "EV charger"
        case .restArea: return sub == "services" ? "Service area" : "Rest area"
        case .toilet:
            // Thousands of washrooms have no name; say where they are instead.
            if let location = place ?? street ?? address { return "Washroom · \(location)" }
            return "Public washroom"
        case .venue: return venueLabel ?? "Washroom"
        }
    }

    /// A short description of what kind of place this is.
    var kindLabel: String {
        switch kind {
        case .fuel: "Gas station"
        case .ev: "EV charger"
        case .restArea: sub == "services" ? "Service area" : "Rest area"
        case .toilet: "Washroom"
        case .venue: venueLabel ?? "Place with washroom"
        }
    }

    private var venueLabel: String? {
        guard let sub else { return nil }
        return switch sub {
        case "fast_food": "Fast food"
        case "community_centre": "Community centre"
        case "camp_site": "Campground"
        case "caravan_site": "RV park"
        case "information": "Visitor centre"
        case "department_store": "Department store"
        case "car_wash": "Car wash"
        default: sub.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    var symbol: String {
        guard kind == .venue else { return primaryCategory.symbol }
        return switch sub {
        case "cafe": "cup.and.saucer.fill"
        case "fast_food", "restaurant", "pub", "bar": "fork.knife"
        case "library": "books.vertical.fill"
        case "mall", "department_store", "supermarket", "convenience": "bag.fill"
        case "community_centre", "townhall": "building.2.fill"
        case "camp_site", "caravan_site": "tent.fill"
        case "information": "info.circle.fill"
        default: Category.toilet.symbol
        }
    }

    /// True when the washroom is only guessed from a brand or category rule.
    var isInferred: Bool { toilet?.confidence == .inferred && kind == .venue }

    var sourceLabel: String {
        switch source {
        case "osm": "OpenStreetMap"
        case "afdc": "AFDC / Natural Resources Canada"
        case "ocm": "Open Charge Map"
        case "vancouver": "City of Vancouver Open Data"
        case "databc": "BC Ministry of Transportation (DataBC)"
        default: source
        }
    }
}
