import SwiftUI

@main
struct TripApp: App {
    @State private var store = POIStore()
    @State private var location = LocationManager()
    @State private var planner = TripPlanner()
    @State private var search = DestinationSearch()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(store)
                .environment(location)
                .environment(planner)
                .environment(search)
                .task { await store.load() }
        }
        .onChange(of: scenePhase) {
            // Coming back to the app: look for new data if the last check was a while ago.
            if scenePhase == .active {
                Task { await store.checkForUpdates(force: false) }
            }
        }
    }
}
