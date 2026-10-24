import XCTest
@testable import GlanceKit

/// Replays the user's real calibration samples (skipped when the file is absent) and prints
/// false-switch / missed-switch rates for the old pipeline vs the display classifier.
final class CalibrationRealDataEval: XCTestCase {
    struct Raw { var f: [Double]; var x: Double; var y: Double; var w: Double }
    static let laptop = Displays.Info(id: 1, frame: CGRect(x: -1470, y: 0, width: 1470, height: 956))
    static let ext = Displays.Info(id: 2, frame: CGRect(x: 0, y: 0, width: 2560, height: 1440))
    static let displays = [laptop, ext]

    static func loadRaw() -> [Raw]? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/GlanceSwitch/calibration.json")
        guard let data = try? Data(contentsOf: url),
              let blob = try? JSONDecoder().decode(RegressionGazeMapper.Persisted.self, from: data) else { return nil }
        let sig = RegressionGazeMapper.signature(of: displays)
        guard let prof = blob.profiles[sig] else { return nil }
        return prof.samples.map { Raw(f: $0.f, x: $0.x, y: $0.y, w: $0.w) }
    }

    static func pose(_ f: [Double], pitch: Double? = nil) -> HeadPose {
        HeadPose(timestamp: 0, yaw: f[0], pitch: pitch ?? f[1], roll: f[7], faceCenter: CGPoint(x: f[2], y: f[3]),
                 faceSize: f[4], eyeOffset: CGVector(dx: f[5], dy: f[6]), confidence: 0.9)
    }
    static func label(_ r: Raw) -> DisplayID { r.x < 0 ? 1 : 2 }

    func mapper(train: [Raw], classifier: Bool) -> RegressionGazeMapper {
        let m = RegressionGazeMapper(url: FileManager.default.temporaryDirectory.appendingPathComponent("eval-\(UUID()).json"),
                                     displays: { Self.displays })
        m.useClassifier = classifier
        m.ridge = classifier ? 0.03 : 0.002
        for r in train { m.addSample(Self.pose(r.f), target: CGPoint(x: r.x, y: r.y), weight: r.w) }
        XCTAssertTrue(m.fit())
        return m
    }

    struct Tally { var n = 0, falseSwitch = 0, nilCount = 0, correct = 0, missed = 0
        var fs: String { n == 0 ? "-" : String(format: "%d/%d (%.1f%%)", falseSwitch, n, 100 * Double(falseSwitch) / Double(n)) }
        var ms: String { n == 0 ? "-" : String(format: "%d/%d (%.1f%%)", missed, n, 100 * Double(missed) / Double(n)) }
    }

    func run(classifier: Bool, folds: [[Int]], raw: [Raw]) -> String {
        var extWhileExt = Tally(), lapMissed = Tally(), keyboard = Tally(), lapWhileLap = Tally(), extMissedFromLap = Tally()
        let minPitch = raw.map { $0.f[1] }.min()!
        for held in folds {
            let m = mapper(train: raw.indices.filter { !held.contains($0) }.map { raw[$0] }, classifier: classifier)
            for i in held where raw[i].w >= 0.9 {
                let r = raw[i], lab = Self.label(r)
                let other: DisplayID = lab == 1 ? 2 : 1
                let e = m.estimate(Self.pose(r.f), currentDisplay: other, edgeBias: 0.5, displays: Self.displays)
                if lab == 2 {          // on external, current = external
                    let e2 = m.estimate(Self.pose(r.f), currentDisplay: 2, edgeBias: 0.5, displays: Self.displays)
                    extWhileExt.n += 1
                    if e2?.displayID == 1 { extWhileExt.falseSwitch += 1 }
                    if e2?.displayID == nil { extWhileExt.nilCount += 1 }
                    // keyboard: same yaw/eyes as this external sample, pitch far below every calibration sample
                    let k = m.estimate(Self.pose(r.f, pitch: minPitch - 0.3), currentDisplay: 2, edgeBias: 0.5, displays: Self.displays)
                    keyboard.n += 1
                    if k?.displayID == 1 { keyboard.falseSwitch += 1 }
                    if k?.displayID == nil { keyboard.nilCount += 1 }
                    // reverse: on external, current = laptop => should (eventually) switch to external
                    extMissedFromLap.n += 1
                    if e?.displayID != 2 { extMissedFromLap.missed += 1 }
                } else {               // on laptop, current = external => a switch is wanted
                    lapMissed.n += 1
                    if e?.displayID != 1 { lapMissed.missed += 1 }
                    let e2 = m.estimate(Self.pose(r.f), currentDisplay: 1, edgeBias: 0.5, displays: Self.displays)
                    lapWhileLap.n += 1
                    if e2?.displayID == 2 { lapWhileLap.falseSwitch += 1 }
                }
            }
        }
        return """
          FALSE switch  ext-looking, current=ext -> laptop : \(extWhileExt.fs)   (nil: \(extWhileExt.nilCount))
          FALSE switch  keyboard (pitch-0.3), current=ext -> laptop : \(keyboard.fs)   (nil: \(keyboard.nilCount)/\(keyboard.n))
          FALSE switch  laptop-looking, current=laptop -> ext : \(lapWhileLap.fs)
          MISSED switch laptop-looking, current=ext, not -> laptop : \(lapMissed.ms)
          MISSED switch ext-looking, current=laptop, not -> ext : \(extMissedFromLap.ms)
        """
    }

    func testReportRealData() throws {
        guard let raw = Self.loadRaw() else { throw XCTSkip("no real calibration profile for this arrangement") }
        let cal = raw.indices.filter { raw[$0].w >= 0.9 }
        let loo = cal.map { [$0] }
        let blocked = stride(from: 0, to: cal.count, by: 4).map { Array(cal[$0..<min($0 + 4, cal.count)]) }
        for (name, folds) in [("leave-one-out", loo), ("blocked CV (4 consecutive samples held out)", blocked)] {
            print("=== \(name), \(cal.count) calibration samples")
            print(" before (ridge 0.002 + point resolver):\n" + run(classifier: false, folds: folds, raw: raw))
            print(" after  (display classifier):\n" + run(classifier: true, folds: folds, raw: raw))
        }
    }
}
