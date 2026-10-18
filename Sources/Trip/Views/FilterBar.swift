import SwiftUI

/// The category chips along the top of the map.
struct FilterBar: View {
    @Binding var categories: Set<Category>
    @Binding var publicToiletsOnly: Bool

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Category.allCases) { category in
                    Chip(
                        label: category.label,
                        symbol: category.symbol,
                        color: category.color,
                        isOn: categories.contains(category)
                    ) {
                        if categories.contains(category) {
                            categories.remove(category)
                        } else {
                            categories.insert(category)
                        }
                    }
                }
                if categories.contains(.toilet) {
                    Chip(
                        label: "Public only",
                        symbol: "person.2.fill",
                        color: Category.toilet.color,
                        isOn: publicToiletsOnly
                    ) {
                        publicToiletsOnly.toggle()
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
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
            Label(label, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(isOn ? .white : .primary)
                .background {
                    Capsule().fill(isOn ? AnyShapeStyle(color) : AnyShapeStyle(.regularMaterial))
                }
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
