import SwiftUI
import AppKit

// MARK: - Root

struct RootView: View {
    @ObservedObject var state: FlowState

    var body: some View {
        NavigationSplitView {
            SidebarView(state: state)
                .navigationSplitViewColumnWidth(min: 214, ideal: 232, max: 280)
        } detail: {
            DetailView(state: state)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if state.devices.count > 1 {
                    Picker("Clavier", selection: Binding(
                        get: { state.selectedDevice?.id ?? "" },
                        set: { id in if let d = state.devices.first(where: { $0.id == id }) { state.selectDevice(d) } }
                    )) {
                        ForEach(state.devices) { device in
                            Text("\(device.name) · \(device.connection)").tag(device.id)
                        }
                    }
                    .help("Choisir le clavier à configurer")
                }
                if let device = state.selectedDevice {
                    HStack(spacing: 10) {
                        Label(device.connection, systemImage: device.connectionSymbol)
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.secondary)
                        if let percent = state.batteryPercent {
                            BatteryLabel(percent: percent, charging: state.isCharging)
                        }
                    }
                    .font(.subheadline)
                    .padding(.horizontal, 6)
                    .help(state.statusMessage)
                }
                Button {
                    state.scanDevices()
                    state.refreshAll()
                } label: {
                    Label("Actualiser", systemImage: "arrow.clockwise")
                }
                .help("Relire les réglages du clavier (⌘R)")
                .disabled(state.isFlashing)
            }
        }
        .alert("Installer le firmware Studio 0.10 ?", isPresented: $state.showFlashConfirm) {
            Button("Annuler", role: .cancel) {}
            Button("Installer", role: .destructive) { state.prepareStudioFirmware(restoreStock: false) }
        } message: {
            Text("Le firmware actuel est sauvegardé et vérifié avant l’écriture. Gardez le câble USB-C branché sur le même port et ne quittez pas l’app pendant l’opération : une coupure peut rendre le clavier inutilisable.")
        }
        .alert("Restaurer le firmware d’origine ?", isPresented: $state.showRestoreConfirm) {
            Button("Annuler", role: .cancel) {}
            Button("Restaurer", role: .destructive) { state.prepareStudioFirmware(restoreStock: true) }
        } message: {
            Text("Le clavier revient au firmware Lofree 0.14. Les réglages avancés (Touch Bar par zones, veille, effets) ne seront plus disponibles. Gardez le câble USB-C branché sur le même port jusqu’à la fin.")
        }
        .alert(tr("Rétablir le calque %@ ?", state.activeLayer.title), isPresented: $state.showResetLayerConfirm) {
            Button("Annuler", role: .cancel) {}
            Button("Rétablir", role: .destructive) { state.resetActiveLayer() }
        } message: {
            Text("Toutes les touches de ce calque reprennent leur action d’usine. Les autres calques ne changent pas.")
        }
        .alert(item: $state.riskyAssignment) { risky in
            Alert(
                title: Text(tr("Remplacer « %@ » ?", risky.currentTitle)),
                message: Text("Cette touche donne accès à un calque. Si vous la réaffectez, les fonctions de ce calque (Bluetooth, mode Mac ou Windows, réglages Fn) ne seront plus accessibles depuis le clavier tant qu’une autre touche ne reprend pas ce rôle."),
                primaryButton: .destructive(Text("Remplacer")) { state.assign(risky.code, to: risky.key, confirmed: true) },
                secondaryButton: .cancel(Text("Annuler"))
            )
        }
    }
}

// MARK: - Sidebar

struct SidebarView: View {
    @ObservedObject var state: FlowState

    var body: some View {
        List(selection: $state.section) {
            ForEach(SidebarSection.groups, id: \.title) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        Label {
                            Text(section.title)
                        } icon: {
                            RoundedRectangle(cornerRadius: 5.5, style: .continuous)
                                .fill(section.badgeColor.gradient)
                                .frame(width: 22, height: 22)
                                .overlay(
                                    Image(systemName: section.symbol)
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(.white)
                                )
                        }
                        .tag(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) {
            DeviceCard(state: state)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 6)
                .padding(.bottom, 10)
        }
    }
}

/// Which keyboard is connected, how, and how much battery it has.
struct DeviceCard: View {
    @ObservedObject var state: FlowState

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.34), Color(white: 0.16)], startPoint: .top, endPoint: .bottom))
                .frame(width: 36, height: 36)
                .overlay(
                    Image(systemName: "keyboard.fill")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(.white)
                )
            VStack(alignment: .leading, spacing: 2) {
                Text(state.selectedDevice?.name ?? "Flow Operator")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var statusColor: Color {
        guard state.selectedDevice != nil else { return .secondary }
        if state.isAsleep { return .yellow }
        return state.profileSupported ? .green : .orange
    }

    private var statusText: String {
        guard let device = state.selectedDevice else { return tr("Aucun clavier") }
        if state.isAsleep { return tr("En veille · %@", device.connection) }
        if let percent = state.batteryPercent { return "\(device.connection) · \(percent) %" }
        return device.connection
    }
}

// MARK: - Stage

/// The keyboard itself, always on screen above the settings.
struct StageView: View {
    @ObservedObject var state: FlowState
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                RadialGradient(
                    colors: [Color.white.opacity(colorScheme == .dark ? 0.075 : 0.55), .clear],
                    center: UnitPoint(x: 0.5, y: 0.6), startRadius: 10, endRadius: 430
                )
                if Keyboard3DView.isAvailable {
                    Keyboard3DView(state: state)
                        .accessibilityLabel("Lofree Flow 2 en 3D")
                } else {
                    KeyboardSchematicView(state: state)
                }
            }
            .frame(height: 270)

            // Controls sit under the keyboard, never on top of it.
            HStack(spacing: 12) {
                hint
                Spacer(minLength: 8)
                if Keyboard3DView.isAvailable { cameraControl }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .frame(height: 40)
        }
    }

    @ViewBuilder
    private var hint: some View {
        switch state.section {
        case .keys, .macros:
            if let index = state.selectedKeyIndex, index < FlowState.layout84.count {
                Label(FlowState.layout84[index].name, systemImage: "cursorarrow.click.2")
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .floatingGlass()
            } else {
                Label("Cliquez sur une touche", systemImage: "cursorarrow.click.2")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .floatingGlass()
            }
        case .touchbar:
            Label(tr("Zone %d sur la tranche droite", state.activeTouchZone + 1), systemImage: "hand.draw")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .floatingGlass()
        default:
            EmptyView()
        }
    }

    private var cameraControl: some View {
        HStack(spacing: 6) {
            Picker("Vue", selection: $state.cameraPreset) {
                ForEach(CameraPreset.allCases) { preset in
                    Text(preset.title).tag(preset)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Button {
                state.cameraNonce += 1
            } label: {
                Image(systemName: "scope")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .help("Recentrer la vue (⌘0)")
            .accessibilityLabel("Recentrer la vue")
        }
        .padding(.leading, 4).padding(.trailing, 9).padding(.vertical, 4)
        .floatingGlass()
    }
}

// MARK: - Detail

struct DetailView: View {
    @ObservedObject var state: FlowState

    var body: some View {
        content
            .safeAreaInset(edge: .top, spacing: 0) {
                // The keyboard stays in place while the settings scroll underneath.
                VStack(spacing: 0) {
                    StageView(state: state)
                    banners
                }
            }
            // The split view sizes its columns from their ideal height: keep it below any window height
            // so a long form scrolls instead of pushing the whole column under the title bar.
            .frame(minHeight: 420, idealHeight: 480, maxHeight: .infinity)
            .navigationTitle(state.section.title)
        .onChange(of: state.section) { _, section in
            // The camera follows what is being configured.
            switch section {
            case .touchbar: state.cameraPreset = .touchbar
            case .keys, .macros: state.cameraPreset = .top
            default: state.cameraPreset = .cinematic
            }
            if section == .keys || section == .macros { state.readActiveLayer() }
            if section == .macros { state.readMacros() } else { state.stopMacroRecording() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if state.selectedDevice == nil {
            ContentUnavailableView {
                Label("Aucun clavier détecté", systemImage: "keyboard")
            } description: {
                Text("Branchez votre Lofree Flow 2 en USB-C, ou allumez-le en Bluetooth ou avec son récepteur 2,4 GHz.")
            } actions: {
                Button("Rechercher à nouveau") { state.scanDevices() }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            switch state.section {
            case .general: OverviewSection(state: state)
            case .lighting: LightingSection(state: state)
            case .power: PowerSection(state: state)
            case .keys: KeysSection(state: state)
            case .touchbar: TouchBarSection(state: state)
            case .macros: MacrosSection(state: state)
            case .firmware: FirmwareSection(state: state)
            }
        }
    }

    @ViewBuilder
    private var banners: some View {
        VStack(spacing: 8) {
            if let error = state.errorMessage {
                BannerView(symbol: "exclamationmark.triangle.fill", tint: .orange, title: tr("Action impossible"), message: error) {
                    if state.isAsleep {
                        Button("Réveiller") { state.wakeKeyboard() }
                    }
                    Button {
                        state.errorMessage = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("Fermer")
                }
            }
            if state.isDemo && !UserDefaults.standard.bool(forKey: "FlowDemoHideBanner") {
                BannerView(symbol: "play.rectangle", tint: .blue, title: tr("Mode démonstration"),
                           message: tr("Clavier simulé : rien n’est envoyé à un vrai clavier.")) { EmptyView() }
            } else if let device = state.selectedDevice, !state.profileSupported, state.section != .firmware, state.section != .general {
                if !device.vendor {
                    BannerView(symbol: "lock", tint: .secondary, title: tr("Lecture seule"),
                               message: tr("Dans ce mode de connexion, seul le niveau de batterie est disponible. Branchez le clavier en USB-C pour le configurer.")) { EmptyView() }
                } else if state.isAsleep {
                    BannerView(symbol: "moon.zzz", tint: .yellow, title: tr("Clavier en veille"),
                               message: tr("Appuyez sur une touche du clavier, puis actualisez.")) {
                        Button("Réveiller") { state.wakeKeyboard() }
                    }
                } else {
                    BannerView(symbol: "sparkles", tint: .indigo, title: tr("Firmware d’origine"),
                               message: tr("Ces réglages demandent le firmware Studio.")) {
                        Button("Voir le firmware") { state.section = .firmware }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, state.errorMessage != nil || state.isDemo || (!state.profileSupported && state.selectedDevice != nil) ? 4 : 0)
        .animation(.snappy(duration: 0.2), value: state.errorMessage)
    }
}
