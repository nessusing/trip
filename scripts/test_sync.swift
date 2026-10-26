// Tests for DataSync.swift that run on Linux. Run: scripts/test-swift.sh
import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

let base = URL(string: "https://example.test/data/")!

func regionFile(_ id: String, pois: Int, generated: String) -> Data {
    let poi = #"{"id":"osm:n1","kind":"toilet","name":null,"lat":49.0,"lon":-123.0,"source":"osm"}"#
    let list = Array(repeating: poi, count: pois).joined(separator: ",")
    return Data(#"{"schema":1,"id":"\#(id)","region":"\#(id)","generated":"\#(generated)","sources":["osm"],"pois":[\#(list)]}"#.utf8)
}

func entry(_ id: String, _ data: Data, hash: String, schema: Int = 1) -> String {
    #"{"id":"\#(id)","name":"\#(id)","file":"regions/\#(id).json","generated":"2026-10-25T00:00:00Z","schema":\#(schema),"sha256":"\#(hash)","bytes":\#(data.count),"count":1,"sources":["osm"],"boundary":{"type":"MultiPolygon","coordinates":[[[[-123,49],[-122,49],[-122,50],[-123,49]]]]}}"#
}

/// A fake data branch: files by path, and a log of what was downloaded.
final class Server: @unchecked Sendable {
    var files: [String: Data] = [:]
    var downloads: [String] = []
    var offline = false

    func publish(_ regions: [(String, Data, String, Int)], schema: Int = 1) {
        files = [:]
        for (id, data, _, _) in regions { files["data/regions/\(id).json"] = data }
        let entries = regions.map { entry($0.0, $0.1, hash: $0.2, schema: $0.3) }.joined(separator: ",")
        files["data/manifest.json"] = Data(#"{"schema":\#(schema),"regions":[\#(entries)]}"#.utf8)
    }

    func fetch(_ url: URL) throws -> Data {
        let path = String(url.path.dropFirst())
        if offline { throw URLError(.notConnectedToInternet) }
        downloads.append(path)
        guard let data = files[path] else { throw URLError(.fileDoesNotExist) }
        return data
    }
}

let dir = FileManager.default.temporaryDirectory.appendingPathComponent("trip-sync-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: dir) }
let server = Server()
let sync = RegionSync(directory: dir, remoteBase: base, fetch: { try server.fetch($0) })

let bc1 = regionFile("bc", pois: 2, generated: "2026-10-22T00:00:00Z")
let wa1 = regionFile("wa", pois: 3, generated: "2026-10-22T00:00:00Z")

// First sync downloads everything.
server.publish([("bc", bc1, "h-bc1", 1), ("wa", wa1, "h-wa1", 1)])
var result = try await sync.sync()
check(result.changed && result.failed.isEmpty, "first sync changes")
check(result.manifest.regions.map(\.id) == ["bc", "wa"], "both regions kept")
check(try sync.loadAll().map(\.pois.count) == [2, 3], "files load")

// Nothing new: only the manifest is fetched.
server.downloads = []
result = try await sync.sync()
check(!result.changed, "unchanged sync")
check(server.downloads == ["data/manifest.json"], "only manifest fetched, got \(server.downloads)")

// One region updated.
let bc2 = regionFile("bc", pois: 4, generated: "2026-10-25T00:00:00Z")
server.publish([("bc", bc2, "h-bc2", 1), ("wa", wa1, "h-wa1", 1)])
server.downloads = []
result = try await sync.sync()
check(result.changed, "update changes")
check(server.downloads == ["data/manifest.json", "data/regions/bc.json"], "only bc fetched, got \(server.downloads)")
check(try sync.loadAll().map(\.pois.count) == [4, 3], "bc replaced")

// A corrupt download keeps the old version and reports it.
var truncated = regionFile("bc", pois: 5, generated: "2026-10-28T00:00:00Z")
server.publish([("bc", truncated, "h-bc3", 1), ("wa", wa1, "h-wa1", 1)])
truncated.removeLast(10)
server.files["data/regions/bc.json"] = truncated
result = try await sync.sync()
check(result.failed == ["bc"], "corrupt bc reported")
check(result.manifest.regions.first?.sha256 == "h-bc2", "old bc entry kept")
check(try sync.loadAll().map(\.pois.count) == [4, 3], "old bc file kept")

// A region dropped from the manifest is removed locally.
server.publish([("wa", wa1, "h-wa1", 1)])
result = try await sync.sync()
check(result.changed && result.manifest.regions.map(\.id) == ["wa"], "bc removed")
check(!FileManager.default.fileExists(atPath: sync.regionFile("bc").path), "bc file deleted")

// Offline: the error surfaces and local data is untouched.
server.offline = true
do {
    _ = try await sync.sync()
    check(false, "offline should throw")
} catch {}
check(try sync.loadAll().map(\.pois.count) == [3], "offline keeps data")
server.offline = false

// Newer formats are skipped rather than misread.
server.publish([("wa", wa1, "h-wa1", 1)], schema: 2)
do {
    _ = try await sync.sync()
    check(false, "schema 2 should throw")
} catch let error as SyncError {
    check(error == .appTooOld, "appTooOld")
}
server.publish([("wa", wa1, "h-wa1", 1), ("or", wa1, "h-or", 2)])
result = try await sync.sync()
check(result.manifest.regions.map(\.id) == ["wa"], "region with newer schema skipped")

// The real manifest format, as update.py writes it, decodes.
if let path = CommandLine.arguments.dropFirst().first {
    let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    check(!manifest.regions.isEmpty, "real manifest has regions")
}

if failures > 0 {
    print("\(failures) sync test(s) failed")
    exit(1)
}
print("All sync tests passed")
