// OWNER: App worker. SceneKit stylized human head that mirrors the user.
import SceneKit
import AppKit

/// Thread-safe hand-off from the main thread (camera poses) to the render thread.
final class FaceTarget {
    private let lock = NSLock()
    private var angles = FaceAngles()
    func set(_ a: FaceAngles) { lock.lock(); angles = a; lock.unlock() }
    func get() -> FaceAngles { lock.lock(); defer { lock.unlock() }; return angles }
}

final class FaceRig {
    let scene = SCNScene()
    let cameraNode = SCNNode()
    private let head = SCNNode()
    private var eyeballs: [SCNNode] = []
    private var upperLids: [SCNNode] = []
    private(set) var current = FaceAngles()
    private let lidOpenAngle = 2.0     // radians the upper lid is rotated up when fully open

    private static let skin = NSColor(calibratedRed: 0.93, green: 0.74, blue: 0.62, alpha: 1)

    init() {
        scene.background.contents = NSColor.clear
        build()
        apply(FaceAngles())
    }

    // MARK: Build

    private func material(_ color: NSColor, shininess: CGFloat = 0.1, doubleSided: Bool = false) -> SCNMaterial {
        let m = SCNMaterial()
        m.diffuse.contents = color
        m.lightingModel = .blinn
        m.specular.contents = NSColor(white: 1, alpha: shininess)
        m.shininess = 0.25
        m.isDoubleSided = doubleSided
        return m
    }

    private func node(_ g: SCNGeometry, _ m: SCNMaterial, at p: SCNVector3 = SCNVector3Zero,
                      scale: SCNVector3 = SCNVector3(1, 1, 1)) -> SCNNode {
        g.materials = [m]
        (g as? SCNSphere)?.segmentCount = 96
        let n = SCNNode(geometry: g)
        n.position = p; n.scale = scale
        return n
    }

    /// Spherical cap around +z reaching `maxAngle` from the pole (π/2 = hemisphere).
    static func cap(radius: CGFloat, maxAngle: Double, rings: Int = 14, segments: Int = 32) -> SCNGeometry {
        var verts: [SCNVector3] = [], normals: [SCNVector3] = [], idx: [Int32] = []
        for i in 0...rings {
            let phi = maxAngle * Double(i) / Double(rings)
            for j in 0...segments {
                let th = 2 * Double.pi * Double(j) / Double(segments)
                let n = SCNVector3(sin(phi) * cos(th), sin(phi) * sin(th), cos(phi))
                normals.append(n)
                verts.append(SCNVector3(n.x * radius, n.y * radius, n.z * radius))
            }
        }
        let row = Int32(segments + 1)
        for i in 0..<Int32(rings) {
            for j in 0..<Int32(segments) {
                let a = i * row + j, b = a + 1, c = a + row, d = c + 1
                idx += [a, c, b, b, c, d]
            }
        }
        return SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(normals: normals)],
                           elements: [SCNGeometryElement(indices: idx, primitiveType: .triangles)])
    }

    private func build() {
        let skin = FaceRig.skin
        let skinM = material(skin, shininess: 0.08)
        let hairM = material(NSColor(calibratedRed: 0.20, green: 0.13, blue: 0.09, alpha: 1), shininess: 0.12, doubleSided: true)
        let darkM = material(NSColor(calibratedRed: 0.22, green: 0.14, blue: 0.1, alpha: 1))

        // Body (does not rotate with the head).
        let body = SCNNode()
        body.addChildNode(node(SCNCylinder(radius: 0.3, height: 1.1), skinM, at: SCNVector3(0, -1.25, -0.05)))
        let shoulders = node(SCNCapsule(capRadius: 0.45, height: 3.1), material(NSColor(calibratedRed: 0.27, green: 0.38, blue: 0.55, alpha: 1)),
                             at: SCNVector3(0, -2.15, -0.1))
        shoulders.eulerAngles.z = .pi / 2
        shoulders.scale = SCNVector3(1, 1, 0.75)
        body.addChildNode(shoulders)
        scene.rootNode.addChildNode(body)

        // Head.
        scene.rootNode.addChildNode(head)
        head.addChildNode(node(SCNSphere(radius: 1), skinM, scale: SCNVector3(0.88, 1.05, 0.95)))                    // skull
        head.addChildNode(node(SCNSphere(radius: 0.62), skinM, at: SCNVector3(0, -0.62, 0.02), scale: SCNVector3(0.9, 0.86, 0.9))) // jaw
        head.addChildNode(node(SCNSphere(radius: 0.17), skinM, at: SCNVector3(-0.87, -0.02, -0.02), scale: SCNVector3(0.4, 1, 0.75)))
        head.addChildNode(node(SCNSphere(radius: 0.17), skinM, at: SCNVector3(0.87, -0.02, -0.02), scale: SCNVector3(0.4, 1, 0.75)))
        let nose = node(SCNSphere(radius: 0.13), material(skin.blended(withFraction: 0.12, of: .systemRed) ?? skin, shininess: 0.3),
                        at: SCNVector3(0, -0.2, 0.93), scale: SCNVector3(0.85, 1.25, 1.1))
        head.addChildNode(nose)
        head.addChildNode(node(SCNCapsule(capRadius: 0.07, height: 0.5), skinM, at: SCNVector3(0, 0.0, 0.9)))        // bridge
        let mouth = node(SCNCapsule(capRadius: 0.028, height: 0.34), material(NSColor(calibratedRed: 0.66, green: 0.3, blue: 0.3, alpha: 1)),
                         at: SCNVector3(0, -0.56, 0.86))
        mouth.eulerAngles.z = .pi / 2
        head.addChildNode(mouth)
        for s: CGFloat in [-1, 1] {
            let brow = node(SCNCapsule(capRadius: 0.026, height: 0.3), darkM, at: SCNVector3(0.36 * s, 0.4, 0.86))
            brow.eulerAngles.z = .pi / 2 + 0.12 * Double(s)
            head.addChildNode(brow)
        }
        // Hair: a cap over the top and back of the skull.
        // The scale lives on a parent so it applies along head axes, not the tilted cap's.
        let hairCap = node(FaceRig.cap(radius: 1.0, maxAngle: 1.5), hairM)
        hairCap.eulerAngles.x = -(Double.pi / 2 + 0.6)
        let hair = SCNNode()
        hair.position = SCNVector3(0, 0, -0.04)
        hair.scale = SCNVector3(0.915, 1.085, 1.0)
        hair.addChildNode(hairCap)
        head.addChildNode(hair)

        // Eyes.
        for s: CGFloat in [-1, 1] {
            let socket = SCNNode()
            socket.position = SCNVector3(0.34 * s, 0.12, 0.8)
            head.addChildNode(socket)
            let ball = SCNNode()
            ball.addChildNode(node(SCNSphere(radius: 0.17), material(NSColor(white: 0.97, alpha: 1), shininess: 0.6)))
            ball.addChildNode(node(FaceRig.cap(radius: 0.172, maxAngle: 0.5), material(NSColor(calibratedRed: 0.28, green: 0.5, blue: 0.62, alpha: 1))))
            ball.addChildNode(node(FaceRig.cap(radius: 0.1735, maxAngle: 0.22), material(.black)))
            socket.addChildNode(ball)
            eyeballs.append(ball)
            let glint = node(SCNSphere(radius: 0.016), material(.white), at: SCNVector3(0.05, 0.06, 0.168))
            glint.geometry?.firstMaterial?.emission.contents = NSColor.white
            socket.addChildNode(glint)
            let lid = node(FaceRig.cap(radius: 0.186, maxAngle: .pi / 2), skinM)
            lid.geometry?.firstMaterial?.isDoubleSided = true
            socket.addChildNode(lid)
            upperLids.append(lid)
        }

        // Camera and light.
        let cam = SCNCamera()
        cam.fieldOfView = 28; cam.zNear = 0.1; cam.zFar = 50
        cameraNode.camera = cam
        cameraNode.position = SCNVector3(0, -0.15, 7.2)
        scene.rootNode.addChildNode(cameraNode)

        let amb = SCNNode(); amb.light = SCNLight(); amb.light?.type = .ambient
        amb.light?.color = NSColor(white: 0.6, alpha: 1)
        scene.rootNode.addChildNode(amb)
        let key = SCNNode(); key.light = SCNLight(); key.light?.type = .directional
        key.light?.color = NSColor(white: 0.85, alpha: 1)
        key.eulerAngles = SCNVector3(-0.5, -0.5, 0)
        scene.rootNode.addChildNode(key)
        let fill = SCNNode(); fill.light = SCNLight(); fill.light?.type = .omni
        fill.light?.color = NSColor(calibratedRed: 0.7, green: 0.8, blue: 1, alpha: 1)
        fill.light?.intensity = 150
        fill.position = SCNVector3(-3, 1, 5)
        scene.rootNode.addChildNode(fill)
    }

    // MARK: Pose

    /// Advance the smoothed pose toward `target` and apply it. Call on the render thread's update.
    func advance(to target: FaceAngles, dt: Double) {
        apply(FaceSmoother.step(current, toward: target, dt: dt))
    }

    func apply(_ a: FaceAngles) {
        current = a
        // Mirror: the user's right is the viewer's right (+x). Pitch up tilts the nose up (-x rotation).
        head.eulerAngles = SCNVector3(-a.pitch, a.yaw, -a.roll)
        head.position = SCNVector3(a.leanX, a.leanY, 0)
        let s = CGFloat(a.scale)
        head.scale = SCNVector3(s, s, s)
        for e in eyeballs { e.eulerAngles = SCNVector3(-a.eyePitch, a.eyeYaw, 0) }
        let lidAngle = lidOpenAngle * min(max(a.openness, 0), 1)
        for l in upperLids { l.eulerAngles = SCNVector3(-lidAngle, 0, 0) }
    }

    /// Render offscreen (no window) to an image.
    func snapshot(size: CGSize, angles: FaceAngles) -> NSImage? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        apply(angles)
        let r = SCNRenderer(device: device, options: nil)
        r.scene = scene
        r.pointOfView = cameraNode
        r.autoenablesDefaultLighting = false
        return r.snapshot(atTime: 0, with: size, antialiasingMode: .multisampling4X)
    }
}
