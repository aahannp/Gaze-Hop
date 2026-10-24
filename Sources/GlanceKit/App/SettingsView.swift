// OWNER: UI worker. GazeHop's main window: a sidebar of panes in the style of System Settings.
//
// Rendering budget: nothing here observes the 15 Hz pose stream. The root only observes the
// router (which pane is showing). Each pane observes just what it shows, and `AppStatus` publishes
// only when a visible field changes. Only `LiveFacePanel` observes `LiveFaceModel`.
import AppKit
import SwiftUI
import ServiceManagement

/// What the main window can ask the app to do.
struct MainWindowActions {
    var setPaused: (Bool) -> Void = { _ in }
    var recalibrate: () -> Void = {}
    var resetCalibration: () -> Void = {}
    var changeTracker: (String) -> Void = { _ in }
    var showSetupGuide: () -> Void = {}
    var checkForUpdates: () -> Void = {}
    var installUpdate: () -> Void = {}
}

struct SettingsView: View {
    @ObservedObject var router: SettingsRouter
    var store: SettingsStore
    var status: AppStatus
    var updater: Updater
    var meshAvailable: Bool
    var cameras: [CameraInfo]
    var actions: MainWindowActions
    /// The live face view. Snapshots pass a stand-in, since SceneKit can't draw off-screen.
    var live: () -> AnyView
    /// Snapshots only: show this update state instead of the updater's.
    var previewUpdate: UpdateState? = nil

    static let sidebarWidth: CGFloat = 214
    static let headerHeight: CGFloat = 52

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(router: router, status: status, updater: updater, previewUpdate: previewUpdate)
                .frame(width: Self.sidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .modifier(PaneHeaderBar(title: router.pane.title))
        }
        .ignoresSafeArea()
        .frame(minWidth: 740, idealWidth: 800, minHeight: 540, idealHeight: 640)
    }

    @ViewBuilder private var detail: some View {
        switch router.pane {
        case .overview:
            OverviewPane(store: store, status: status, actions: actions, open: { router.pane = $0 }, live: live)
        case .tracking:
            TrackingPane(store: store, status: status, meshAvailable: meshAvailable, cameras: cameras, actions: actions)
        case .calibration:
            CalibrationPane(store: store, status: status, actions: actions)
        case .switching:
            SwitchingPane(store: store)
        case .advanced:
            AdvancedPane(store: store, actions: actions)
        case .about:
            AboutPane(updater: updater, actions: actions, previewUpdate: previewUpdate)
        }
    }
}

// MARK: Chrome

/// Pins the pane title to the top of the detail column. The pane's Form scrolls underneath it,
/// with the system scroll-edge effect on macOS 26 and a bar material before that.
struct PaneHeaderBar: ViewModifier {
    var title: String
    /// Snapshot tests render without a window, where a Form ignores safe-area insets,
    /// so there the title simply stacks above the pane.
    static var inWindow = true

    func body(content: Content) -> some View {
        if !Self.inWindow {
            VStack(spacing: 0) { PaneHeader(title: title); content }
        } else if #available(macOS 26.0, *) {
            content.safeAreaBar(edge: .top, spacing: 0) { PaneHeader(title: title) }
        } else {
            content.safeAreaInset(edge: .top, spacing: 0) { PaneHeader(title: title).background(.bar) }
        }
    }
}

/// The pane title, level with the traffic lights, like System Settings.
private struct PaneHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(.system(size: 15, weight: .semibold))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .frame(height: SettingsView.headerHeight)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct Sidebar: View {
    @ObservedObject var router: SettingsRouter
    var status: AppStatus
    var updater: Updater
    var previewUpdate: UpdateState?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Color.clear.frame(height: SettingsView.headerHeight)
            ForEach(SettingsPane.allCases) { pane in
                SidebarRow(pane: pane, selected: router.pane == pane) {
                    router.pane = pane
                } accessory: {
                    if pane == .about {
                        UpdateBadge(updater: updater, preview: previewUpdate)
                    }
                }
                if pane == .overview { Spacer().frame(height: 8) }
            }
            Spacer(minLength: 12)
            SidebarStatus(status: status)
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background {
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                SidebarMaterial()
            }
            .ignoresSafeArea()
        }
        .focusable()
        .focused($focused)
        .focusEffectDisabled()
        .onMoveCommand { direction in
            let all = SettingsPane.allCases
            guard let i = all.firstIndex(of: router.pane) else { return }
            switch direction {
            case .up where i > 0: router.pane = all[i - 1]
            case .down where i < all.count - 1: router.pane = all[i + 1]
            default: break
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sections")
    }
}

private struct SidebarRow<Accessory: View>: View {
    var pane: SettingsPane
    var selected: Bool
    var action: () -> Void
    @ViewBuilder var accessory: () -> Accessory
    @Environment(\.controlActiveState) private var activeState

    private var emphasized: Bool { selected && activeState != .inactive }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                TileIcon(symbol: pane.symbol, tint: pane.tint, size: 22)
                Text(pane.title)
                    .foregroundStyle(emphasized ? Color.white : Color.primary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                accessory()
            }
            .padding(.horizontal, 6)
            .frame(height: 30)
            .contentShape(Rectangle())
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color(nsColor: emphasized ? .selectedContentBackgroundColor
                                                        : .unemphasizedSelectedContentBackgroundColor))
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

/// A dot on "About & Updates" when there's an update. Only this view watches the updater, so
/// download progress never re-renders the rest of the window.
private struct UpdateBadge: View {
    @ObservedObject var updater: Updater
    var preview: UpdateState?

    var body: some View {
        let state = preview ?? updater.state
        switch state {
        case .available, .downloading, .installing:
            Text("New")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().fill(Color.accentColor))
                .accessibilityLabel("Update available")
        default:
            EmptyView()
        }
    }
}

private struct SidebarStatus: View {
    @ObservedObject var status: AppStatus

    var body: some View {
        let summary = StatusSummary(status.value)
        HStack(spacing: 8) {
            Circle().fill(summary.color).frame(width: 8, height: 8)
            Text(StatusSummary.menuLine(status.value))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 8)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Overview

private struct OverviewPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: AppStatus
    var actions: MainWindowActions
    var open: (SettingsPane) -> Void
    var live: () -> AnyView

    var body: some View {
        let s = status.value
        let summary = StatusSummary(s)
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        Circle().fill(summary.color.opacity(0.16))
                        Image(systemName: summary.symbol)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(summary.color)
                    }
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(summary.title).font(.title2.weight(.semibold))
                        Text(summary.detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 12)
                    if s.calibrating {
                        ProgressView().controlSize(.small)
                    } else if s.calibrated {
                        // Uncalibrated, there is nothing to resume: the calibration row below says what to do.
                        Toggle("Tracking", isOn: Binding(get: { !s.paused }, set: { actions.setPaused(!$0) }))
                            .toggleStyle(.switch)
                            .labelsHidden()
                            .controlSize(.large)
                            .help("Pause or resume tracking (⇧⌘G)")
                            .accessibilityLabel("Tracking")
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                LabeledContent("Current display") {
                    Text(s.currentDisplay.map(DisplayNames.name(for:)) ?? "—")
                }
                LabeledContent("Gaze") {
                    Button(gazeText) { open(.tracking) }.buttonStyle(.link)
                }
                LabeledContent("Eye tracker", value: s.trackerName)
            }

            if !s.cameraAllowed || !s.accessibilityAllowed || !s.inputMonitoringAllowed {
                Section("Needs Attention") {
                    if !s.cameraAllowed {
                        PermissionRow(symbol: "camera.fill", tint: .blue, title: "Camera",
                                      detail: "GazeHop can't see you without it.", granted: false, required: true) {
                            Permissions.requestCamera {}
                        }
                    }
                    if !s.accessibilityAllowed {
                        PermissionRow(symbol: "accessibility", tint: .blue, title: "Accessibility",
                                      detail: "Needed to move keyboard focus.", granted: false, required: true,
                                      action: Permissions.requestAccessibility)
                    }
                    if !s.inputMonitoringAllowed {
                        PermissionRow(symbol: "keyboard.fill", tint: .gray, title: "Input Monitoring",
                                      detail: "Without it, GazeHop can't hold while you type.", granted: false,
                                      required: false, action: Permissions.requestInputMonitoring)
                    }
                }
            }

            Section {
                CalibrationStatusRow(status: s, gazeMode: store.settings.gazeMode, onCalibrate: actions.recalibrate)
            }

            Section("Live View") {
                live()
                    .frame(height: 470)
                    .listRowInsets(EdgeInsets())
            }
        }
        .formStyle(.grouped)
    }

    private var gazeText: String {
        switch store.settings.gazeMode {
        case .head: return "Head only"
        case .eyes: return "Eyes only"
        case .both: return "Head & eyes · \(Formats.percent(store.settings.eyeWeight)) eyes"
        }
    }
}

// MARK: Tracking

private struct TrackingPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: AppStatus
    var meshAvailable: Bool
    var cameras: [CameraInfo]
    var actions: MainWindowActions
    /// The picker shows the choice at once; the tracker restarts a beat later so the click never stalls.
    @State private var pendingTracker: String?

    var body: some View {
        let s = $store.settings
        let tracker = pendingTracker ?? status.value.trackerKind
        Form {
            Section {
                Picker("Follow", selection: s.gazeMode) {
                    Text("Head").tag(GazeMode.head)
                    Text("Eyes").tag(GazeMode.eyes)
                    Text("Both").tag(GazeMode.both)
                }
                .pickerStyle(.segmented)
                if store.settings.gazeMode == .both {
                    SliderRow("Balance", value: s.eyeWeight, in: 0...1, step: 0.05,
                              minLabel: "Head", maxLabel: "Eyes") { "\(Formats.percent($0)) eyes" }
                }
            } header: {
                Text("Gaze")
            } footer: {
                Text(modeCaption).foregroundStyle(.secondary)
            }

            Section {
                Picker("Eye tracker", selection: Binding(get: { tracker }, set: chooseTracker)) {
                    Text("Apple Vision").tag("vision")
                    Text("MediaPipe").tag("mesh")
                }
                .disabled(!meshAvailable)
                Picker("Camera", selection: s.cameraID) {
                    Text("Automatic (external first)").tag(String?.none)
                    ForEach(cameras, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }
            } header: {
                Text("Camera")
            } footer: {
                Text(trackerFooter(tracker)).foregroundStyle(.secondary)
            }

            if tracker == "mesh", !status.value.calibrated, !status.value.calibrating {
                Section {
                    CalibrationStatusRow(status: status.value, gazeMode: store.settings.gazeMode,
                                         onCalibrate: actions.recalibrate)
                }
            }
        }
        .formStyle(.grouped)
    }

    private var modeCaption: String {
        switch store.settings.gazeMode {
        case .head: return "Turn your head to switch displays. Your eyes are ignored."
        case .eyes: return "Glance to switch. Your head only corrects for posture, it never decides."
        case .both: return "Blends head and eyes. Move toward Eyes for quick glances, toward Head for deliberate turns."
        }
    }

    private func trackerFooter(_ tracker: String) -> String {
        if !meshAvailable { return "MediaPipe isn't included in this build, so GazeHop uses Apple Vision." }
        return tracker == "mesh"
            ? "MediaPipe follows your eyes more precisely. It keeps its own calibration."
            : "Apple Vision is built into macOS. Switch to MediaPipe for better eye tracking."
    }

    private func chooseTracker(_ kind: String) {
        guard kind != (pendingTracker ?? status.value.trackerKind) else { return }
        pendingTracker = kind
        // Stopping the camera blocks for a moment; let the picker redraw first.
        DispatchQueue.main.async {
            actions.changeTracker(kind)
            pendingTracker = nil
        }
    }
}

// MARK: Calibration

private struct CalibrationPane: View {
    @ObservedObject var store: SettingsStore
    @ObservedObject var status: AppStatus
    var actions: MainWindowActions
    @State private var confirmReset = false

    var body: some View {
        Form {
            Section {
                CalibrationStatusRow(status: status.value, gazeMode: store.settings.gazeMode,
                                     onCalibrate: actions.recalibrate)
            } footer: {
                Text("Recalibrate after moving a display or your camera. Takes about 30 seconds.")
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle(isOn: $store.settings.learnFromClicks) {
                    Text("Learn from my clicks")
                    Text("Each click quietly fine-tunes where GazeHop thinks you're looking.")
                }
            }

            Section {
                LabeledContent {
                    Button("Reset…", role: .destructive) { confirmReset = true }
                        .disabled(status.value.calibrating)
                } label: {
                    Text("Reset calibration")
                    Text("Deletes what GazeHop has learned and calibrates from scratch.")
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Reset calibration?", isPresented: $confirmReset) {
            Button("Reset and Recalibrate", role: .destructive, action: actions.resetCalibration)
        } message: {
            Text("This deletes the learned gaze model and starts calibration again.")
        }
    }
}

// MARK: Switching

private struct SwitchingPane: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        let s = $store.settings
        Form {
            Section {
                SliderRow("Switch delay", subtitle: "How long you look before focus moves.",
                          value: s.switchDelayMs, in: 100...1000, step: 50, format: Formats.ms)
                SliderRow("Head-turn sensitivity", subtitle: "Lower switches on a smaller turn.",
                          value: s.headTurnThreshold, in: 0.1...0.9, step: 0.05,
                          minLabel: "High", maxLabel: "Low") { String(format: "%.2f", $0) }
            } header: { Text("Displays") }

            Section {
                Toggle(isOn: s.windowFocusEnabled) {
                    Text("Focus windows and split panes")
                    Text("Within a display, focus the window or pane you look at.")
                }
                Toggle(isOn: s.movePointer) {
                    Text("Move the pointer with focus")
                    Text("The pointer jumps to the display you switch to.")
                }
            } header: { Text("Focus") }

            Section {
                Toggle(isOn: s.typingProtection) {
                    Text("Hold while typing")
                    Text("Don't switch away mid-sentence.")
                }
                Toggle(isOn: Binding(get: { store.settings.mousePriorityMs > 0 },
                                     set: { store.settings.mousePriorityMs = $0 ? 600 : 0 })) {
                    Text("Hold while using the mouse")
                    Text("The mouse wins for a moment after you move it.")
                }
            } header: { Text("Interruptions") } footer: {
                Text("Fine-tune these timings in Advanced.").foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: Advanced

private struct AdvancedPane: View {
    @ObservedObject var store: SettingsStore
    var actions: MainWindowActions
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?

    var body: some View {
        let s = $store.settings
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError {
                    Text(loginError).font(.callout).foregroundStyle(.red)
                }
            } header: { Text("General") }

            Section {
                PermissionChecklist()
                LabeledContent("Setup guide") {
                    Button("Show…", action: actions.showSetupGuide)
                }
            } header: { Text("Permissions") }

            Section {
                SliderRow("Pane delay", subtitle: "Dwell before focusing a window or pane.",
                          value: s.paneDelayMs, in: 100...1500, step: 50, format: Formats.ms)
                    .disabled(!store.settings.windowFocusEnabled)
                Toggle(isOn: s.paneClickFallback) {
                    Text("Click to focus stubborn panes")
                    Text("For split-pane apps that ignore Accessibility focus.")
                }
                .disabled(!store.settings.windowFocusEnabled)
                SliderRow("Typing hold", subtitle: "Pause after your last keystroke.",
                          value: s.typingPauseSec, in: 0.5...10, step: 0.5, format: Formats.seconds)
                    .disabled(!store.settings.typingProtection)
                SliderRow("Mouse hold", subtitle: "Pause after you move the mouse.",
                          value: Binding(get: { max(store.settings.mousePriorityMs, 250) },
                                         set: { store.settings.mousePriorityMs = $0 }),
                          in: 250...5000, step: 250, format: Formats.ms)
                    .disabled(store.settings.mousePriorityMs == 0)
            } header: { Text("Timing") }

            Section {
                Toggle(isOn: s.showGazeDot) {
                    Text("Show gaze dot")
                    Text("Draws where GazeHop thinks you're looking. For troubleshooting.")
                }
            } header: { Text("Debug") }
        }
        .formStyle(.grouped)
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change the login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: About & Updates

private struct AboutPane: View {
    var updater: Updater
    var actions: MainWindowActions
    var previewUpdate: UpdateState?
    @State private var autoCheck: Bool

    init(updater: Updater, actions: MainWindowActions, previewUpdate: UpdateState?) {
        self.updater = updater; self.actions = actions; self.previewUpdate = previewUpdate
        _autoCheck = State(initialValue: updater.automaticallyChecks)
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    AppGlyph(size: 56)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("GazeHop").font(.title2.weight(.semibold))
                        Text("Version \(UpdateStatusView.display(updater.currentVersion))")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Text("Keyboard focus follows your gaze.").font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }

            Section {
                if let previewUpdate {
                    UpdateStatusView(state: previewUpdate, lastChecked: Date().addingTimeInterval(-3 * 3600),
                                     currentVersion: updater.currentVersion,
                                     onCheck: actions.checkForUpdates, onInstall: actions.installUpdate)
                } else {
                    LiveUpdateStatus(updater: updater, actions: actions)
                }
                Toggle("Automatically check for updates", isOn: Binding(get: { autoCheck }, set: {
                    autoCheck = $0
                    updater.automaticallyChecks = $0
                }))
            } header: { Text("Updates") }

            Section {
                if let url = URL(string: "https://github.com/\(Updater.repo)") {
                    Link(destination: url) {
                        LabeledContent("Source code") {
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
                if let url = URL(string: "https://github.com/\(Updater.repo)/releases") {
                    Link(destination: url) {
                        LabeledContent("Release notes") {
                            Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            } footer: {
                Text("Video from your camera is processed on this Mac and never stored or sent anywhere.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The only view that watches download progress.
private struct LiveUpdateStatus: View {
    @ObservedObject var updater: Updater
    var actions: MainWindowActions

    var body: some View {
        UpdateStatusView(state: updater.state, lastChecked: updater.lastChecked,
                         currentVersion: updater.currentVersion,
                         onCheck: actions.checkForUpdates, onInstall: actions.installUpdate)
    }
}
