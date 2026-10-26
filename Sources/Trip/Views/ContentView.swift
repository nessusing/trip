import CoreLocation
import SwiftUI

struct ContentView: View {
    static let radiusOptions: [Double] = [0.1, 0.5, 1, 2, 5, 10, 25, 50]

    @Environment(POIStore.self) private var store
    @Environment(LocationManager.self) private var location
    @Environment(TripPlanner.self) private var planner
    @Environment(DestinationSearch.self) private var search

    // Remembered between launches.
    @AppStorage("radiusKm") private var radiusKm = 10.0
    @AppStorage("categories") private var categoriesRaw = Category.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("publicToiletsOnly") private var publicToiletsOnly = false
    @AppStorage("openNow") private var openNow = false
    @AppStorage("fastChargingOnly") private var fastChargingOnly = false
    @AppStorage("connectors") private var connectorsRaw = ""

    /// The centre of the visible map. It's the search centre too, except in
    /// route mode, where the search centre is on the route (`planner.searchPoint`).
    @State private var searchCenter = Geo.downtownVancouver
    @State private var camera: CameraRequest?
    @State private var hasCenteredOnUser = false
    @State private var selected: POI?
    @State private var detent: PresentationDetent = .height(200)
    /// Bottom edge of the filter chips, in screen points.
    @State private var chipsBottom: CGFloat = 100

    /// The collapsed sheet: room for the search box, or for the route controls.
    private var collapsedHeight: CGFloat { planner.route != nil ? 325 : planner.destination != nil ? 190 : 200 }
    private var collapsed: PresentationDetent { .height(collapsedHeight) }

    private var filters: Filters {
        Filters(
            categories: Set(categoriesRaw.split(separator: ",").compactMap { Category(rawValue: String($0)) }),
            publicToiletsOnly: publicToiletsOnly,
            openNow: openNow,
            fastChargingOnly: fastChargingOnly,
            connectors: Set(connectorsRaw.split(separator: ",").map(String.init))
        )
    }

    private var filtersBinding: Binding<Filters> {
        Binding(
            get: { filters },
            set: { new in
                categoriesRaw = Category.allCases.filter(new.categories.contains).map(\.rawValue).joined(separator: ",")
                publicToiletsOnly = new.publicToiletsOnly
                openNow = new.openNow
                fastChargingOnly = new.fastChargingOnly
                connectorsRaw = Filters.allConnectors.filter(new.connectors.contains).joined(separator: ",")
            }
        )
    }

    private var center: CLLocationCoordinate2D { planner.searchPoint ?? searchCenter }

    private var items: [NearbyPOI] {
        var items = store.nearby(center: center, radiusKm: radiusKm, filters: filters)
        guard planner.route != nil else { return items }
        for i in items.indices { items[i].along = planner.along(items[i].poi) }
        // Along the route in driving order first, then places away from it, nearest first.
        return items.sorted { a, b in
            switch (a.along, b.along) {
            case let (x?, y?): x.ahead < y.ahead
            case (.some, nil): true
            case (nil, .some): false
            case (nil, nil): a.distance < b.distance
            }
        }
    }

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            POIMapView(
                items: items,
                searchCenter: center,
                radiusKm: radiusKm,
                camera: camera,
                // The chips cover the top of the map and the collapsed sheet the
                // bottom; the search circle is centred in what's left.
                obscured: UIEdgeInsets(top: chipsBottom, left: 0, bottom: collapsedHeight, right: 0),
                destination: planner.destination,
                routes: planner.routes,
                selectedRoute: planner.selectedRoute,
                scrubPoint: planner.searchPoint,
                selected: $selected,
                onCenterChange: {
                    searchCenter = $0
                    search.bias(to: $0)
                },
                onScrub: { planner.scrub(to: $0) }
            )
            .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 10) {
                FilterBar(filters: filtersBinding)
                    .onGeometryChange(for: CGFloat.self) { $0.frame(in: .global).maxY } action: {
                        chipsBottom = $0
                    }
                RecenterButton(enabled: location.coordinate != nil) { recenter() }
                    .padding(.trailing, 12)
            }
            .padding(.top, 4)
        }
        .sheet(isPresented: .constant(true)) {
            NearbySheet(
                items: items,
                radiusKm: $radiusKm,
                selected: $selected,
                locationDenied: location.isDenied,
                actions: TripActions(
                    pickDestination: pickDestination,
                    planRoute: planRoute,
                    clearTrip: clearTrip,
                    selectRoute: selectRoute,
                    slide: slide,
                    next: next,
                    searchFocused: { if $0 { detent = .large } }
                )
            )
            .presentationDetents([collapsed, .medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .onAppear {
            // Start on downtown Vancouver, or a saved route; we jump to the user
            // once we get a fix.
            if let route = planner.route {
                camera = CameraRequest(.fit(route.line.points.map(\.coordinate)))
            } else {
                camera = CameraRequest(center: searchCenter, radiusKm: radiusKm)
            }
            detent = collapsed
            location.start()
            planner.update(pois: store.pois, boundaries: store.regions.map(\.boundary))
        }
        .onChange(of: location.coordinate?.latitude) {
            guard let coordinate = location.coordinate else { return }
            planner.updateLocation(coordinate)
            // Jump to the user once, on the first fix. After that the map stays
            // where the user put it until they tap the recenter button.
            guard !hasCenteredOnUser, planner.route == nil else { return }
            hasCenteredOnUser = true
            recenter()
        }
        .onChange(of: store.regions) {
            planner.update(pois: store.pois, boundaries: store.regions.map(\.boundary))
        }
        .onChange(of: radiusKm) {
            camera = CameraRequest(center: center, radiusKm: radiusKm)
        }
        .onChange(of: collapsedHeight) { old, _ in
            if detent == .height(old) { detent = collapsed }
        }
        .onChange(of: selected) {
            if selected != nil && detent == collapsed { detent = .medium }
        }
    }

    private func recenter() {
        guard let coordinate = location.coordinate else { return }
        camera = CameraRequest(center: coordinate, radiusKm: radiusKm)
    }

    // MARK: Trip actions

    private func pickDestination(_ destination: Destination) {
        planner.setDestination(destination)
        camera = CameraRequest(center: destination.point.coordinate, radiusKm: radiusKm)
        detent = collapsed
    }

    private func planRoute() {
        Task {
            await planner.planRoute(from: location.coordinate)
            if let route = planner.route {
                camera = CameraRequest(.fit(route.line.points.map(\.coordinate)))
            }
        }
    }

    private func clearTrip() {
        planner.clear()
        camera = CameraRequest(center: searchCenter, radiusKm: radiusKm)
    }

    private func selectRoute(_ index: Int) {
        planner.selectRoute(index, location: location.coordinate)
        if let route = planner.route {
            camera = CameraRequest(.fit(route.line.points.map(\.coordinate)))
        }
    }

    private func slide(_ progress: Double) {
        planner.setProgress(progress)
        // Zoom to the search circle and keep it in view while sliding.
        if let point = planner.searchPoint {
            camera = CameraRequest(.circle(point, radiusKm: radiusKm), animated: false)
        }
    }

    private func next(_ category: Category) {
        let filters = filters
        let poi = planner.jumpToNext(category) { poi in
            guard poi.matches(category, filters) else { return false }
            return !filters.openNow || poi.openStatus(at: .now)?.isOpen != false
        }
        if let point = planner.searchPoint { camera = CameraRequest(center: point, radiusKm: radiusKm) }
        if let poi { selected = poi }
    }
}

private struct RecenterButton: View {
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "location.fill")
                .font(.title3)
                .frame(width: 44, height: 44)
                .background(.regularMaterial, in: Circle())
                .shadow(radius: 2)
        }
        .disabled(!enabled)
        .accessibilityLabel("Show my location")
    }
}
