import Foundation
import SwiftUI
import Combine

// MARK: - Navigation

enum SidebarSection: String, CaseIterable, Identifiable {
    case general = "Aperçu"
    case lighting = "Éclairage"
    case power = "Énergie"
    case keys = "Touches"
    case touchbar = "Touch Bar"
    case macros = "Macros"
    case firmware = "Firmware"

    var id: String { rawValue }
    var title: String { tr(rawValue) }

    var symbol: String {
        switch self {
        case .general:  return "keyboard"
        case .lighting: return "light.max"
        case .power:    return "battery.75percent"
        case .keys:     return "character.cursor.ibeam"
        case .touchbar: return "hand.draw.fill"
        case .macros:   return "record.circle"
        case .firmware: return "cpu"
        }
    }

    var badgeColor: Color {
        switch self {
        case .general:  return .gray
        case .lighting: return .orange
        case .power:    return .green
        case .keys:     return .blue
        case .touchbar: return .pink
        case .macros:   return .red
        case .firmware: return .indigo
        }
    }

    static let groups: [(title: String, sections: [SidebarSection])] = [
        (tr("Clavier"), [.general, .lighting, .power]),
        (tr("Personnalisation"), [.keys, .touchbar, .macros]),
        (tr("Système"), [.firmware]),
    ]
}

enum CameraPreset: String, CaseIterable, Identifiable {
    case cinematic = "Perspective"
    case top = "Dessus"
    case touchbar = "Touch Bar"
    case profile = "Profil"
    var id: String { rawValue }
    var title: String { tr(rawValue) }
}

enum ChassisFinish: String, CaseIterable, Identifiable {
    case spaceGray = "Gris sidéral"
    case silver = "Argent"
    var id: String { rawValue }
    var title: String { tr(rawValue) }
}

struct FlowDeviceInfo: Identifiable, Hashable {
    let id: String
    let name: String
    let model: String
    /// "USB", "2,4 GHz" or "Bluetooth".
    let connection: String
    let vendor: Bool
    let bootloader: Bool
    let raw: [String: Any]

    static func == (lhs: FlowDeviceInfo, rhs: FlowDeviceInfo) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }

    var isUSB: Bool { connection == "USB" }
    var connectionSymbol: String {
        switch connection {
        case "USB": return "cable.connector"
        case "Bluetooth": return "dot.radiowaves.left.and.right"
        default: return "antenna.radiowaves.left.and.right"
        }
    }
}

/// A key assignment waiting for the user's confirmation because it removes access to a layer.
struct RiskyAssignment: Identifiable {
    let id = UUID()
    let key: KeySpec
    let code: Int
    let currentTitle: String
}

// MARK: - State

final class FlowState: ObservableObject {
    // Devices and navigation
    @Published var devices: [FlowDeviceInfo] = []
    @Published var selectedDevice: FlowDeviceInfo?
    @Published var section: SidebarSection = .general

    // 3D stage
    @Published var cameraPreset: CameraPreset = .cinematic
    @Published var cameraNonce: Int = 0          // bumped to re-frame the current view
    @Published var finish: ChassisFinish = ChassisFinish(rawValue: UserDefaults.standard.string(forKey: "chassisFinish") ?? "") ?? .spaceGray {
        didSet { UserDefaults.standard.set(finish.rawValue, forKey: "chassisFinish") }
    }
    @Published var selectedKeyIndex: Int? = nil
    @Published var activeTouchZone: Int = 0

    // Status
    @Published var batteryPercent: Int? = nil
    @Published var isCharging = false
    @Published var statusMessage = tr("Recherche du clavier…")
    @Published var errorMessage: String? = nil
    @Published var isAsleep = false
    @Published var isBusy = false

    // Capabilities
    @Published var profileSupported = false
    @Published var firmwareVersion = "—"
    @Published var protocolVersion = "—"
    @Published var zoneAnimationsSupported = false
    @Published var fillAnimationSupported = false
    @Published var advancedSupported = false
    @Published var macroCount = 0
    @Published var matrixRows = 0
    @Published var matrixCols = 0

    // Lighting
    @Published var brightness: Double = 70
    @Published var effect: Int = 0
    @Published var waveSpeed: Int = 1

    // Sleep, power, status LED
    @Published var idleTimeout: Int = 300
    @Published var touchWake = true
    @Published var indicatorRF = true
    @Published var indicatorBT = true
    @Published var syncBrightness = true
    @Published var indicatorBrightness: Double = 191
    @Published var syncBreathing = false
    @Published var lowBatteryThreshold: Int = 15

    // Touch Bar
    @Published var touchZoneCount: Int = 1
    @Published var touchB1: Int = 33
    @Published var touchB2: Int = 67
    @Published var touchMode: Int = 0            // 0 = normal, 1 = while Fn is held
    @Published var touchActions: [[Int]] = [
        [1, 0, 2, 1, 0, 2, 1, 0, 2],
        [9, 0, 10, 9, 0, 10, 9, 0, 10],
    ]
    @Published var touchLoaded = false
    @Published var touchReadFailed = false

    // Keys
    @Published var activeLayer: FlowLayer = .mac
    @Published var layerKeys: [Int] = []
    @Published var layerDefaults: [Int] = []
    @Published var layerLoaded = false
    @Published var layerReadFailed = false
    @Published var riskyAssignment: RiskyAssignment?
    @Published var showResetLayerConfirm = false

    // Macros
    @Published var macroBank: MacroBank? {
        didSet { savedItemsCache.removeAll() }
    }
    @Published var macroSlot = 0
    @Published var macroDrafts: [Int: [MacroItem]] = [:]     // unsaved edits, per slot
    @Published var macrosLoaded = false
    @Published var macrosReadFailed = false
    /// Macro memory left unreadable by an interrupted save, and the repaired copy that can be written back.
    @Published var macroRepair: (broken: Data, repaired: Data)?
    @Published var isRecordingMacro = false
    @Published var macroKeepDelays = false
    @Published var recordingPreview = ""

    // Firmware
    @Published var firmwareProgress: Double = 0
    @Published var firmwareProgressText = ""
    @Published var isFlashing = false
    @Published var showFlashConfirm = false
    @Published var showRestoreConfirm = false
    @Published var firmwareStatus: [String: Any] = [:]
    /// Outcome of the last firmware operation, kept on screen until dismissed.
    @Published var firmwareResult: (ok: Bool, message: String)?

    /// No hardware: a simulated Flow 2 for screenshots and UI work (`-FlowDemo YES`).
    let isDemo = UserDefaults.standard.bool(forKey: "FlowDemo")

    private let worker = DispatchQueue(label: "app.flowoperator.hid", qos: .userInitiated, autoreleaseFrequency: .workItem)
    private var touchWriteInFlight = false
    private var touchWriteQueued = false
    /// Engine calls queued or running. The app waits for them before quitting.
    private(set) var pendingOperations = 0
    private var whenIdle: (() -> Void)?
    private let bleBattery = FlowBLEBattery()
    private var scanTimer: Timer?
    private var batteryTimer: Timer?
    private var lightingWork: DispatchWorkItem?
    private var factoryCache: [Int: (normal: [Int], factory: [Int])] = [:]
    private var demoLayers: [Int: [Int]] = [:]
    private var flashActivity: NSObjectProtocol?
    private var demoMacros = Data(count: 2976)
    private var savedItemsCache: [Int: [MacroItem]] = [:]
    private var macroMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var recordedEvents: [MacroCodec.RecordedEvent] = []
    private var recordHeld = Set<Int>()

    static let layout84 = FlowLayout.keys84

    init() {
        if isDemo {
            startDemo()
            return
        }
        scanDevices()
        scanTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.scanDevices(silent: true)
        }
        batteryTimer = Timer.scheduledTimer(withTimeInterval: 30.0, repeats: true) { [weak self] _ in
            self?.refreshBattery()
        }
    }

    /// A binding that writes to the keyboard only when the user changes the control,
    /// never when a value is refreshed from the keyboard.
    func binding<T>(_ keyPath: ReferenceWritableKeyPath<FlowState, T>, apply: @escaping (FlowState) -> Void) -> Binding<T> {
        Binding(
            get: { self[keyPath: keyPath] },
            set: { newValue in
                self[keyPath: keyPath] = newValue
                apply(self)
            }
        )
    }

    // MARK: Derived

    var isConnected: Bool { selectedDevice != nil }
    var canConfigure: Bool { isConnected && profileSupported && !isFlashing }
    /// The key editor and the 3D model only know the 84-key matrix (6 × 15).
    var keysSupported: Bool {
        isDemo || (selectedDevice?.model == "84" && matrixRows == FlowLayout.rows84 && matrixCols == FlowLayout.cols84)
    }
    /// Touch Bar edits send the whole configuration: never before it has been read from the keyboard.
    var touchReady: Bool { canConfigure && touchLoaded }
    var touchProfilesSupported: Bool { firmwareVersion == "0.10" }

    /// Keys of the active layer whose assignment differs from the default layout.
    var changedKeys: [KeySpec] {
        guard layerLoaded, layerKeys.count == layerDefaults.count, !layerKeys.isEmpty else { return [] }
        let factory = factoryCache[activeLayer.rawValue]?.factory ?? layerDefaults
        return Self.layout84.filter { key in
            let p = key.position
            guard p < layerKeys.count else { return false }
            let code = layerKeys[p]
            if code == layerDefaults[p] { return false }
            return activeLayer.rawValue < 4 || p >= factory.count || code != factory[p]
        }
    }

    func code(for key: KeySpec) -> Int? {
        layerLoaded && key.position < layerKeys.count ? layerKeys[key.position] : nil
    }

    func defaultCode(for key: KeySpec) -> Int? {
        key.position < layerDefaults.count ? layerDefaults[key.position] : nil
    }

    // MARK: Engine access

    private static func isAsleep(_ error: NSError) -> Bool {
        error.domain == "Flow2Studio" && error.code == 2
    }

    private static func describe(_ error: NSError) -> String {
        if isAsleep(error) {
            return tr("Le clavier est en veille ou hors de portée. Appuyez sur une touche pour le réveiller, puis réessayez.")
        }
        let text = FlowLocalized(error.localizedDescription) ?? error.localizedDescription
        return tr("Le clavier a refusé l’opération : %@", text)
    }

    /// Runs one engine action on the serial worker and reports back on the main queue.
    /// The result is dropped if another keyboard was selected in the meantime.
    private func perform(_ action: String, _ args: [String: Any] = [:], success: String? = nil,
                         failure: ((NSError?) -> Void)? = nil, then: (([String: Any]) -> Void)? = nil) {
        guard let device = selectedDevice else { return }
        if isDemo {
            let result = demoPerform(action, args)
            if let success { statusMessage = success }
            then?(result)
            return
        }
        let raw = device.raw
        let deviceID = device.id
        pendingOperations += 1
        worker.async { [weak self] in
            var err: NSError?
            let res = FlowPerform(raw, action, args, &err) as? [String: Any]
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationFinished()
                guard self.selectedDevice?.id == deviceID else { return }
                if let err {
                    self.isAsleep = Self.isAsleep(err)
                    self.errorMessage = Self.describe(err)
                    failure?(err)
                } else if let res {
                    self.isAsleep = false
                    self.errorMessage = nil
                    if let success { self.statusMessage = success }
                    then?(res)
                } else {
                    self.errorMessage = tr("Le clavier n’a pas répondu.")
                    failure?(nil)
                }
            }
        }
    }

    /// After a refused write the controls may show values the keyboard does not have: read them again.
    private func resyncAfterFailure(_ error: NSError?) {
        if let error, Self.isAsleep(error) { return }
        let message = errorMessage
        refreshAll()
        errorMessage = message
    }

    private func operationFinished() {
        pendingOperations = max(0, pendingOperations - 1)
        if pendingOperations == 0, let done = whenIdle {
            whenIdle = nil
            done()
        }
    }

    /// Calls `done` once every queued keyboard operation has finished, or after a few seconds at most.
    func afterPendingOperations(_ done: @escaping () -> Void) {
        guard pendingOperations > 0 else { done(); return }
        whenIdle = done
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in
            guard let self, let pending = self.whenIdle else { return }
            self.whenIdle = nil
            pending()
        }
    }

    // MARK: Devices

    private static func displayConnection(_ raw: String) -> String {
        if raw == "USB" || raw == "Bluetooth" { return raw }
        return raw.hasPrefix("2.4") ? tr("2,4 GHz") : raw
    }

    func scanDevices(silent: Bool = false) {
        guard !isDemo, !isFlashing else { return }
        worker.async { [weak self] in
            var found: [FlowDeviceInfo] = []
            if let list = FlowDevices() as? [[String: Any]] {
                for d in list {
                    let model = "\(d["model"] ?? "")"
                    found.append(FlowDeviceInfo(
                        id: "\(d["id"] ?? UUID().uuidString)",
                        name: model.isEmpty ? "Lofree Flow 2" : "Lofree Flow 2 · \(model)",
                        model: model,
                        connection: Self.displayConnection("\(d["connection"] ?? "USB")"),
                        vendor: (d["vendor"] as? Bool) ?? false,
                        bootloader: false,
                        raw: d
                    ))
                }
            }
            if let fwList = FlowFirmwareDevices() as? [[String: Any]] {
                for d in fwList {
                    let id = "\(d["id"] ?? UUID().uuidString)"
                    if !found.contains(where: { $0.id == id }) {
                        found.append(FlowDeviceInfo(id: id, name: tr("Clavier en mode récupération"), model: "\(d["model"] ?? "")",
                                                    connection: "USB", vendor: false, bootloader: true, raw: d))
                    }
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                let oldId = self.selectedDevice?.id
                self.devices = found
                if let existing = found.first(where: { $0.id == oldId }) {
                    self.selectedDevice = existing
                } else if let first = found.first {
                    self.selectDevice(first)
                } else {
                    self.selectedDevice = nil
                    self.profileSupported = false
                    self.batteryPercent = nil
                    self.layerLoaded = false
                    self.touchLoaded = false
                    self.statusMessage = tr("Aucun clavier détecté")
                    if !silent { self.errorMessage = nil }
                }
            }
        }
    }

    func selectDevice(_ device: FlowDeviceInfo) {
        stopMacroRecording(keep: false)
        selectedDevice = device
        errorMessage = nil
        isAsleep = false
        // Nothing read from the previous keyboard may be shown or written to this one.
        profileSupported = false
        firmwareVersion = "—"
        protocolVersion = "—"
        zoneAnimationsSupported = false
        fillAnimationSupported = false
        advancedSupported = false
        macroCount = 0
        matrixRows = 0
        matrixCols = 0
        batteryPercent = nil
        layerLoaded = false
        layerReadFailed = false
        touchLoaded = false
        touchReadFailed = false
        touchWriteInFlight = false
        touchWriteQueued = false
        macrosLoaded = false
        macrosReadFailed = false
        macroRepair = nil
        macroBank = nil
        macroDrafts.removeAll()
        firmwareStatus = [:]
        factoryCache.removeAll()
        statusMessage = tr("Lecture du clavier…")
        refreshAll()
    }

    func refreshAll() {
        guard let device = selectedDevice else { scanDevices(); return }
        if isDemo { return }
        let raw = device.raw
        let deviceID = device.id
        isBusy = true
        errorMessage = nil

        if device.connection == "Bluetooth" {
            bleBattery.readDevice(raw) { [weak self] res, _ in
                if let pct = res?["percent"] as? Int, (0...100).contains(pct) { self?.batteryPercent = pct }
            }
        }

        worker.async { [weak self] in
            var err: NSError?
            let status = FlowPerform(raw, "status", [:], &err) as? [String: Any]
            let fwStatus = FlowFirmwareStatus(raw) as? [String: Any]
            var capErr: NSError?
            let caps = device.vendor && !device.bootloader ? (FlowPerform(raw, "capabilities", [:], &capErr) as? [String: Any]) : nil
            var touch = caps?["touch"] as? [String: Any]
            if touch == nil, caps?["profileSupported"] as? Bool == true {
                var touchErr: NSError?
                touch = FlowPerform(raw, "readTouch", [:], &touchErr) as? [String: Any]
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                guard self.selectedDevice?.id == deviceID else { return }
                self.applyStatus(status)
                self.firmwareStatus = fwStatus ?? [:]
                if let caps {
                    self.isAsleep = false
                    self.applyCapabilities(caps)
                } else {
                    self.profileSupported = false
                    self.firmwareVersion = "—"
                    self.protocolVersion = "—"
                    if let capErr, device.vendor {
                        self.isAsleep = capErr.code == 2
                        self.statusMessage = self.isAsleep ? tr("Clavier en veille") : tr("Clavier détecté")
                    } else if device.bootloader {
                        self.statusMessage = tr("Mode récupération")
                    } else {
                        self.statusMessage = tr("Connecté en lecture seule")
                    }
                }
                if let touch {
                    self.applyTouch(touch)
                } else if self.profileSupported {
                    self.touchReadFailed = true
                }
                if self.section == .keys || self.section == .macros { self.readActiveLayer() }
                if self.section == .macros { self.readMacros() }
            }
        }
    }

    private func applyStatus(_ status: [String: Any]?) {
        guard let status, status["valid"] as? Bool == true, let pct = status["percent"] as? Int else { return }
        batteryPercent = pct
        isCharging = (status["power"] as? Bool) ?? false
    }

    func refreshBattery() {
        guard let device = selectedDevice, !isDemo, !isFlashing, device.vendor else { return }
        let raw = device.raw
        let deviceID = device.id
        worker.async { [weak self] in
            var err: NSError?
            let status = FlowPerform(raw, "status", [:], &err) as? [String: Any]
            DispatchQueue.main.async {
                guard let self, self.selectedDevice?.id == deviceID else { return }
                self.applyStatus(status)
            }
        }
    }

    private func applyCapabilities(_ caps: [String: Any]) {
        profileSupported = (caps["profileSupported"] as? Bool) ?? false
        protocolVersion = "VIA \(caps["protocol"] ?? "—")"
        macroCount = (caps["macros"] as? Int) ?? 0
        matrixRows = (caps["rows"] as? Int) ?? 0
        matrixCols = (caps["cols"] as? Int) ?? 0
        if let b = caps["brightness"] as? Int { brightness = Double(b) }
        if let e = caps["effect"] as? Int { effect = e } else if let on = caps["effect"] as? Bool { effect = on ? 1 : 0 }
        if let s = caps["waveSpeed"] as? Int { waveSpeed = s }
        if let p = caps["profile"] as? [String: Any] {
            applyProfileDictionary(p)
            statusMessage = tr("Connecté · Studio %@", firmwareVersion)
        } else {
            firmwareVersion = tr("Lofree (origine)")
            zoneAnimationsSupported = false
            fillAnimationSupported = false
            advancedSupported = false
            statusMessage = tr("Connecté · firmware d’origine")
        }
    }

    private func applyProfileDictionary(_ p: [String: Any]) {
        if let v = p["firmwareVersion"] { firmwareVersion = "\(v)" }
        if let t = p["timeout"] as? Int { idleTimeout = t }
        if let v = p["touchWake"] as? Bool { touchWake = v }
        if let v = p["rf"] as? Bool { indicatorRF = v }
        if let v = p["bluetooth"] as? Bool { indicatorBT = v }
        if let v = p["indicatorBrightness"] as? Int { indicatorBrightness = Double(v) }
        if let v = p["syncBrightness"] as? Bool { syncBrightness = v }
        if let v = p["syncBreathing"] as? Bool { syncBreathing = v }
        if let v = p["lowBatteryThreshold"] as? Int { lowBatteryThreshold = v }
        if let v = p["animationSpeed"] as? Int { waveSpeed = v }
        zoneAnimationsSupported = (p["zoneAnimationsSupported"] as? Bool) ?? false
        fillAnimationSupported = (p["fillAnimationSupported"] as? Bool) ?? false
        advancedSupported = (p["advancedSupported"] as? Bool) ?? false
    }

    func wakeKeyboard() {
        perform("wake", success: tr("Clavier réveillé")) { [weak self] _ in self?.refreshAll() }
    }

    // MARK: Lighting

    func isEffectAvailable(_ id: Int) -> Bool {
        if id >= 6 { return fillAnimationSupported }
        if id >= 2 { return zoneAnimationsSupported }
        return true
    }

    func applyLighting(persist: Bool = true) {
        guard canConfigure, let device = selectedDevice else { return }
        if isDemo { return }
        lightingWork?.cancel()
        let raw = device.raw
        let deviceID = device.id
        let args: [String: Any] = [
            "brightness": Int(brightness.rounded()),
            "effect": effect,
            "waveSpeed": waveSpeed,
            "effectFamily": "zones-v1",
            "persist": persist,
        ]
        let work = DispatchWorkItem { [weak self] in
            // Counted from the moment it really starts: a superseded item is cancelled before that.
            DispatchQueue.main.async { self?.pendingOperations += 1 }
            var err: NSError?
            _ = FlowPerform(raw, "lighting", args, &err)
            DispatchQueue.main.async {
                guard let self else { return }
                self.operationFinished()
                guard self.selectedDevice?.id == deviceID else { return }
                if let err {
                    self.isAsleep = Self.isAsleep(err)
                    self.errorMessage = Self.describe(err)
                    if persist { self.resyncAfterFailure(err) }
                } else {
                    self.errorMessage = nil
                    if persist { self.statusMessage = tr("Éclairage enregistré") }
                }
            }
        }
        lightingWork = work
        worker.asyncAfter(deadline: .now() + 0.08, execute: work)
    }

    // MARK: Sleep, power, status LED

    /// The firmware replaces the whole profile: every field is sent each time.
    func applyProfile() {
        guard canConfigure else { return }
        perform("profile", [
            "rf": indicatorRF,
            "bluetooth": indicatorBT,
            "touchWake": touchWake,
            "syncBreathing": syncBreathing,
            "indicatorBrightness": Int(indicatorBrightness.rounded()),
            "timeout": idleTimeout,
            "persist": true,
        ], success: tr("Réglages enregistrés"), failure: { [weak self] in self?.resyncAfterFailure($0) })
    }

    func applyAdvanced() {
        guard canConfigure, advancedSupported else { return }
        perform("advanced", [
            "syncBrightness": syncBrightness,
            "lowBatteryThreshold": lowBatteryThreshold,
            "persist": true,
        ], success: tr("Réglages enregistrés"), failure: { [weak self] in self?.resyncAfterFailure($0) })
    }

    // MARK: Touch Bar

    private func applyTouch(_ touch: [String: Any]) {
        if let c = touch["count"] as? Int, (1...3).contains(c) { touchZoneCount = c }
        if let b1 = touch["b1"] as? Int { touchB1 = b1 }
        if let b2 = touch["b2"] as? Int { touchB2 = b2 }
        if let acts = touch["actions"] as? [[Int]], acts.count == 2, acts.allSatisfy({ $0.count == 9 }) {
            touchActions = acts
        }
        if activeTouchZone >= touchZoneCount { activeTouchZone = 0 }
        touchLoaded = true
        touchReadFailed = false
    }

    func readTouch() {
        guard canConfigure else { return }
        touchReadFailed = false
        perform("readTouch", failure: { [weak self] _ in self?.touchReadFailed = true }) { [weak self] res in
            self?.applyTouch(res)
        }
    }

    /// Keeps the boundaries inside what the firmware accepts for the current zone count.
    private func normalizedBoundaries() -> (Int, Int) {
        var b1 = min(max(touchB1, TouchCatalog.b1Range.lowerBound), TouchCatalog.b1Range.upperBound)
        var b2 = min(max(touchB2, TouchCatalog.b2Range.lowerBound), TouchCatalog.b2Range.upperBound)
        if touchZoneCount == 3 {
            if b1 > TouchCatalog.b2Range.upperBound - TouchCatalog.minimumGap { b1 = TouchCatalog.b2Range.upperBound - TouchCatalog.minimumGap }
            if b2 < b1 + TouchCatalog.minimumGap { b2 = b1 + TouchCatalog.minimumGap }
        }
        return (b1, b2)
    }

    /// Writes are sent one at a time: an edit made while one is in flight is sent right after,
    /// and a stale reply never overwrites what the user has changed since.
    func applyTouchBar() {
        guard touchReady else { return }
        if touchWriteInFlight {
            touchWriteQueued = true
            return
        }
        let (b1, b2) = normalizedBoundaries()
        touchB1 = b1
        touchB2 = b2
        var args: [String: Any] = ["count": touchZoneCount, "b1": b1, "b2": b2, "actions": touchActions]
        if touchProfilesSupported { args["keepActive"] = true }
        touchWriteInFlight = true
        perform("setTouch", args, success: tr("Touch Bar enregistrée"), failure: { [weak self] _ in
            guard let self else { return }
            self.touchWriteInFlight = false
            self.touchWriteQueued = false
            self.readTouch()
        }) { [weak self] res in
            guard let self else { return }
            self.touchWriteInFlight = false
            if self.touchWriteQueued {
                self.touchWriteQueued = false
                self.applyTouchBar()
            } else {
                self.applyTouch(res)
            }
        }
    }

    /// Each zone count is its own profile on Studio 0.10: switching loads what the keyboard stored for it.
    func setTouchZoneCount(_ count: Int) {
        guard touchReady, !touchWriteInFlight, (1...3).contains(count), count != touchZoneCount else { return }
        if touchProfilesSupported {
            perform("selectTouchProfile", ["count": count], success: tr("Profil Touch Bar activé")) { [weak self] res in
                self?.applyTouch(res)
            }
        } else {
            touchZoneCount = count
            let d = TouchCatalog.defaults(for: count)
            touchB1 = d.b1
            touchB2 = d.b2
            if activeTouchZone >= count { activeTouchZone = 0 }
            perform("setTouch", ["count": count, "b1": d.b1, "b2": d.b2, "actions": touchActions], success: tr("Touch Bar enregistrée")) { [weak self] res in
                self?.applyTouch(res)
            }
        }
    }

    func touchAction(zone: Int, gesture: TouchGesture) -> Int {
        let i = zone * 3 + gesture.rawValue
        guard touchMode < touchActions.count, i < touchActions[touchMode].count else { return 0 }
        return touchActions[touchMode][i]
    }

    func setTouchAction(_ code: Int, zone: Int, gesture: TouchGesture) {
        guard TouchCatalog.isValid(code), zone < 3, touchMode < touchActions.count else { return }
        if gesture == .tap && code == TouchCatalog.scroll { return }
        touchActions[touchMode][zone * 3 + gesture.rawValue] = code
        applyTouchBar()
    }

    func touchSlots(zone: Int) -> [Int] {
        TouchGesture.allCases.map { touchAction(zone: zone, gesture: $0) }
    }

    func applyTouchPreset(_ preset: TouchCatalog.Preset, zone: Int) {
        guard zone < 3, touchMode < touchActions.count, preset.slots.count == 3 else { return }
        for i in 0..<3 { touchActions[touchMode][zone * 3 + i] = preset.slots[i] }
        applyTouchBar()
    }

    // MARK: Keys

    func readActiveLayer() {
        guard isConnected, keysSupported, selectedDevice?.vendor == true || isDemo else { return }
        let layer = activeLayer.rawValue
        layerLoaded = false
        layerReadFailed = false
        perform("readLayer", ["layer": layer], failure: { [weak self] _ in self?.layerReadFailed = true }) { [weak self] res in
            guard let self, self.activeLayer.rawValue == layer, let keys = res["keys"] as? [Int] else { return }
            self.layerKeys = keys
            self.loadDefaults(layer: layer)
        }
    }

    /// Default layout of a layer, asked from the firmware tables once per connection.
    private func loadDefaults(layer: Int) {
        if let cached = factoryCache[layer] {
            layerDefaults = cached.normal
            layerLoaded = true
            return
        }
        guard profileSupported else {
            layerDefaults = layerKeys
            layerLoaded = true
            return
        }
        let failed: (NSError?) -> Void = { [weak self] _ in self?.layerReadFailed = true }
        perform("layerTemplate", ["layer": layer, "template": "normal"], failure: failed) { [weak self] normalRes in
            guard let self, let normal = normalRes["keys"] as? [Int] else { return }
            self.perform("layerTemplate", ["layer": layer, "template": "factory"], failure: failed) { [weak self] factoryRes in
                guard let self else { return }
                let factory = (factoryRes["keys"] as? [Int]) ?? normal
                self.factoryCache[layer] = (normal, factory)
                if self.activeLayer.rawValue == layer {
                    self.layerDefaults = normal
                    self.layerLoaded = true
                }
            }
        }
    }

    /// Assigns a code to a key. Keys that open a layer ask for confirmation first.
    func assign(_ code: Int, to key: KeySpec, confirmed: Bool = false) {
        guard canConfigure, keysSupported, let current = self.code(for: key), current != code else { return }
        if !confirmed, KeyCatalog.isStructural(current) {
            riskyAssignment = RiskyAssignment(key: key, code: code, currentTitle: KeyCatalog.title(for: current))
            return
        }
        let layer = activeLayer.rawValue
        perform("setKey", ["layer": layer, "row": key.row, "col": key.col, "code": code, "expectedCode": current],
                success: "\(key.name) → \(KeyCatalog.title(for: code))") { [weak self] res in
            guard let self, self.activeLayer.rawValue == layer else { return }
            if let keys = res["keys"] as? [Int] { self.layerKeys = keys }
        }
    }

    func restoreDefault(for key: KeySpec) {
        guard let code = defaultCode(for: key) else { return }
        assign(code, to: key, confirmed: true)
    }

    func resetActiveLayer() {
        guard canConfigure, keysSupported else { return }
        let layer = activeLayer.rawValue
        perform("resetLayer", ["layer": layer], success: tr("Calque %@ rétabli", activeLayer.title)) { [weak self] res in
            guard let self, self.activeLayer.rawValue == layer else { return }
            if let keys = res["keys"] as? [Int] { self.layerKeys = keys }
            self.readActiveLayer()
        }
    }

    /// Fn-layer templates computed by the firmware tables: "factory" or "fkeys" (F1–F12 on the top row).
    func applyFnTemplate(_ template: String) {
        guard canConfigure, keysSupported, activeLayer.isFn, layerLoaded else { return }
        let layer = activeLayer.rawValue
        let expected = layerKeys
        perform("layerTemplate", ["layer": layer, "template": template]) { [weak self] tpl in
            guard let self, self.activeLayer.rawValue == layer, let keys = tpl["keys"] as? [Int] else { return }
            self.perform("setLayer", ["layer": layer, "keys": keys, "expected": expected], success: tr("Modèle appliqué")) { [weak self] res in
                guard let self, self.activeLayer.rawValue == layer else { return }
                if let keys = res["keys"] as? [Int] { self.layerKeys = keys }
            }
        }
    }

    // MARK: Macros

    /// What the keyboard currently stores in a slot, or nil if this editor cannot read it.
    func savedMacro(_ slot: Int) -> [MacroStep]? {
        guard let bank = macroBank, slot < bank.slots.count else { return [] }
        return MacroCodec.decode(bank.slots[slot])
    }

    /// Saved steps as list items. Cached so rows keep their identity between renders.
    private func savedItems(_ slot: Int) -> [MacroItem] {
        if let cached = savedItemsCache[slot] { return cached }
        let items = (savedMacro(slot) ?? []).map { MacroItem(step: $0) }
        savedItemsCache[slot] = items
        return items
    }

    /// The steps being edited: the unsaved draft if there is one, else what the keyboard stores.
    var macroDraft: [MacroItem] {
        get { macroDrafts[macroSlot] ?? savedItems(macroSlot) }
        set {
            if newValue.map(\.step) == (savedMacro(macroSlot) ?? []) {
                savedItemsCache[macroSlot] = newValue     // same rows, no longer a draft
                macroDrafts[macroSlot] = nil
            } else {
                macroDrafts[macroSlot] = newValue
            }
        }
    }

    var macroReadOnly: Bool { savedMacro(macroSlot) == nil }
    func macroIsDirty(_ slot: Int) -> Bool { macroDrafts[slot] != nil }

    /// Encoded draft, or the reason it cannot be written.
    var macroDraftBytes: Result<[UInt8], MacroError> {
        do { return .success(try MacroCodec.encode(macroDraft.map(\.step))) } catch let e as MacroError { return .failure(e) } catch {
            return .failure(.unknownFormat)
        }
    }

    var macroBudget: Int { macroBank.map { MacroCodec.budget($0, slot: macroSlot) } ?? 0 }

    /// Keys of the active layer that trigger a macro slot.
    func macroTriggers(_ slot: Int) -> [KeySpec] {
        guard layerLoaded else { return [] }
        let code = KeyCatalog.macroBase + slot
        return Self.layout84.filter { $0.position < layerKeys.count && layerKeys[$0.position] == code }
    }

    func readMacros() {
        guard isConnected, selectedDevice?.vendor == true || isDemo else { return }
        macrosReadFailed = false
        perform("readMacros", failure: { [weak self] _ in self?.macrosReadFailed = true }) { [weak self] res in
            guard let self else { return }
            guard let text = res["data"] as? String, let data = Data(base64Encoded: text) else {
                self.macrosReadFailed = true
                return
            }
            if let bank = MacroCodec.parse(data) {
                self.macroBank = bank
                self.macroRepair = nil
                self.macrosLoaded = true
                return
            }
            // An interrupted save leaves a guard byte at the end of the memory: everything else is intact.
            self.macroBank = nil
            self.macrosLoaded = false
            var fixed = data
            if !fixed.isEmpty { fixed[fixed.count - 1] = 0 }
            self.macroRepair = MacroCodec.parse(fixed) != nil ? (data, fixed) : nil
            self.macrosReadFailed = true
            self.errorMessage = self.macroRepair != nil
                ? tr("La dernière écriture des macros a été interrompue. Réparez la mémoire des macros pour les retrouver.")
                : MacroError.unknownFormat.message
        }
    }

    /// Writes back the macro memory with the guard byte of an interrupted save cleared.
    func repairMacros() {
        guard canConfigure, let repair = macroRepair else { return }
        perform("saveMacros", ["expected": repair.broken.base64EncodedString(), "data": repair.repaired.base64EncodedString()],
                success: tr("Mémoire des macros réparée")) { [weak self] _ in
            self?.macroRepair = nil
            self?.readMacros()
        }
    }

    func saveMacro() {
        guard canConfigure, let bank = macroBank, !macroReadOnly, case .success(let bytes) = macroDraftBytes else { return }
        let slot = macroSlot
        let savedSteps = macroDraft.map(\.step)
        let next: Data
        do { next = try MacroCodec.rebuild(bank, slot: slot, bytes: bytes) } catch let e as MacroError {
            errorMessage = e.message
            return
        } catch { return }
        perform("saveMacros", ["expected": bank.raw.base64EncodedString(), "data": next.base64EncodedString()],
                success: tr("Macro %d enregistrée dans le clavier", slot + 1)) { [weak self] res in
            guard let self else { return }
            if let text = res["data"] as? String, let data = Data(base64Encoded: text), let fresh = MacroCodec.parse(data) {
                self.macroBank = fresh
            } else {
                self.readMacros()
            }
            // Keep the draft if it was edited again while the save was in flight.
            if self.macroDrafts[slot]?.map(\.step) == savedSteps { self.macroDrafts[slot] = nil }
        }
    }

    func revertMacro() {
        stopMacroRecording(keep: false)
        macroDrafts[macroSlot] = nil
    }

    func appendMacroStep(_ step: MacroStep) {
        var draft = macroDraft
        draft.append(MacroItem(step: step))
        macroDraft = draft
    }

    func updateMacroStep(_ id: UUID, _ step: MacroStep) {
        var draft = macroDraft
        guard let i = draft.firstIndex(where: { $0.id == id }) else { return }
        draft[i].step = step
        macroDraft = draft
    }

    func removeMacroStep(_ id: UUID) {
        var draft = macroDraft
        draft.removeAll { $0.id == id }
        macroDraft = draft
    }

    func moveMacroStep(_ id: UUID, by offset: Int) {
        var draft = macroDraft
        guard let i = draft.firstIndex(where: { $0.id == id }), draft.indices.contains(i + offset) else { return }
        draft.swapAt(i, i + offset)
        macroDraft = draft
    }

    /// Records the keys typed in the app until stopped. Events are swallowed so shortcuts
    /// being recorded (⌘Q, ⌘W…) do not act on the app.
    func startMacroRecording() {
        guard !isRecordingMacro, !macroReadOnly, macrosLoaded else { return }
        recordedEvents = []
        recordHeld = []
        recordingPreview = ""
        isRecordingMacro = true
        macroMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self, self.isRecordingMacro else { return event }
            guard let usage = MacroCodec.usage(forMacKeyCode: event.keyCode) else { return nil }
            switch event.type {
            case .keyDown:
                if !event.isARepeat { self.record(usage, down: true, at: event.timestamp) }
            case .keyUp:
                self.record(usage, down: false, at: event.timestamp)
            case .flagsChanged:
                if usage == 57 {            // Caps Lock reports one change per press
                    self.record(usage, down: true, at: event.timestamp)
                    self.record(usage, down: false, at: event.timestamp)
                } else {
                    // The event's flags tell whether this kind of modifier is still down. With both
                    // keys of a pair held, the one that changed is the one not yet recorded.
                    let flag: NSEvent.ModifierFlags = [224, 228].contains(usage) ? .control : [225, 229].contains(usage) ? .shift
                        : [226, 230].contains(usage) ? .option : .command
                    let down = event.modifierFlags.contains(flag) && !self.recordHeld.contains(usage)
                    if down || self.recordHeld.contains(usage) {
                        self.record(usage, down: down, at: event.timestamp)
                    }
                }
            default:
                break
            }
            return nil
        }
        resignObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.stopMacroRecording()
        }
    }

    private func record(_ usage: Int, down: Bool, at time: TimeInterval) {
        guard recordedEvents.count < 400 else { return }
        if down { recordHeld.insert(usage) } else { recordHeld.remove(usage) }
        recordedEvents.append(MacroCodec.RecordedEvent(usage: usage, down: down, time: time))
        recordingPreview = MacroCodec.summary(MacroCodec.steps(from: recordedEvents, keepDelays: false), limit: 8)
    }

    func stopMacroRecording(keep: Bool = true) {
        guard isRecordingMacro else { return }
        if let macroMonitor { NSEvent.removeMonitor(macroMonitor) }
        macroMonitor = nil
        if let resignObserver { NotificationCenter.default.removeObserver(resignObserver) }
        resignObserver = nil
        isRecordingMacro = false
        guard keep, !recordedEvents.isEmpty else { return }
        var draft = macroDraft
        draft += MacroCodec.steps(from: recordedEvents, keepDelays: macroKeepDelays).map { MacroItem(step: $0) }
        macroDraft = draft
        recordedEvents = []
    }

    // MARK: Firmware

    var firmwareNeedsCable: Bool { selectedDevice?.isUSB != true }

    private func firmwareFlag(_ key: String) -> Bool { (firmwareStatus[key] as? Bool) ?? false }
    /// The engine decides what is allowed for this keyboard; the buttons follow it.
    var canInstallFirmware: Bool { !isDemo && !isFlashing && firmwareFlag("available") && firmwareFlag("canPrepare") }
    var canRestoreFirmware: Bool { !isDemo && !isFlashing && firmwareFlag("available") && firmwareFlag("canRestoreFactory") }
    var firmwareStatusMessage: String? {
        guard let text = firmwareStatus["message"] as? String, !text.isEmpty else { return nil }
        return FlowLocalized(text) ?? text
    }

    func prepareStudioFirmware(restoreStock: Bool = false) {
        guard let device = selectedDevice, !isDemo, !isFlashing else { return }
        guard restoreStock ? canRestoreFirmware : canInstallFirmware else { return }
        stopMacroRecording(keep: false)
        let raw = device.raw
        firmwareResult = nil
        isFlashing = true
        firmwareProgress = 0.02
        firmwareProgressText = tr("Préparation…")
        errorMessage = nil
        // Keep the Mac awake and the app alive for the whole write.
        flashActivity = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled, .automaticTerminationDisabled, .userInitiated],
            reason: "Mise à jour du firmware du clavier")

        worker.async { [weak self] in
            var err: NSError?
            _ = FlowFirmwarePrepare(raw, restoreStock ? 1 : 0, nil, { info in
                let info = info as? [String: Any]
                DispatchQueue.main.async {
                    guard let self, let info else { return }
                    self.firmwareProgressText = FirmwareCatalog.phaseTitle("\(info["phase"] ?? "")")
                    let done = (info["done"] as? NSNumber)?.doubleValue ?? 0
                    let total = (info["total"] as? NSNumber)?.doubleValue ?? 0
                    if total > 0 { self.firmwareProgress = max(0.02, min(1.0, done / total)) }
                }
            }, &err)

            DispatchQueue.main.async {
                guard let self else { return }
                if let activity = self.flashActivity { ProcessInfo.processInfo.endActivity(activity) }
                self.flashActivity = nil
                self.isFlashing = false
                if let err {
                    let text = FlowLocalized(err.localizedDescription) ?? err.localizedDescription
                    self.firmwareResult = (false, tr("L’opération n’a pas abouti : %@", text))
                    self.firmwareProgressText = tr("Échec")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.scanDevices() }
                } else {
                    self.firmwareProgress = 1.0
                    self.firmwareProgressText = tr("Terminé")
                    self.statusMessage = restoreStock ? tr("Firmware d’origine restauré") : tr("Firmware Studio installé")
                    self.firmwareResult = (true, restoreStock ? tr("Le firmware Lofree d’origine est restauré.") : tr("Le firmware Studio est installé."))
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.scanDevices() }
                }
            }
        }
    }

    func openFirmwareBackups() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let url = base?.appendingPathComponent("Flow2Studio/FirmwareBackups") else { return }
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.open(url)
        } else {
            errorMessage = tr("Aucune sauvegarde de firmware n’a encore été créée sur ce Mac.")
        }
    }

    // MARK: Demo keyboard

    private func startDemo() {
        let device = FlowDeviceInfo(id: "demo", name: "Lofree Flow 2 · 84", model: "84", connection: "USB",
                                    vendor: true, bootloader: false, raw: [:])
        devices = [device]
        selectedDevice = device
        profileSupported = true
        firmwareVersion = "0.10"
        protocolVersion = "VIA 12"
        zoneAnimationsSupported = true
        fillAnimationSupported = true
        advancedSupported = true
        macroCount = 16
        batteryPercent = 86
        isCharging = true
        touchZoneCount = 3
        touchB1 = 30
        touchB2 = 68
        touchActions = [[1, 3, 2, 7, 4, 7, 9, 0, 10], [9, 0, 10, 146, 0, 145, 5, 4, 6]]
        touchLoaded = true
        statusMessage = tr("Connecté · Studio %@", "0.10")
        var mac = FlowLayout.factoryMac84
        mac[3 * FlowLayout.cols84] = 41          // Caps Lock → Escape
        mac[5 * FlowLayout.cols84 + 11] = 0x7E0B // right Option → Mission Control
        demoLayers[0] = mac
        if let bank = MacroCodec.parse(demoMacros),
           let copyPaste = try? MacroCodec.encode([.down(227), .tap(6), .up(227), .wait(150), .down(227), .tap(25), .up(227)]),
           let first = try? MacroCodec.rebuild(bank, slot: 0, bytes: copyPaste),
           let bank2 = MacroCodec.parse(first),
           let greeting = try? MacroCodec.encode([.text("Hello, world!"), .tap(40)]),
           let second = try? MacroCodec.rebuild(bank2, slot: 1, bytes: greeting) {
            demoMacros = second
        }
    }

    private func demoPerform(_ action: String, _ args: [String: Any]) -> [String: Any] {
        let layer = (args["layer"] as? Int) ?? 0
        switch action {
        case "readLayer":
            return ["keys": demoLayers[layer] ?? FlowLayout.factoryMac84, "layer": layer]
        case "layerTemplate":
            return ["keys": FlowLayout.factoryMac84, "layer": layer]
        case "setKey":
            var keys = demoLayers[layer] ?? FlowLayout.factoryMac84
            if let row = args["row"] as? Int, let col = args["col"] as? Int, let code = args["code"] as? Int {
                keys[row * FlowLayout.cols84 + col] = code
            }
            demoLayers[layer] = keys
            return ["keys": keys, "layer": layer]
        case "setLayer":
            if let keys = args["keys"] as? [Int] { demoLayers[layer] = keys }
            return ["keys": demoLayers[layer] ?? FlowLayout.factoryMac84, "layer": layer]
        case "resetLayer":
            demoLayers[layer] = FlowLayout.factoryMac84
            return ["keys": FlowLayout.factoryMac84, "layer": layer]
        case "readMacros":
            return ["data": demoMacros.base64EncodedString(), "count": 16, "size": demoMacros.count]
        case "saveMacros":
            if let text = args["data"] as? String, let data = Data(base64Encoded: text) { demoMacros = data }
            return ["data": demoMacros.base64EncodedString(), "count": 16, "size": demoMacros.count]
        case "setTouch":
            return args
        case "selectTouchProfile":
            let count = (args["count"] as? Int) ?? 1
            let d = TouchCatalog.defaults(for: count)
            return ["count": count, "b1": d.b1, "b2": d.b2, "actions": touchActions]
        default:
            return [:]
        }
    }
}
