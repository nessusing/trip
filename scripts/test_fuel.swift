// Tests for GasBuddyModel.swift that run on Linux. Run: scripts/test-swift.sh
import Foundation

var failures = 0

func check(_ condition: Bool, _ message: String, line: Int = #line) {
    if !condition {
        failures += 1
        print("FAIL (line \(line)): \(message)")
    }
}

let now = ISO8601DateFormatter().date(from: "2026-11-02T20:00:00Z")!

// A reply shaped like GasBuddy's, trimmed to the fields we ask for.
let reply = #"""
{"data":{"locationBySearchTerm":{"stations":{"cursor":{"next":"10"},"results":[
 {"id":"33462","name":"Petro-Canada","latitude":50.67374,"longitude":-120.3315,"priceUnit":"cents_per_liter",
  "address":{"line1":"411 10th Ave","locality":"Kamloops"},"brands":[{"name":"Petro-Canada"}],
  "hours":{"openingHours":"24/7"},
  "prices":[
   {"fuelProduct":"regular_gas","credit":{"price":185.9,"postedTime":"2026-11-02T16:45:10.644Z"},"cash":null},
   {"fuelProduct":"midgrade_gas","credit":{"price":0,"postedTime":null},"cash":null},
   {"fuelProduct":"premium_gas","credit":{"price":205.9,"postedTime":"2026-10-20T10:00:00Z"},"cash":null},
   {"fuelProduct":"diesel","credit":{"price":199.9,"postedTime":"2026-11-02T19:30:00Z"},"cash":{"price":197.9,"postedTime":"2026-11-02T19:30:00Z"}}]},
 {"id":"99","name":"Quilchena Ranch General Store","latitude":50.1,"longitude":-120.5,"priceUnit":"cents_per_liter",
  "address":{"line1":"6570 BC-5A","locality":"Merritt"},"brands":[],"hours":null,"prices":[]}
]}}}}
"""#
let page = try! GBPage.decode(Data(reply.utf8))
check(page.results.count == 2, "decoded \(page.results.count) stations")
check(page.cursor?.next == "10", "cursor")
let petro = page.results[0]
check(petro.brand == "Petro-Canada", "brand")
check(page.results[1].brand == nil, "empty brands → nil")

// Quotes.
let regular = petro.quote(.regular, now: now)
check(regular?.price == 185.9, "regular price")
check(regular?.text == "185.9¢/L", "regular text \(regular?.text ?? "nil")")
check(regular?.age(now: now) == "3h ago", "age \(regular?.age(now: now) ?? "nil")")
check(regular?.mapLabel(now: now) == "185.9¢", "fresh map label")
check(regular?.isStale(now: now) == false, "3h isn't stale")
check(regular?.cash == nil, "no cash price")
check(petro.quote(.midgrade, now: now) == nil, "price 0 means no price")
check(petro.quote(.premium, now: now) == nil, "13 days old is too old")
let diesel = petro.quote(.diesel, now: now)
check(diesel?.cashText == "cash 197.9¢/L", "cash shown when it differs: \(diesel?.cashText ?? "nil")")
check(diesel?.age(now: now) == "30m ago", "minutes")
check(FuelQuote.format(4.289, unit: "dollars_per_gallon") == "$4.29/gal", "US format")
let dayOld = FuelQuote(price: 1, unit: nil, posted: now.addingTimeInterval(-30 * 3600), cash: nil)
check(dayOld.isStale(now: now), "30h is stale")
check(dayOld.age(now: now) == "30h ago", "hours up to 2 days")
check(dayOld.mapLabel(now: now) == "$1.00 · 30h", "stale map label has the age: \(dayOld.mapLabel(now: now))")
check(FuelQuote(price: 1, unit: nil, posted: now.addingTimeInterval(-3 * 86400), cash: nil).age(now: now) == "3d ago", "days")

// Live-only place.
let place = petro.asPOI()
check(place.id == "gb:33462" && place.source == "gasbuddy" && place.kind == .fuel, "asPOI identity")
check(place.address == "411 10th Ave, Kamloops", "asPOI address")
check(place.open?.count == 7 && place.open?[0] == [[0, 1440]], "24/7 → open all week")
check(place.fuel?.diesel == true, "has diesel")
check(page.results[1].asPOI().open == nil, "unknown hours stay unknown")

// Normalising.
check(FuelMatcher.addressKey("1234 West Broadway, Vancouver") == "1234 w broadway", "address key")
check(FuelMatcher.addressKey("885 Water Avenue") == FuelMatcher.addressKey("885 Water Ave"), "avenue = ave")
check(FuelMatcher.addressKey("587 Old Hope-Princeton Hwy") == "587 old hope princeton hwy", "hyphen")
check(FuelMatcher.addressKey("12B Main St.") == "12 main st", "suffix letter and dot")
check(FuelMatcher.addressKey("#20 3435 Westsyde Rd") == nil, "unit prefix: no key")
check(FuelMatcher.addressKey("Trans-Canada Hwy") == nil, "no house number")
check(FuelMatcher.normalizedBrand("Petro-Canada") == "petrocanada", "brand letters")
check(FuelMatcher.normalizedBrand("Gas Station") == nil, "generic name")

// Matching.
func poi(_ id: String, _ lat: Double, _ lon: Double, brand: String? = nil, name: String? = nil, address: String? = nil) -> POI {
    var fields = [#""id":"\#(id)""#, #""kind":"fuel""#, #""lat":\#(lat)"#, #""lon":\#(lon)"#, #""source":"osm""#]
    if let name { fields.append(#""name":"\#(name)""#) }
    if let address { fields.append(#""address":"\#(address)""#) }
    if let brand { fields.append(#""fuel":{"brand":"\#(brand)"}"#) }
    return try! JSONDecoder().decode(POI.self, from: Data("{\(fields.joined(separator: ","))}".utf8))
}

func station(_ id: String, _ lat: Double, _ lon: Double, brand: String, line1: String? = nil) -> GBStation {
    let address = line1.map { #","address":{"line1":"\#($0)"}"# } ?? ""
    let json = #"{"id":"\#(id)","name":"\#(brand)","latitude":\#(lat),"longitude":\#(lon),"brands":[{"name":"\#(brand)"}]\#(address)}"#
    return try! JSONDecoder().decode(GBStation.self, from: Data(json.utf8))
}

let metre = 1 / 111_195.0  // degrees of latitude
let ours = [
    poi("o-noname", 49.0, -123.0),
    poi("o-shell", 49.01, -123.0, brand: "Shell"),
    poi("o-esso", 49.02, -123.0, brand: "Esso"),
    poi("o-addr", 49.03, -123.0, name: "Chevron", address: "1955 Powell Street, Vancouver"),
    poi("o-busy", 49.04, -123.0, brand: "Co-op"),
]
let theirs = [
    station("g-near", 49.0 + 20 * metre, -123.0, brand: "Husky"),          // 20 m, any brand
    station("g-shell", 49.01 + 80 * metre, -123.0, brand: "Shell"),        // 80 m, same brand
    station("g-other", 49.02 + 80 * metre, -123.0, brand: "Chevron"),      // 80 m, other brand
    station("g-addr", 49.03 + 400 * metre, -123.0, brand: "Chevron", line1: "1955 Powell St"),  // address
    station("g-close", 49.04 + 10 * metre, -123.0, brand: "Co-op"),        // two claim o-busy,
    station("g-far", 49.04 + 60 * metre, -123.0, brand: "Co-op"),          // the closer wins
    station("g-alone", 48.5, -123.0, brand: "Shell"),                      // nothing near
]
let pairs = FuelMatcher.match(theirs, to: ours)
check(pairs["g-near"] == "o-noname", "within 30 m whatever the brand")
check(pairs["g-shell"] == "o-shell", "same brand within 100 m")
check(pairs["g-other"] == nil, "different brand at 80 m stays separate")
check(pairs["g-addr"] == "o-addr", "same street address 400 m apart")
check(pairs["g-close"] == "o-busy" && pairs["g-far"] == nil, "closest claim wins: \(pairs)")
check(pairs["g-alone"] == nil, "nothing nearby")

if failures > 0 {
    print("\(failures) fuel test(s) failed")
    exit(1)
}
print("fuel tests passed")
