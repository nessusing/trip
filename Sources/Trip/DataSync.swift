import Foundation

/// `manifest.json` on the `data` branch, written by `data/update.py`.
struct Manifest: Codable, Equatable, Sendable {
    let schema: Int
    let regions: [RegionEntry]
}

struct RegionEntry: Codable, Equatable, Sendable {
    let id: String
    let name: String
    /// Path of the region file, relative to the manifest.
    let file: String
    let generated: String
    let schema: Int
    /// Hash of the region file; a different value means there's a new version.
    let sha256: String
    let bytes: Int
    let count: Int
    /// Data sources used, e.g. ["afdc", "osm"]; matches `POI.source`.
    let sources: [String]
    let boundary: Boundary
}

/// A GeoJSON MultiPolygon: polygons → rings → [lon, lat] points.
struct Boundary: Codable, Equatable, Sendable {
    let type: String
    let coordinates: [[[[Double]]]]
}

enum SyncError: Error, Equatable {
    /// The published data needs a newer version of the app.
    case appTooOld
    case badFile(region: String)
}

/// Keeps a local copy of the published region files up to date.
///
/// Layout of `directory`: `manifest.json` lists the regions present locally
/// (same format as the remote one), and `regions/<id>.json` holds each file.
/// A region is only replaced once its new file has fully downloaded and
/// decoded, so a failed sync leaves the previous data in place.
struct RegionSync: Sendable {
    /// Newest region file format this app can read; see SCHEMA_VERSION in data/build.py.
    static let supportedSchema = 1
    static let remoteBase = URL(string: "https://raw.githubusercontent.com/nessusing/trip/data/")!

    let directory: URL
    var remoteBase: URL = Self.remoteBase
    /// Downloads a URL; injected so tests can run without a network.
    let fetch: @Sendable (URL) async throws -> Data

    struct Result: Equatable, Sendable {
        let manifest: Manifest
        /// True if any region file was added, replaced or removed.
        let changed: Bool
        /// Regions whose new version couldn't be downloaded (their old version is kept).
        let failed: [String]
    }

    func localManifest() -> Manifest? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")) else {
            return nil
        }
        return try? JSONDecoder().decode(Manifest.self, from: data)
    }

    func regionFile(_ id: String) -> URL {
        directory.appendingPathComponent("regions/\(id).json")
    }

    /// Every region file present locally.
    func loadAll() throws -> [POIFile] {
        try (localManifest()?.regions ?? []).map {
            try JSONDecoder().decode(POIFile.self, from: Data(contentsOf: regionFile($0.id)))
        }
    }

    func sync() async throws -> Result {
        let remote = try JSONDecoder().decode(
            Manifest.self, from: await fetch(remoteBase.appendingPathComponent("manifest.json"))
        )
        guard remote.schema <= Self.supportedSchema else { throw SyncError.appTooOld }

        let fm = FileManager.default
        try fm.createDirectory(at: directory.appendingPathComponent("regions"), withIntermediateDirectories: true)
        let local = Dictionary(uniqueKeysWithValues: (localManifest()?.regions ?? []).map { ($0.id, $0) })
        var kept: [RegionEntry] = []
        var changed = false
        var failed: [String] = []

        for entry in remote.regions where entry.schema <= Self.supportedSchema {
            if let have = local[entry.id], have.sha256 == entry.sha256,
               fm.fileExists(atPath: regionFile(entry.id).path) {
                kept.append(entry)
                continue
            }
            do {
                let data = try await fetch(remoteBase.appendingPathComponent(entry.file))
                // A truncated or corrupt download won't decode.
                guard data.count == entry.bytes,
                      (try? JSONDecoder().decode(POIFile.self, from: data)) != nil
                else { throw SyncError.badFile(region: entry.id) }
                try data.write(to: regionFile(entry.id), options: .atomic)
                kept.append(entry)
                changed = true
            } catch {
                failed.append(entry.id)
                if let have = local[entry.id] { kept.append(have) }
            }
        }

        // Regions no longer published are removed.
        let keptIDs = Set(kept.map(\.id))
        for id in local.keys where !keptIDs.contains(id) {
            try? fm.removeItem(at: regionFile(id))
            changed = true
        }

        let manifest = Manifest(schema: remote.schema, regions: kept.sorted { $0.id < $1.id })
        try JSONEncoder().encode(manifest).write(to: directory.appendingPathComponent("manifest.json"), options: .atomic)
        return Result(manifest: manifest, changed: changed, failed: failed)
    }
}
