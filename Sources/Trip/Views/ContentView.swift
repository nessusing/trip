import CoreLocation
import SwiftUI

struct ContentView: View {
    static let radiusOptions: [Double] = [0.1, 0.5, 1, 2, 5, 10, 25, 50]

    @Environment(POIStore.self) private var store
    @Environment(LocationManager.self) private var location

    // Remembered between launches.
    @AppStorage("radiusKm") private var radiusKm = 10.0
    @AppStorage("categories") private var categoriesRaw = Category.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("publicToiletsOnly") private var publicToiletsOnly = false
    @AppStorage("openNow") private var openNow = false
    @AppStorage("fastChargingOnly") private var fastChargingOnly = false
    @AppStorage("connectors") private var connectorsRaw = ""

    /// The centre of the map, which is also the centre of the search circle.
    @State private var searchCenter = Geo.downtownVancouver
    @State private var camera: CameraRequest?
    @State private var hasCenteredOnUser = false
    @State private var selected: POI?
    @State private var detent: PresentationDetent = Self.collapsed
    /// Bottom edge of the filter chips, in screen points.
    @State private var chipsBottom: CGFloat = 100

    static let collapsedHeight: CGFloat = 150
    static let collapsed = PresentationDetent.height(collapsedHeight)

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

    private var items: [NearbyPOI] {
        store.nearby(center: searchCenter, radiusKm: radiusKm, filters: filters)
    }

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            POIMapView(
                items: items,
                searchCenter: searchCenter,
                radiusKm: radiusKm,
                camera: camera,
                // The chips cover the top of the map and the collapsed sheet the
                // bottom; the search circle is centred in what's left.
                obscured: UIEdgeInsets(top: chipsBottom, left: 0, bottom: Self.collapsedHeight, right: 0),
                selected: $selected,
                onCenterChange: { searchCenter = $0 }
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
                locationDenied: location.isDenied
            )
            .presentationDetents([Self.collapsed, .medium, .large], selection: $detent)
            .presentationBackgroundInteraction(.enabled(upThrough: .medium))
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled()
        }
        .onAppear {
            // Start on downtown Vancouver; we jump to the user once we get a fix.
            camera = CameraRequest(center: searchCenter, radiusKm: radiusKm)
            location.start()
        }
        .onChange(of: location.coordinate?.latitude) {
            // Jump to the user once, on the first fix. After that the map stays
            // where the user put it until they tap the recenter button.
            guard !hasCenteredOnUser, location.coordinate != nil else { return }
            hasCenteredOnUser = true
            recenter()
        }
        .onChange(of: radiusKm) {
            camera = CameraRequest(center: searchCenter, radiusKm: radiusKm)
        }
        .onChange(of: selected) {
            if selected != nil && detent == Self.collapsed { detent = .medium }
        }
    }

    private func recenter() {
        guard let coordinate = location.coordinate else { return }
        camera = CameraRequest(center: coordinate, radiusKm: radiusKm)
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
