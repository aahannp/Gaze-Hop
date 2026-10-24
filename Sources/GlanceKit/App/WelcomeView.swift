// OWNER: App worker. Onboarding window content.
import SwiftUI

struct WelcomeView: View {
    var onCalibrate: () -> Void
    @State private var camera = Permissions.cameraGranted
    @State private var ax = Permissions.accessibilityGranted
    @State private var input = Permissions.inputMonitoringGranted
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "eye").font(.system(size: 34, weight: .light))
                VStack(alignment: .leading) {
                    Text("Welcome to Glance Switch").font(.title2.bold())
                    Text("Keyboard focus follows your eyes.").foregroundStyle(.secondary)
                }
            }
            Text("Glance uses your webcam to see which screen — and which window or split pane — you're facing, and moves keyboard focus there. Video never leaves your Mac and is never recorded.")
                .fixedSize(horizontal: false, vertical: true)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    row("Camera", "Sees where your head is turned.", camera,
                        button: "Grant Camera") { Permissions.requestCamera { refresh() } }
                    Divider()
                    row("Accessibility", "Lets Glance raise windows and focus panes.", ax,
                        button: "Grant Accessibility") { Permissions.requestAccessibility() }
                    Divider()
                    row("Input Monitoring", "Pauses switching while you type or use the mouse.", input,
                        button: "Grant Input Monitoring") { Permissions.requestInputMonitoring() }
                }.padding(6)
            }

            Text("After granting Accessibility or Input Monitoring in System Settings you may need to quit and reopen Glance.")
                .font(.caption).foregroundStyle(.secondary)

            HStack {
                Text("Moved monitors or changed your setup? Use Recalibrate… from the menu bar (⌘R) any time.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Calibrate") { onCalibrate() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!(camera && ax && input))
            }
        }
        .padding(24)
        .frame(width: 520)
        .onReceive(timer) { _ in refresh() }
    }

    private func refresh() {
        camera = Permissions.cameraGranted
        ax = Permissions.accessibilityGranted
        input = Permissions.inputMonitoringGranted
    }

    private func row(_ title: String, _ detail: String, _ ok: Bool, button: String,
                     action: @escaping () -> Void) -> some View {
        HStack {
            Image(systemName: ok ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(ok ? Color.green : Color.secondary).font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if !ok { Button(button, action: action) }
        }
    }
}
