import SwiftUI

struct AboutView: View {
    @Environment(POIStore.self) private var store

    var body: some View {
        List {
            Section("Data") {
                LabeledContent("Places", value: "\(store.pois.count)")
                if let generated = store.generated {
                    LabeledContent("Updated", value: String(generated.prefix(10)))
                }
                LabeledContent("Region", value: "British Columbia")
            }

            Section {
                source("OpenStreetMap",
                       "Gas stations, washrooms, cafés and more. © OpenStreetMap contributors, available under the Open Database License.",
                       "https://www.openstreetmap.org/copyright")
                source("Alternative Fuels Data Center",
                       "EV chargers, with Canadian data from Natural Resources Canada.",
                       "https://afdc.energy.gov/stations")
                source("City of Vancouver Open Data",
                       "Public washrooms. Contains information licensed under the Open Government Licence – Vancouver.",
                       "https://opendata.vancouver.ca/explore/dataset/public-washrooms/")
                source("DataBC",
                       "Highway rest areas from the BC Ministry of Transportation. Contains information licensed under the Open Government Licence – British Columbia.",
                       "https://catalogue.data.gov.bc.ca/dataset/ministry-of-transportation-mot-rest-area")
            } header: {
                Text("Sources")
            } footer: {
                Text("Faded markers are washrooms guessed from a chain or place type. They may not exist or may be for customers only.")
            }
        }
        .navigationTitle("About")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func source(_ name: String, _ detail: String, _ url: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let link = URL(string: url) {
                Link(name, destination: link).font(.body.weight(.medium))
            }
            Text(detail).font(.footnote).foregroundStyle(.secondary)
        }
    }
}
