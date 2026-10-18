import UIKit

/// Hands navigation off to Google Maps, falling back to Apple Maps.
@MainActor
enum MapsLauncher {
    static func navigate(to poi: POI) {
        let destination = "\(poi.lat),\(poi.lon)"
        // Requires `comgooglemaps` in LSApplicationQueriesSchemes (Info.plist).
        if let google = URL(string: "comgooglemaps://?daddr=\(destination)&directionsmode=driving"),
           UIApplication.shared.canOpenURL(google) {
            UIApplication.shared.open(google)
            return
        }
        if let apple = URL(string: "https://maps.apple.com/?daddr=\(destination)&dirflg=d") {
            UIApplication.shared.open(apple)
        }
    }
}
