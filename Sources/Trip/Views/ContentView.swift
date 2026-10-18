import CoreLocation
import SwiftUI

struct ContentView: View {
    static let radiusOptions: [Double] = [2, 5, 10, 25, 50]

    @Environment(POIStore.self) private var store
    @Environment(LocationManager.self) private var location

    // Remembered between launches.
    @AppStorage("radiusKm") private var radiusKm = 10.0
    @AppStorage("categories") private var categoriesRaw = Category.allCases.map(\.rawValue).joined(separator: ",")
    @AppStorage("publicToiletsOnly") private var publicToiletsOnly = false

    /// The centre of the map, which is also the centre of the search circle.
    @State private var searchCenter = Geo.downtownVancouver
    @State private var camera: CameraRequest?
    @State private var hasCenteredOnUser = false
    @State private var selected: POI?
    @State private var detent: PresentationDetent = Self.collapsed

    static let collapsed = PresentationDetent.height(150)

    private var categories: Set<Category> {
        Set(categoriesRaw.split(separator: ",").compactMap { Category(rawValue: String($0)) })
    }

    private var categoriesBinding: Binding<Set<Category>> {
        Binding(
            get: { categories },
            set: { categoriesRaw = Category.allCases.filter($0.contains).map(\.rawValue).joined(separator: ",") }
        )
    }

    private var items: [NearbyPOI] {
        store.nearby(
            center: searchCenter,
            radiusKm: radiusKm,
            categories: categories,
            publicToiletsOnly: publicToiletsOnly
        )
    }

    var body: some View {
        let items = items
        ZStack(alignment: .top) {
            POIMapView(
                items: items,
                searchCenter: searchCenter,
                radiusKm: radiusKm,
                camera: camera,
                selected: $selected,
                onCenterChange: { searchCenter = $0 }
            )
            .ignoresSafeArea()

            VStack(alignment: .trailing, spacing: 10) {
                FilterBar(categories: categoriesBinding, publicToiletsOnly: $publicToiletsOnly)
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
