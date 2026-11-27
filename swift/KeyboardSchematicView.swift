import SwiftUI

/// Precision Apple-native vector schematic of the Lofree Flow 2 (84-key)
/// with live backlight glow, clickable keys, and clickable right-edge Touch Bar zones.
struct KeyboardSchematicView: View {
    @ObservedObject var state: FlowState
    @Environment(\.colorScheme) private var colorScheme

    private let zoneColors: [Color] = [.blue, .indigo, .cyan]

    var body: some View {
        TimelineView(.animation(minimumInterval: state.effect == 0 ? 0.5 : 1.0 / 30.0)) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            GeometryReader { geo in
                let totalCols: CGFloat = 16.0
                let totalRows: CGFloat = 6.0
                let wingUnits: CGFloat = 1.15
                let pad: CGFloat = 12
                let availW = max(200, geo.size.width - pad * 2)
                let availH = max(120, geo.size.height - pad * 2)
                let unit = min(availW / (totalCols + wingUnits + 0.5), availH / (totalRows + 0.45))

                let boardW = (totalCols + wingUnits + 0.5) * unit
                let boardH = (totalRows + 0.45) * unit
                let keysOriginX = (geo.size.width - boardW) / 2 + 0.22 * unit
                let keysOriginY = (geo.size.height - boardH) / 2 + 0.22 * unit

                let isLight = (state.finish == .silver)
                let caseFill = isLight
                    ? LinearGradient(colors: [Color(white: 0.91), Color(white: 0.84)], startPoint: .top, endPoint: .bottom)
                    : LinearGradient(colors: [Color(white: 0.20), Color(white: 0.14)], startPoint: .top, endPoint: .bottom)
                let caseStroke = isLight ? Color.black.opacity(0.14) : Color.white.opacity(0.14)

                ZStack(alignment: .topLeading) {
                    // CNC Aluminum Unibody Frame
                    RoundedRectangle(cornerRadius: unit * 0.32, style: .continuous)
                        .fill(caseFill)
                        .overlay(
                            RoundedRectangle(cornerRadius: unit * 0.32, style: .continuous)
                                .strokeBorder(caseStroke, lineWidth: 1)
                        )
                        .shadow(color: .black.opacity(colorScheme == .dark ? 0.45 : 0.14), radius: 12, y: 5)
                        .frame(width: boardW, height: boardH)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)

                    // Recessed Key Well
                    RoundedRectangle(cornerRadius: unit * 0.18, style: .continuous)
                        .fill(Color.black.opacity(isLight ? 0.12 : 0.42))
                        .frame(width: totalCols * unit + 6, height: totalRows * unit + 6)
                        .position(
                            x: keysOriginX + (totalCols * unit) / 2,
                            y: keysOriginY + (totalRows * unit) / 2
                        )

                    // All 84 Keys
                    ForEach(FlowState.layout84) { key in
                        let kw = CGFloat(key.w) * unit - 3
                        let kh = CGFloat(key.h) * unit - 3
                        let cx = keysOriginX + CGFloat(key.x + key.w / 2.0) * unit
                        let cy = keysOriginY + CGFloat(key.y + key.h / 2.0) * unit
                        let isSelected = (state.selectedKeyIndex == key.id)
                        let glow = backlightFactor(for: key, time: time)

                        KeycapView(
                            label: key.label,
                            width: kw,
                            height: kh,
                            isLight: isLight,
                            isSelected: isSelected,
                            glowOpacity: glow
                        )
                        .position(x: cx, y: cy)
                        .onTapGesture {
                            withAnimation(.snappy(duration: 0.16)) {
                                state.selectedKeyIndex = key.id
                            }
                        }
                    }

                    // Top-Right Status LED on the CNC Wing
                    let wingCenterX = keysOriginX + totalCols * unit + (wingUnits * unit) * 0.56
                    Capsule()
                        .fill(state.profileSupported ? Color.green : Color.orange)
                        .shadow(color: (state.profileSupported ? Color.green : Color.orange).opacity(0.75), radius: 4)
                        .frame(width: unit * 0.55, height: 3)
                        .position(x: wingCenterX, y: keysOriginY + unit * 0.22)

                    // Right-Edge Side Touch Bar (1, 2 or 3 clickable zones along right flank)
                    let edgeX = (geo.size.width + boardW) / 2 - 4
                    let tbTopY = keysOriginY + unit * 1.05
                    let tbHeight = totalRows * unit - unit * 1.25
                    SideTouchBarStrip(
                        count: state.touchZoneCount,
                        b1: state.touchB1,
                        b2: state.touchB2,
                        activeZone: state.activeTouchZone,
                        totalHeight: tbHeight,
                        colors: zoneColors
                    ) { zoneIdx in
                        withAnimation(.snappy(duration: 0.16)) {
                            state.activeTouchZone = zoneIdx
                            state.section = .touchbar
                        }
                    }
                    .position(x: edgeX, y: tbTopY + tbHeight / 2)
                }
            }
        }
        .frame(height: 220)
    }

    private func backlightFactor(for key: KeySpec, time: TimeInterval) -> Double {
        let base = max(0, min(1, state.brightness / 100.0))
        if base <= 0.01 { return 0 }
        let speeds = [0.65, 1.25, 2.0, 3.1]
        let sp = speeds[max(0, min(3, state.waveSpeed))]
        let nx = (key.x + key.w / 2.0) / 16.0
        let ny = (key.y + key.h / 2.0) / 6.0

        let factor: Double
        switch state.effect {
        case 1: factor = 0.25 + 0.75 * (0.5 + 0.5 * sin(time * sp * 1.6))
        case 2: factor = 0.2 + 0.8 * (0.5 + 0.5 * sin(time * sp * 2.4 - ny * 5.0))
        case 3: factor = 0.2 + 0.8 * (0.5 + 0.5 * sin(time * sp * 2.4 + ny * 5.0))
        case 4:
            let wave = sin(time * sp * 1.4) * 0.5 + 0.5
            factor = max(0.15, 1.0 - abs(nx - wave) * 2.1)
        case 5: factor = 0.3 + 0.7 * (0.5 + 0.5 * sin(time * sp * 2.0 - nx * 4.5 - ny * 2.0))
        case 6: factor = 0.2 + 0.8 * (0.5 + 0.5 * sin(time * sp * 3.0 - ny * 6.5 + sin(nx * 8.0)))
        default: factor = 1.0
        }
        return base * factor
    }
}

private struct KeycapView: View {
    let label: String
    let width: CGFloat
    let height: CGFloat
    let isLight: Bool
    let isSelected: Bool
    let glowOpacity: Double

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(
                    isSelected
                        ? Color.accentColor
                        : (isLight ? Color(white: 0.965) : Color(white: 0.175))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(
                            isSelected
                                ? Color.white.opacity(0.6)
                                : (isLight ? Color.black.opacity(0.12) : Color.white.opacity(0.1 + glowOpacity * 0.28)),
                            lineWidth: isSelected ? 1.5 : 0.75
                        )
                )
                .shadow(
                    color: glowOpacity > 0.05 && !isSelected
                        ? Color.white.opacity(glowOpacity * (isLight ? 0.22 : 0.32))
                        : Color.black.opacity(0.18),
                    radius: glowOpacity > 0.05 ? 3.5 : 1,
                    y: 0.5
                )

            if !label.isEmpty {
                Text(label)
                    .font(.system(size: label.count > 2 ? 7.5 : 9.5, weight: .medium, design: .rounded))
                    .foregroundStyle(
                        isSelected
                            ? Color.white
                            : (isLight ? Color(white: 0.15) : Color(white: 0.82 + glowOpacity * 0.18))
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(width: max(8, width), height: max(8, height))
        .contentShape(Rectangle())
    }
}

private struct SideTouchBarStrip: View {
    let count: Int
    let b1: Int
    let b2: Int
    let activeZone: Int
    let totalHeight: CGFloat
    let colors: [Color]
    let onSelect: (Int) -> Void

    var body: some View {
        let spans: [(Double, Double)] = {
            if count == 3 { return [(0, Double(b1) / 100), (Double(b1) / 100, Double(b2) / 100), (Double(b2) / 100, 1)] }
            if count == 2 { return [(0, Double(b1) / 100), (Double(b1) / 100, 1)] }
            return [(0, 1)]
        }()

        VStack(spacing: 3) {
            ForEach(0..<spans.count, id: \.self) { i in
                let frac = max(0.1, spans[i].1 - spans[i].0)
                let col = colors[i % colors.count]
                let isActive = (i == activeZone)
                Capsule()
                    .fill(col.opacity(isActive ? 1.0 : 0.45))
                    .shadow(color: isActive ? col.opacity(0.75) : .clear, radius: 5)
                    .frame(width: 5, height: max(12, totalHeight * frac - 3))
                    .onTapGesture { onSelect(i) }
                    .help(tr("Zone %d", i + 1))
            }
        }
    }
}
