// OWNER: App worker. SceneKit stylized human head that mirrors the user.
import SceneKit
import AppKit
import QuartzCore

/// Thread-safe hand-off from the main thread (camera poses, ~15 Hz) to the render thread.
/// `nil` angles mean no face this frame; each `set` is stamped so the renderer sees every new sample once.
final class FaceTarget {
    private let lock = NSLock()
    private var angles: FaceAngles?
    private var stamp = 0.0
    private var seq = 0
    private var settleRequested = true

    func set(_ a: FaceAngles?, at time: Double = CACurrentMediaTime()) {
        lock.lock(); angles = a; stamp = time; seq &+= 1; lock.unlock()
    }
    /// Latest angles (neutral when there is no face).
    func get() -> FaceAngles { lock.lock(); defer { lock.unlock() }; return angles ?? FaceAngles() }
    /// The latest sample if it is newer than `seen`.
    func take(after seen: Int) -> (angles: FaceAngles?, time: Double, seq: Int)? {
        lock.lock(); defer { lock.unlock() }
        return seq == seen ? nil : (angles, stamp, seq)
    }
    /// Asks the renderer to jump to the latest pose on its next frame (the view was hidden, so gliding in
    /// from a stale pose would look like a glitch).
    func requestSettle() { lock.lock(); settleRequested = true; lock.unlock() }
    func takeSettleRequest() -> Bool {
        lock.lock(); defer { lock.unlock() }
        let r = settleRequested; settleRequested = false; return r
    }
}

final class FaceRig {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let avatar = SCNNode()       // lean + distance
    private let torso = SCNNode()
    private let headPivot = SCNNode()    // turns at the top of the neck, like a real head
    private var eyeballs: [SCNNode] = []
    private var upperLids: [SCNNode] = []
    private var lowerLids: [SCNNode] = []
    private var brows: [SCNNode] = []
    private(set) var current = FaceAngles()
    private(set) var animator = FaceAnimator()
    private var seen = 0

    /// Visible extent to frame (scene units): head with hair, ears and the top of the shoulders.
    private static let frameSize = CGSize(width: 2.55, height: 3.35), frameCenterY = -0.12

    init() {
        scene.background.contents = NSColor.clear
        scene.lightingEnvironment.contents = FaceGeometry.environmentImage
        scene.lightingEnvironment.intensity = 0.85
        build()
        apply(FaceAngles())
    }

    // MARK: Materials

    /// Soft PBR material with a fresnel rim, so the silhouette separates from light and dark backgrounds.
    private static func material(_ color: NSColor, roughness: CGFloat, rim: CGFloat = 0.22,
                                 clearCoat: CGFloat = 0) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = 0.0
        if clearCoat > 0 { m.clearCoat.contents = clearCoat; m.clearCoatRoughness.contents = 0.05 }
        if rim > 0 {
            m.shaderModifiers = [.fragment: """
            float ndv = saturate(dot(_surface.normal, _surface.view));
            _output.color.rgb += float3(1.0, 0.97, 0.94) * pow(1.0 - ndv, 3.0) * \(rim);
            """]
        }
        return m
    }

    private static var skinColor: NSColor {
        let t = FaceGeometry.skinTone
        return NSColor(srgbRed: CGFloat(t.x), green: CGFloat(t.y), blue: CGFloat(t.z), alpha: 1)
    }

    // MARK: Build

    private func add(_ mesh: MeshData, _ m: SCNMaterial, to parent: SCNNode, at p: SCNVector3 = SCNVector3Zero) -> SCNNode {
        let n = SCNNode(geometry: mesh.geometry(m))
        n.position = p
        parent.addChildNode(n)
        return n
    }

    private func build() {
        let skin = FaceRig.material(.white, roughness: 0.58, rim: 0.2)          // tinted by the head's vertex colours
        let plainSkin = FaceRig.material(FaceRig.skinColor, roughness: 0.58, rim: 0.2)
        let hairM = FaceRig.material(.white, roughness: 0.66, rim: 0.14)
        let lashM = FaceRig.material(NSColor(srgbRed: 0.13, green: 0.09, blue: 0.07, alpha: 1), roughness: 0.6, rim: 0)
        let browM = FaceRig.material(NSColor(srgbRed: 0.24, green: 0.16, blue: 0.11, alpha: 1), roughness: 0.7, rim: 0)
        let lipM = FaceRig.material(NSColor(srgbRed: 0.78, green: 0.42, blue: 0.4, alpha: 1), roughness: 0.42, rim: 0.1)
        let earInner = FaceRig.material(NSColor(srgbRed: 0.88, green: 0.62, blue: 0.54, alpha: 1), roughness: 0.6, rim: 0)
        let accent = NSColor.controlAccentColor.usingColorSpace(.sRGB) ?? .systemBlue
        let shirtColor = accent.blended(withFraction: 0.55, of: NSColor(white: 0.5, alpha: 1)) ?? accent
        let shirt = FaceRig.material(shirtColor, roughness: 0.85, rim: 0.12)
        let eyeM = FaceRig.material(.white, roughness: 0.3, rim: 0, clearCoat: 1)
        eyeM.diffuse.contents = FaceGeometry.irisImage

        scene.rootNode.addChildNode(avatar)

        // Body: does not turn with the head (a little, for life).
        avatar.addChildNode(torso)
        _ = add(FaceGeometry.neck, plainSkin, to: torso)
        _ = add(FaceGeometry.torso, shirt, to: torso, at: SCNVector3(0, -1.88, -0.12))
        let collar = SCNNode(geometry: SCNTorus(ringRadius: 0.34, pipeRadius: 0.06))
        collar.geometry?.materials = [shirt]
        collar.position = SCNVector3(0, -1.2, -0.06)
        collar.eulerAngles.x = 0.18
        torso.addChildNode(collar)

        // Head, pivoting at the top of the neck.
        let pivotY = -0.55
        headPivot.position = SCNVector3(0, pivotY, -0.08)
        avatar.addChildNode(headPivot)
        let head = SCNNode()
        head.position = SCNVector3(0, -pivotY, 0.08)
        headPivot.addChildNode(head)

        _ = add(FaceGeometry.head, skin, to: head)
        _ = add(FaceGeometry.hair, hairM, to: head)
        for s in [-1.0, 1.0] {
            let ear = SCNNode()
            ear.position = SCNVector3(0.8 * s, -0.06, -0.06)
            ear.eulerAngles = SCNVector3(0, 0.35 * s, 0.08 * s)
            head.addChildNode(ear)
            _ = add(FaceGeometry.ellipsoid(V3(0.1, 0.2, 0.15)), plainSkin, to: ear)
            _ = add(FaceGeometry.ellipsoid(V3(0.05, 0.12, 0.08)), earInner, to: ear, at: SCNVector3(0.06 * s, 0, 0.02))

            // Eyebrow: a soft arched stroke just above the socket, thicker toward the middle.
            let browNode = SCNNode()
            head.addChildNode(browNode)
            let pts = (0...16).map { k -> V3 in
                let t = Double(k) / 16
                return FaceGeometry.onSkin(s * (0.13 + 0.36 * t), 0.36 + 0.07 * sin(.pi * min(t * 1.2, 1)) - 0.03 * t, lift: 0.012)
            }
            _ = add(FaceGeometry.tube(pts, radius: FaceGeometry.taper(0.032, bias: -0.9)), browM, to: browNode)
            brows.append(browNode)

            // Eye: textured eyeball in a socket, with upper and lower lids (skin shells) and a lash line.
            let socket = SCNNode()
            socket.position = SCNVector3(0.34 * s, 0.05, 0.69)
            head.addChildNode(socket)
            let ball = add(FaceGeometry.eyeball, eyeM, to: socket)
            eyeballs.append(ball)

            let r = FaceGeometry.eyeRadius
            let upper = SCNNode()
            socket.addChildNode(upper)
            let lidMesh = FaceGeometry.cap(radius: r + 0.012, maxAngle: .pi / 2)
            let lidM = plainSkin.copy() as! SCNMaterial
            lidM.isDoubleSided = true
            _ = add(lidMesh, lidM, to: upper)
            let lash = (0...24).map { k -> V3 in
                let t = Double.pi + 0.18 + (Double.pi - 0.36) * Double(k) / 24
                return V3(cos(t), sin(t), 0) * (r + 0.016)
            }
            // Thicker toward the outer corner (viewer's right eye: +x).
            _ = add(FaceGeometry.tube(lash, sides: 8, radius: FaceGeometry.taper(0.017, bias: 1.1 * s)), lashM, to: upper)
            upperLids.append(upper)

            let lower = SCNNode()
            socket.addChildNode(lower)
            _ = add(FaceGeometry.cap(radius: r + 0.008, maxAngle: .pi / 2), lidM, to: lower)
            lowerLids.append(lower)
        }

        // Mouth: a small friendly smile on the skin.
        let smile = (0...20).map { k -> V3 in
            let t = Double(k) / 20 * 2 - 1
            return FaceGeometry.onSkin(0.2 * t, -0.53 + 0.05 * t * t, lift: 0.004)
        }
        _ = add(FaceGeometry.tube(smile, radius: FaceGeometry.taper(0.024)), lipM, to: head)

        // Camera.
        let cam = SCNCamera()
        cam.zNear = 1; cam.zFar = 30
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, FaceRig.frameCenterY, 11)
        scene.rootNode.addChildNode(cameraNode)
        fit(aspect: 1)

        // Lights: soft image-based fill from the environment, a warm key from the upper left and a cool
        // rim from behind on the right.
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional
        key.light?.intensity = 1150
        key.light?.color = NSColor(srgbRed: 1, green: 0.97, blue: 0.93, alpha: 1)
        key.eulerAngles = SCNVector3(-0.55, -0.45, 0)
        scene.rootNode.addChildNode(key)
        let rim = SCNNode(); rim.light = SCNLight(); rim.light?.type = .directional
        rim.light?.intensity = 1800
        rim.light?.color = NSColor(srgbRed: 0.9, green: 0.95, blue: 1, alpha: 1)
        rim.eulerAngles = SCNVector3(-0.35, .pi - 0.7, 0)
        scene.rootNode.addChildNode(rim)
    }

    /// Frame the head and shoulders for a view of the given width / height.
    func fit(aspect: CGFloat) {
        guard let cam = cameraNode.camera, aspect > 0 else { return }
        let d = Double(cameraNode.position.z)
        let f = FaceRig.frameSize
        if aspect >= f.width / f.height {
            cam.projectionDirection = .vertical
            cam.fieldOfView = 2 * atan(f.height / 2 / d) * 180 / .pi
        } else {
            cam.projectionDirection = .horizontal
            cam.fieldOfView = 2 * atan(f.width / 2 / d) * 180 / .pi
        }
    }

    // MARK: Pose

    /// Render thread, once per frame: take any new sample from `target`, step the animator, apply.
    func advance(from target: FaceTarget, at time: Double) {
        if let s = target.take(after: seen) {
            seen = s.seq
            animator.push(s.angles, at: s.time)
        }
        apply(animator.advance(to: time), presence: animator.presence.value)
    }

    /// Start from the latest sample instead of gliding in from neutral.
    func settle(from target: FaceTarget, at time: Double) {
        if let s = target.take(after: seen) { seen = s.seq; animator.push(s.angles, at: s.time) }
        animator.advance(to: time)
        animator.settle()
        apply(animator.output, presence: animator.presence.value)
    }

    func apply(_ a: FaceAngles, presence: Double = 1) {
        current = a
        // Mirror: the user's right is the viewer's right (+x). Pitch up tilts the nose up (-x rotation).
        headPivot.eulerAngles = SCNVector3(-a.pitch, a.yaw, -a.roll)
        torso.eulerAngles = SCNVector3(0, a.yaw * 0.12, -a.roll * 0.1)
        avatar.position = SCNVector3(a.leanX, a.leanY, 0)
        let s = CGFloat(a.scale)
        avatar.scale = SCNVector3(s, s, s)
        for e in eyeballs { e.eulerAngles = SCNVector3(-a.eyePitch, a.eyeYaw, 0) }

        // Lids follow the gaze a little (look up: lids lift), close on a blink and droop while no face is seen.
        let open = min(max(a.openness, 0), 1) * (0.7 + 0.3 * presence)
        let deg = Double.pi / 180
        let upperEdge = -26 * deg + (54 * deg + 0.45 * a.eyePitch) * open
        let lowerEdge = -31 * deg + 0.15 * min(a.eyePitch, 0) + 5 * deg * (1 - open)
        for l in upperLids { l.eulerAngles = SCNVector3(-(Double.pi / 2 + upperEdge), 0, 0) }
        for l in lowerLids { l.eulerAngles = SCNVector3(Double.pi / 2 - lowerEdge, 0, 0) }
        let lift = 0.05 * max(min(a.eyePitch / FaceMapping.maxEyePitch, 1), -1)
        for b in brows { b.position = SCNVector3(0, lift, 0) }
    }

    private lazy var offscreen: SCNRenderer? = {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        r.pointOfView = cameraNode
        r.autoenablesDefaultLighting = false
        return r
    }()

    /// Render offscreen (no window) to an image.
    func snapshot(size: CGSize, angles: FaceAngles, presence: Double = 1) -> NSImage? {
        guard let r = offscreen else { return nil }
        fit(aspect: size.width / size.height)
        apply(angles, presence: presence)
        return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
