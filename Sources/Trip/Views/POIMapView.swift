import MapKit
import SwiftUI

/// Asks the map to move. A new `id` triggers the move even if the coordinate is unchanged.
struct CameraRequest: Equatable {
    let id = UUID()
    let center: CLLocationCoordinate2D
    let radiusKm: Double

    static func == (a: CameraRequest, b: CameraRequest) -> Bool { a.id == b.id }
}

/// MKMapView wrapped for SwiftUI. SwiftUI's own `Map` can't cluster markers,
/// and BC has thousands of them.
struct POIMapView: UIViewRepresentable {
    /// Maximum markers on the map at once; the list still shows everything.
    static let markerLimit = 1500

    let items: [NearbyPOI]
    let searchCenter: CLLocationCoordinate2D
    let radiusKm: Double
    let camera: CameraRequest?
    @Binding var selected: POI?
    /// Called when the user finishes moving the map.
    let onCenterChange: (CLLocationCoordinate2D) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsUserLocation = true
        map.pointOfInterestFilter = .excludingAll
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: Coordinator.markerID)
        map.register(MKMarkerAnnotationView.self,
                     forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        if let camera, camera.id != coordinator.lastCameraID {
            coordinator.lastCameraID = camera.id
            let span = camera.radiusKm * 2000 * 1.15
            map.setRegion(
                MKCoordinateRegion(center: camera.center, latitudinalMeters: span, longitudinalMeters: span),
                animated: coordinator.hasPositioned
            )
            coordinator.hasPositioned = true
        }

        coordinator.updateCircle(on: map, center: searchCenter, radiusKm: radiusKm)
        coordinator.updateAnnotations(on: map, items: Array(items.prefix(Self.markerLimit)))
        coordinator.updateSelection(on: map, selected: selected)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        static let markerID = "poi"

        var parent: POIMapView
        var lastCameraID: UUID?
        var hasPositioned = false
        private var annotations: [String: POIAnnotation] = [:]
        private var circle: MKCircle?
        private var circleKey: (Double, Double, Double)?

        init(_ parent: POIMapView) {
            self.parent = parent
        }

        func updateCircle(on map: MKMapView, center: CLLocationCoordinate2D, radiusKm: Double) {
            let key = (center.latitude, center.longitude, radiusKm)
            if let circleKey, circleKey == key { return }
            circleKey = key
            if let circle { map.removeOverlay(circle) }
            let new = MKCircle(center: center, radius: radiusKm * 1000)
            map.addOverlay(new)
            circle = new
        }

        func updateAnnotations(on map: MKMapView, items: [NearbyPOI]) {
            let wanted = Set(items.map(\.id))
            let stale = annotations.filter { !wanted.contains($0.key) }
            map.removeAnnotations(Array(stale.values))
            stale.keys.forEach { annotations.removeValue(forKey: $0) }

            let added = items.filter { annotations[$0.id] == nil }.map { POIAnnotation(poi: $0.poi) }
            added.forEach { annotations[$0.poi.id] = $0 }
            map.addAnnotations(added)
        }

        func updateSelection(on map: MKMapView, selected: POI?) {
            let current = map.selectedAnnotations.compactMap { $0 as? POIAnnotation }.first
            guard current?.poi.id != selected?.id else { return }
            if let selected, let annotation = annotations[selected.id] {
                map.selectAnnotation(annotation, animated: true)
            } else if let current {
                map.deselectAnnotation(current, animated: true)
            }
        }

        // MARK: MKMapViewDelegate

        // These callbacks can fire synchronously inside updateUIView (setRegion,
        // selectAnnotation), so state changes are deferred to the next run loop.

        func mapView(_ map: MKMapView, regionDidChangeAnimated animated: Bool) {
            let center = map.centerCoordinate
            DispatchQueue.main.async { self.parent.onCenterChange(center) }
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if let cluster = annotation as? MKClusterAnnotation {
                let view = map.dequeueReusableAnnotationView(
                    withIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier, for: cluster
                ) as? MKMarkerAnnotationView
                view?.markerTintColor = .darkGray
                return view
            }
            guard let annotation = annotation as? POIAnnotation else { return nil }
            let view = map.dequeueReusableAnnotationView(withIdentifier: Self.markerID, for: annotation)
                as? MKMarkerAnnotationView
            let poi = annotation.poi
            view?.clusteringIdentifier = "poi"
            view?.glyphImage = UIImage(systemName: poi.symbol)
            // Guessed washrooms are drawn faded so they read as "maybe".
            let color = UIColor(poi.primaryCategory.color)
            view?.markerTintColor = poi.isInferred ? color.withAlphaComponent(0.45) : color
            view?.displayPriority = poi.isInferred ? .defaultLow : .defaultHigh
            return view
        }

        func mapView(_ map: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6)
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.05)
            renderer.lineWidth = 1.5
            renderer.lineDashPattern = [6, 4]
            return renderer
        }

        func mapView(_ map: MKMapView, didSelect annotation: MKAnnotation) {
            if let cluster = annotation as? MKClusterAnnotation {
                map.deselectAnnotation(cluster, animated: false)
                map.showAnnotations(cluster.memberAnnotations, animated: true)
            } else if let annotation = annotation as? POIAnnotation {
                let poi = annotation.poi
                DispatchQueue.main.async {
                    if self.parent.selected?.id != poi.id { self.parent.selected = poi }
                }
            }
        }

        func mapView(_ map: MKMapView, didDeselect annotation: MKAnnotation) {
            guard let annotation = annotation as? POIAnnotation else { return }
            let id = annotation.poi.id
            DispatchQueue.main.async {
                if self.parent.selected?.id == id { self.parent.selected = nil }
            }
        }
    }
}

final class POIAnnotation: NSObject, MKAnnotation {
    let poi: POI
    let coordinate: CLLocationCoordinate2D

    init(poi: POI) {
        self.poi = poi
        self.coordinate = poi.coordinate
    }

    var title: String? { poi.displayName }
}
