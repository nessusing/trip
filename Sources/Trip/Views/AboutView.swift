import SwiftUI

struct AboutView: View {
    @Environment(POIStore.self) private var store

    var body: some View {
        List {
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

            Section {
                ForEach(Self.sources.filter { usedSources.contains($0.id) }, id: \.id) { source in
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
