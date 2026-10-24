// OWNER: Tracking worker.
// Apple Vision implementation of the per-frame pose estimator (the default tracker).
import Foundation
import Vision
import CoreImage

/// One camera frame -> smoothed HeadPose. Called on the capture video queue.
protocol FramePoseEstimator: AnyObject {
    func estimate(_ buffer: CVPixelBuffer, t: TimeInterval) -> HeadPose?
    func reset()
}

final class VisionPoseEstimator: FramePoseEstimator {
    // Vision convention -> contract convention.
    static let visionYawSign = 1.0
    static let visionPitchSign = 1.0
    static let visionRollSign = 1.0
    static let noseGain = 0.6          // nx at yaw = 90deg (nose protrusion / inter-eye distance)
    static let pitchNeutralRatio = 0.5
    static let pitchGain = 2.0         // rad per unit of ratio change
    static let yawBlend = 0.85         // weight of the geometric estimate (Vision yaw is bucketed to 22.5 deg steps)
    static let minConfidence = 0.5
    /// Last unfiltered yaw inputs (debug output only; racy by design).
    nonisolated(unsafe) static var debugRawStorage: (Double, Double?) = (0, nil)
    private var debugRaw: (Double, Double?) { get { Self.debugRawStorage } set { Self.debugRawStorage = newValue } }

    private var smoother = PoseSmoother()
    private let sequence = VNSequenceRequestHandler()

    func reset() { smoother.reset() }

    func estimate(_ buffer: CVPixelBuffer, t: TimeInterval) -> HeadPose? {
        let request = VNDetectFaceLandmarksRequest()
        request.revision = VNDetectFaceLandmarksRequestRevision3
        do {
            try sequence.perform([request], on: buffer, orientation: .up)
            return makePose(from: request.results ?? [], t: t)
        } catch {
            return nil
        }
    }

    private func makePose(from faces: [VNFaceObservation], t: TimeInterval) -> HeadPose? {
        guard let face = faces.max(by: { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }),
              Double(face.confidence) >= Self.minConfidence else { return nil }

        let box = face.boundingBox   // normalized, origin bottom-left, raw (un-mirrored) image
        let visionYaw = (face.yaw?.doubleValue ?? 0) * Self.visionYawSign
        var pitch = (face.pitch?.doubleValue).map { $0 * Self.visionPitchSign } ?? 0
        var roll = (face.roll?.doubleValue ?? 0) * Self.visionRollSign   // bucketed (0/±30deg) -> replaced by eye-line angle below

        var yaw = visionYaw
        var geoYaw: Double?
        var eye = CGVector.zero
        if let lm = face.landmarks {
            geoYaw = geometricYaw(lm)
            if let g = geoYaw { yaw = (1 - Self.yawBlend) * visionYaw + Self.yawBlend * g }
            eye = eyeOffset(lm)
            if let r = eyeLineRoll(lm) { roll = r }
            // Vision reports no pitch on many Macs (nil) -> landmark-based estimate.
            if face.pitch == nil, let g = geometricPitch(lm) { pitch = g }
        }

        debugRaw = (visionYaw, geoYaw)
        let cx = 1 - Double(box.midX)      // flip to user's view
        let cy = 1 - Double(box.midY)      // Vision y is up; contract y is down
        let vals = [yaw, pitch, roll, cx, cy, Double(box.width), Double(eye.dx), Double(eye.dy)]
        let out = smoother.smooth(vals, at: t)

        return HeadPose(timestamp: t, yaw: out[0], pitch: out[1], roll: out[2],
                        faceCenter: CGPoint(x: out[3], y: out[4]), faceSize: out[5],
                        eyeOffset: CGVector(dx: out[6], dy: out[7]), confidence: Double(face.confidence))
    }

    /// Nose-tip offset from the midpoint between the eyes, in units of inter-eye distance,
    /// converted to a yaw angle in the user's frame: yaw = asin(nx / noseGain).
    /// (The face-contour midpoint was tried first and saturated: the contour is the visible
    /// silhouette and shifts with the nose when turning.)
    private func geometricYaw(_ lm: VNFaceLandmarks2D) -> Double? {
        guard let le = lm.leftEye?.normalizedPoints, let re = lm.rightEye?.normalizedPoints,
              !le.isEmpty, !re.isEmpty,
              let nose = lm.nose?.normalizedPoints, !nose.isEmpty else { return nil }
        let lx = le.map { Double($0.x) }.reduce(0, +) / Double(le.count)
        let rx = re.map { Double($0.x) }.reduce(0, +) / Double(re.count)
        let iod = abs(lx - rx)
        guard iod > 0.05 else { return nil }
        let noseX = nose.map { Double($0.x) }.reduce(0, +) / Double(nose.count)  // mean of the nose region: far steadier than any single point
        let nxImage = (noseX - (lx + rx) / 2) / iod
        let nxUser = -nxImage      // image-left is the user's right
        return asin(max(-1, min(1, nxUser / Self.noseGain)))
    }

    /// Roll from the line between the eye centers (image is not mirrored, so a user-clockwise
    /// tilt shows as the user's-right eye (image left) dropping... handled by the sign below).
    private func eyeLineRoll(_ lm: VNFaceLandmarks2D) -> Double? {
        guard let le = lm.leftEye?.normalizedPoints, let re = lm.rightEye?.normalizedPoints,
              !le.isEmpty, !re.isEmpty else { return nil }
        func c(_ p: [CGPoint]) -> (Double, Double) {
            (p.map { Double($0.x) }.reduce(0, +) / Double(p.count), p.map { Double($0.y) }.reduce(0, +) / Double(p.count))
        }
        let a = c(le), b = c(re)
        // image-left eye is the user's right eye; clockwise from user's view = user's right eye lower.
        let (l, r) = a.0 < b.0 ? (a, b) : (b, a)      // l = image-left (user's right eye)
        let dx = r.0 - l.0, dy = r.1 - l.1            // Vision y up
        return atan2(dy, dx)                          // l lower than r (dy > 0) => positive => clockwise for user
    }

    /// Pitch proxy from nose-tip height between eye line and chin: r = (eyes - nose) / (eyes - chin).
    /// Tilting the head up pulls the nose tip toward eye level (r falls), so pitch = (r0 - r) * gain.
    /// Offset/scale are approximate (r0 = typical neutral ratio); the gaze mapper's regression absorbs both.
    private func geometricPitch(_ lm: VNFaceLandmarks2D) -> Double? {
        guard let contour = lm.faceContour?.normalizedPoints, !contour.isEmpty,
              let nose = lm.nose?.normalizedPoints, !nose.isEmpty,
              let le = lm.leftEye?.normalizedPoints, let re = lm.rightEye?.normalizedPoints,
              !le.isEmpty, !re.isEmpty else { return nil }
        let eyeY = (le + re).map { Double($0.y) }.reduce(0, +) / Double(le.count + re.count)
        let chinY = Double(contour.map(\.y).min()!)
        let noseY = Double(nose.map(\.y).min()!)
        let span = eyeY - chinY
        guard span > 0.05 else { return nil }
        let r = (eyeY - noseY) / span
        return (Self.pitchNeutralRatio - r) * Self.pitchGain
    }

    /// Mean pupil position inside each eye's landmark bbox, -1...1, user's view (dx + = right, dy + = up).
    private func eyeOffset(_ lm: VNFaceLandmarks2D) -> CGVector {
        var dxs = [Double](), dys = [Double]()
        for (eye, pupil) in [(lm.leftEye, lm.leftPupil), (lm.rightEye, lm.rightPupil)] {
            guard let e = eye?.normalizedPoints, e.count > 2, let p = pupil?.normalizedPoints, !p.isEmpty else { continue }
            let minX = e.map { Double($0.x) }.min()!, maxX = e.map { Double($0.x) }.max()!
            let minY = e.map { Double($0.y) }.min()!, maxY = e.map { Double($0.y) }.max()!
            let halfW = (maxX - minX) / 2
            let halfH = max((maxY - minY) / 2, halfW * 0.25)   // floor: eye boxes are thin and noisy
            guard halfW > 1e-4 else { continue }
            let px = p.map { Double($0.x) }.reduce(0, +) / Double(p.count)
            let py = p.map { Double($0.y) }.reduce(0, +) / Double(p.count)
            dxs.append(-max(-1, min(1, (px - (minX + maxX) / 2) / halfW)))   // flip: image-right = user's left
            dys.append(max(-1, min(1, (py - (minY + maxY) / 2) / halfH)))
        }
        guard !dxs.isEmpty else { return .zero }
        return CGVector(dx: dxs.reduce(0, +) / Double(dxs.count), dy: dys.reduce(0, +) / Double(dys.count))
    }
}
