import SwiftUI

@main
struct TripApp: App {
    @State private var store = POIStore()
    @State private var location = LocationManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(location)
                .task { await store.load() }
        }
    }
}
