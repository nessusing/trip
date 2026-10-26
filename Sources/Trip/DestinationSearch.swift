import MapKit
import Observation

/// Address and place suggestions for the search box, from Apple Maps.
@MainActor
@Observable
final class DestinationSearch: NSObject, MKLocalSearchCompleterDelegate {
    var query = "" {
        didSet {
            if query.isEmpty { results = [] } else { completer.queryFragment = query }
        }
    }
    private(set) var results: [MKLocalSearchCompletion] = []

    @ObservationIgnored private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
    }

    /// Prefer results near here.
    func bias(to center: CLLocationCoordinate2D) {
        completer.region = MKCoordinateRegion(center: center, latitudinalMeters: 200_000, longitudinalMeters: 200_000)
    }

    /// Looks up where a suggestion actually is.
    func resolve(_ completion: MKLocalSearchCompletion) async -> Destination? {
        let response = try? await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start()
        guard let item = response?.mapItems.first else { return nil }
        return Destination(name: item.name ?? completion.title, point: item.placemark.coordinate.latLon)
    }

    // MapKit calls these on the main thread, with our own `completer`.
    nonisolated func completerDidUpdateResults(_: MKLocalSearchCompleter) {
        MainActor.assumeIsolated {
            results = query.isEmpty ? [] : completer.results
        }
    }

    nonisolated func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        MainActor.assumeIsolated { results = [] }
    }
}
