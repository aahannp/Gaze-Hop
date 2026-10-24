// OWNER: App worker. Procedural meshes and textures for the live face (no asset files to ship).
import SceneKit
import AppKit
import simd

typealias V3 = SIMD3<Double>

/// Positions, normals and optional colours / UVs for one mesh. Plain data, so it is built once and every
/// rig makes its own SCNGeometry from it (two live views can render on two threads at once).
struct MeshData {
    var positions: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var colors: [SIMD4<Float>] = []
    var uvs: [SIMD2<Float>] = []
    var indices: [UInt32] = []

    func geometry(_ material: SCNMaterial) -> SCNGeometry {
        func source<T>(_ a: [T], _ s: SCNGeometrySource.Semantic, _ n: Int) -> SCNGeometrySource {
            SCNGeometrySource(data: a.withUnsafeBytes { Data($0) }, semantic: s, vectorCount: a.count,
                              usesFloatComponents: true, componentsPerVector: n, bytesPerComponent: 4,
                              dataOffset: 0, dataStride: MemoryLayout<T>.stride)
        }
        var sources = [source(positions, .vertex, 3), source(normals, .normal, 3)]
        if !colors.isEmpty { sources.append(source(colors, .color, 4)) }
        if !uvs.isEmpty { sources.append(source(uvs, .texcoord, 2)) }
        let g = SCNGeometry(sources: sources, elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)])
        g.materials = [material]
        return g
    }
}

enum FaceGeometry {
    // MARK: Shape helpers

    static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = min(max((x - a) / (b - a), 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// Soft bump on the unit sphere around `c` (anisotropic: `sx` across, `sy` up/down).
    static func bump(_ d: V3, _ c: V3, _ sx: Double, _ sy: Double) -> Double {
        let q = d - simd_normalize(c)
        return exp(-(q.x * q.x + q.z * q.z) / (2 * sx * sx) - q.y * q.y / (2 * sy * sy))
    }

    /// Direction for azimuth `theta` (0 = front, + = viewer's right) and polar angle `phi` from the top.
    static func dir(_ theta: Double, _ phi: Double) -> V3 {
        V3(sin(phi) * sin(theta), cos(phi), sin(phi) * cos(theta))
    }

    /// Where the skin is along direction `d` from the head centre: a rounded skull, tapered jaw, full
    /// cheeks, a button nose and soft eye sockets, all as one smooth surface (no seams between parts).
    static func headPoint(_ d: V3) -> V3 {
        var p = d * V3(0.9, 1.0, 0.92)
        let low = smoothstep(-0.05, -1.0, d.y)                 // 0 above the cheekbones, 1 at the chin
        p.x *= 1 - 0.14 * low
        p.z *= 1 - 0.04 * low
        p.y -= 0.04 * low
        var r = 0.0
        for s in [-1.0, 1.0] {
            r += 0.05 * bump(d, V3(0.5 * s, -0.36, 0.78), 0.2, 0.17)    // cheeks
            r -= 0.045 * bump(d, V3(0.4 * s, 0.06, 0.9), 0.13, 0.1)     // eye sockets
        }
        r += 0.075 * bump(d, V3(0, -0.2, 1), 0.07, 0.075)               // nose
        r += 0.02 * bump(d, V3(0, -0.62, 0.78), 0.22, 0.14)             // chin
        r += 0.025 * bump(d, V3(0, 0.32, 0.95), 0.4, 0.1)               // brow ridge
        return p + d * r
    }

    /// Point on the skin at (azimuth, elevation) in radians, pushed out by `lift`.
    static func onSkin(_ az: Double, _ el: Double, lift: Double = 0) -> V3 {
        let d = dir(az, .pi / 2 - el)
        let p = headPoint(d)
        return p + simd_normalize(p) * lift
    }

    // MARK: Mesh builders

    /// Grid over a parametric surface f(u, v), u, v in 0...1. Normals by central differences, oriented away
    /// from `inside(p)`; triangles wound to match, so single-sided materials render correctly.
    static func grid(cols: Int, rows: Int, inside: (V3) -> V3 = { _ in .zero },
                     color: ((V3, Double, Double) -> SIMD4<Float>)? = nil,
                     uv: ((V3) -> SIMD2<Float>)? = nil, _ f: (Double, Double) -> V3) -> MeshData {
        var m = MeshData()
        let e = 1e-4
        for j in 0...rows {
            let v = Double(j) / Double(rows)
            for i in 0...cols {
                let u = Double(i) / Double(cols)
                let p = f(u, v)
                let vc = min(max(v, 2e-3), 1 - 2e-3)
                let pu = f(u + e, vc) - f(u - e, vc), pv = f(u, vc + e) - f(u, vc - e)
                var n = simd_cross(pu, pv)
                n = simd_length(n) > 1e-12 ? simd_normalize(n) : simd_normalize(p - inside(p))
                if simd_dot(n, p - inside(p)) < 0 { n = -n }
                m.positions.append(SIMD3<Float>(p))
                m.normals.append(SIMD3<Float>(n))
                if let color { m.colors.append(color(p, u, v)) }
                if let uv { m.uvs.append(uv(p)) }
            }
        }
        let row = UInt32(cols + 1)
        for j in 0..<UInt32(rows) {
            for i in 0..<UInt32(cols) {
                let a = j * row + i, b = a + 1, c = a + row, d = c + 1
                m.addTriangle(a, c, b); m.addTriangle(b, c, d)
            }
        }
        return m
    }

    /// Tube along `points` with radius `radius(t)` (t = 0...1 along the curve); ends close to a point.
    static func tube(_ points: [V3], sides: Int = 12, radius: (Double) -> Double) -> MeshData {
        var m = MeshData()
        let n = points.count
        var normal = V3(0, 1, 0)
        for k in 0..<n {
            let t = Double(k) / Double(n - 1)
            let tangent = simd_normalize(points[min(k + 1, n - 1)] - points[max(k - 1, 0)])
            normal = simd_normalize(normal - tangent * simd_dot(normal, tangent))   // parallel transport
            if simd_length(normal) < 1e-6 || normal.x.isNaN { normal = simd_normalize(simd_cross(tangent, V3(0, 0, 1))) }
            let binormal = simd_cross(tangent, normal)
            let r = radius(t)
            for s in 0...sides {
                let a = 2 * Double.pi * Double(s) / Double(sides)
                let dir = normal * cos(a) + binormal * sin(a)
                m.positions.append(SIMD3<Float>(points[k] + dir * r))
                m.normals.append(SIMD3<Float>(simd_length(dir) > 0 ? simd_normalize(dir) : tangent))
            }
        }
        let row = UInt32(sides + 1)
        for k in 0..<UInt32(n - 1) {
            for s in 0..<UInt32(sides) {
                let a = k * row + s, b = a + 1, c = a + row, d = c + 1
                m.addTriangle(a, c, b); m.addTriangle(b, c, d)
            }
        }
        return m
    }

    /// Rounded-end radius profile for `tube`, with `bias` > 0 thickening toward the end (t = 1).
    static func taper(_ r: Double, bias: Double = 0) -> (Double) -> Double {
        { t in r * pow(max(sin(.pi * t), 0), 0.45) * (1 + bias * (t - 0.5)) }
    }

    /// Ellipsoid of radii `r` (an ear, a torso).
    static func ellipsoid(_ r: V3, cols: Int = 48, rows: Int = 32) -> MeshData {
        grid(cols: cols, rows: rows) { u, v in dir(2 * .pi * (u - 0.5), .pi * v) * r }
    }

    /// Spherical cap of `radius` around +z reaching `maxAngle` from the pole (eyelids).
    static func cap(radius: Double, maxAngle: Double) -> MeshData {
        grid(cols: 40, rows: 14) { u, v in
            let th = 2 * Double.pi * u, ph = maxAngle * v
            return V3(sin(ph) * cos(th), sin(ph) * sin(th), cos(ph)) * radius
        }
    }

    // MARK: The parts (built once)

    static let skinTone = SIMD3<Float>(0.95, 0.77, 0.65)

    /// Vertex colours are read as linear; author them in sRGB like everything else.
    static func linear(_ c: SIMD3<Float>) -> SIMD4<Float> {
        SIMD4<Float>(pow(c.x, 2.2), pow(c.y, 2.2), pow(c.z, 2.2), 1)
    }

    static let head: MeshData = grid(cols: 200, rows: 140, color: { p, _, _ in
        let d = simd_normalize(p)
        var c = skinTone
        var blush = 0.0
        for s in [-1.0, 1.0] { blush += bump(d, V3(0.52 * s, -0.3, 0.8), 0.14, 0.12) }
        c = simd_mix(c, SIMD3<Float>(0.96, 0.6, 0.56), SIMD3(repeating: Float(0.32 * blush)))
        return linear(c)
    }) { u, v in headPoint(dir(2 * .pi * (u - 0.5), .pi * v)) }

    /// Hairline: polar angle (from the crown) where the hair stops, by azimuth. Low on the forehead with a
    /// side-swept fringe, down to the temples, short sideburns, and the nape at the back.
    static func hairline(_ th: Double) -> Double {
        let deg = Double.pi / 180
        let front = pow(max(cos(th), 0), 2)
        var a = 95 * deg - 34 * deg * cos(th) - 3 * deg * cos(2 * th)
        a += 9 * deg * sin(th) * exp(-th * th / 0.35)                         // swept fringe
        a += 2.5 * deg * sin(11 * th + 0.6) * front                          // a few locks
        let side = abs(th)
        a += 15 * deg * exp(-pow((side - 1.2) / 0.16, 2))                    // sideburns
        a -= 8 * deg * exp(-pow((side - 1.62) / 0.28, 2))                    // clear the ears
        return a
    }

    static let hair: MeshData = grid(cols: 180, rows: 60, color: { p, _, v in
        let top = Float(1 - v)
        return linear(SIMD3<Float>(0.3, 0.2, 0.14) * (0.8 + 0.3 * top * top))
    }) { u, v in
        let th = 2 * Double.pi * (u - 0.5)
        let d = dir(th, v * hairline(th))
        let front = pow(max(cos(th), 0), 2)
        let volume = 0.1 + 0.07 * front * sin(.pi * min(v * 1.4, 1))      // a soft quiff above the forehead
        let thick = 0.012 + volume * pow(max(1 - pow(v, 5), 0), 0.5)
        return headPoint(d) * (1 + thick)
    }

    static let eyeRadius = 0.195
    /// Eyeball with planar UVs facing +z, for the iris texture.
    static let eyeball: MeshData = {
        let r = eyeRadius
        return grid(cols: 48, rows: 32, uv: { p in SIMD2<Float>(Float(0.5 + p.x / (2 * r)), Float(0.5 - p.y / (2 * r))) }) { u, v in
            dir(2 * .pi * (u - 0.5), .pi * v) * r
        }
    }()

    static let neck: MeshData = grid(cols: 48, rows: 8, inside: { V3(0, $0.y, -0.08) }) { u, v in
        let th = 2 * Double.pi * u, y = -0.35 - 1.1 * v, r = 0.32 + 0.06 * v * v
        return V3(r * sin(th), y, r * cos(th) - 0.08)
    }

    static let torso: MeshData = {
        grid(cols: 72, rows: 40) { u, v in
            var p = dir(2 * .pi * (u - 0.5), .pi * v) * V3(1.28, 0.75, 0.62)
            p.y += 0.12 * pow(abs(p.x) / 1.28, 2) * (p.y > 0 ? -1 : 0)      // sloped shoulders
            return p
        }
    }()

    // MARK: Textures

    /// Sclera + iris + pupil, planar, for `eyeball`'s UVs. Iris angular radius ≈ 36°, pupil ≈ 15°.
    static let irisImage: CGImage = {
        let n = 512, w = CGFloat(n)
        let ctx = CGContext(data: nil, width: n, height: n, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let c = CGPoint(x: w / 2, y: w / 2)
        ctx.setFillColor(CGColor(srgbRed: 0.97, green: 0.965, blue: 0.955, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: w))
        let ri = w * 0.5 * sin(36 * .pi / 180), rp = w * 0.5 * sin(15 * .pi / 180)
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let iris = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.62, green: 0.45, blue: 0.24, alpha: 1),
            CGColor(srgbRed: 0.42, green: 0.27, blue: 0.14, alpha: 1),
            CGColor(srgbRed: 0.27, green: 0.17, blue: 0.09, alpha: 1),
            CGColor(srgbRed: 0.1, green: 0.07, blue: 0.05, alpha: 1)] as CFArray, locations: [0, 0.45, 0.86, 1])!
        ctx.saveGState()
        ctx.addEllipse(in: CGRect(x: c.x - ri, y: c.y - ri, width: 2 * ri, height: 2 * ri)); ctx.clip()
        ctx.drawRadialGradient(iris, startCenter: c, startRadius: rp * 0.8, endCenter: c, endRadius: ri, options: [.drawsAfterEndLocation])
        var seed: UInt64 = 0x9E3779B97F4A7C15
        func rand() -> CGFloat { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return CGFloat(seed >> 33) / CGFloat(1 << 31) }
        for k in 0..<140 {
            let a = CGFloat(k) / 140 * 2 * .pi + rand() * 0.04
            ctx.setStrokeColor(rand() > 0.5 ? CGColor(srgbRed: 0.85, green: 0.68, blue: 0.4, alpha: 0.16)
                                             : CGColor(srgbRed: 0.12, green: 0.07, blue: 0.03, alpha: 0.18))
            ctx.setLineWidth(1 + rand() * 1.5)
            ctx.move(to: CGPoint(x: c.x + cos(a) * rp * 1.1, y: c.y + sin(a) * rp * 1.1))
            ctx.addLine(to: CGPoint(x: c.x + cos(a) * ri * (0.75 + 0.2 * rand()), y: c.y + sin(a) * ri * (0.75 + 0.2 * rand())))
            ctx.strokePath()
        }
        ctx.restoreGState()
        let pupil = CGGradient(colorsSpace: space, colors: [CGColor(gray: 0.02, alpha: 1), CGColor(gray: 0.04, alpha: 1),
                                                            CGColor(gray: 0.04, alpha: 0)] as CFArray, locations: [0, 0.9, 1])!
        ctx.drawRadialGradient(pupil, startCenter: c, startRadius: 0, endCenter: c, endRadius: rp, options: [])
        return ctx.makeImage()!
    }()

    /// Soft studio environment for image-based lighting: bright above, neutral horizon, dim floor.
    static let environmentImage: CGImage = {
        let w = 256, h = 128
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let space = CGColorSpace(name: CGColorSpace.sRGB)!
        let g = CGGradient(colorsSpace: space, colors: [
            CGColor(srgbRed: 0.42, green: 0.42, blue: 0.43, alpha: 1),     // floor (bottom row in CG coords)
            CGColor(srgbRed: 0.72, green: 0.72, blue: 0.73, alpha: 1),     // horizon
            CGColor(srgbRed: 0.98, green: 0.97, blue: 0.95, alpha: 1)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: h), options: [])
        return ctx.makeImage()!
    }()
}

extension MeshData {
    /// Appends a triangle wound so its face normal agrees with the vertex normals (skips degenerate ones).
    mutating func addTriangle(_ a: UInt32, _ b: UInt32, _ c: UInt32) {
        let pa = positions[Int(a)], pb = positions[Int(b)], pc = positions[Int(c)]
        let face = simd_cross(pb - pa, pc - pa)
        guard simd_length_squared(face) > 1e-14 else { return }
        let n = normals[Int(a)] + normals[Int(b)] + normals[Int(c)]
        if simd_dot(face, n) >= 0 { indices += [a, b, c] } else { indices += [a, c, b] }
    }
}
