import MapKit
import SwiftUI

/// Asks the map to move. A new `id` triggers the move even if the target is unchanged.
struct CameraRequest: Equatable {
    enum Target {
        /// Fit a search circle into view.
        case circle(CLLocationCoordinate2D, radiusKm: Double)
        /// Put this point under the search centre, keeping the zoom.
        case follow(CLLocationCoordinate2D)
        /// Fit all these points into view, e.g. a route.
        case fit([CLLocationCoordinate2D])
    }

    let id = UUID()
    let target: Target
    /// False for moves that follow a finger, where animating would lag behind.
    var animated = true

    init(_ target: Target, animated: Bool = true) {
        self.target = target
        self.animated = animated
    }

    init(center: CLLocationCoordinate2D, radiusKm: Double) {
        self.target = .circle(center, radiusKm: radiusKm)
    }

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
    /// Screen edges covered by other UI. The search centre is the middle of the rest.
    let obscured: UIEdgeInsets
    let destination: Destination?
    let routes: [PlannedRoute]
    let selectedRoute: Int
    /// In route mode, where the draggable search-centre handle sits.
    let scrubPoint: CLLocationCoordinate2D?
    @Binding var selected: POI?
    /// Called when the user finishes moving the map.
    let onCenterChange: (CLLocationCoordinate2D) -> Void
    /// Called continuously while the handle is dragged, with the finger's position.
    let onScrub: (CLLocationCoordinate2D) -> Void

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
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: Coordinator.destinationID)
        map.register(ScrubHandleView.self, forAnnotationViewWithReuseIdentifier: Coordinator.scrubID)
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self

        // Moves the Apple logo, Legal link and compass out from under our UI.
        if map.layoutMargins != obscured { map.layoutMargins = obscured }

        if let camera, camera.id != coordinator.lastCameraID {
            coordinator.lastCameraID = camera.id
            coordinator.move(map, to: camera)
        }

        coordinator.updateRoutes(on: map, routes: routes, selected: selectedRoute)
        coordinator.updateCircle(on: map, center: searchCenter, radiusKm: radiusKm)
        coordinator.updateDestination(on: map, destination: destination)
        coordinator.updateScrubHandle(on: map, at: scrubPoint)
        coordinator.updateAnnotations(on: map, items: Array(items.prefix(Self.markerLimit)))
        coordinator.updateSelection(on: map, selected: selected)
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        static let markerID = "poi"
        static let destinationID = "destination"
        static let scrubID = "scrub"

        var parent: POIMapView
        var lastCameraID: UUID?
        private var hasPositioned = false
        /// Whether MapKit fits a rect inside the map's `layoutMargins` (which we set
        /// to the obscured edges) or inside the whole view. Learned on the first move.
        private var rectsFitInMargins: Bool?
        private var annotations: [String: POIAnnotation] = [:]
        private var circle: MKCircle?
        private var circleKey: (Double, Double, Double)?
        private var routeOverlays: [RoutePolyline] = []
        private var routesKey: [Double] = []
        private var destinationAnnotation: DestinationAnnotation?
        private var scrubAnnotation: ScrubAnnotation?

        init(_ parent: POIMapView) {
            self.parent = parent
        }

        /// Fits the search circle into the unobscured part of the map.
        func move(_ map: MKMapView, to camera: CameraRequest, attempt: Int = 0) {
            // Before the first layout the map has no size to fit into; retry shortly.
            guard map.bounds.height > parent.obscured.top + parent.obscured.bottom + 50 else {
                if attempt < 20 {
                    DispatchQueue.main.async { self.move(map, to: camera, attempt: attempt + 1) }
                }
                return
            }
            let animated = hasPositioned && camera.animated
            switch camera.target {
            case .circle(let center, let radiusKm):
                let circle = MKCircle(center: center, radius: radiusKm * 1000)
                show(circle.boundingMapRect, on: map, animated: animated)
            case .fit(let coordinates):
                let line = MKPolyline(coordinates: coordinates, count: coordinates.count)
                show(line.boundingMapRect, on: map, animated: animated)
            case .follow(let coordinate):
                // Shift the map so `coordinate` lands under the search point.
                let at = map.convert(coordinate, toPointTo: map)
                let target = searchPoint(in: map)
                let center = CGPoint(x: map.bounds.midX + at.x - target.x, y: map.bounds.midY + at.y - target.y)
                map.setCenter(map.convert(center, toCoordinateFrom: map), animated: false)
            }
            hasPositioned = true
        }

        /// Shows `rect` as large as fits in the unobscured part of the map, centred there.
        private func show(_ rect: MKMapRect, on map: MKMapView, animated: Bool) {
            let margin: CGFloat = 8
            if rectsFitInMargins == true {
                let padding = UIEdgeInsets(top: margin, left: margin, bottom: margin, right: margin)
                map.setVisibleMapRect(rect, edgePadding: padding, animated: animated)
                return
            }
            // Work out the whole view's rect so `rect` fills the unobscured area.
            let insets = parent.obscured
            let width = max(map.bounds.width - 2 * margin, 50)
            let height = max(map.bounds.height - insets.top - insets.bottom - 2 * margin, 50)
            let scale = max(rect.size.width / width, rect.size.height / height)  // map points per screen point
            let target = searchPoint(in: map)
            let whole = MKMapRect(
                x: rect.midX - target.x * scale,
                y: rect.midY - target.y * scale,
                width: map.bounds.width * scale,
                height: map.bounds.height * scale
            )
            guard rectsFitInMargins == nil else {
                map.setVisibleMapRect(whole, animated: animated)
                return
            }
            // First move: set it without animation and see what MapKit actually shows.
            map.setVisibleMapRect(whole, animated: false)
            rectsFitInMargins = map.visibleMapRect.size.width > whole.size.width * 1.05
            if rectsFitInMargins == true { show(rect, on: map, animated: false) }
        }

        /// The point on screen the search centre sits under.
        private func searchPoint(in map: MKMapView) -> CGPoint {
            let insets = parent.obscured
            let visible = map.bounds.height - insets.top - insets.bottom
            guard visible > 50 else { return CGPoint(x: map.bounds.midX, y: map.bounds.midY) }
            return CGPoint(x: map.bounds.midX, y: insets.top + visible / 2)
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

        func updateRoutes(on map: MKMapView, routes: [PlannedRoute], selected: Int) {
            let key = routes.map(\.line.length) + [Double(selected)]
            guard key != routesKey else { return }
            routesKey = key
            map.removeOverlays(routeOverlays)
            // The selected route last, so it draws on top.
            let order = routes.indices.filter { $0 != selected } + (routes.indices.contains(selected) ? [selected] : [])
            routeOverlays = order.map { i in
                let coordinates = routes[i].line.points.map(\.coordinate)
                let line = RoutePolyline(coordinates: coordinates, count: coordinates.count)
                line.isSelected = i == selected
                return line
            }
            map.addOverlays(routeOverlays, level: .aboveRoads)
        }

        func updateDestination(on map: MKMapView, destination: Destination?) {
            guard destinationAnnotation?.destination != destination else { return }
            if let destinationAnnotation { map.removeAnnotation(destinationAnnotation) }
            destinationAnnotation = destination.map(DestinationAnnotation.init)
            if let destinationAnnotation { map.addAnnotation(destinationAnnotation) }
        }

        func updateScrubHandle(on map: MKMapView, at point: CLLocationCoordinate2D?) {
            switch (scrubAnnotation, point) {
            case (nil, let point?):
                let annotation = ScrubAnnotation(coordinate: point)
                scrubAnnotation = annotation
                map.addAnnotation(annotation)
            case (let annotation?, let point?):
                if annotation.coordinate.latitude != point.latitude || annotation.coordinate.longitude != point.longitude {
                    annotation.coordinate = point
                }
            case (let annotation?, nil):
                map.removeAnnotation(annotation)
                scrubAnnotation = nil
            case (nil, nil):
                break
            }
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
            let center = map.convert(searchPoint(in: map), toCoordinateFrom: map)
            DispatchQueue.main.async { self.parent.onCenterChange(center) }
        }

        func mapView(_ map: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            if annotation is ScrubAnnotation {
                let view = map.dequeueReusableAnnotationView(withIdentifier: Self.scrubID, for: annotation) as? ScrubHandleView
                view?.onDrag = { [weak self, weak map] point in
                    guard let self, let map else { return }
                    self.parent.onScrub(map.convert(point, toCoordinateFrom: map))
                }
                return view
            }
            if annotation is DestinationAnnotation {
                let view = map.dequeueReusableAnnotationView(withIdentifier: Self.destinationID, for: annotation)
                    as? MKMarkerAnnotationView
                view?.glyphImage = UIImage(systemName: "flag.checkered")
                view?.markerTintColor = .systemRed
                view?.displayPriority = .required
                view?.canShowCallout = true
                return view
            }
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
            if let route = overlay as? RoutePolyline {
                let renderer = MKPolylineRenderer(polyline: route)
                renderer.strokeColor = route.isSelected ? .systemBlue : .systemGray.withAlphaComponent(0.7)
                renderer.lineWidth = route.isSelected ? 6 : 4
                return renderer
            }
            guard let circle = overlay as? MKCircle else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKCircleRenderer(circle: circle)
            renderer.strokeColor = UIColor.systemBlue.withAlphaComponent(0.6)
            renderer.fillColor = UIColor.systemBlue.withAlphaComponent(0.05)
            renderer.lineWidth = 1.5
            renderer.lineDashPattern = [6, 4]
            return renderer
        }

        func mapView(_ map: MKMapView, didSelect annotation: MKAnnotation) {
            if annotation is ScrubAnnotation {
                map.deselectAnnotation(annotation, animated: false)
            } else if let cluster = annotation as? MKClusterAnnotation {
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

final class RoutePolyline: MKPolyline {
    var isSelected = false
}

final class DestinationAnnotation: NSObject, MKAnnotation {
    let destination: Destination
    let coordinate: CLLocationCoordinate2D

    init(_ destination: Destination) {
        self.destination = destination
        self.coordinate = destination.point.coordinate
    }

    var title: String? { destination.name }
}

final class ScrubAnnotation: NSObject, MKAnnotation {
    // KVO-observable so the map moves the handle when this changes.
    @objc dynamic var coordinate: CLLocationCoordinate2D

    init(coordinate: CLLocationCoordinate2D) {
        self.coordinate = coordinate
    }
}

/// The search-centre handle on the route. Dragging it reports the finger's
/// position; the planner snaps that to the route and moves the handle there.
final class ScrubHandleView: MKAnnotationView {
    var onDrag: ((CGPoint) -> Void)?

    override init(annotation: MKAnnotation?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        frame = CGRect(x: 0, y: 0, width: 44, height: 44)  // a comfortable touch target
        backgroundColor = .clear
        displayPriority = .required
        zPriority = .max
        collisionMode = .none

        let dot = UIView(frame: bounds.insetBy(dx: 8, dy: 8))
        dot.backgroundColor = .systemBlue
        dot.layer.cornerRadius = dot.bounds.width / 2
        dot.layer.borderColor = UIColor.white.cgColor
        dot.layer.borderWidth = 3
        dot.layer.shadowOpacity = 0.3
        dot.layer.shadowRadius = 3
        dot.layer.shadowOffset = CGSize(width: 0, height: 1)
        dot.isUserInteractionEnabled = false
        let arrows = UIImageView(image: UIImage(systemName: "arrow.left.and.right",
                                                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .bold)))
        arrows.tintColor = .white
        arrows.center = CGPoint(x: dot.bounds.midX, y: dot.bounds.midY)
        dot.addSubview(arrows)
        addSubview(dot)

        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        accessibilityLabel = "Search centre. Drag along the route."
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    private var map: MKMapView? {
        var view = superview
        while let current = view, !(current is MKMapView) { view = current.superview }
        return view as? MKMapView
    }

    // Stop the map from scrolling as soon as the finger lands on the handle,
    // before the map's own pan gesture can claim the drag.
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        map?.isScrollEnabled = false
        super.touchesBegan(touches, with: event)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        map?.isScrollEnabled = true
        super.touchesEnded(touches, with: event)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        map?.isScrollEnabled = true
        super.touchesCancelled(touches, with: event)
    }

    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        guard let map else { return }
        switch gesture.state {
        case .began, .changed:
            onDrag?(gesture.location(in: map))
        default:
            map.isScrollEnabled = true
        }
    }
}
