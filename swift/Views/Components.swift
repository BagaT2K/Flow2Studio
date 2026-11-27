import SwiftUI

// MARK: - Floating controls

extension View {
    /// Liquid Glass on macOS 26 and later, a regular material before that.
    @ViewBuilder
    func floatingGlass() -> some View {
        if #available(macOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(.separator, lineWidth: 0.5))
        }
    }
}

// MARK: - Action menu

/// Pop-up menu listing every assignable action, grouped in submenus, with a checkmark on the current one.
struct ActionMenu: View {
    let title: String
    let groups: [FlowActionGroup]
    let selection: Int
    let onSelect: (Int) -> Void

    var body: some View {
        Menu {
            ForEach(groups) { group in
                if group.inline {
                    Section(group.title) { items(group) }
                } else {
                    Menu {
                        items(group)
                    } label: {
                        Label(group.title, systemImage: group.symbol)
                    }
                }
            }
        } label: {
            Text(title)
                .lineLimit(1)
        }
        .menuStyle(.button)
        .fixedSize()
    }

    @ViewBuilder
    private func items(_ group: FlowActionGroup) -> some View {
        ForEach(group.actions) { action in
            Toggle(action.title, isOn: Binding(
                get: { action.code == selection },
                set: { _ in onSelect(action.code) }
            ))
        }
    }
}

// MARK: - Keycap chip

/// A small keycap, used to name a physical key in text.
struct KeycapChip: View {
    let label: String
    var wide = false

    var body: some View {
        Text(label.isEmpty ? tr("espace") : label)
            .font(.system(size: label.count > 2 || label.isEmpty ? 11 : 15, weight: .medium, design: .rounded))
            .foregroundStyle(.primary)
            .frame(minWidth: wide ? 64 : 38, minHeight: 38)
            .padding(.horizontal, label.count > 2 || label.isEmpty ? 8 : 0)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .shadow(color: .black.opacity(0.18), radius: 1.5, y: 1)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.separator, lineWidth: 0.5)
            )
            .accessibilityHidden(true)
    }
}

// MARK: - Banner

struct BannerView<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            trailing()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.25), lineWidth: 0.5))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Battery

struct BatteryLabel: View {
    let percent: Int
    let charging: Bool

    private var symbol: String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<13: return "battery.0percent"
        case ..<38: return "battery.25percent"
        case ..<63: return "battery.50percent"
        case ..<88: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: symbol)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(charging ? .green : (percent < 15 ? .red : .secondary))
            Text("\(percent) %")
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(charging ? tr("Batterie %d pour cent, en charge", percent) : tr("Batterie %d pour cent", percent))
    }
}

// MARK: - Touch strip editor

/// The side Touch Bar laid flat: tap a zone to select it, drag a divider to resize the zones.
struct TouchStripEditor: View {
    @ObservedObject var state: FlowState
    static let zoneColors: [Color] = [.blue, .indigo, .cyan]

    private var spans: [(Double, Double)] {
        let b1 = Double(state.touchB1) / 100, b2 = Double(state.touchB2) / 100
        switch state.touchZoneCount {
        case 3: return [(0, b1), (b1, b2), (b2, 1)]
        case 2: return [(0, b1), (b1, 1)]
        default: return [(0, 1)]
        }
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let width = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.black.opacity(0.85))
                    ForEach(Array(spans.enumerated()), id: \.offset) { index, span in
                        let active = index == state.activeTouchZone
                        let color = Self.zoneColors[index % Self.zoneColors.count]
                        Capsule()
                            .fill(color.opacity(active ? 1 : 0.42))
                            .overlay(
                                Text(tr("Zone %d", index + 1))
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.white.opacity(active ? 1 : 0.8))
                            )
                            .shadow(color: active ? color.opacity(0.7) : .clear, radius: 6)
                            .frame(width: max(24, (span.1 - span.0) * width - 8), height: 22)
                            .offset(x: span.0 * width + 4)
                            .onTapGesture {
                                withAnimation(.snappy(duration: 0.18)) { state.activeTouchZone = index }
                            }
                            .accessibilityLabel(tr("Zone %d", index + 1))
                            .accessibilityAddTraits(active ? [.isSelected, .isButton] : .isButton)
                    }
                    if state.touchZoneCount >= 2 { divider(1, width: width) }
                    if state.touchZoneCount >= 3 { divider(2, width: width) }
                }
                .coordinateSpace(name: "touchStrip")
            }
            .frame(height: 30)

            HStack {
                Label("Haut", systemImage: "arrow.up")
                Spacer()
                if state.touchZoneCount > 1 {
                    Text("Faites glisser les séparateurs pour redimensionner les zones")
                }
                Spacer()
                Label("Bas", systemImage: "arrow.down")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .labelStyle(.titleAndIcon)
        }
    }

    private func divider(_ which: Int, width: CGFloat) -> some View {
        let value = which == 1 ? state.touchB1 : state.touchB2
        return Capsule()
            .fill(.white)
            .frame(width: 5, height: 30)
            .shadow(color: .black.opacity(0.4), radius: 2)
            .contentShape(Rectangle().inset(by: -8))
            .offset(x: CGFloat(value) / 100 * width - 2.5)
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .named("touchStrip"))
                    .onChanged { drag in
                        let percent = Int((drag.location.x / max(width, 1) * 100).rounded())
                        if which == 1 {
                            let upper = state.touchZoneCount == 3 ? state.touchB2 - TouchCatalog.minimumGap : TouchCatalog.b1Range.upperBound
                            state.touchB1 = min(max(percent, TouchCatalog.b1Range.lowerBound), upper)
                        } else {
                            let lower = max(TouchCatalog.b2Range.lowerBound, state.touchB1 + TouchCatalog.minimumGap)
                            state.touchB2 = min(max(percent, lower), TouchCatalog.b2Range.upperBound)
                        }
                    }
                    .onEnded { _ in state.applyTouchBar() }
            )
            .help(tr("Limite à %d %%", value))
            .accessibilityLabel(which == 1 ? tr("Limite entre les zones 1 et 2") : tr("Limite entre les zones 2 et 3"))
            .accessibilityValue(tr("%d pour cent", value))
    }
}
