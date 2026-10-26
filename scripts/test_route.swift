// Tests for RouteMath.swift that run on Linux. Run: scripts/test-swift.sh
import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool { abs(a - b) <= tolerance }

func poi(_ id: String, _ lat: Double, _ lon: Double, kind: String = "fuel") -> POI {
    let json = #"{"id":"\#(id)","kind":"\#(kind)","lat":\#(lat),"lon":\#(lon),"source":"osm"}"#
    return try! JSONDecoder().decode(POI.self, from: Data(json.utf8))
}

// A route due north from 49°N to 50°N along -123°, then east to -122°.
let route = RouteLine(points: [
    LatLon(lat: 49, lon: -123), LatLon(lat: 49.5, lon: -123), LatLon(lat: 50, lon: -123),
    LatLon(lat: 50, lon: -122),
])
let northLeg = 111_195.0  // 1° of latitude
let eastLeg = 71_474.0    // 1° of longitude at 50°N
check(near(route.length, northLeg + eastLeg, 200), "length \(route.length)")

// Snapping.
let beside = route.snap(LatLon(lat: 49.25, lon: -122.99))
check(near(beside.progress, northLeg / 4, 100), "snap progress \(beside.progress)")
check(near(beside.offRoute, 727, 20), "snap off-route \(beside.offRoute)")
let pastEnd = route.snap(LatLon(lat: 50, lon: -121.9))
check(near(pastEnd.progress, route.length, 1), "snap past end clamps to end")

// Points along the route.
let mid = route.point(at: northLeg / 2)
check(near(mid.lat, 49.5, 0.001) && near(mid.lon, -123, 0.0001), "point at half the north leg")
check(route.point(at: -5) == route.points[0], "clamps before start")
check(route.point(at: route.length + 5) == route.points[3], "clamps after end")
let onEastLeg = route.point(at: northLeg + eastLeg / 2)
check(near(onEastLeg.lat, 50, 0.0001) && near(onEastLeg.lon, -122.5, 0.001), "point on east leg")

// Corridor.
let pois = [
    poi("a", 49.25, -122.99),             // 0.7 km off, 28 km along
    poi("b", 49.75, -122.9, kind: "toilet"), // 7 km off: outside a 5 km corridor
    poi("c", 50.01, -122.5),              // 1.1 km off, on the east leg
    poi("d", 49.6, -123.02, kind: "toilet"), // 1.4 km off
    poi("e", 45, -100),                   // nowhere near
]
let corridor = Corridor(route: route, pois: pois)
check(corridor.entries.map(\.poi.id) == ["a", "d", "c"], "corridor order \(corridor.entries.map(\.poi.id))")
check(corridor.entry(for: "b") == nil && corridor.entry(for: "e") == nil, "far POIs excluded")
check(corridor.next(after: 0, maxOffRoute: 2000) { _ in true }?.poi.id == "a", "next from start")
check(corridor.next(after: corridor.entry(for: "a")!.progress, maxOffRoute: 2000) { _ in true }?.poi.id == "d",
      "next is strictly after")
check(corridor.next(after: 0, maxOffRoute: 2000) { $0.kind == .toilet }?.poi.id == "d", "next toilet")
check(corridor.next(after: 0, maxOffRoute: 1000) { $0.kind == .toilet } == nil, "next respects max off-route")

// Coverage: a box covering the north leg only, with a hole around 49.5°N.
let box = Boundary(type: "MultiPolygon", coordinates: [[
    [[-123.5, 48.9], [-122.8, 48.9], [-122.8, 49.9], [-123.5, 49.9], [-123.5, 48.9]],
    [[-123.1, 49.45], [-122.9, 49.45], [-122.9, 49.55], [-123.1, 49.55], [-123.1, 49.45]],
]])
check(box.contains(LatLon(lat: 49.2, lon: -123)), "inside box")
check(!box.contains(LatLon(lat: 49.5, lon: -123)), "inside hole")
check(!box.contains(LatLon(lat: 50, lon: -122.5)), "outside box")
let gaps = route.uncovered(by: [box], step: 1000)
check(gaps.count == 2, "two gaps: the hole and the end, got \(gaps)")
if gaps.count == 2 {
    check(near(gaps[0].lowerBound, 0.45 * northLeg, 1500) && near(gaps[0].upperBound, 0.55 * northLeg, 1500), "hole gap \(gaps[0])")
    check(near(gaps[1].lowerBound, 0.9 * northLeg, 1500) && gaps[1].upperBound == route.length, "end gap \(gaps[1])")
}
check(route.uncovered(by: []).first == 0...route.length, "no data: all uncovered")

// Speed at real scale: a 10,000-point route and 26,000 POIs.
var points: [LatLon] = []
for i in 0..<10_000 {
    let t = Double(i) / 10_000
    points.append(LatLon(lat: 49 + 2 * t, lon: -123 + 5 * t + 0.05 * sin(t * 200)))
}
let long = RouteLine(points: points)
var many: [POI] = []
var rng = SystemRandomNumberGenerator()
for i in 0..<26_000 {
    many.append(poi("p\(i)", Double.random(in: 48.5...51.5, using: &rng), Double.random(in: -124...(-117), using: &rng)))
}
let started = Date()
let big = Corridor(route: long, pois: many)
let elapsed = Date().timeIntervalSince(started)
// Debug builds on CI are slow; this only catches an accidental all-pairs search (minutes).
check(elapsed < 10, "corridor build took \(elapsed) s")
print("Corridor: \(big.entries.count) of \(many.count) POIs near a \(Int(long.length / 1000)) km route in \(String(format: "%.2f", elapsed)) s")

if failures > 0 {
    print("\(failures) route test(s) failed")
    exit(1)
}
print("All route tests passed")
