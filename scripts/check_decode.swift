// Decodes pois.json with the app's own model on Linux (no simulator needed).
// Run: scripts/test-swift.sh FILE, or build it with scripts/build-decoder.sh
import Foundation

let url = URL(fileURLWithPath: CommandLine.arguments[1])
let file = try JSONDecoder().decode(POIFile.self, from: Data(contentsOf: url))
var kinds: [String: Int] = [:]
for poi in file.pois { kinds[poi.kind.rawValue, default: 0] += 1 }
print("Decoded \(file.pois.count) POIs (generated \(file.generated))")
for (kind, n) in kinds.sorted(by: { $0.key < $1.key }) { print("  \(kind): \(n)") }
