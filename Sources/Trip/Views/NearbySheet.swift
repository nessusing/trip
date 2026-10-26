import MapKit
import SwiftUI

/// The bottom sheet: destination search or trip controls, the list of nearby
/// places, and the detail page pushed on top.
struct NearbySheet: View {
    let items: [NearbyPOI]
    @Binding var radiusKm: Double
    @Binding var selected: POI?
    let locationDenied: Bool
    let actions: TripActions

    @Environment(POIStore.self) private var store
    @Environment(TripPlanner.self) private var planner
    @Environment(DestinationSearch.self) private var search
    @State private var showAbout = false
    @State private var searching = false

    var body: some View {
        NavigationStack {
            Group {
                if planner.destination == nil {
                    list.searchable(
                        text: Bindable(search).query,
                        isPresented: $searching,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Search for a destination"
                    )
                } else {
                    list.safeAreaInset(edge: .top, spacing: 0) {
                        TripHeader(actions: actions)
                            .background(.bar)
                    }
                }
            }
            .onChange(of: searching) { actions.searchFocused(searching) }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showAbout = true
                    } label: {
                        Image(systemName: "info.circle")
                    }
                    .accessibilityLabel("About")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Picker("Radius", selection: $radiusKm) {
                            ForEach(ContentView.radiusOptions, id: \.self) { km in
                                Text(Geo.format(radius: km)).tag(km)
                            }
                        }
                    } label: {
                        Label(Geo.format(radius: radiusKm), systemImage: "circle.dashed")
                            .labelStyle(.titleAndIcon)
                    }
                }
            }
            .navigationDestination(item: $selected) { poi in
                POIDetailView(poi: poi, distance: items.first { $0.id == poi.id }?.distance)
            }
            .navigationDestination(isPresented: $showAbout) {
                AboutView()
            }
        }
    }

    @ViewBuilder
    private var list: some View {
        if searching && !search.query.isEmpty {
            List(search.results, id: \.self) { result in
                Button {
                    pick(result)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty {
                            Text(result.subtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .listStyle(.plain)
        } else {
            places
        }
    }

    private func pick(_ result: MKLocalSearchCompletion) {
        Task {
            guard let destination = await search.resolve(result) else { return }
            searching = false
            search.query = ""
            actions.pickDestination(destination)
        }
    }

    private var places: some View {
        List {
            if store.loaded && store.pois.isEmpty && !store.isSyncing {
                VStack(alignment: .leading, spacing: 4) {
                    Label("No data yet. Connect to the internet to download.", systemImage: "icloud.and.arrow.down")
                    if let error = store.syncError {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if locationDenied {
                Label("Location is off. Drag the map to search elsewhere.", systemImage: "location.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                Button {
                    selected = item.poi
                } label: {
                    POIRow(item: item, routeMode: planner.route != nil)
                }
                .buttonStyle(.plain)
            }
            if items.isEmpty && !store.pois.isEmpty {
                Text("Nothing here. Try a bigger radius or turn on more categories.")
                    .foregroundStyle(.secondary)
            }
        }
        .listStyle(.plain)
    }

    private var title: String {
        if store.pois.isEmpty && (!store.loaded || store.isSyncing) { return "Loading…" }
        return items.count == 1 ? "1 place" : "\(items.count) places"
    }
}

struct POIRow: View {
    let item: NearbyPOI
    var routeMode = false

    var body: some View {
        let poi = item.poi
        HStack(spacing: 12) {
            Image(systemName: poi.symbol)
                .font(.body.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(poi.primaryCategory.color.opacity(poi.isInferred ? 0.45 : 1), in: Circle())

            VStack(alignment: .leading, spacing: 2) {
                Text(poi.displayName)
                    .font(.body.weight(.medium))
                    .lineLimit(1)
                subtitle(poi)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            distance
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private var distance: some View {
        if let along = item.along {
            // In route mode: how far down the road, and roughly how long.
            VStack(alignment: .trailing, spacing: 1) {
                if along.ahead < -500 {
                    Text("Passed")
                } else {
                    Text(Geo.format(distance: max(along.ahead, 0)))
                    Text(Geo.format(seconds: along.seconds)).font(.caption)
                }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        } else {
            VStack(alignment: .trailing, spacing: 1) {
                Text(Geo.format(distance: item.distance))
                if routeMode {
                    Text("off route").font(.caption)
                }
            }
            .font(.subheadline.monospacedDigit())
            .foregroundStyle(.secondary)
        }
    }

    private func subtitle(_ poi: POI) -> Text {
        let details = Text(details(poi))
        guard let status = item.status else { return details }
        return Text(status.shortLabel(now: .now))
            .foregroundStyle(status.isOpen ? Color.green : Color.red)
            + Text(" · ") + details
    }

    private func details(_ poi: POI) -> String {
        var parts = [poi.kindLabel]
        if let ev = poi.ev {
            if let kw = ev.maxKW { parts.append("\(Int(kw)) kW") }
            if let connectors = ev.connectors, !connectors.isEmpty {
                parts.append(connectors.joined(separator: "/"))
            }
        }
        if let toilet = poi.toilet, poi.kind != .toilet {
            parts.append(toilet.confidence == .inferred ? "washroom likely" : "washroom")
        } else if let toilet = poi.toilet, toilet.access != .public {
            parts.append(toilet.access == .customers ? "customers only" : "access unknown")
        }
        return parts.joined(separator: " · ")
    }
}

extension OpenStatus {
    /// Compact form for list rows: "Open 24h", "Open until 10 PM", "Closed".
    func shortLabel(now: Date) -> String {
        switch self {
        case .alwaysOpen: "Open 24h"
        case .open: label(now: now)
        case .closed: "Closed"
        }
    }
}
