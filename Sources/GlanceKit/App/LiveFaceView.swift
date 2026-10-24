// OWNER: App worker. "Live view": a mirror face driven by PoseHub next to a to-scale display mini-map.
import SwiftUI
import SceneKit
import Combine

/// Feeds the face rig and the mini-map. Only listens to the hub while visible.
public final class LiveFaceModel: ObservableObject {
    @Published var pose: HeadPose?
    @Published var estimate: GazeEstimate?
    @Published var currentDisplay: DisplayID?
    @Published var displays: [Displays.Info] = []
    @Published var signals = FaceMapping.Signals()
    @Published var mode: GazeMode = .both
    @Published var eyeWeight = 0.7
    @Published var calibrated = false
    var isVisible: Bool { visibleCount > 0 }
    let target = FaceTarget()

    private let hub: PoseHub
    private var token: UUID?
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
        target.set(faceAngles(for: pose))
        self.pose = pose
        signals = FaceMapping.signals(from: pose)
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
        ingest(hub.latest)
        token = hub.observe { [weak self] in self?.ingest($0) }
    }

    func hide() {
        visibleCount = max(visibleCount - 1, 0)
        guard visibleCount == 0, let t = token else { return }
        hub.remove(t); token = nil
        onVisibilityChange?()
    }
}

// MARK: SceneKit host

/// SCNView that smooths toward the target at display rate and stops rendering when hidden.
final class FaceSCNView: SCNView, SCNSceneRendererDelegate {
    var rig: FaceRig?
    var target: FaceTarget?
    private var lastTime: TimeInterval?
    private var observer: NSObjectProtocol?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        guard let w = window else { isPlaying = false; return }
        observer = NotificationCenter.default.addObserver(forName: NSWindow.didChangeOcclusionStateNotification,
                                                          object: w, queue: .main) { [weak self] _ in self?.syncPlaying() }
        syncPlaying()
    }

    func syncPlaying() {
        let visible = window?.occlusionState.contains(.visible) ?? false
        isPlaying = visible && !(window?.isMiniaturized ?? true)
        if !isPlaying { lastTime = nil }
    }

    func renderer(_ renderer: SCNSceneRenderer, updateAtTime time: TimeInterval) {
        defer { lastTime = time }
        guard let rig, let target else { return }
        rig.advance(to: target.get(), dt: lastTime.map { min(time - $0, 0.1) } ?? 0.016)
    }

    deinit { if let o = observer { NotificationCenter.default.removeObserver(o) } }
}

struct FaceSceneView: NSViewRepresentable {
    let target: FaceTarget

    func makeNSView(context: Context) -> FaceSCNView {
        let v = FaceSCNView()
        let rig = FaceRig()
        v.rig = rig; v.target = target
        v.scene = rig.scene
        v.pointOfView = rig.cameraNode
        v.delegate = v
        v.backgroundColor = .clear
        v.antialiasingMode = .multisampling4X
        v.preferredFramesPerSecond = 60
        v.rendersContinuously = false
        v.isPlaying = false     // viewDidMoveToWindow turns it on once it is actually visible
        return v
    }

    func updateNSView(_ nsView: FaceSCNView, context: Context) {}
}

// MARK: Mini-map and bars

struct MiniMapView: View {
    @ObservedObject var model: LiveFaceModel

    var body: some View {
        Canvas { ctx, size in
            let layout = MiniMapLayout(displays: model.displays, size: size)
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 4, dy: 4)
            let selected = model.estimate?.displayID
            for d in model.displays {
                let r = layout.rect(of: d)
                let isSel = d.id == selected
                let isCur = d.id == model.currentDisplay
                let path = Path(roundedRect: r.insetBy(dx: 1, dy: 1), cornerRadius: 4)
                ctx.fill(path, with: .color(isSel ? Color.accentColor.opacity(0.28) : Color.secondary.opacity(0.12)))
                ctx.stroke(path, with: .color(isSel ? Color.accentColor : Color.secondary.opacity(isCur ? 0.9 : 0.4)),
                           lineWidth: isCur ? 2.5 : 1)
                if isCur {
                    ctx.draw(Text("focus").font(.caption2).foregroundColor(.secondary), at: CGPoint(x: r.midX, y: r.maxY - 10))
                }
            }
            if let e = model.estimate {
                let p = layout.point(e.point, clampedTo: bounds)
                let off = e.displayID == nil
                let dot = Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14))
                let color: Color = off ? .orange : .red
                ctx.fill(dot, with: .color(color.opacity(off ? 0.15 : 0.9)))
                ctx.stroke(dot, with: .color(color), lineWidth: 2)
            }
        }
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.06)))
        .overlay(alignment: .topLeading) {
            Text(model.estimate.map { $0.displayID == nil ? "off-screen" : "looking at display" } ?? "no estimate")
                .font(.caption2).foregroundStyle(.secondary).padding(6)
        }
    }
}

struct SignalBar: View {
    var title: String
    var value: Double       // -1...1
    var tint: Color

    var body: some View {
        HStack(spacing: 8) {
            Text(title).font(.caption).frame(width: 74, alignment: .leading)
            GeometryReader { g in
                let half = g.size.width / 2
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.secondary.opacity(0.15))
                    Capsule().fill(tint)
                        .frame(width: max(abs(value) * half, 2))
                        .offset(x: value >= 0 ? half : half - abs(value) * half)
                    Rectangle().fill(Color.secondary.opacity(0.6)).frame(width: 1).offset(x: half)
                }
            }
            .frame(height: 8)
        }
    }
}

struct LiveFacePanel: View {
    @ObservedObject var model: LiveFaceModel

    private var modeText: String {
        switch model.mode {
        case .head: return "Head only"
        case .eyes: return "Eyes only"
        case .both: return "Both · \(Int((model.eyeWeight * 100).rounded()))% eyes"
        }
    }

    var body: some View {
        VStack(spacing: 10) {
            FaceSceneView(target: model.target)
                .frame(minHeight: 220)
                .overlay(alignment: .topTrailing) {
                    if model.pose == nil {
                        Label("No face", systemImage: "eye.slash").font(.caption).foregroundStyle(.secondary).padding(6)
                    }
                }
            MiniMapView(model: model).frame(height: 120)
            HStack {
                Label(modeText, systemImage: "scope").font(.caption)
                Spacer()
                if let e = model.estimate {
                    Text("confidence \(Int((e.confidence * 100).rounded()))%").font(.caption).monospacedDigit()
                } else if !model.calibrated {
                    Text("not calibrated").font(.caption).foregroundStyle(.orange)
                }
            }
            VStack(spacing: 4) {
                SignalBar(title: "Head ↔", value: model.signals.headX, tint: .blue)
                SignalBar(title: "Eyes ↔", value: model.signals.eyeX, tint: .green)
                SignalBar(title: "Head ↕", value: model.signals.headY, tint: .blue.opacity(0.6))
                SignalBar(title: "Eyes ↕", value: model.signals.eyeY, tint: .green.opacity(0.6))
            }
        }
        .padding(14)
        .onAppear { model.show() }
        .onDisappear { model.hide() }
    }
}
