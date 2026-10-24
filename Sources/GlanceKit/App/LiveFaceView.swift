// OWNER: App worker. "Live view": a mirror face driven by PoseHub next to a to-scale display mini-map.
import SwiftUI
import SceneKit
import Combine

/// Feeds the face rig and the mini-map. Only listens to the hub while visible.
///
/// Camera-rate data (`pose`, `estimate`, `signals`) is deliberately not `@Published`: it goes straight to the
/// SceneKit renderer (`target`) and to `motion`, which the canvases read once per display frame. Only slow
/// facts are published (displays, settings, whether a face is in view, which display the gaze is on), and
/// only when they change, so the SwiftUI tree rebuilds a few times a minute instead of 15 times a second.
public final class LiveFaceModel: ObservableObject {
    struct DisplayLabel: Equatable { var name: String; var builtin: Bool }
    enum GazeTarget: Equatable { case none, offScreen, display(DisplayID) }

    var pose: HeadPose?
    var signals = FaceMapping.Signals()
    var estimate: GazeEstimate? {
        didSet {
            motion.push(gaze: estimate, at: clock())
            let t: GazeTarget = estimate.map { $0.displayID.map(GazeTarget.display) ?? .offScreen } ?? .none
            if t != gazeTarget { gazeTarget = t }
        }
    }
    var currentDisplay: DisplayID? {
        didSet { if currentDisplay != focusedDisplay { focusedDisplay = currentDisplay } }
    }
    @Published var displays: [Displays.Info] = [] {
        didSet { displayLabels = Self.labels(for: displays) }
    }
    @Published var mode: GazeMode = .both
    @Published var eyeWeight = 0.7
    @Published var calibrated = false
    /// A face is in view. Goes false only after the face has been missing for `lostDelay`, so a dropped
    /// frame doesn't flash "No face".
    @Published private(set) var faceVisible = false
    /// Nothing has moved for a while (no face): the face and the canvases stop redrawing.
    @Published private(set) var isIdle = false
    @Published private(set) var gazeTarget = GazeTarget.none
    @Published private(set) var focusedDisplay: DisplayID?
    var displayLabels: [DisplayID: DisplayLabel] = [:]
    var isVisible: Bool { visibleCount > 0 }
    let target = FaceTarget()
    let motion = LiveMotion()
    var clock: () -> Double = CACurrentMediaTime
    static let lostDelay = 0.6, idleDelay = 3.0

    private let hub: PoseHub
    private var token: UUID?
    private var screenObserver: NSObjectProtocol?
    private var lostWork: DispatchWorkItem?
    private var idleWork: DispatchWorkItem?
    private var heldEyes: (yaw: Double, pitch: Double) = (0, 0)
    private(set) var visibleCount = 0
    /// Called when the first view appears / the last one goes away (keeps the camera on while watching).
    var onVisibilityChange: (() -> Void)?

    init(hub: PoseHub) { self.hub = hub }

    /// Holds the last eye angles while the lids are shut (the offset is unreliable then).
    func faceAngles(for pose: HeadPose?) -> FaceAngles {
        var a = FaceMapping.angles(from: pose)
        guard let p = pose else { return a }
        if p.eyeOpenness < 0.3 { a.eyeYaw = heldEyes.yaw; a.eyePitch = heldEyes.pitch }
        else { heldEyes = (a.eyeYaw, a.eyePitch) }
        return a
    }

    func ingest(_ pose: HeadPose?) {
        let now = clock()
        let angles = pose.map { faceAngles(for: $0) }
        target.set(angles, at: now)
        motion.push(face: angles, at: now)
        self.pose = pose
        signals = FaceMapping.signals(from: pose)
        notePresence(pose != nil)
    }

    func update(state: SwitchEngine.State) {
        guard visibleCount > 0 else { return }
        estimate = state.estimate
        currentDisplay = state.currentDisplay
    }

    /// Reference-counted: the Settings tab and the Live Face window can both be showing.
    func show() {
        visibleCount += 1
        guard token == nil else { return }
        defer { onVisibilityChange?() }
        displays = Displays.all()
        faceVisible = hub.latest != nil
        isIdle = false
        target.requestSettle()
        ingest(hub.latest)
        motion.settle()
        token = hub.observe { [weak self] in self?.ingest($0) }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.displays = Displays.all()
        }
    }

    func hide() {
        visibleCount = max(visibleCount - 1, 0)
        guard visibleCount == 0, let t = token else { return }
        hub.remove(t); token = nil
        if let o = screenObserver { NotificationCenter.default.removeObserver(o); screenObserver = nil }
        lostWork?.cancel(); lostWork = nil
        idleWork?.cancel(); idleWork = nil
        onVisibilityChange?()
    }

    private func notePresence(_ present: Bool) {
        if present {
            lostWork?.cancel(); lostWork = nil
            idleWork?.cancel(); idleWork = nil
            if !faceVisible { faceVisible = true }
            if isIdle { isIdle = false }
        } else if lostWork == nil, idleWork == nil, faceVisible || !isIdle {
            let lost = DispatchWorkItem { [weak self] in self?.faceVisible = false; self?.lostWork = nil }
            let idle = DispatchWorkItem { [weak self] in self?.isIdle = true; self?.idleWork = nil }
            lostWork = lost; idleWork = idle
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.lostDelay, execute: lost)
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDelay, execute: idle)
        }
    }

    private static func labels(for displays: [Displays.Info]) -> [DisplayID: DisplayLabel] {
        Dictionary(uniqueKeysWithValues: displays.map {
            ($0.id, DisplayLabel(name: DisplayNames.name(for: $0.id), builtin: CGDisplayIsBuiltin($0.id) != 0))
        })
    }
}

// MARK: SceneKit host

/// SCNView that animates the rig at the display's refresh rate while it can be seen, and not at all otherwise
/// (hidden, occluded, minimised, or idle with no face).
final class FaceSCNView: SCNView, SCNSceneRendererDelegate {
    var rig: FaceRig?
    var target: FaceTarget?
    var idle = false { didSet { if idle != oldValue { syncPlaying() } } }
    private var observers: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        if let w = window {
            let names = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification]
            observers = names.map {
                NotificationCenter.default.addObserver(forName: $0, object: w, queue: .main) { [weak self] _ in self?.syncPlaying() }
            }
        }
        syncPlaying()
    }

    override func layout() {
        super.layout()
        if bounds.height > 0 { rig?.fit(aspect: bounds.width / bounds.height) }
    }

    func syncPlaying() {
        let shown = window.map { $0.occlusionState.contains(.visible) && !$0.isMiniaturized } ?? false
        if !shown { target?.requestSettle() }      // coming back, jump to the current pose instead of gliding
        preferredFramesPerSecond = min(window?.screen?.maximumFramesPerSecond ?? 60, 120)
        let play = shown && !idle
        if isPlaying != play { isPlaying = play; rendersContinuously = play }
    }

    // Render thread.
    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        guard let rig, let target else { return }
        let now = CACurrentMediaTime()
        if target.takeSettleRequest() { rig.settle(from: target, at: now) } else { rig.advance(from: target, at: now) }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}

struct FaceSceneView: NSViewRepresentable {
    let target: FaceTarget
    var idle = false

    func makeNSView(context: Context) -> FaceSCNView {
        let v = FaceSCNView()
        let rig = FaceRig()
        v.rig = rig; v.target = target
        v.scene = rig.scene
        v.pointOfView = rig.cameraNode
        v.delegate = v
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.rendersContinuously = false
        v.isPlaying = false     // viewDidMoveToWindow turns it on once it is actually visible
        return v
    }

    func updateNSView(_ nsView: FaceSCNView, context: Context) { nsView.idle = idle }
}

// MARK: Panel

/// The whole live view. Lays out side by side when wide (the main window's Overview, ~540 x 470) and
/// stacked when tall (the Live Face window, 380 x 640).
struct LiveFacePanel: View {
    @ObservedObject var model: LiveFaceModel
    /// Snapshots draw this instead of the SceneKit view, which `ImageRenderer` can't capture.
    var faceStandIn: NSImage? = nil

    var body: some View {
        GeometryReader { g in
            let inner = CGSize(width: max(g.size.width - 24, 0), height: max(g.size.height - 24, 0))
            Group {
                if inner.width >= inner.height { wide(inner) } else { tall(inner) }
            }
            .padding(12)
        }
        .onAppear { model.show() }
        .onDisappear { model.hide() }
    }

    private func wide(_ s: CGSize) -> some View {
        let top = (s.height * 0.58).rounded()
        return VStack(spacing: 10) {
            HStack(spacing: 10) {
                faceCard.frame(width: min(max(s.width * 0.42, 190), 300))
                VStack(spacing: 10) { gauge(.head); gauge(.eyes) }
            }
            .frame(height: top)
            mapCard
        }
    }

    private func tall(_ s: CGSize) -> some View {
        let map = min(max(s.height * 0.3, 150), 230)
        return VStack(spacing: 10) {
            faceCard
            HStack(spacing: 10) { gauge(.head); gauge(.eyes) }.frame(height: 112)
            mapCard.frame(height: map)
        }
    }

    // MARK: Cards

    private var card: RoundedRectangle { RoundedRectangle(cornerRadius: 12, style: .continuous) }

    private var faceCard: some View {
        ZStack(alignment: .topLeading) {
            Group {
                if let img = faceStandIn {
                    Image(nsImage: img).resizable().scaledToFit()
                } else {
                    FaceSceneView(target: model.target, idle: model.isIdle)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.top, 4)
            Rectangle().fill(.background).opacity(model.faceVisible ? 0 : 0.4).allowsHitTesting(false)
            StatusChip(faceVisible: model.faceVisible).padding(8)
        }
        .background {
            GeometryReader { g in
                RadialGradient(colors: [Color.accentColor.opacity(0.16), Color.accentColor.opacity(0)],
                               center: UnitPoint(x: 0.5, y: 0.42), startRadius: 0,
                               endRadius: max(g.size.width, g.size.height) * 0.55)
            }
            .background(.quinary)
        }
        .clipShape(card)
        .overlay(card.strokeBorder(.quaternary, lineWidth: 0.5))
        .animation(.easeInOut(duration: 0.35), value: model.faceVisible)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Live face")
        .accessibilityValue(model.faceVisible ? "Tracking" : "No face in view")
    }

    private func gauge(_ kind: MotionGauge.Kind) -> some View {
        let eyes = Int((model.eyeWeight * 100).rounded())
        let (note, active): (String, Bool) = {
            switch (model.mode, kind) {
            case (.both, .head): return ("\(100 - eyes)% weight", true)
            case (.both, .eyes): return ("\(eyes)% weight", true)
            case (.head, .head), (.eyes, .eyes): return ("In use", true)
            default: return ("Not used", false)
            }
        }()
        return MotionGauge(kind: kind, motion: model.motion, note: note, active: active, paused: model.isIdle)
            .background(.quinary, in: card)
            .overlay(card.strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private var mapCard: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: headline.symbol).foregroundStyle(headline.tint)
                Text(headline.text).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 8)
                if model.calibrated { ConfidenceLabel(model: model) }
            }
            .font(.caption)
            GazeMapView(motion: model.motion, displays: model.displays, labels: model.displayLabels,
                        focused: model.focusedDisplay, calibrated: model.calibrated, paused: model.isIdle)
        }
        .padding(.horizontal, 10).padding(.top, 8).padding(.bottom, 4)
        .background(.quinary, in: card)
        .overlay(card.strokeBorder(.quaternary, lineWidth: 0.5))
    }

    private var headline: (text: String, symbol: String, tint: Color) {
        if !model.calibrated { return ("Calibrate to see where you're looking", "scope", .orange) }
        switch model.gazeTarget {
        case .display(let id):
            return ("Looking at \(model.displayLabels[id]?.name ?? "a display")", "eye", .accentColor)
        case .offScreen:
            return ("Looking away from the displays", "eye.slash", .orange)
        case .none:
            return model.faceVisible ? ("Finding your gaze…", "eye", .secondary) : ("No face in view", "eye.slash", .secondary)
        }
    }
}

/// "Tracking" / "No face" in the corner of the face card.
private struct StatusChip: View {
    let faceVisible: Bool

    var body: some View {
        HStack(spacing: 5) {
            if faceVisible {
                Circle().fill(.green).frame(width: 6, height: 6)
            } else {
                Image(systemName: "eye.slash").imageScale(.small)
            }
            Text(faceVisible ? "Tracking" : "No face")
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(faceVisible ? .primary : .secondary)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.background.opacity(0.85), in: Capsule())
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 0.5))
    }
}

/// Confidence changes at camera rate; this small leaf re-reads it four times a second.
private struct ConfidenceLabel: View {
    let model: LiveFaceModel

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.25)) { _ in
            Text(model.estimate.map { "\(Int(($0.confidence * 100).rounded()))% confidence" } ?? "")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }
}
