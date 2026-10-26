import CoreLocation
import MapKit
import Observation

/// A place picked in the search box.
struct Destination: Codable, Equatable, Sendable {
    let name: String
    let point: LatLon
}

/// One driving route option from MKDirections.
struct PlannedRoute: Codable, Equatable, Sendable {
    let line: RouteLine
    /// Seconds, as estimated by Apple.
    let expectedTime: Double
    /// Apple's short description, e.g. "BC-99 N".
    let name: String
}

/// Where a place is relative to me along the route.
struct AlongRoute: Equatable {
    /// Metres along the route from my position; negative once passed.
    let ahead: Double
    /// Rough driving time to it.
    let seconds: Double
}

/// The destination and route, and the search centre moving along it.
///
/// With a route, the search circle sits `progress` metres along it instead of
/// following the map. The trip is saved so it's still there after a restart or
/// without signal.
@MainActor
@Observable
final class TripPlanner {
    /// Places further than this from the route only get a straight-line distance.
    static let corridorWidth: Double = 5000
    /// "Next washroom" etc. only considers places this close to the route.
    static let nextMaxOffRoute: Double = 2000
    /// Further than this from the route, I'm not "on" it (e.g. not at the start yet).
    static let onRouteDistance: Double = 3000

    private(set) var destination: Destination?
    private(set) var routes: [PlannedRoute] = []
    private(set) var selectedRoute = 0
    /// Search centre, in metres along the selected route.
    private(set) var progress: Double = 0
    /// My position along the selected route; nil without a fix or when far from it.
    private(set) var myProgress: Double?
    private(set) var corridor: Corridor?
    private(set) var isRouting = false
    /// A one-off message for the route header, e.g. a routing error.
    var notice: String?
    /// Names of provinces/states the route passes through without data.
    private(set) var missingRegions: [String] = []
    private(set) var hasGaps = false
    /// True when no part of the route has data.
    private(set) var noCoverage = false

    @ObservationIgnored private var pois: [POI] = []
    @ObservationIgnored private var boundaries: [Boundary] = []
    @ObservationIgnored private var corridorTask: Task<Void, Never>?
    @ObservationIgnored private var coverageTask: Task<Void, Never>?

    var route: PlannedRoute? { routes.indices.contains(selectedRoute) ? routes[selectedRoute] : nil }

    var searchPoint: CLLocationCoordinate2D? {
        route.map { $0.line.point(at: progress).coordinate }
    }

    /// The slider's range: from me (or the start) to the end.
    var progressRange: ClosedRange<Double> {
        let end = route?.line.length ?? 0
        return min(myProgress ?? 0, end)...end
    }

    init() {
        restore()
    }

    // MARK: Destination and route

    func setDestination(_ destination: Destination) {
        self.destination = destination
        routes = []
        corridor = nil
        clearCoverage()
        notice = nil
        save()
    }

    func clear() {
        destination = nil
        routes = []
        corridor = nil
        myProgress = nil
        clearCoverage()
        notice = nil
        save()
    }

    func planRoute(from start: CLLocationCoordinate2D?) async {
        guard let destination else { return }
        guard let start else {
            notice = "Turn on location to plan a route from where you are."
            return
        }
        isRouting = true
        defer { isRouting = false }
        notice = nil
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: start))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: destination.point.coordinate))
        request.transportType = .automobile
        request.requestsAlternateRoutes = true
        do {
            let response = try await MKDirections(request: request).calculate()
            routes = response.routes.prefix(3).map { route in
                let polyline = route.polyline
                let mapPoints = polyline.points()
                let points = (0..<polyline.pointCount).map { mapPoints[$0].coordinate.latLon }
                return PlannedRoute(line: RouteLine(points: points), expectedTime: route.expectedTravelTime,
                                    name: route.name)
            }
            selectRoute(0, location: start)
        } catch {
            notice = "Couldn't find a driving route: \(error.localizedDescription)"
        }
    }

    func selectRoute(_ index: Int, location: CLLocationCoordinate2D?) {
        guard routes.indices.contains(index) else { return }
        selectedRoute = index
        myProgress = nil
        progress = 0
        if let location { updateLocation(location) }
        rebuild()
        save()
    }

    // MARK: Moving the search centre

    func setProgress(_ value: Double) {
        progress = min(max(value, progressRange.lowerBound), progressRange.upperBound)
        notice = nil
    }

    /// Moves the search centre to the point on the route nearest `coordinate`.
    func scrub(to coordinate: CLLocationCoordinate2D) {
        guard let route else { return }
        setProgress(route.line.snap(coordinate.latLon).progress)
    }

    func updateLocation(_ coordinate: CLLocationCoordinate2D) {
        guard let route else { return }
        let snap = route.line.snap(coordinate.latLon)
        myProgress = snap.offRoute <= Self.onRouteDistance ? snap.progress : nil
        // Once I've passed the search centre, it moves along with me.
        if let myProgress, progress < myProgress {
            progress = myProgress
            save()
        }
    }

    /// Jumps the search centre to the next place ahead of it that passes `matches`.
    /// Returns that place, or nil (and sets `notice`) if there's none.
    func jumpToNext(_ category: Category, matches: (POI) -> Bool) -> POI? {
        guard let corridor else { return nil }
        guard let entry = corridor.next(after: progress + 1, maxOffRoute: Self.nextMaxOffRoute, where: matches) else {
            notice = "No \(category.singular) ahead within \(Int(Self.nextMaxOffRoute / 1000)) km of the route."
            return nil
        }
        progress = entry.progress
        notice = nil
        save()
        return entry.poi
    }

    func along(_ poi: POI) -> AlongRoute? {
        guard let route, let entry = corridor?.entry(for: poi.id) else { return nil }
        return along(progress: entry.progress, route: route)
    }

    /// Distance and time from me to the search centre.
    var searchPointAhead: AlongRoute? {
        route.map { along(progress: progress, route: $0) }
    }

    private func along(progress: Double, route: PlannedRoute) -> AlongRoute {
        let ahead = progress - (myProgress ?? 0)
        let length = max(route.line.length, 1)
        return AlongRoute(ahead: ahead, seconds: ahead / length * route.expectedTime)
    }

    // MARK: Derived data

    /// Call when the places or downloaded regions change.
    func update(pois: [POI], boundaries: [Boundary]) {
        self.pois = pois
        self.boundaries = boundaries
        rebuild()
    }

    private func rebuild() {
        corridorTask?.cancel()
        coverageTask?.cancel()
        guard let route else { return }
        let pois = pois, boundaries = boundaries, width = Self.corridorWidth
        corridorTask = Task {
            let corridor = await Task.detached(priority: .userInitiated) {
                Corridor(route: route.line, pois: pois, width: width)
            }.value
            if !Task.isCancelled { self.corridor = corridor }
        }
        // Before any region has loaded, everything would look uncovered.
        guard !boundaries.isEmpty else { return }
        coverageTask = Task {
            let gaps = await Task.detached(priority: .utility) {
                route.line.uncovered(by: boundaries)
            }.value
            guard !Task.isCancelled else { return }
            let uncovered = gaps.reduce(0) { $0 + $1.upperBound - $1.lowerBound }
            hasGaps = !gaps.isEmpty
            noCoverage = uncovered >= route.line.length - 1
            missingRegions = []
            missingRegions = await regionNames(of: gaps, on: route.line)
        }
    }

    private func clearCoverage() {
        corridorTask?.cancel()
        coverageTask?.cancel()
        hasGaps = false
        noCoverage = false
        missingRegions = []
    }

    /// Province/state names for the uncovered stretches. Apple allows only a
    /// few lookups at a time, so each stretch is sampled once or twice.
    private func regionNames(of gaps: [ClosedRange<Double>], on line: RouteLine) async -> [String] {
        var names: [String] = []
        for gap in gaps.prefix(5) {
            for fraction in gap.upperBound - gap.lowerBound > 100_000 ? [0.25, 0.75] : [0.5] {
                let point = line.point(at: gap.lowerBound + fraction * (gap.upperBound - gap.lowerBound))
                let location = CLLocation(latitude: point.lat, longitude: point.lon)
                guard let placemark = try? await CLGeocoder().reverseGeocodeLocation(location).first,
                      let name = placemark.administrativeArea ?? placemark.country
                else { continue }
                if !names.contains(name) { names.append(name) }
            }
        }
        return names
    }

    // MARK: Saving

    private struct Saved: Codable {
        let destination: Destination?
        let routes: [PlannedRoute]
        let selectedRoute: Int
        let progress: Double
    }

    private static var saveURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("trip.json")
    }

    private func save() {
        let saved = Saved(destination: destination, routes: routes, selectedRoute: selectedRoute, progress: progress)
        try? JSONEncoder().encode(saved).write(to: Self.saveURL, options: .atomic)
    }

    private func restore() {
        guard let data = try? Data(contentsOf: Self.saveURL),
              let saved = try? JSONDecoder().decode(Saved.self, from: data)
        else { return }
        destination = saved.destination
        routes = saved.routes
        selectedRoute = saved.selectedRoute
        progress = saved.progress
    }
}

extension LatLon {
    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: lat, longitude: lon) }
}

extension CLLocationCoordinate2D {
    var latLon: LatLon { LatLon(lat: latitude, lon: longitude) }
}

extension Category {
    /// For messages: "No washroom ahead…".
    var singular: String {
        switch self {
        case .fuel: "gas station"
        case .ev: "EV charger"
        case .restArea: "rest area"
        case .toilet: "washroom"
        }
    }
}
