import SwiftUI
import AppKit

/// Refuses to quit while a firmware write is in progress.
final class FlowAppDelegate: NSObject, NSApplicationDelegate {
    static weak var state: FlowState?
    private var quitWhenIdle = false

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let state = FlowAppDelegate.state else { return .terminateNow }
        guard state.isFlashing else {
            state.stopMacroRecording(keep: false)
            if state.pendingOperations == 0 || quitWhenIdle { return .terminateNow }
            // A write cut short can leave the keyboard's memory half written: let it finish, then quit.
            // The quit is cancelled and asked again so the run loop keeps running normally meanwhile.
            quitWhenIdle = true
            state.afterPendingOperations { NSApp.terminate(nil) }
            return .terminateCancel
        }
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = tr("Mise à jour du firmware en cours")
        alert.informativeText = tr("Quitter maintenant peut rendre le clavier inutilisable. Attendez la fin de l’opération.")
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return .terminateCancel
    }
}

@main
struct FlowOperatorApp: App {
    @NSApplicationDelegateAdaptor(FlowAppDelegate.self) private var appDelegate
    @StateObject private var state = FlowState()

    init() {
        FlowLanguage.configureEngine()
    }

    var body: some Scene {
        WindowGroup("Flow Operator") {
            RootView(state: state)
                .frame(minWidth: 900, minHeight: 640)
                .onAppear { FlowAppDelegate.state = state }
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1040, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .sidebar) {
                Divider()
                Button("Vue en perspective") { state.cameraPreset = .cinematic; state.cameraNonce += 1 }
                    .keyboardShortcut("1", modifiers: .command)
                Button("Vue de dessus") { state.cameraPreset = .top; state.cameraNonce += 1 }
                    .keyboardShortcut("2", modifiers: .command)
                Button("Vue de la Touch Bar") { state.cameraPreset = .touchbar; state.cameraNonce += 1 }
                    .keyboardShortcut("3", modifiers: .command)
                Button("Vue de profil") { state.cameraPreset = .profile; state.cameraNonce += 1 }
                    .keyboardShortcut("4", modifiers: .command)
                Button("Recentrer la vue") { state.cameraNonce += 1 }
                    .keyboardShortcut("0", modifiers: .command)
                Divider()
                Picker("Finition du clavier", selection: $state.finish) {
                    ForEach(ChassisFinish.allCases) { finish in
                        Text(finish.title).tag(finish)
                    }
                }
            }
            CommandMenu("Clavier") {
                Button("Actualiser") {
                    state.scanDevices()
                    state.refreshAll()
                }
                .keyboardShortcut("r", modifiers: .command)
                .disabled(state.isFlashing)
                Button("Réveiller le clavier") { state.wakeKeyboard() }
                    .disabled(!state.isConnected || state.isFlashing)
                Divider()
                ForEach(SidebarSection.allCases) { section in
                    Button(section.title) { state.section = section }
                }
            }
        }

        MenuBarExtra {
            VStack(alignment: .leading, spacing: 6) {
                if let device = state.selectedDevice {
                    Text(device.name).font(.headline)
                    if let percent = state.batteryPercent {
                        Text(state.isCharging ? tr("Batterie : %d %% (en charge)", percent) : tr("Batterie : %d %%", percent))
                            .foregroundStyle(.secondary)
                    } else {
                        Text(tr("Connexion : %@", device.connection))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text("Aucun Lofree Flow 2 détecté")
                        .foregroundStyle(.secondary)
                }
                Divider()
                Button("Actualiser") { state.scanDevices(); state.refreshAll() }
                Button("Quitter Flow Operator") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .padding(6)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "keyboard")
                if let percent = state.batteryPercent {
                    Text("\(percent)%").monospacedDigit()
                }
            }
        }
    }
}
