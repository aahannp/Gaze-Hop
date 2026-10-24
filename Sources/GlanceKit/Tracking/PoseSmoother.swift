// OWNER: Tracking worker.
// Filter chain for the 8 pose channels: optional median (spike rejection) -> One-Euro.
// Channel order: yaw, pitch, roll, cx, cy, size, eyeX, eyeY.
import Foundation

struct PoseSmoother {
    struct Config {
        var angleMedian: Int
        var angle: (minCutoff: Double, beta: Double, dCutoff: Double)
        var position: (minCutoff: Double, beta: Double, dCutoff: Double)
        var eye: (minCutoff: Double, beta: Double, dCutoff: Double)
        var otherMedian: Int
    }

    /// Before the latency fix (kept for the lag test's baseline).
    static let legacy = Config(angleMedian: 5, angle: (0.8, 0.6, 1.0), position: (1.5, 1.0, 1.0),
                               eye: (1.0, 1.0, 1.0), otherMedian: 5)
    /// Latency-tuned: median(3) keeps single-frame spike rejection for 1 frame of lag, and the
    /// high beta lets fast head turns bypass the low-pass (cutoff = minCutoff + beta * speed).
    static let standard = Config(angleMedian: 3, angle: (2.0, 20.0, 3.0), position: (3.0, 5.0, 3.0),
                                 eye: (2.0, 5.0, 3.0), otherMedian: 3)

    private var filters: [OneEuroFilter] = []
    private var medians: [MedianWindow] = []
    private let config: Config

    init(config: Config = PoseSmoother.standard) {
        self.config = config
        func f(_ p: (minCutoff: Double, beta: Double, dCutoff: Double)) -> OneEuroFilter {
            OneEuroFilter(minCutoff: p.minCutoff, beta: p.beta, dCutoff: p.dCutoff)
        }
        filters = [f(config.angle), f(config.angle), f(config.angle),
                   f(config.position), f(config.position), f(config.position), f(config.eye), f(config.eye)]
        medians = (0..<8).map { MedianWindow(size: $0 < 3 ? config.angleMedian : config.otherMedian) }
    }

    mutating func reset() { self = PoseSmoother(config: config) }

    mutating func smooth(_ v: [Double], at t: TimeInterval) -> [Double] {
        var out = v
        for i in v.indices { out[i] = filters[i].filter(medians[i].push(v[i]), at: t) }
        return out
    }
}
