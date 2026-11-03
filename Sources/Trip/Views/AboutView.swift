import SwiftUI

struct AboutView: View {
    @Environment(POIStore.self) private var store
    @Environment(FuelPrices.self) private var fuel
    @State private var showGasBuddy = false
    @AppStorage(FuelGrade.storageKey) private var fuelGrade = FuelGrade.regular

    var body: some View {
        List {
            Section("Settings") {
                Picker("Gas price shown", selection: $fuelGrade) {
                    ForEach(FuelGrade.allCases) { Text($0.label).tag($0) }
                }
            }

            Section {
                ForEach(store.regions, id: \.id) { region in
                    LabeledContent(region.name) {
                        VStack(alignment: .trailing) {
                            Text("\(region.count) places")
                            Text("Updated \(String(region.generated.prefix(10)))").font(.footnote)
                        }
                    }
                }
                Button {
                    Task { await store.checkForUpdates(force: true) }
                } label: {
                    HStack {
                        Text("Check for updates")
                        Spacer()
                        if store.isSyncing { ProgressView() }
                    }
                }
                .disabled(store.isSyncing)
            } header: {
                Text("Data")
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if let error = store.syncError {
                        Text(error).foregroundStyle(.red)
                    }
                    if let lastChecked = store.lastChecked {
                        Text("Last checked \(lastChecked.formatted(date: .abbreviated, time: .shortened))")
                    }
                }
            }

            gasPrices

            Section {
                ForEach(Self.sources.filter { usedSources.contains($0.id) } + [Self.gasBuddy], id: \.id) { source in
                    VStack(alignment: .leading, spacing: 4) {
                        Link(source.name, destination: source.url).font(.body.weight(.medium))
                        Text(source.detail).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Sources")
            } footer: {
                Text("Faded markers are washrooms guessed from a chain or place type. They may not exist or may be for customers only.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showGasBuddy, onDismiss: { Task { await fuel.client.pageClosed() } }) {
            NavigationStack {
                GasBuddyPage(web: fuel.client.web)
                    .ignoresSafeArea(edges: .bottom)
                    .navigationTitle("GasBuddy")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") { showGasBuddy = false }
                        }
                    }
            }
        }
    }

    private var gasPrices: some View {
        let client = fuel.client
        return Section {
            if let until = client.pausedUntil, until > .now {
                LabeledContent("Status", value: "Paused until \(until.formatted(date: .omitted, time: .shortened))")
            } else if let success = client.lastSuccess {
                LabeledContent("Last update") {
                    Text("\(success.at.formatted(.relative(presentation: .named))) via \(success.path)")
                }
            } else {
                LabeledContent("Status", value: "No prices yet")
            }
            if let error = client.lastError {
                Text(error).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Fix GasBuddy") { showGasBuddy = true }
        } header: {
            Text("Gas prices")
        } footer: {
            Text("If prices stop coming in, open GasBuddy here and complete any \"verify you are human\" check.")
        }
    }

    /// Sources used by the downloaded regions; all of them before any download.
    private var usedSources: Set<String> {
        let used = Set(store.regions.flatMap(\.sources))
        return used.isEmpty ? Set(Self.sources.map(\.id)) : used
    }

    private struct Source {
        /// Matches `POI.source` and the manifest's `sources`.
        let id: String
        let name: String
        let detail: String
        let url: URL
    }

    private static let gasBuddy = Source(
        id: "gasbuddy", name: "GasBuddy",
        detail: "Live gas prices reported by GasBuddy users, through GasBuddy's unofficial web API. Not affiliated with GasBuddy.",
        url: URL(string: "https://www.gasbuddy.com")!)

    private static let sources = [
        Source(id: "osm", name: "OpenStreetMap",
               detail: "Gas stations, washrooms, cafés and more. © OpenStreetMap contributors, available under the Open Database License.",
               url: URL(string: "https://www.openstreetmap.org/copyright")!),
        Source(id: "afdc", name: "Alternative Fuels Data Center",
               detail: "EV chargers, with Canadian data from Natural Resources Canada.",
               url: URL(string: "https://afdc.energy.gov/stations")!),
        Source(id: "ocm", name: "Open Charge Map",
               detail: "Additional EV chargers.",
               url: URL(string: "https://openchargemap.org/site/develop/api")!),
        Source(id: "vancouver", name: "City of Vancouver Open Data",
               detail: "Public washrooms. Contains information licensed under the Open Government Licence – Vancouver.",
               url: URL(string: "https://opendata.vancouver.ca/explore/dataset/public-washrooms/")!),
        Source(id: "databc", name: "DataBC",
               detail: "Highway rest areas from the BC Ministry of Transportation. Contains information licensed under the Open Government Licence – British Columbia.",
               url: URL(string: "https://catalogue.data.gov.bc.ca/dataset/ministry-of-transportation-mot-rest-area")!),
    ]
}

/// Hosts the hidden GasBuddy web view on screen so the user can click through a
/// Cloudflare check. It goes back into hiding when the sheet closes.
private struct GasBuddyPage: UIViewRepresentable {
    let web: GasBuddyWeb

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        web.show(in: container)
        return container
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
