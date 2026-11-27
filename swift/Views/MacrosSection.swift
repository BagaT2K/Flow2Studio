import SwiftUI

/// Editor for the 16 macros stored in the keyboard.
struct MacrosSection: View {
    @ObservedObject var state: FlowState

    private var slot: Int { state.macroSlot }
    private var items: [MacroItem] { state.macroDraft }
    private var selectedKey: KeySpec? {
        guard let index = state.selectedKeyIndex, index < FlowState.layout84.count else { return nil }
        return FlowState.layout84[index]
    }

    var body: some View {
        Form {
            Section {
                slotGrid
            } header: {
                Text("Emplacements")
            } footer: {
                Text("Une macro rejoue une suite de touches ou un texte quand vous appuyez sur la touche à laquelle elle est assignée. Le clavier en garde 16 en mémoire : elles fonctionnent sur n’importe quel appareil, sans cette app.")
            }

            if !state.macrosLoaded {
                Section {
                    if state.macroRepair != nil {
                        LabeledContent {
                            Button("Réparer") { state.repairMacros() }
                                .disabled(!state.canConfigure)
                        } label: {
                            Text("Mémoire des macros à réparer")
                            Text("La dernière écriture a été interrompue. La réparation conserve vos macros.")
                        }
                    } else if state.macrosReadFailed {
                        HStack {
                            Label("Les macros n’ont pas pu être lues.", systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Réessayer") { state.readMacros() }
                        }
                    } else {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Lecture des macros…").foregroundStyle(.secondary)
                        }
                    }
                }
            } else if state.macroReadOnly {
                Section(tr("Macro %d", slot + 1)) {
                    Label("Cette macro contient des instructions que l’éditeur ne sait pas afficher. Elle est conservée telle quelle.", systemImage: "lock")
                        .foregroundStyle(.secondary)
                }
            } else {
                stepsSection
                saveSection
                triggerSection
            }
        }
        .formStyle(.grouped)
        .onDisappear { state.stopMacroRecording() }
    }

    // MARK: Slots

    private var slotGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 8), spacing: 8) {
            ForEach(0..<MacroCodec.slotCount, id: \.self) { index in
                let selected = index == slot
                let saved = state.savedMacro(index)
                let filled = saved.map { !$0.isEmpty } ?? true
                Button {
                    state.stopMacroRecording()
                    state.macroSlot = index
                } label: {
                    Text("\(index + 1)")
                        .font(.body.weight(selected ? .semibold : .regular))
                        .monospacedDigit()
                        .frame(maxWidth: .infinity, minHeight: 30)
                        .foregroundStyle(selected ? Color.white : (filled ? Color.primary : Color.secondary))
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(selected ? Color.accentColor : Color.primary.opacity(filled ? 0.10 : 0.04))
                        )
                        .overlay(alignment: .topTrailing) {
                            if state.macroIsDirty(index) {
                                Circle().fill(.orange).frame(width: 7, height: 7).padding(4)
                            }
                        }
                }
                .buttonStyle(.plain)
                .help(slotHelp(index, saved: saved))
                .accessibilityLabel(tr("Macro %d", index + 1))
                .accessibilityValue(slotHelp(index, saved: saved))
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(.vertical, 4)
    }

    private func slotHelp(_ index: Int, saved: [MacroStep]?) -> String {
        let text = saved.map { MacroCodec.summary($0) } ?? tr("Format inconnu")
        return state.macroIsDirty(index) ? tr("%@ (modifications non enregistrées)", text) : text
    }

    // MARK: Steps

    private var stepsSection: some View {
        Section {
            if items.isEmpty && !state.isRecordingMacro {
                Label("Cette macro est vide. Enregistrez des frappes, ou ajoutez les étapes une à une.", systemImage: "sparkles")
                    .foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                stepRow(item)
            }
            if state.isRecordingMacro {
                HStack(spacing: 10) {
                    Image(systemName: "record.circle.fill")
                        .foregroundStyle(.red)
                        .symbolEffect(.pulse)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Enregistrement : tapez la suite de touches.")
                        Text(state.recordingPreview.isEmpty ? tr("En attente d’une touche…") : state.recordingPreview)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    Spacer()
                    Button("Arrêter") { state.stopMacroRecording() }
                }
            }
            HStack {
                Menu {
                    Button { state.appendMacroStep(.text("")) } label: { Label("Texte à taper", systemImage: "textformat") }
                    Button { state.appendMacroStep(.tap(40)) } label: { Label("Appui sur une touche", systemImage: "keyboard") }
                    Button { state.appendMacroStep(.wait(200)) } label: { Label("Pause", systemImage: "timer") }
                    Divider()
                    Button { state.appendMacroStep(.down(227)) } label: { Label("Maintenir une touche", systemImage: "arrow.down.to.line") }
                    Button { state.appendMacroStep(.up(227)) } label: { Label("Relâcher une touche", systemImage: "arrow.up.to.line") }
                } label: {
                    Label("Ajouter une étape", systemImage: "plus")
                }
                .menuStyle(.button)
                .fixedSize()
                Spacer()
                Toggle("Garder les pauses", isOn: $state.macroKeepDelays)
                    .toggleStyle(.checkbox)
                    .help("Rejouer aussi le temps écoulé entre deux frappes")
                Button {
                    state.startMacroRecording()
                } label: {
                    Label("Enregistrer des frappes", systemImage: "record.circle")
                }
            }
            .disabled(state.isRecordingMacro)
        } header: {
            HStack {
                Text(tr("Macro %d", slot + 1))
                Spacer()
                Text(MacroCodec.summary(items.map(\.step)))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } footer: {
            Text("Le texte est tapé comme sur un clavier QWERTY américain, sans accents. Pour un raccourci comme ⌘C, le plus simple est de l’enregistrer.")
        }
    }

    @ViewBuilder
    private func stepRow(_ item: MacroItem) -> some View {
        HStack(spacing: 10) {
            switch item.step {
            case .text(let text):
                stepIcon("textformat", .blue)
                Text("Taper")
                TextField("Texte", text: Binding(
                    get: { text },
                    set: { state.updateMacroStep(item.id, .text($0)) }
                ), prompt: Text("Texte à taper"))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            case .tap(let key):
                stepIcon("keyboard", .gray)
                Text("Appuyer sur")
                keyMenu(key) { state.updateMacroStep(item.id, .tap($0)) }
                Spacer()
            case .down(let key):
                stepIcon("arrow.down.to.line", .purple)
                Text("Maintenir")
                keyMenu(key) { state.updateMacroStep(item.id, .down($0)) }
                Spacer()
            case .up(let key):
                stepIcon("arrow.up.to.line", .purple)
                Text("Relâcher")
                keyMenu(key) { state.updateMacroStep(item.id, .up($0)) }
                Spacer()
            case .wait(let ms):
                stepIcon("timer", .orange)
                Text("Attendre")
                TextField("Durée", value: Binding(
                    get: { ms },
                    set: { state.updateMacroStep(item.id, .wait(min(max($0, 1), MacroCodec.maxWait))) }
                ), format: .number.grouping(.never))
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(width: 72)
                .multilineTextAlignment(.trailing)
                Text("ms").foregroundStyle(.secondary)
                Spacer()
            }
            Button {
                state.removeMacroStep(item.id)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Supprimer cette étape")
            .accessibilityLabel("Supprimer cette étape")
        }
        .contextMenu {
            Button("Monter") { state.moveMacroStep(item.id, by: -1) }
            Button("Descendre") { state.moveMacroStep(item.id, by: 1) }
            Divider()
            Button("Supprimer", role: .destructive) { state.removeMacroStep(item.id) }
        }
        .disabled(state.isRecordingMacro)
    }

    private func stepIcon(_ symbol: String, _ color: Color) -> some View {
        RoundedRectangle(cornerRadius: 5, style: .continuous)
            .fill(color.gradient)
            .frame(width: 22, height: 22)
            .overlay(Image(systemName: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
            .accessibilityHidden(true)
    }

    private func keyMenu(_ key: Int, onSelect: @escaping (Int) -> Void) -> some View {
        ActionMenu(title: KeyCatalog.title(for: key), groups: KeyCatalog.hidGroups, selection: key, onSelect: onSelect)
    }

    // MARK: Save

    @ViewBuilder
    private var saveSection: some View {
        let encoded = state.macroDraftBytes
        let dirty = state.macroIsDirty(slot)
        Section {
            if case .failure(let error) = encoded {
                Label(error.message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            } else if case .success(let bytes) = encoded, bytes.count > state.macroBudget {
                Label(MacroError.tooLarge(used: bytes.count, available: state.macroBudget).message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            HStack {
                if case .success(let bytes) = encoded {
                    Text(tr("%d octets sur %d disponibles", bytes.count, max(0, state.macroBudget)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
                Spacer()
                if dirty {
                    Button("Annuler les modifications") { state.revertMacro() }
                }
                Button("Enregistrer dans le clavier") { state.saveMacro() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!dirty || !state.canConfigure || state.isRecordingMacro || !canSave(encoded))
            }
        }
    }

    private func canSave(_ encoded: Result<[UInt8], MacroError>) -> Bool {
        if case .success(let bytes) = encoded { return bytes.count <= state.macroBudget }
        return false
    }

    // MARK: Trigger

    @ViewBuilder
    private var triggerSection: some View {
        let triggers = state.macroTriggers(slot)
        Section {
            if triggers.isEmpty {
                Text(tr("Aucune touche du calque %@ ne lance cette macro.", state.activeLayer.title))
                    .foregroundStyle(.secondary)
            } else {
                LabeledContent("Lancée par") {
                    HStack(spacing: 6) {
                        ForEach(triggers) { key in KeycapChip(label: key.label) }
                    }
                }
            }
            if !state.keysSupported {
                EmptyView()
            } else if let key = selectedKey {
                LabeledContent {
                    Button("Assigner") { state.assign(KeyCatalog.macroBase + slot, to: key) }
                        .disabled(!state.canConfigure || !state.layerLoaded || state.code(for: key) == KeyCatalog.macroBase + slot)
                } label: {
                    Text(tr("Assigner à « %@ »", key.name))
                    Text(tr("Remplace son action actuelle : %@", state.code(for: key).map(KeyCatalog.title(for:)) ?? "—"))
                }
            } else {
                Label("Cliquez sur une touche du clavier ci-dessus pour lui assigner cette macro.", systemImage: "cursorarrow.click.2")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Déclencheur")
        } footer: {
            Text(tr("Vous pouvez aussi choisir « Macro %d » dans Touches, sur n’importe quel calque, ou dans les gestes de la Touch Bar.", slot + 1))
        }
    }
}
