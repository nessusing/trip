import SwiftUI

struct POIDetailView: View {
    let poi: POI
    /// Metres from the search centre, when known.
    let distance: Double?

    @Environment(FuelPrices.self) private var fuel

    var body: some View {
        List {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: poi.symbol)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(width: 48, height: 48)
                        .background(poi.primaryCategory.color.opacity(poi.isInferred ? 0.45 : 1), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(poi.displayName).font(.title3.weight(.semibold))
                        Text([poi.kindLabel, distance.map { Geo.format(distance: $0) }]
                            .compactMap { $0 }.joined(separator: " · "))
                            .foregroundStyle(.secondary)
                        if let status = poi.openStatus(at: .now) {
                            Text(status.label(now: .now))
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(status.isOpen ? .green : .red)
                        }
                    }
                }
                Button {
                    MapsLauncher.navigate(to: poi)
                } label: {
                    Label("Navigate", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .frame(maxWidth: .infinity)
                        .font(.headline)
                }
                .buttonStyle(.borderedProminent)
                .listRowSeparator(.hidden)
            }

            Section {
                Field("Address", poi.address)
                Field("In", poi.name == nil ? nil : poi.place)
                Field("Near", poi.address == nil ? poi.street : nil)
                Field("Hours", poi.hours)
            }

            if let toilet = poi.toilet { washroom(toilet) }
            if let ev = poi.ev { charger(ev) }
            if poi.kind == .fuel { prices }
            if let fuel = poi.fuel { gas(fuel) }
            if let rest = poi.restArea { restArea(rest) }

            Section {
                Text("Source: \(poi.sourceLabel)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(poi.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { fuel.detailOpened(poi) }
    }

    private var prices: some View {
        let now = Date.now
        let quotes = fuel.station(for: poi).map { station in
            FuelGrade.allCases.compactMap { grade in station.quote(grade, now: now).map { (grade, $0) } }
        }
        return Section {
            if let quotes, !quotes.isEmpty {
                ForEach(quotes, id: \.0) { grade, quote in
                    LabeledContent(grade.label) {
                        VStack(alignment: .trailing, spacing: 1) {
                            Text(quote.text).monospacedDigit()
                                .foregroundStyle(quote.isStale(now: now) ? Color.secondary : Color.primary)
                            Text([quote.age(now: now), quote.cashText].compactMap { $0 }.joined(separator: " · "))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            } else if !fuel.online {
                Text("Prices need internet").foregroundStyle(.secondary)
            } else if fuel.loading {
                ProgressView()
            } else if quotes != nil || fuel.covered(poi.coordinate) {
                Text("No recent price").foregroundStyle(.secondary)
            } else {
                Text("No price yet").foregroundStyle(.secondary)
            }
        } header: {
            Text("Prices")
        } footer: {
            Text("Reported by GasBuddy users. The price at the pump may have changed since.")
        }
    }

    private func washroom(_ t: ToiletInfo) -> some View {
        Section("Washroom") {
            Field("Access", t.accessLabel)
            Field("Info", t.confidenceLabel)
            Field("Wheelchair accessible", yesNo(t.wheelchair))
            Field("Changing table", yesNo(t.changingTable))
            Field("Fee", t.fee.map { $0 ? "Yes" : "Free" })
        }
    }

    private func charger(_ ev: EVInfo) -> some View {
        Section("Charging") {
            Field("Connectors", ev.connectors.flatMap { $0.isEmpty ? nil : $0.joined(separator: ", ") })
            Field("Max power", ev.maxKW.map { "\(Int($0)) kW" })
            Field("Network", ev.network)
            Field("DC fast ports", ev.dcFast.map(String.init))
            Field("Level 2 ports", ev.level2.map(String.init))
            Field("Pricing", ev.pricing)
        }
    }

    private func gas(_ fuel: FuelInfo) -> some View {
        Section("Gas station") {
            Field("Brand", fuel.brand)
            Field("Diesel", yesNo(fuel.diesel))
            Field("Convenience store", yesNo(fuel.shop))
        }
    }

    private func restArea(_ r: RestAreaInfo) -> some View {
        Section("Rest area") {
            Field("Highway", r.highway.map { "Hwy \($0)" })
            Field("Direction", r.direction)
            Field("Toilets", r.toilets.map { count in
                count == 0 ? "None" : "\(count)" + (r.toiletType.map { " × \($0.lowercased())" } ?? "")
            })
            Field("Picnic tables", r.tables.map(String.init))
            Field("Open year-round", yesNo(r.yearRound))
            Field("Fits trucks", yesNo(r.trucks))
        }
    }

    private func yesNo(_ value: Bool?) -> String? {
        value.map { $0 ? "Yes" : "No" }
    }
}

private extension ToiletInfo {
    var accessLabel: String {
        switch access {
        case .public: "Public"
        case .customers: "Customers only"
        case .unknown: "Unknown"
        }
    }

    var confidenceLabel: String {
        switch confidence {
        case .official: "Official government data"
        case .osm: "Mapped on OpenStreetMap"
        case .inferred: "Guessed from chain or place type. May not exist or be open to you."
        }
    }
}

/// A label/value row that hides itself when there is no value.
private struct Field: View {
    let label: String
    let value: String?

    init(_ label: String, _ value: String?) {
        self.label = label
        self.value = value
    }

    var body: some View {
        if let value, !value.isEmpty {
            LabeledContent(label) {
                Text(value).multilineTextAlignment(.trailing)
            }
        }
    }
}
