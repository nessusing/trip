import Foundation

/// The shape of `pois.json`, produced by `data/build.py`.
struct POIFile: Decodable {
    let generated: String
    let region: String
    let pois: [POI]
}

struct POI: Decodable, Identifiable, Hashable {
    enum Kind: String, Decodable {
        case fuel, ev, restArea, toilet
        /// A café, library, mall etc. that is only included because it has a washroom.
        case venue
    }

    let id: String
    let kind: Kind
    let name: String?
    let lat: Double
    let lon: Double
    let address: String?
    /// Opening hours as the source wrote them.
    let hours: String?
    /// `hours` parsed into a weekly schedule; see `OpeningHours`. Nil if unparseable.
    let open: [[[Int]]]?
    /// For unnamed washrooms: the named park/facility it's in, and a nearby street.
    let place: String?
    let street: String?
    let source: String
    /// Venue subtype from OSM, e.g. "cafe" or "library"; "services" for service plazas.
    let sub: String?
    let toilet: ToiletInfo?
    let ev: EVInfo?
    let fuel: FuelInfo?
    let restArea: RestAreaInfo?

    static func == (a: POI, b: POI) -> Bool { a.id == b.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

struct ToiletInfo: Decodable, Hashable {
    enum Access: String, Decodable {
        case `public`, customers, unknown
    }

    enum Confidence: String, Decodable {
        case official, osm, inferred
    }

    let access: Access
    let confidence: Confidence
    let wheelchair: Bool?
    let changingTable: Bool?
    let fee: Bool?
}

struct EVInfo: Decodable, Hashable {
    let connectors: [String]?
    let maxKW: Double?
    let network: String?
    let dcFast: Int?
    let level2: Int?
    let pricing: String?
}

struct FuelInfo: Decodable, Hashable {
    let brand: String?
    let diesel: Bool?
    let shop: Bool?
}

struct RestAreaInfo: Decodable, Hashable {
    let highway: String?
    let direction: String?
    let toilets: Int?
    let toiletType: String?
    let yearRound: Bool?
    let trucks: Bool?
    let tables: Int?
}
