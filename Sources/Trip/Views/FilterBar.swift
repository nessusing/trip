import SwiftUI

/// The filter chips along the top of the map. Sub-filters (Fast, Plug, Public
/// only) appear next to their category when it's on.
struct FilterBar: View {
    @Binding var filters: Filters

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                Chip(label: "Open now", symbol: "clock.fill", color: .indigo, isOn: filters.openNow) {
                    filters.openNow.toggle()
                }
                ForEach(Category.allCases) { category in
                    Chip(
                        label: category.label,
                        symbol: category.symbol,
                        color: category.color,
                        isOn: filters.categories.contains(category)
                    ) {
                        if filters.categories.contains(category) {
                            filters.categories.remove(category)
                        } else {
                            filters.categories.insert(category)
                        }
                    }
                    if filters.categories.contains(category) {
                        subFilters(for: category)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func subFilters(for category: Category) -> some View {
        switch category {
        case .ev:
            Chip(label: "Fast", symbol: "bolt.badge.clock.fill", color: Category.ev.color,
                 isOn: filters.fastChargingOnly) {
                filters.fastChargingOnly.toggle()
            }
            PlugMenu(connectors: $filters.connectors)
        case .toilet:
            Chip(label: "Public only", symbol: "person.2.fill", color: Category.toilet.color,
                 isOn: filters.publicToiletsOnly) {
                filters.publicToiletsOnly.toggle()
            }
        case .fuel, .restArea:
            EmptyView()
        }
    }
}

private struct PlugMenu: View {
    @Binding var connectors: Set<String>

    var body: some View {
        Menu {
            ForEach(Filters.allConnectors, id: \.self) { plug in
                Toggle(plug, isOn: Binding(
                    get: { connectors.contains(plug) },
                    set: { on in
                        if on { connectors.insert(plug) } else { connectors.remove(plug) }
                    }
                ))
            }
            if !connectors.isEmpty {
                Divider()
                Button("Any plug") { connectors.removeAll() }
            }
        } label: {
            ChipLabel(label: label, symbol: "powerplug.fill", color: Category.ev.color,
                      isOn: !connectors.isEmpty, showsMenuIndicator: true)
        }
    }

    private var label: String {
        connectors.isEmpty
            ? "Any plug"
            : Filters.allConnectors.filter(connectors.contains).joined(separator: ", ")
    }
}

private struct Chip: View {
    let label: String
    let symbol: String
    let color: Color
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ChipLabel(label: label, symbol: symbol, color: color, isOn: isOn)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

private struct ChipLabel: View {
    let label: String
    let symbol: String
    let color: Color
    let isOn: Bool
    var showsMenuIndicator = false

    var body: some View {
        HStack(spacing: 4) {
            Label(label, systemImage: symbol)
            if showsMenuIndicator {
                Image(systemName: "chevron.down").font(.caption2.weight(.bold))
            }
        }
        .font(.subheadline.weight(.semibold))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .foregroundStyle(isOn ? .white : .primary)
        .background {
            Capsule().fill(isOn ? AnyShapeStyle(color) : AnyShapeStyle(.regularMaterial))
        }
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    }
}
