import CoreLocation
import Foundation
import Observation

struct NearbyPOI: Identifiable, Equatable {
    let poi: POI
    /// Metres from the search centre.
    let distance: Double
    /// Open or closed at query time; nil when the hours are unknown.
    let status: OpenStatus?

    var id: String { poi.id }
}

/// Holds every POI from the downloaded region files, keeps them up to date and
/// answers radius queries.
@MainActor
@Observable
final class POIStore {
    /// How often coming back to the app checks for new data.
    static let checkInterval: TimeInterval = 6 * 3600

    private(set) var pois: [POI] = []
    /// Regions present on the phone.
    private(set) var regions: [RegionEntry] = []
    private(set) var isSyncing = false
    private(set) var lastChecked: Date?
    /// Why the last check or load failed; nil once one succeeds.
    private(set) var syncError: String?
    /// True once local data has been read, so "no places" means none were downloaded.
    private(set) var loaded = false

    private let sync: RegionSync

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var directory = support.appendingPathComponent("Data", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Re-downloadable, so keep it out of iCloud backups.
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        sync = RegionSync(directory: directory) { url in
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalCacheData
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    /// Reads the regions already on the phone, then checks for newer ones.
    func load() async {
        await reload()
        loaded = true
        await checkForUpdates(force: true)
    }

    /// Downloads changed regions. Unless `force`, does nothing if the last check
    /// was recent.
    func checkForUpdates(force: Bool) async {
        guard !isSyncing else { return }
        if !force, let lastChecked, Date.now.timeIntervalSince(lastChecked) < Self.checkInterval { return }
        isSyncing = true
        defer { isSyncing = false }
        do {
            let result = try await sync.sync()
            lastChecked = .now
            syncError = result.failed.isEmpty
                ? nil
                : "Couldn't update \(result.failed.joined(separator: ", ").uppercased())."
            if result.changed { await reload() }
        } catch SyncError.appTooOld {
            syncError = "New data needs a newer version of the app."
        } catch {
            syncError = "Couldn't check for new data: \(error.localizedDescription)"
        }
    }

    private func reload() async {
        let sync = sync
        do {
            let (manifest, files) = try await Task.detached(priority: .userInitiated) {
                (sync.localManifest(), try sync.loadAll())
            }.value
            regions = manifest?.regions ?? []
            pois = files.flatMap(\.pois)
        } catch {
            syncError = "Couldn't read place data: \(error.localizedDescription)"
        }
    }

    /// POIs within `radiusKm` of `center` that pass `filters`, nearest first.
    func nearby(
        center: CLLocationCoordinate2D,
        radiusKm: Double,
        filters: Filters,
        now: Date = .now
    ) -> [NearbyPOI] {
        let radius = radiusKm * 1000
        // Cheap bounding-box test before the exact distance.
        let latDelta = radiusKm / 111.0
        let lonDelta = radiusKm / (111.0 * max(cos(center.latitude * .pi / 180), 0.01))

        var result: [NearbyPOI] = []
        for poi in pois {
            guard abs(poi.lat - center.latitude) <= latDelta,
                  abs(poi.lon - center.longitude) <= lonDelta,
                  filters.categories.contains(where: { poi.matches($0, filters) })
            else { continue }
            let d = Geo.distance(center, poi.coordinate)
            guard d <= radius else { continue }
            let status = poi.openStatus(at: now)
            if filters.openNow && status?.isOpen == false { continue }
            result.append(NearbyPOI(poi: poi, distance: d, status: status))
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
