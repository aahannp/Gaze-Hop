// OWNER: UI worker. Slow-changing app state shared by the main window and the menu bar menu.
import AppKit
import SwiftUI
import Combine

/// Everything the main window and the menu show about the app, as one value.
struct AppStatusValue: Equatable {
    var paused = false
    var calibrated = false
    var calibrating = false
    var needsEyeCalibration = false
    var cameraAllowed = true
    var accessibilityAllowed = true
    var inputMonitoringAllowed = true
    var cameraError: String?
    /// Asleep, screen locked or screensaver running.
    var suspended = false
    var trackerKind = "vision"          // "vision" | "mesh"
    var currentDisplay: DisplayID?
    var displayCount = 1

    var trackerName: String { trackerKind == "mesh" ? "MediaPipe" : "Apple Vision" }
}

/// Published only when a field actually changes, so per-frame engine updates (15 Hz) never
/// invalidate SwiftUI views unless something visible changed. Fast-changing data (pose, gaze dot)
/// stays in `LiveFaceModel` and only the Live view observes it.
final class AppStatus: ObservableObject {
    @Published private(set) var value: AppStatusValue

    init(_ value: AppStatusValue = AppStatusValue()) { self.value = value }

    func update(_ change: (inout AppStatusValue) -> Void) {
        var v = value
        change(&v)
        if v != value { value = v }
    }
}

/// Headline for the Overview card and the first line of the menu bar menu.
struct StatusSummary: Equatable {
    enum Tone: Equatable { case good, attention, neutral }
    var title: String
    var detail: String
    var symbol: String
    var tone: Tone

    init(title: String, detail: String, symbol: String, tone: Tone) {
        self.title = title; self.detail = detail; self.symbol = symbol; self.tone = tone
    }

    init(_ s: AppStatusValue, displayName: (DisplayID) -> String = DisplayNames.name(for:)) {
        if s.calibrating {
            self.init(title: "Calibrating", detail: "Follow the dots on screen.", symbol: "scope", tone: .attention)
        } else if !s.cameraAllowed {
            self.init(title: "Camera access needed", detail: "Allow camera access to start tracking.",
                      symbol: "video.slash", tone: .attention)
        } else if !s.accessibilityAllowed {
            self.init(title: "Accessibility access needed", detail: "Allow Accessibility so GazeHop can move keyboard focus.",
                      symbol: "hand.raised", tone: .attention)
        } else if let e = s.cameraError {
            self.init(title: "Camera unavailable", detail: e, symbol: "video.slash", tone: .attention)
        } else if !s.calibrated {
            self.init(title: "Not calibrated", detail: "Calibrate once so GazeHop knows where your displays are.",
                      symbol: "exclamationmark.triangle", tone: .attention)
        } else if s.paused {
            self.init(title: "Paused", detail: "Focus stays where it is. Press ⇧⌘G to resume.",
                      symbol: "pause", tone: .neutral)
        } else if s.suspended {
            self.init(title: "Idle", detail: "Waiting while the Mac is locked or asleep.", symbol: "moon", tone: .neutral)
        } else if let d = s.currentDisplay {
            self.init(title: "Tracking", detail: "Focus is on \(displayName(d)).", symbol: "eye", tone: .good)
        } else {
            self.init(title: "Tracking", detail: "Keyboard focus follows your gaze.", symbol: "eye", tone: .good)
        }
    }

    /// "Tracking · Built-in Retina Display", "Paused", …
    static func menuLine(_ s: AppStatusValue, displayName: (DisplayID) -> String = DisplayNames.name(for:)) -> String {
        let summary = StatusSummary(s, displayName: displayName)
        if summary.tone == .good, let d = s.currentDisplay { return "Tracking · \(displayName(d))" }
        return summary.title
    }

    var color: Color {
        switch tone {
        case .good: return .green
        case .attention: return .orange
        case .neutral: return .secondary
        }
    }

    var nsColor: NSColor {
        switch tone {
        case .good: return .systemGreen
        case .attention: return .systemOrange
        case .neutral: return .secondaryLabelColor
        }
    }
}

enum DisplayNames {
    /// The name System Settings uses ("Built-in Retina Display", "LG HDR 4K"), else a generic one.
    static func name(for id: DisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let screen = NSScreen.screens.first(where: { ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id }) {
            return screen.localizedName
        }
        return CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "External Display"
    }
}

/// Which page of the main window is showing. Remembered across launches.
final class SettingsRouter: ObservableObject {
    static let defaultsKey = "gazehop.window.pane"
    @Published var pane: SettingsPane {
        didSet { UserDefaults.standard.set(pane.rawValue, forKey: Self.defaultsKey) }
    }

    init(pane: SettingsPane? = nil) {
        self.pane = pane ?? UserDefaults.standard.string(forKey: Self.defaultsKey).flatMap(SettingsPane.init) ?? .overview
    }
}

enum SettingsPane: String, CaseIterable, Identifiable {
    case overview, tracking, calibration, switching, advanced, about
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .tracking: return "Tracking"
        case .calibration: return "Calibration"
        case .switching: return "Switching"
        case .advanced: return "Advanced"
        case .about: return "About & Updates"
        }
    }

    var symbol: String {
        switch self {
        case .overview: return "eye.fill"
        case .tracking: return "viewfinder"
        case .calibration: return "scope"
        case .switching: return "rectangle.on.rectangle"
        case .advanced: return "gearshape.2.fill"
        case .about: return "arrow.down.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .overview: return .blue
        case .tracking: return .purple
        case .calibration: return .orange
        case .switching: return .green
        case .advanced: return .gray
        case .about: return .indigo
        }
    }
}
