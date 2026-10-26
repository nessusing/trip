import Foundation

/// A point in degrees. Plain doubles rather than CLLocationCoordinate2D so this
/// file builds on Linux, where the route logic is tested.
struct LatLon: Codable, Equatable, Sendable {
    var lat: Double
    var lon: Double
}

/// A route polyline with the distance along it to every point.
struct RouteLine: Codable, Equatable, Sendable {
    let points: [LatLon]
    /// Metres from the start to each point.
    let along: [Double]

    var length: Double { along.last ?? 0 }

    init(points: [LatLon]) {
        self.points = points
        var along = [0.0]
        for i in points.indices.dropFirst() {
            along.append(along[i - 1] + Self.distance(points[i - 1], points[i]))
        }
        self.along = points.isEmpty ? [] : along
    }

    struct Snap: Equatable {
        /// Metres along the route to the closest point.
        let progress: Double
        /// Metres from the given point to the route.
        let offRoute: Double
    }

    /// The point on the route closest to `p`.
    func snap(_ p: LatLon) -> Snap {
        snap(p, segments: 0..<max(points.count - 1, 0))
    }

    func snap<S: Sequence<Int>>(_ p: LatLon, segments: S) -> Snap {
        guard points.count > 1 else { return Snap(progress: 0, offRoute: points.first.map { Self.distance(p, $0) } ?? 0) }
        var best = Snap(progress: 0, offRoute: .infinity)
        let metresPerDegLon = 111_320 * cos(p.lat * .pi / 180)
        for i in segments {
            // Flat projection around p: plenty accurate at the scale of one segment.
            let a = points[i], b = points[i + 1]
            let ax = (a.lon - p.lon) * metresPerDegLon, ay = (a.lat - p.lat) * 110_540
            let bx = (b.lon - p.lon) * metresPerDegLon, by = (b.lat - p.lat) * 110_540
            let dx = bx - ax, dy = by - ay
            let len2 = dx * dx + dy * dy
            let t = len2 > 0 ? min(1, max(0, -(ax * dx + ay * dy) / len2)) : 0
            let x = ax + t * dx, y = ay + t * dy
            let d = (x * x + y * y).squareRoot()
            if d < best.offRoute {
                best = Snap(progress: along[i] + t * (along[i + 1] - along[i]), offRoute: d)
            }
        }
        return best
    }

    /// The point `progress` metres along the route, clamped to its ends.
    func point(at progress: Double) -> LatLon {
        guard let first = points.first else { return LatLon(lat: 0, lon: 0) }
        guard progress > 0 else { return first }
        guard progress < length else { return points[points.count - 1] }
        // First point at or past `progress`.
        var lo = 0, hi = along.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if along[mid] < progress { lo = mid + 1 } else { hi = mid }
        }
        let a = points[lo - 1], b = points[lo]
        let span = along[lo] - along[lo - 1]
        let t = span > 0 ? (progress - along[lo - 1]) / span : 0
        return LatLon(lat: a.lat + t * (b.lat - a.lat), lon: a.lon + t * (b.lon - a.lon))
    }

    /// Great-circle distance in metres.
    static func distance(_ a: LatLon, _ b: LatLon) -> Double {
        let lat1 = a.lat * .pi / 180, lat2 = b.lat * .pi / 180
        let dLat = lat2 - lat1
        let dLon = (b.lon - a.lon) * .pi / 180
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(lat1) * cos(lat2) * sin(dLon / 2) * sin(dLon / 2)
        return 6_371_000 * 2 * asin(min(1, h.squareRoot()))
    }
}

/// The POIs within `width` metres of a route, with where each one is along it.
/// Built once per route, off the main thread: checking every POI against every
/// segment would be far too slow, so segments are bucketed in a grid first.
struct Corridor: Sendable {
    struct Entry: Equatable, Sendable {
        let poi: POI
        let progress: Double
        let offRoute: Double
    }

    let width: Double
    /// Sorted by progress.
    let entries: [Entry]
    private let byID: [String: Entry]

    init(route: RouteLine, pois: [POI], width: Double = 5000) {
        self.width = width
        let cell = 0.05  // degrees, about 5.5 km north–south
        func key(_ lat: Double, _ lon: Double) -> Int64 {
            Int64((lat / cell).rounded(.down)) << 32 | Int64(Int32((lon / cell).rounded(.down)))
        }

        // Each segment goes in every cell its bounding box, grown by `width`, touches.
        var grid: [Int64: [Int]] = [:]
        let pad = width / 110_540
        for i in 0..<max(route.points.count - 1, 0) {
            let a = route.points[i], b = route.points[i + 1]
            let lonPad = pad / max(cos(a.lat * .pi / 180), 0.01)
            let lat0 = Int(((min(a.lat, b.lat) - pad) / cell).rounded(.down))
            let lat1 = Int(((max(a.lat, b.lat) + pad) / cell).rounded(.down))
            let lon0 = Int(((min(a.lon, b.lon) - lonPad) / cell).rounded(.down))
            let lon1 = Int(((max(a.lon, b.lon) + lonPad) / cell).rounded(.down))
            for y in lat0...lat1 {
                for x in lon0...lon1 {
                    grid[Int64(y) << 32 | Int64(Int32(x)), default: []].append(i)
                }
            }
        }

        var entries: [Entry] = []
        for poi in pois {
            guard let segments = grid[key(poi.lat, poi.lon)] else { continue }
            let snap = route.snap(LatLon(lat: poi.lat, lon: poi.lon), segments: segments)
            if snap.offRoute <= width {
                entries.append(Entry(poi: poi, progress: snap.progress, offRoute: snap.offRoute))
            }
        }
        self.entries = entries.sorted { $0.progress < $1.progress }
        self.byID = Dictionary(entries.map { ($0.poi.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    func entry(for id: String) -> Entry? { byID[id] }

    /// The first entry after `progress` within `maxOffRoute` of the route that passes `matches`.
    func next(after progress: Double, maxOffRoute: Double, where matches: (POI) -> Bool) -> Entry? {
        // Binary search for the first entry past `progress`, then scan forward.
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].progress <= progress { lo = mid + 1 } else { hi = mid }
        }
        return entries[lo...].first { $0.offRoute <= maxOffRoute && matches($0.poi) }
    }
}

extension Boundary {
    /// Whether `p` is inside the area: in some polygon's outer ring and none of its holes.
    func contains(_ p: LatLon) -> Bool {
        coordinates.contains { polygon in
            guard let outer = polygon.first, Self.ring(outer, contains: p) else { return false }
            return !polygon.dropFirst().contains { Self.ring($0, contains: p) }
        }
    }

    /// Even-odd ray casting; rings are [lon, lat] pairs.
    private static func ring(_ ring: [[Double]], contains p: LatLon) -> Bool {
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let (xi, yi, xj, yj) = (ring[i][0], ring[i][1], ring[j][0], ring[j][1])
            if (yi > p.lat) != (yj > p.lat), p.lon < (xj - xi) * (p.lat - yi) / (yj - yi) + xi {
                inside.toggle()
            }
            j = i
        }
        return inside
    }
}

extension RouteLine {
    /// Stretches of the route outside every boundary, as progress ranges in metres,
    /// checked every `step` metres.
    func uncovered(by boundaries: [Boundary], step: Double = 2000) -> [ClosedRange<Double>] {
        guard length > 0 else { return [] }
        var stretches: [ClosedRange<Double>] = []
        var start: Double?
        var s = 0.0
        while true {
            let covered = boundaries.contains { $0.contains(point(at: s)) }
            if !covered, start == nil { start = s }
            if covered, let from = start {
                stretches.append(from...s)
                start = nil
            }
            if s >= length { break }
            s = min(s + step, length)
        }
        if let from = start { stretches.append(from...length) }
        return stretches
    }
}
