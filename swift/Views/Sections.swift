import SwiftUI

// MARK: - Aperçu

struct OverviewSection: View {
    @ObservedObject var state: FlowState

    var body: some View {
        Form {
            if let device = state.selectedDevice {
                Section {
                    HStack(spacing: 14) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(device.name).font(.title3.weight(.semibold))
                            Text(state.statusMessage)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let percent = state.batteryPercent {
                            VStack(alignment: .trailing, spacing: 4) {
                                BatteryLabel(percent: percent, charging: state.isCharging)
                                    .font(.callout.weight(.medium))
                                Gauge(value: Double(percent), in: 0...100) { EmptyView() }
                                    .gaugeStyle(.accessoryLinearCapacity)
                                    .tint(percent < 15 ? .red : .green)
                                    .frame(width: 110)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !state.profileSupported && device.vendor && !state.isAsleep {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "sparkles")
                                .font(.title2)
                                .foregroundStyle(.indigo)
                                .frame(width: 30)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("Débloquer tous les réglages").font(.headline)
                                Text("Le firmware Studio ajoute la Touch Bar par zones, la réaffectation des touches, les effets lumineux et le délai de veille.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Voir le firmware") { state.section = .firmware }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("Clavier") {
                    LabeledContent("Modèle", value: device.model.isEmpty ? "Flow 2" : tr("Flow 2 · %@ touches", device.model))
                    LabeledContent("Connexion") {
                        Label(device.connection, systemImage: device.connectionSymbol)
                    }
                    LabeledContent("Firmware", value: state.firmwareVersion)
                    LabeledContent("Protocole", value: state.protocolVersion)
                }

                Section {
                    Picker("Finition", selection: $state.finish) {
                        ForEach(ChassisFinish.allCases) { finish in
                            Text(finish.title).tag(finish)
                        }
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Aperçu 3D")
                } footer: {
                    Text("Choisissez la couleur de votre clavier. Faites glisser le modèle pour le faire tourner, pincez pour zoomer.")
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Éclairage

struct LightingSection: View {
    @ObservedObject var state: FlowState

    var body: some View {
        Form {
            Section("Rétroéclairage") {
                LabeledContent("Luminosité") {
                    HStack(spacing: 8) {
                        Image(systemName: "light.min").foregroundStyle(.secondary)
                        Slider(value: state.binding(\.brightness) { $0.applyLighting(persist: false) }, in: 0...100) { editing in
                            if !editing {
                                state.brightness = state.brightness.rounded()
                                state.applyLighting(persist: true)
                            }
                        }
                        .accessibilityLabel("Luminosité du rétroéclairage")
                        Image(systemName: "light.max").foregroundStyle(.secondary)
                        Text("\(Int(state.brightness)) %")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }

                Picker("Effet", selection: Binding(
                    get: { state.effect },
                    set: { id in
                        guard state.isEffectAvailable(id) else { return }
                        state.effect = id
                        state.applyLighting(persist: true)
                    }
                )) {
                    ForEach(LightingCatalog.effects, id: \.id) { effect in
                        Text(effect.title).tag(effect.id).disabled(!state.isEffectAvailable(effect.id))
                    }
                }

                if state.effect > 0 {
                    Picker("Vitesse", selection: state.binding(\.waveSpeed) { $0.applyLighting(persist: true) }) {
                        ForEach(LightingCatalog.speeds, id: \.id) { speed in
                            Text(speed.title).tag(speed.id)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section {
                Toggle("Même luminosité que les touches", isOn: state.binding(\.syncBrightness) { $0.applyAdvanced() })
                    .disabled(!state.advancedSupported)

                LabeledContent("Luminosité du voyant") {
                    HStack(spacing: 8) {
                        Slider(value: $state.indicatorBrightness, in: 0...255) { editing in
                            if !editing { state.applyProfile() }
                        }
                        .accessibilityLabel("Luminosité du voyant")
                        Text("\(Int((state.indicatorBrightness / 255 * 100).rounded())) %")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .trailing)
                    }
                }
                .disabled(state.syncBrightness && state.advancedSupported)

                Toggle("Suivre l’effet du rétroéclairage", isOn: state.binding(\.syncBreathing) { $0.applyProfile() })
                Toggle("Allumé en Bluetooth", isOn: state.binding(\.indicatorBT) { $0.applyProfile() })
                Toggle("Allumé avec le récepteur 2,4 GHz", isOn: state.binding(\.indicatorRF) { $0.applyProfile() })
            } header: {
                Text("Voyant d’état")
            } footer: {
                Text("Le voyant est le trait lumineux en haut à droite du clavier.")
            }
        }
        .formStyle(.grouped)
        .disabled(!state.canConfigure)
    }
}

// MARK: - Énergie

struct PowerSection: View {
    @ObservedObject var state: FlowState

    private var timeoutIsPreset: Bool { LightingCatalog.timeouts.contains { $0.seconds == state.idleTimeout } }

    var body: some View {
        Form {
            Section {
                Picker("Mettre en veille après", selection: state.binding(\.idleTimeout) { $0.applyProfile() }) {
                    ForEach(LightingCatalog.timeouts, id: \.seconds) { option in
                        Text(option.title).tag(option.seconds)
                    }
                    if !timeoutIsPreset {
                        Text(tr("%d secondes", state.idleTimeout)).tag(state.idleTimeout)
                    }
                }

                Toggle("Réveiller en touchant la Touch Bar", isOn: state.binding(\.touchWake) { $0.applyProfile() })
            } header: {
                Text("Veille")
            } footer: {
                if state.idleTimeout == 0 {
                    Label("Sans mise en veille, la batterie se vide plus vite en Bluetooth et en 2,4 GHz.", systemImage: "exclamationmark.triangle")
                }
            }

            Section {
                if let percent = state.batteryPercent {
                    LabeledContent("Niveau actuel") {
                        BatteryLabel(percent: percent, charging: state.isCharging)
                    }
                }
                Picker("Alerte de batterie faible", selection: state.binding(\.lowBatteryThreshold) { $0.applyAdvanced() }) {
                    ForEach(LightingCatalog.lowBattery, id: \.self) { value in
                        Text(value == 0 ? tr("Par défaut") : tr("À %d %%", value)).tag(value)
                    }
                    if !LightingCatalog.lowBattery.contains(state.lowBatteryThreshold) {
                        Text(tr("À %d %%", state.lowBatteryThreshold)).tag(state.lowBatteryThreshold)
                    }
                }
                .disabled(!state.advancedSupported)
            } header: {
                Text("Batterie")
            } footer: {
                Text("Sous ce niveau, le voyant d’état passe au rouge.")
            }
        }
        .formStyle(.grouped)
        .disabled(!state.canConfigure)
    }
}

// MARK: - Touches

struct KeysSection: View {
    @ObservedObject var state: FlowState

    private var groups: [FlowActionGroup] {
        KeyCatalog.groups(touchProfiles: state.touchProfilesSupported, macroCount: state.macroCount)
    }

    private var selectedKey: KeySpec? {
        guard let index = state.selectedKeyIndex, index < FlowState.layout84.count else { return nil }
        return FlowState.layout84[index]
    }

    var body: some View {
        if state.keysSupported {
            editor
        } else {
            Form {
                Section {
                    Label("La réaffectation des touches ne gère pour l’instant que le Flow 2 84. Les autres réglages restent disponibles.", systemImage: "keyboard.badge.ellipsis")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
        }
    }

    private var editor: some View {
        Form {
            Section {
                Picker("Calque", selection: $state.activeLayer) {
                    ForEach(FlowLayer.allCases) { layer in
                        Text(layer.title).tag(layer)
                    }
                }
                .onChange(of: state.activeLayer) { _, _ in state.readActiveLayer() }

                if state.activeLayer.isFn {
                    LabeledContent("Rangée du haut avec Fn") {
                        HStack {
                            Button("F1 à F12") { state.applyFnTemplate("fkeys") }
                            Button("Disposition d’usine") { state.applyFnTemplate("factory") }
                        }
                    }
                    .disabled(!state.canConfigure || !state.layerLoaded)
                }
            } footer: {
                Text(state.activeLayer.hint)
            }

            Section("Touche sélectionnée") {
                if let key = selectedKey {
                    selectedKeyRows(key)
                } else {
                    Label("Cliquez sur une touche du clavier ci-dessus pour voir et changer son action.", systemImage: "cursorarrow.click.2")
                        .foregroundStyle(.secondary)
                }
            }

            let changed = state.changedKeys
            Section {
                if state.layerReadFailed {
                    HStack {
                        Label("Le calque n’a pas pu être lu.", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Réessayer") { state.readActiveLayer() }
                    }
                } else if !state.layerLoaded {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Lecture du calque…").foregroundStyle(.secondary)
                    }
                } else if changed.isEmpty {
                    Text("Ce calque est identique à la disposition d’usine.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(changed) { key in
                        HStack(spacing: 10) {
                            KeycapChip(label: key.label)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(state.code(for: key).map(KeyCatalog.title(for:)) ?? "—")
                                Text(tr("Au lieu de : %@", state.defaultCode(for: key).map(KeyCatalog.title(for:)) ?? "—"))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Rétablir") { state.restoreDefault(for: key) }
                                .disabled(!state.canConfigure)
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { state.selectedKeyIndex = key.id }
                        .accessibilityElement(children: .combine)
                    }
                }
            } header: {
                HStack {
                    Text(changed.isEmpty ? tr("Touches modifiées") : tr("Touches modifiées (%d)", changed.count))
                    Spacer()
                    Button("Rétablir le calque…") { state.showResetLayerConfirm = true }
                        .buttonStyle(.borderless)
                        .font(.callout)
                        .disabled(!state.canConfigure || changed.isEmpty)
                }
            } footer: {
                if !changed.isEmpty {
                    Text("Les touches modifiées ont une légende orange sur le clavier.")
                }
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private func selectedKeyRows(_ key: KeySpec) -> some View {
        let current = state.code(for: key)
        let fallback = state.defaultCode(for: key)
        HStack(spacing: 12) {
            KeycapChip(label: key.label, wide: key.w >= 2)
            VStack(alignment: .leading, spacing: 2) {
                Text(key.name).font(.headline)
                Text(tr("Calque %@", state.activeLayer.title))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 2)

        LabeledContent("Action") {
            if let current {
                ActionMenu(title: KeyCatalog.title(for: current), groups: groups, selection: current) { code in
                    state.assign(code, to: key)
                }
                .disabled(!state.canConfigure)
            } else {
                ProgressView().controlSize(.small)
            }
        }

        if let current, let fallback, current != fallback {
            LabeledContent("Action d’usine") {
                HStack(spacing: 10) {
                    Text(KeyCatalog.title(for: fallback)).foregroundStyle(.secondary)
                    Button("Rétablir") { state.restoreDefault(for: key) }
                        .disabled(!state.canConfigure)
                }
            }
        }
    }
}

// MARK: - Touch Bar

struct TouchBarSection: View {
    @ObservedObject var state: FlowState

    var body: some View {
        Form {
            if state.canConfigure && !state.touchLoaded {
                Section {
                    if state.touchReadFailed {
                        HStack {
                            Label("Les réglages de la Touch Bar n’ont pas pu être lus.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Réessayer") { state.readTouch() }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Lecture de la Touch Bar…").foregroundStyle(.secondary)
                        }
                    }
                }
            }
            touchSections
                .disabled(!state.touchReady)
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var touchSections: some View {
            Section {
                Picker("Zones", selection: Binding(
                    get: { state.touchZoneCount },
                    set: { state.setTouchZoneCount($0) }
                )) {
                    Text("1 zone").tag(1)
                    Text("2 zones").tag(2)
                    Text("3 zones").tag(3)
                }
                .pickerStyle(.segmented)

                TouchStripEditor(state: state)
                    .padding(.vertical, 4)
            } header: {
                Text("Découpage")
            } footer: {
                if state.touchProfilesSupported {
                    Text("Chaque découpage est un profil enregistré dans le clavier : vous pouvez passer de l’un à l’autre avec une touche ou un geste « Profil suivant ».")
                }
            }

            Section {
                Picker("Gestes", selection: $state.touchMode) {
                    Text("Normaux").tag(0)
                    Text("Avec Fn maintenue").tag(1)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text(state.touchMode == 0
                     ? tr("Actions déclenchées quand vous touchez la tranche droite du clavier.")
                     : tr("Actions déclenchées quand vous touchez la tranche droite en maintenant la touche Fn."))
            }

            ForEach(0..<state.touchZoneCount, id: \.self) { zone in
                zoneSection(zone)
            }
    }

    private func zoneSection(_ zone: Int) -> some View {
        let slots = state.touchSlots(zone: zone)
        let preset = TouchCatalog.preset(matching: slots)
        let color = TouchStripEditor.zoneColors[zone % TouchStripEditor.zoneColors.count]
        return Section {
            ForEach(TouchGesture.allCases) { gesture in
                LabeledContent {
                    ActionMenu(
                        title: TouchCatalog.title(for: slots[gesture.rawValue]),
                        groups: TouchCatalog.groups(for: gesture, touchProfiles: state.touchProfilesSupported, macroCount: state.macroCount),
                        selection: slots[gesture.rawValue]
                    ) { code in
                        state.activeTouchZone = zone
                        state.setTouchAction(code, zone: zone, gesture: gesture)
                    }
                } label: {
                    Label(gesture.title, systemImage: gesture.symbol)
                }
            }
        } header: {
            HStack(spacing: 6) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(state.touchZoneCount == 1 ? tr("Toute la Touch Bar") : tr("Zone %d", zone + 1))
                Spacer()
                Menu {
                    ForEach(TouchCatalog.presets) { option in
                        Button {
                            state.activeTouchZone = zone
                            state.applyTouchPreset(option, zone: zone)
                        } label: {
                            Label(option.title, systemImage: option.symbol)
                        }
                    }
                } label: {
                    Text(preset?.title ?? tr("Personnalisé"))
                        .font(.callout)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Appliquer un préréglage à cette zone")
            }
        }
    }
}

// MARK: - Firmware

struct FirmwareSection: View {
    @ObservedObject var state: FlowState

    var body: some View {
        Form {
            if let result = state.firmwareResult {
                Section {
                    HStack(spacing: 10) {
                        Image(systemName: result.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(result.ok ? .green : .orange)
                        Text(result.message)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("OK") { state.firmwareResult = nil }
                    }
                }
            }
            Section {
                LabeledContent("Version installée", value: state.firmwareVersion)
                LabeledContent("Studio fourni avec l’app", value: "0.10")
                LabeledContent("Connexion") {
                    if state.selectedDevice?.isUSB == true {
                        Label("USB-C", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("Câble USB-C requis", systemImage: "cable.connector").foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("Firmware")
            } footer: {
                Text("Le firmware Studio remplace celui de Lofree pour ajouter la Touch Bar par zones, la réaffectation des touches, les effets lumineux et le réglage de la veille.")
            }

            if state.isFlashing {
                Section("Opération en cours") {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: state.firmwareProgress)
                        Text(state.firmwareProgressText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        Label("Ne débranchez pas le clavier et ne quittez pas l’app.", systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section {
                    LabeledContent {
                        Button("Installer…") { state.showFlashConfirm = true }
                            .disabled(!state.canInstallFirmware)
                    } label: {
                        Text(state.profileSupported ? tr("Réinstaller Studio 0.10") : tr("Installer Studio 0.10"))
                        Text("Une sauvegarde vérifiée du firmware actuel est créée avant l’écriture.")
                    }
                    LabeledContent {
                        Button("Restaurer…", role: .destructive) { state.showRestoreConfirm = true }
                            .disabled(!state.canRestoreFirmware)
                    } label: {
                        Text("Revenir au firmware Lofree")
                        Text("Réinstalle le firmware d’origine 0.14.")
                    }
                    LabeledContent {
                        Button("Ouvrir le dossier") { state.openFirmwareBackups() }
                    } label: {
                        Text("Sauvegardes")
                        Text("Images du firmware enregistrées sur ce Mac avant chaque écriture.")
                    }
                } header: {
                    Text("Actions")
                } footer: {
                    VStack(alignment: .leading, spacing: 6) {
                        if !state.canInstallFirmware, !state.canRestoreFirmware, !state.isDemo, let message = state.firmwareStatusMessage {
                            Text(message)
                        }
                        Label("Une écriture interrompue peut rendre le clavier inutilisable. Gardez le câble branché jusqu’à la fin.", systemImage: "exclamationmark.triangle")
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}
