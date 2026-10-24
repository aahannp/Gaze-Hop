// OWNER: App worker. Settings window content.
import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var store: SettingsStore
    var onRecalibrate: () -> Void
    var onResetCalibration: () -> Void
    private let cameras = CameraPoseTracker.availableCameras()
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var confirmReset = false

    var body: some View {
        let s = $store.settings
        Form {
            Section("Switching") {
                slider("Switch delay", s.switchDelayMs, 100...1000, step: 50, unit: "ms")
                slider("Head-turn threshold", s.headTurnThreshold, 0.1...0.9, step: 0.05, unit: nil,
                       hint: "Lower switches sooner when you turn; higher needs a bigger turn.")
                Toggle("Move pointer to the new display", isOn: s.movePointer)
                Toggle("Mouse priority", isOn: Binding(get: { s.wrappedValue.mousePriorityMs > 0 },
                                                       set: { s.wrappedValue.mousePriorityMs = $0 ? 600 : 0 }))
                if store.settings.mousePriorityMs > 0 {
                    slider("Mouse priority window", s.mousePriorityMs, 250...5000, step: 250, unit: "ms")
                }
            }
            Section("Windows & panes") {
                Toggle("Focus windows and split panes on the same display", isOn: s.windowFocusEnabled)
                if store.settings.windowFocusEnabled {
                    slider("Pane delay", s.paneDelayMs, 100...1500, step: 50, unit: "ms")
                    Toggle("Click fallback for stubborn split-pane apps", isOn: s.paneClickFallback)
                }
            }
            Section("Typing") {
                Toggle("Typing protection", isOn: s.typingProtection)
                if store.settings.typingProtection {
                    slider("Pause after last keystroke", s.typingPauseSec, 0.5...10, step: 0.5, unit: "s")
                }
            }
            Section("Camera & accuracy") {
                Picker("Camera", selection: s.cameraID) {
                    Text("Automatic (external first)").tag(String?.none)
                    ForEach(cameras, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }
                Toggle("Learn from my clicks", isOn: s.learnFromClicks)
                Toggle("Show gaze dot", isOn: s.showGazeDot)
                HStack {
                    Button("Recalibrate…", action: onRecalibrate).buttonStyle(.borderedProminent)
                    Button("Reset calibration…") { confirmReset = true }
                }
            }
            Section("General") {
                Toggle("Start at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).font(.caption).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480, height: 640)
        .confirmationDialog("Reset calibration?", isPresented: $confirmReset) {
            Button("Reset and recalibrate", role: .destructive, action: onResetCalibration)
        } message: { Text("This deletes the learned gaze model and starts calibration again.") }
    }

    private func slider(_ title: String, _ value: Binding<Double>, _ range: ClosedRange<Double>,
                        step: Double, unit: String?, hint: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(unit.map { String(format: value.wrappedValue < 10 ? "%.1f %@" : "%.0f %@", value.wrappedValue, $0) }
                     ?? String(format: "%.2f", value.wrappedValue))
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
        }
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            loginError = nil
        } catch {
            loginError = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}
