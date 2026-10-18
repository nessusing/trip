import CoreLocation
import SwiftUI

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

    func matches(_ category: Category, publicToiletsOnly: Bool) -> Bool {
        switch category {
        case .fuel: kind == .fuel
        case .ev: kind == .ev
        case .restArea: kind == .restArea
        case .toilet:
            if let toilet {
                !publicToiletsOnly || toilet.access == .public
            } else {
                false
            }
        }
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        switch kind {
        case .fuel: return "Gas station"
        case .ev: return "EV charger"
        case .restArea: return sub == "services" ? "Service area" : "Rest area"
        case .toilet: return "Public washroom"
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
