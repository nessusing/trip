import SwiftUI

/// What the trip controls in the sheet ask ContentView to do (they also move the map).
struct TripActions {
    let pickDestination: (Destination) -> Void
    let planRoute: () -> Void
    let clearTrip: () -> Void
    let selectRoute: (Int) -> Void
    /// The slider moved: metres along the route.
    let slide: (Double) -> Void
    /// "Next washroom" etc.
    let next: (Category) -> Void
    /// The search box gained or lost focus.
    let searchFocused: (Bool) -> Void
}

/// Top of the sheet once there's a destination: the destination card, or with
/// a route, the route choice, the search-centre slider and "next" buttons.
struct TripHeader: View {
    let actions: TripActions

    @Environment(TripPlanner.self) private var planner

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "flag.checkered")
                    .foregroundStyle(.red)
                Text(planner.destination?.name ?? "")
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if planner.route == nil {
                    Button {
                        actions.planRoute()
                    } label: {
                        if planner.isRouting {
                            ProgressView()
                        } else {
                            Label("Route", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(planner.isRouting)
                }
                Button {
                    actions.clearTrip()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear destination")
            }

            if let route = planner.route {
                if planner.routes.count > 1 {
                    routePicker
                }
                slider(route)
                nextButtons
            }

            if let notice = planner.notice {
                Label(notice, systemImage: "info.circle")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            coverage
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var routePicker: some View {
        HStack(spacing: 8) {
            ForEach(planner.routes.indices, id: \.self) { i in
                let route = planner.routes[i]
                let isOn = i == planner.selectedRoute
                Button {
                    actions.selectRoute(i)
                } label: {
                    VStack(spacing: 1) {
                        Text(Geo.format(seconds: route.expectedTime)).font(.subheadline.weight(.semibold))
                        Text(Geo.format(distance: route.line.length)).font(.caption)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .foregroundStyle(isOn ? .white : .primary)
                    .background(isOn ? AnyShapeStyle(Color.blue) : AnyShapeStyle(.quaternary),
                                in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Route \(i + 1), \(route.name)")
                .accessibilityAddTraits(isOn ? .isSelected : [])
            }
        }
    }

    private func slider(_ route: PlannedRoute) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(aheadLabel)
                .font(.subheadline.weight(.medium).monospacedDigit())
            let range = planner.progressRange
            if range.upperBound > range.lowerBound {
                RouteSlider(value: planner.progress, range: range, onChange: actions.slide)
                    .accessibilityLabel("Search point along the route")
                    .accessibilityValue(aheadLabel)
            }
        }
    }

    private var aheadLabel: String {
        guard let ahead = planner.searchPointAhead else { return "" }
        if ahead.ahead < 500 { return planner.myProgress == nil ? "Searching at the start" : "Searching around you" }
        return "Searching \(Geo.format(distance: ahead.ahead)) ahead · \(Geo.format(seconds: ahead.seconds))"
    }

    private var nextButtons: some View {
        HStack(spacing: 8) {
            Text("Next")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ForEach(Category.allCases) { category in
                Button {
                    actions.next(category)
                } label: {
                    Image(systemName: category.symbol)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity, minHeight: 32)
                        .background(category.color, in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(planner.corridor == nil)
                .accessibilityLabel("Next \(category.singular) ahead")
            }
        }
    }

    @ViewBuilder
    private var coverage: some View {
        if planner.noCoverage {
            Label("No place data along this route.", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        } else if planner.hasGaps {
            let missing = planner.missingRegions.isEmpty ? "" : ": no data for \(planner.missingRegions.joined(separator: ", "))"
            Label("Data is incomplete along this route\(missing).", systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
        }
    }
}

/// A big slider for moving the search centre along the route. The system
/// Slider's thumb is small and can't be resized; this one has a large thumb
/// matching the handle on the map, and responds to a touch anywhere on the track.
struct RouteSlider: View {
    let value: Double
    let range: ClosedRange<Double>
    let onChange: (Double) -> Void

    private let thumb: CGFloat = 34

    var body: some View {
        GeometryReader { geo in
            let usable = max(geo.size.width - thumb, 1)
            let span = range.upperBound - range.lowerBound
            let fraction = span > 0 ? (min(max(value, range.lowerBound), range.upperBound) - range.lowerBound) / span : 0
            let x = thumb / 2 + usable * fraction
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                    .frame(height: 10)
                Capsule()
                    .fill(.blue)
                    .frame(width: x, height: 10)
                Circle()
                    .fill(.blue)
                    .overlay(Circle().stroke(.white, lineWidth: 3))
                    .overlay(Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    .offset(x: x - thumb / 2)
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { drag in
                let f = min(max((drag.location.x - thumb / 2) / usable, 0), 1)
                onChange(range.lowerBound + span * f)
            })
        }
        .frame(height: 44)
        .accessibilityElement()
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 20
            onChange(value + (direction == .increment ? step : -step))
        }
    }
}

extension Geo {
    /// "25 min", "1 h 30 min".
    static func format(seconds: Double) -> String {
        let minutes = max(0, Int((seconds / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}
