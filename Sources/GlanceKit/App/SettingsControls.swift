// OWNER: UI worker. Small building blocks shared by the main window and the Welcome window.
import AppKit
import SwiftUI

// MARK: Slider that saves when you let go

/// A slider row that keeps its value locally while you drag and writes the binding once:
/// on release, or 0.3 s after the last change for keyboard/scroll adjustments. Writing the
/// settings store on every tick re-encoded the JSON, hit UserDefaults and re-rendered the
/// whole page 30+ times a second, which is what made the old sliders stutter.
struct SliderRow: View {
    var title: String
    var subtitle: String?
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double
    var minLabel: String?
    var maxLabel: String?
    var format: (Double) -> String

    @State private var draft: Double?
    @State private var pending: DispatchWorkItem?

    init(_ title: String, subtitle: String? = nil, value: Binding<Double>, in range: ClosedRange<Double>,
         step: Double, minLabel: String? = nil, maxLabel: String? = nil, format: @escaping (Double) -> String) {
        self.title = title; self.subtitle = subtitle; self._value = value
        self.range = range; self.step = step
        self.minLabel = minLabel; self.maxLabel = maxLabel; self.format = format
    }

    var body: some View {
        let shown = draft ?? value
        LabeledContent {
            HStack(spacing: 8) {
                if let minLabel { Text(minLabel).font(.callout).foregroundStyle(.secondary) }
                Slider(value: Binding(get: { shown }, set: { change(to: $0) }), in: range) { editing in
                    if !editing { commit() }
                }
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 200)
                if let maxLabel { Text(maxLabel).font(.callout).foregroundStyle(.secondary) }
                Text(format(shown))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 58, alignment: .trailing)
            }
        } label: {
            Text(title)
            if let subtitle { Text(subtitle) }
        }
    }

    private func change(to raw: Double) {
        let snapped = min(max((raw / step).rounded() * step, range.lowerBound), range.upperBound)
        guard snapped != (draft ?? value) else { return }
        draft = snapped
        pending?.cancel()
        let work = DispatchWorkItem { commit() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }

    private func commit() {
        pending?.cancel()
        pending = nil
        if let d = draft, d != value { value = d }
        draft = nil
    }
}

enum Formats {
    static func ms(_ v: Double) -> String { v >= 1000 ? String(format: "%.2g s", v / 1000) : "\(Int(v.rounded())) ms" }
    static func seconds(_ v: Double) -> String { String(format: v < 10 ? "%.1f s" : "%.0f s", v) }
    static func percent(_ v: Double) -> String { "\(Int((v * 100).rounded()))%" }
}

// MARK: Icons

/// The coloured rounded-square icon System Settings uses for its panes.
struct TileIcon: View {
    var symbol: String
    var tint: Color
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
            .fill(tint.gradient)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: size * 0.55, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// GazeHop's app icon (BrandMark). `size` is the tile; the icon's grid margin and shadow overhang it.
struct AppGlyph: View {
    var size: CGFloat = 64

    var body: some View {
        let canvas = size * 1024 / 824
        Image(nsImage: BrandMark.appIcon(size: canvas))
            .frame(width: canvas, height: canvas)
            .padding(-(canvas - size) / 2)
            .accessibilityHidden(true)
    }
}

// MARK: Calibration status

/// "Calibrated for MediaPipe · 2 displays", or a warning with a Calibrate button.
struct CalibrationStatusRow: View {
    var status: AppStatusValue
    var gazeMode: GazeMode
    var onCalibrate: () -> Void

    private var displays: String { status.displayCount == 1 ? "1 display" : "\(status.displayCount) displays" }

    var body: some View {
        HStack(spacing: 12) {
            if status.calibrating {
                ProgressView().controlSize(.small).frame(width: 22)
            } else {
                Image(systemName: symbol)
                    .font(.title2)
                    .foregroundStyle(tint)
                    .frame(width: 22)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if needsAction {
                Button("Calibrate…", action: onCalibrate).buttonStyle(.borderedProminent)
            } else {
                Button("Recalibrate…", action: onCalibrate)
            }
        }
        .disabled(status.calibrating)
        .padding(.vertical, 2)
    }

    private var eyeWarning: Bool { status.calibrated && status.needsEyeCalibration && gazeMode != .head }
    private var needsAction: Bool { !status.calibrated || eyeWarning }

    private var symbol: String {
        needsAction ? "exclamationmark.triangle.fill" : "checkmark.seal.fill"
    }
    private var tint: Color { needsAction ? .orange : .green }

    private var title: String {
        if status.calibrating { return "Calibrating…" }
        if !status.calibrated { return "Not calibrated for \(status.trackerName)" }
        if eyeWarning { return "Eye tracking needs calibrating" }
        return "Calibrated for \(status.trackerName) · \(displays)"
    }

    private var detail: String {
        if status.calibrating { return "Follow the dots on screen." }
        if !status.calibrated { return "Tracking stays off until you calibrate for this display setup." }
        if eyeWarning { return "Head tracking is ready. Recalibrate so GazeHop can follow your eyes too." }
        return "Saved for this display arrangement."
    }
}

// MARK: Permissions

struct PermissionState: Equatable {
    var camera: Bool
    var accessibility: Bool
    var inputMonitoring: Bool

    static func current() -> PermissionState {
        PermissionState(camera: Permissions.cameraGranted, accessibility: Permissions.accessibilityGranted,
                        inputMonitoring: Permissions.inputMonitoringGranted)
    }

    /// Camera and Accessibility are required; Input Monitoring only powers typing protection.
    var ready: Bool { camera && accessibility }
}

/// The three permissions with live ticks. Polls once a second while it is on screen, and
/// only re-renders when something actually changed.
struct PermissionChecklist: View {
    var read: () -> PermissionState
    var live: Bool
    @State private var state: PermissionState
    var onChange: (PermissionState) -> Void

    init(read: @escaping () -> PermissionState = PermissionState.current, live: Bool = true,
         onChange: @escaping (PermissionState) -> Void = { _ in }) {
        self.read = read; self.live = live; self.onChange = onChange
        _state = State(initialValue: read())
    }

    var body: some View {
        Group {
            PermissionRow(symbol: "camera.fill", tint: .blue, title: "Camera",
                          detail: "Sees which way you're facing. Video never leaves your Mac.",
                          granted: state.camera, required: true) {
                Permissions.requestCamera { refresh() }
            }
            PermissionRow(symbol: "accessibility", tint: .blue, title: "Accessibility",
                          detail: "Moves keyboard focus to the window or pane you look at.",
                          granted: state.accessibility, required: true) {
                Permissions.requestAccessibility()
            }
            PermissionRow(symbol: "keyboard.fill", tint: .gray, title: "Input Monitoring",
                          detail: "Holds switching while you type or use the mouse.",
                          granted: state.inputMonitoring, required: false) {
                Permissions.requestInputMonitoring()
            }
        }
        .task(id: live) {
            onChange(state)
            guard live else { return }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                refresh()
            }
        }
    }

    private func refresh() {
        let s = read()
        guard s != state else { return }
        state = s
        onChange(s)
    }
}

struct PermissionRow: View {
    var symbol: String
    var tint: Color
    var title: String
    var detail: String
    var granted: Bool
    var required: Bool
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            TileIcon(symbol: symbol, tint: tint, size: 28)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).fontWeight(.medium)
                    if !required {
                        Text("Recommended")
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Capsule().strokeBorder(.tertiary))
                    }
                }
                Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            // Both states take the same space, so the window never jumps when a tick appears.
            ZStack(alignment: .trailing) {
                Label("Allowed", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .opacity(granted ? 1 : 0)
                Button("Allow…", action: action)
                    .opacity(granted ? 0 : 1)
                    .disabled(granted)
            }
            .frame(minWidth: 90, alignment: .trailing)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityValue(granted ? "Allowed" : "Not allowed")
    }
}

// MARK: Updates

/// One row describing the updater's state, with the action that fits it.
struct UpdateStatusView: View {
    var state: UpdateState
    var lastChecked: Date?
    var currentVersion: String
    var onCheck: () -> Void
    var onInstall: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                icon.frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).fontWeight(.medium)
                    Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                action
            }
            if case .downloading(let p) = state {
                ProgressView(value: min(max(p, 0), 1))
                    .progressViewStyle(.linear)
                    .padding(.leading, 36)
            }
            if case .available(_, let notes) = state, !notes.isEmpty {
                ScrollView {
                    Text(Self.attributed(notes))
                        .font(.callout)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(10)
                }
                .frame(maxHeight: 120)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
                .padding(.leading, 36)
            }
        }
        .padding(.vertical, 2)
    }

    static func display(_ version: String) -> String {
        version.hasPrefix("v") || version.hasPrefix("V") ? String(version.dropFirst()) : version
    }

    private static func attributed(_ notes: String) -> AttributedString {
        (try? AttributedString(markdown: notes, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(notes)
    }

    @ViewBuilder private var icon: some View {
        switch state {
        case .checking, .installing:
            ProgressView().controlSize(.small)
        case .upToDate:
            Image(systemName: "checkmark.circle.fill").font(.title2).foregroundStyle(.green)
        case .available, .downloading:
            Image(systemName: "arrow.down.circle.fill").font(.title2).foregroundStyle(Color.accentColor)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").font(.title2).foregroundStyle(.orange)
        case .idle:
            Image(systemName: "arrow.triangle.2.circlepath").font(.title2).foregroundStyle(.secondary)
        }
    }

    private var title: String {
        switch state {
        case .idle: return "Version \(Self.display(currentVersion))"
        case .checking: return "Checking for updates…"
        case .upToDate: return "GazeHop is up to date"
        case .available(let v, _): return "Version \(Self.display(v)) is available"
        case .downloading(let p): return "Downloading update… \(Formats.percent(min(max(p, 0), 1)))"
        case .installing: return "Installing update…"
        case .failed: return "Couldn't update"
        }
    }

    private var detail: String {
        switch state {
        case .idle, .upToDate: return lastCheckedText
        case .checking: return "Asking GitHub for the newest release."
        case .available: return "You have version \(Self.display(currentVersion)). GazeHop relaunches after installing."
        case .downloading: return "GazeHop relaunches when it's done."
        case .installing: return "GazeHop will relaunch in a moment."
        case .failed(let message): return message
        }
    }

    private var lastCheckedText: String {
        guard let d = lastChecked else { return "Not checked yet." }
        if Date().timeIntervalSince(d) < 60 { return "Last checked just now." }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return "Last checked \(f.localizedString(for: d, relativeTo: Date()))."
    }

    @ViewBuilder private var action: some View {
        switch state {
        case .available:
            Button("Install & Relaunch", action: onInstall).buttonStyle(.borderedProminent)
        case .downloading, .installing:
            Button("Install & Relaunch") {}.buttonStyle(.borderedProminent).disabled(true)
        case .failed:
            Button("Try Again", action: onCheck)
        case .checking:
            Button("Check Now") {}.disabled(true)
        case .idle, .upToDate:
            Button("Check Now", action: onCheck)
        }
    }
}

// MARK: Sidebar material

/// The translucent sidebar material. Off-screen renders can't draw it, so a plain window
/// colour sits underneath as a stand-in.
struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .sidebar
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
