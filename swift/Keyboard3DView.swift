import SwiftUI
import SceneKit
import AppKit

/// SCNView that leaves scrolling to the enclosing form: dragging orbits, pinching zooms.
final class KeyboardSCNView: SCNView {
    /// Called with the pointer location (view coordinates), or nil when it leaves the view.
    var onHover: ((CGPoint?) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func scrollWheel(with event: NSEvent) {
        nextResponder?.scrollWheel(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        onHover?(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil)
    }
}

/// Hosts the SCNView. On 1x displays the scene is laid out at twice the size and its layer is
/// scaled back down (supersampling), which keeps the legends and the edges sharp.
final class KeyboardHostView: NSView {
    let scnView = KeyboardSCNView()
    /// Scene points per host point: multiply host-space locations by this before hit testing.
    private(set) var renderScale: CGFloat = 1

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = true
        scnView.wantsLayer = true
        addSubview(scnView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func layout() {
        super.layout()
        // Hidden override for testing: `defaults write app.flowoperator Keyboard3DRenderScale 2`.
        let forced = CGFloat(UserDefaults.standard.double(forKey: "Keyboard3DRenderScale"))
        renderScale = forced >= 1 ? min(forced, 3) : ((window?.backingScaleFactor ?? 2) < 1.5 ? 2 : 1)
        let size = NSSize(width: bounds.width * renderScale, height: bounds.height * renderScale)
        if scnView.frame.size != size || scnView.frame.origin != .zero {
            scnView.frame = NSRect(origin: .zero, size: size)
        }
        applyScale()
    }

    private func applyScale() {
        guard let layer = scnView.layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.anchorPoint = .zero
        layer.position = .zero
        layer.setAffineTransform(CGAffineTransform(scaleX: 1 / renderScale, y: 1 / renderScale))
        CATransaction.commit()
    }

    override func viewWillDraw() {
        super.viewWillDraw()
        applyScale()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        needsLayout = true
    }
}

/// Interactive SceneKit view of the Lofree Flow 2 (84 keys), driven by `FlowState`.
struct Keyboard3DView: NSViewRepresentable {
    @ObservedObject var state: FlowState

    static let isAvailable: Bool = Bundle.main.url(forResource: "Flow2-84", withExtension: "usdz") != nil

    func makeCoordinator() -> Coordinator { Coordinator(state: state) }

    func makeNSView(context: Context) -> KeyboardHostView {
        let host = KeyboardHostView(frame: .zero)
        let view = host.scnView
        view.backgroundColor = .clear
        view.antialiasingMode = .multisampling4X
        view.autoenablesDefaultLighting = false
        view.preferredFramesPerSecond = 60

        let coordinator = context.coordinator
        coordinator.view = view
        coordinator.host = host
        guard let stage = coordinator.stage else { return host }

        view.scene = stage.scene
        view.pointOfView = stage.cameraNode
        view.delegate = coordinator

        view.allowsCameraControl = true
        let controller = view.defaultCameraController
        controller.interactionMode = .orbitTurntable
        controller.target = SCNVector3(0, 0.8, 0)
        controller.minimumVerticalAngle = 4
        controller.maximumVerticalAngle = 89
        controller.inertiaEnabled = true

        view.addGestureRecognizer(NSClickGestureRecognizer(target: coordinator, action: #selector(Coordinator.handleClick(_:))))
        view.onHover = { [weak coordinator] point in coordinator?.handleHover(point) }

        coordinator.sync(state: state, initial: true)
        view.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(coordinator, selector: #selector(Coordinator.viewDidResize(_:)),
                                               name: NSView.frameDidChangeNotification, object: view)
        return host
    }

    func updateNSView(_ nsView: KeyboardHostView, context: Context) {
        context.coordinator.sync(state: state, initial: false)
    }

    final class Coordinator: NSObject, SCNSceneRendererDelegate {
        let state: FlowState
        let stage: Flow2Scene?
        weak var view: SCNView?
        weak var host: KeyboardHostView?

        private var lastFinish: ChassisFinish?
        private var lastPreset: CameraPreset?
        private var lastNonce = -1
        private var lastSelectedKey: Int??
        private var lastZones: [Int] = []
        private var lastLED: Int = -1
        private var lastAppliedPosition: SCNVector3?
        private var didOpen = false
        private var opening = false

        // Read on the render thread.
        private var brightness: Double = 0
        private var effect: Int = 0
        private var speed: Int = 1

        init(state: FlowState) {
            self.state = state
            if let dir = Bundle.main.resourceURL {
                stage = try? Flow2Scene(resourceDirectory: dir)
            } else {
                stage = nil
            }
            super.init()
        }

        static func camera(for preset: CameraPreset) -> Flow2Scene.Camera {
            switch preset {
            case .cinematic: return .cinematic
            case .top: return .top
            case .touchbar: return .touchBar
            case .profile: return .profile
            }
        }

        private var aspect: CGFloat {
            guard let view, view.bounds.height > 1 else { return 3.4 }
            return view.bounds.width / view.bounds.height
        }

        /// True while the camera is still where the last preset put it (the user has not orbited).
        private var cameraIsOnPreset: Bool {
            guard let p = view?.pointOfView?.position, let last = lastAppliedPosition else { return true }
            let d = SCNVector3(p.x - last.x, p.y - last.y, p.z - last.z)
            return (d.x * d.x + d.y * d.y + d.z * d.z) < 0.01
        }

        private func applyCamera(animated: Bool, duration: Double = 0.8) {
            guard let stage, let view else { return }
            lastAppliedPosition = stage.setCamera(Self.camera(for: state.cameraPreset), aspect: aspect,
                                                  animated: animated, duration: duration, node: view.pointOfView)
        }

        @objc func viewDidResize(_ note: Notification) {
            guard let stage, let view, view.bounds.width > 10, view.bounds.height > 10 else { return }
            if !didOpen {
                // Opening move: sweep from the Touch Bar flank to the selected view.
                didOpen = true
                lastAppliedPosition = stage.setCamera(.touchBar, aspect: aspect, animated: false, node: view.pointOfView)
                opening = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                    self?.applyCamera(animated: true, duration: 1.4)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.opening = false }
                }
            } else if !opening && cameraIsOnPreset {
                applyCamera(animated: false)       // keep the board framed when the window resizes
            }
        }

        func sync(state: FlowState, initial: Bool) {
            guard let stage else { return }

            if lastFinish != state.finish {
                lastFinish = state.finish
                stage.apply(finish: state.finish == .silver ? .silver : .spaceGray)
            }

            if lastSelectedKey != .some(state.selectedKeyIndex) {
                lastSelectedKey = .some(state.selectedKeyIndex)
                stage.setSelectedKey(state.selectedKeyIndex)
            }

            // Orange legends: remapped keys in Touches, the keys that trigger the macro in Macros.
            switch state.section {
            case .keys: stage.setMarkedKeys(Set(state.changedKeys.map(\.id)))
            case .macros: stage.setMarkedKeys(Set(state.macroTriggers(state.macroSlot).map(\.id)))
            default: stage.setMarkedKeys([])
            }

            let showZones = state.section == .touchbar
            let zones = [state.touchZoneCount, state.touchB1, state.touchB2, state.activeTouchZone, showZones ? 1 : 0]
            if zones != lastZones {
                lastZones = zones
                stage.setTouchZones(count: state.touchZoneCount, b1: state.touchB1, b2: state.touchB2,
                                    active: state.activeTouchZone, visible: showZones)
            }

            let ledState = state.selectedDevice == nil ? 0 : (state.profileSupported ? 1 : 2)
            if ledState != lastLED {
                lastLED = ledState
                stage.setStatusLED(ledState == 0 ? nil : (ledState == 1 ? .systemGreen : .systemOrange))
            }

            brightness = state.brightness
            effect = state.effect
            speed = state.waveSpeed
            let animated = effect != 0 && brightness > 0.5
            view?.rendersContinuously = animated
            if !animated {
                stage.updateBacklight(time: 0, brightness: brightness, effect: 0, speed: speed)
            }

            if initial {
                lastPreset = state.cameraPreset
                lastNonce = state.cameraNonce
            } else if lastPreset != state.cameraPreset || lastNonce != state.cameraNonce {
                lastPreset = state.cameraPreset
                lastNonce = state.cameraNonce
                if didOpen { applyCamera(animated: true) }
            }
        }

        func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
            guard effect != 0 else { return }
            stage?.updateBacklight(time: time, brightness: brightness, effect: effect, speed: speed)
        }

        func handleHover(_ raw: CGPoint?) {
            guard let view, let stage else { return }
            guard let raw else { stage.setHoveredKey(nil); return }
            let scale = host?.renderScale ?? 1
            let point = CGPoint(x: raw.x * scale, y: raw.y * scale)
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            if let node = hits.first?.node, case .key(let id)? = stage.resolve(hit: node) {
                stage.setHoveredKey(id)
            } else {
                stage.setHoveredKey(nil)
            }
        }

        @objc func handleClick(_ gesture: NSClickGestureRecognizer) {
            guard let view, let stage else { return }
            // The click arrives in host points; the scene may be rendered at twice that size.
            let scale = host?.renderScale ?? 1
            let raw = gesture.location(in: view)
            let point = CGPoint(x: raw.x * scale, y: raw.y * scale)
            let hits = view.hitTest(point, options: [.searchMode: SCNHitTestSearchMode.closest.rawValue])
            guard let node = hits.first?.node, let hit = stage.resolve(hit: node) else { return }
            switch hit {
            case .key(let id):
                stage.pressKey(id)
                state.selectedKeyIndex = id
            case .touchZone(let zone):
                state.activeTouchZone = min(zone, max(0, state.touchZoneCount - 1))
                state.section = .touchbar
            }
        }
    }
}
