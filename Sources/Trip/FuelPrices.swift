import CoreLocation
import Foundation
import Network
import Observation

/// Live gas prices from GasBuddy, kept in memory only (prices change within hours).
/// Asks for prices when the search centre settles somewhere new, matches GasBuddy's
/// stations to ours, and keeps the ones we don't have as live-only places.
@MainActor
@Observable
final class FuelPrices {
    /// Don't ask again for a spot fetched this recently…
    static let cacheFor: TimeInterval = 15 * 60
    /// …within this distance (at most; `min(this, radius / 4)`).
    static let moveThreshold = 1000.0
    /// The centre must sit still this long before we ask (the "let go" of a drag).
    static let settle: Duration = .seconds(1)

    let client = GasBuddyClient()
    private(set) var online = true

    /// Every station seen this session, by GasBuddy id.
    private(set) var stations: [String: GBStation] = [:]
    /// Our POI id → GasBuddy id.
    private(set) var matchedPOI: [String: String] = [:]
    /// Stations GasBuddy has and we don't, as places.
    private(set) var extras: [POI] = []
    /// Our POI id → GasBuddy's weekly hours, for matched stations where they could be read.
    private(set) var hours: [String: [[[Int]]]] = [:]
    private(set) var loading = false

    @ObservationIgnored private var fetches: [(center: CLLocationCoordinate2D, at: Date)] = []
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var pois: [POI] = []
    @ObservationIgnored private let monitor = NWPathMonitor()

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in self?.online = online }
        }
        monitor.start(queue: .main)
    }

    /// Our stations to match against; call when the downloaded places change.
    func update(pois: [POI]) {
        self.pois = pois.filter { $0.kind == .fuel }
        rematch()
    }

    /// The search centre moved (map, route handle or slider). Asks once it settles.
    func centerChanged(_ center: CLLocationCoordinate2D, radiusKm: Double) {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(for: Self.settle)
            guard !Task.isCancelled else { return }
            let threshold = min(Self.moveThreshold, radiusKm * 1000 / 4)
            await fetch(at: center, unlessWithin: threshold)
        }
    }

    /// A gas station's page opened: make sure it has a price if GasBuddy has one.
    func detailOpened(_ poi: POI) {
        guard poi.kind == .fuel, station(for: poi) == nil else { return }
        Task { await fetch(at: poi.coordinate, unlessWithin: 300) }
    }

    func quote(for poi: POI, grade: FuelGrade, now: Date = .now) -> FuelQuote? {
        station(for: poi)?.quote(grade, now: now)
    }

    /// The GasBuddy station behind one of our places, if we have one.
    func station(for poi: POI) -> GBStation? {
        if poi.id.hasPrefix(GBStation.poiPrefix) {
            return stations[String(poi.id.dropFirst(GBStation.poiPrefix.count))]
        }
        return matchedPOI[poi.id].flatMap { stations[$0] }
    }

    /// True if prices were looked up around here; a gas station there without one has none.
    func covered(_ coordinate: CLLocationCoordinate2D) -> Bool {
        fetches.contains { Geo.distance($0.center, coordinate) < 3000 }
    }

    // MARK: - Private

    private func fetch(at center: CLLocationCoordinate2D, unlessWithin threshold: Double) async {
        let now = Date.now
        fetches.removeAll { now.timeIntervalSince($0.at) > Self.cacheFor }
        if fetches.contains(where: { Geo.distance($0.center, center) < threshold }) { return }
        guard online else { return }

        // Over our own rate limit: try again when allowed, if nothing newer came in.
        let wait = client.wait()
        if client.isPaused() { return }
        if wait > 0 {
            pending?.cancel()
            pending = Task {
                try? await Task.sleep(for: .seconds(wait + 0.1))
                guard !Task.isCancelled else { return }
                await fetch(at: center, unlessWithin: threshold)
            }
            return
        }

        loading = true
        defer { loading = false }
        do {
            let found = try await client.stations(lat: center.latitude, lng: center.longitude)
            fetches.append((center, .now))
            for station in found { stations[station.id] = station }
            rematch()
        } catch {
            // The client records the error and any pause; the UI reads them from there.
        }
    }

    private func rematch() {
        let all = Array(stations.values)
        let pairs = FuelMatcher.match(all, to: pois)
        matchedPOI = Dictionary(pairs.map { ($0.value, $0.key) }, uniquingKeysWith: { a, _ in a })
        extras = all.filter { pairs[$0.id] == nil }.map { $0.asPOI() }
        hours = matchedPOI.compactMapValues { stations[$0]?.schedule }
    }
}
