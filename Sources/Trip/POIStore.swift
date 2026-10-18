import CoreLocation
import Foundation
import Observation

struct NearbyPOI: Identifiable, Hashable {
    let poi: POI
    /// Metres from the search centre.
    let distance: Double

    var id: String { poi.id }
}

/// Holds every POI from the bundled `pois.json` and answers radius queries.
@MainActor
@Observable
final class POIStore {
    private(set) var pois: [POI] = []
    private(set) var generated: String?
    private(set) var loadError: String?

    func load() async {
        guard pois.isEmpty else { return }
        do {
            let file = try await Task.detached(priority: .userInitiated) {
                guard let url = Bundle.module.url(forResource: "pois", withExtension: "json") else {
                    throw CocoaError(.fileNoSuchFile)
                }
                return try JSONDecoder().decode(POIFile.self, from: Data(contentsOf: url))
            }.value
            pois = file.pois
            generated = file.generated
        } catch {
            loadError = "Couldn't load place data: \(error.localizedDescription)"
        }
    }

    /// POIs within `radiusKm` of `center` matching any of `categories`, nearest first.
    func nearby(
        center: CLLocationCoordinate2D,
        radiusKm: Double,
        categories: Set<Category>,
        publicToiletsOnly: Bool
    ) -> [NearbyPOI] {
        let radius = radiusKm * 1000
        // Cheap bounding-box test before the exact distance.
        let latDelta = radiusKm / 111.0
        let lonDelta = radiusKm / (111.0 * max(cos(center.latitude * .pi / 180), 0.01))

        var result: [NearbyPOI] = []
        for poi in pois {
            guard abs(poi.lat - center.latitude) <= latDelta,
                  abs(poi.lon - center.longitude) <= lonDelta,
                  categories.contains(where: { poi.matches($0, publicToiletsOnly: publicToiletsOnly) })
            else { continue }
            let d = Geo.distance(center, poi.coordinate)
            if d <= radius {
                result.append(NearbyPOI(poi: poi, distance: d))
            }
        }
        return result.sorted { $0.distance < $1.distance }
    }
}

enum Geo {
    static let downtownVancouver = CLLocationCoordinate2D(latitude: 49.2827, longitude: -123.1207)

    /// Great-circle distance in metres.
    static func distance(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> Double {
        let lat1 = a.latitude * .pi / 180, lat2 = b.latitude * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.longitude - a.longitude) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * asin(min(1, sqrt(h)))
    }

    /// "100 m", "500 m", "1 km", "25 km".
    static func format(radius km: Double) -> String {
        km < 1 ? "\(Int((km * 1000).rounded())) m" : "\(Int(km.rounded())) km"
    }

    static func format(distance metres: Double) -> String {
        if metres < 1000 {
            return "\(Int((metres / 10).rounded()) * 10) m"
        }
        let km = metres / 1000
        return km < 10 ? String(format: "%.1f km", km) : "\(Int(km.rounded())) km"
    }
}
