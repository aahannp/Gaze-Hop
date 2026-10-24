// OWNER: UI worker. First-run setup: what GazeHop does, the permissions it needs, then calibration.
import SwiftUI

struct WelcomeView: View {
    /// Already calibrated (opened again as the setup guide): the main button just closes.
    var calibrated: Bool
    var read: () -> PermissionState = PermissionState.current
    /// False in snapshots, so nothing polls.
    var live = true
    var onContinue: () -> Void
    var onRecalibrate: () -> Void = {}
    var onLater: () -> Void = {}

    static let size = CGSize(width: 560, height: 600)

    @State private var ready: Bool

    init(calibrated: Bool, read: @escaping () -> PermissionState = PermissionState.current, live: Bool = true,
         onContinue: @escaping () -> Void, onRecalibrate: @escaping () -> Void = {}, onLater: @escaping () -> Void = {}) {
        self.calibrated = calibrated; self.read = read; self.live = live
        self.onContinue = onContinue; self.onRecalibrate = onRecalibrate; self.onLater = onLater
        _ready = State(initialValue: read().ready)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(spacing: 10) {
                AppGlyph(size: 72)
                    .padding(.bottom, 4)
                Text("Welcome to GazeHop")
                    .font(.system(size: 26, weight: .semibold))
                Text("Look at a display, window or split pane and GazeHop moves keyboard focus there. Video stays on your Mac and is never recorded.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 430)
            }
            .padding(.top, 44)
            .padding(.horizontal, 24)

            Form {
                Section {
                    PermissionChecklist(read: read, live: live) { ready = $0.ready }
                } header: {
                    Text("Allow access")
                } footer: {
                    Text("After allowing Accessibility or Input Monitoring in System Settings, you may need to quit and reopen GazeHop.")
                        .foregroundStyle(.secondary)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .scrollContentBackground(.hidden)

            Divider()
            HStack(spacing: 10) {
                Text(hint)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 12)
                if calibrated {
                    Button("Recalibrate…", action: onRecalibrate).disabled(!ready)
                    Button("Done", action: onContinue).keyboardShortcut(.defaultAction)
                } else {
                    Button("Later", action: onLater).keyboardShortcut(.cancelAction)
                    Button("Start Calibration", action: onContinue)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!ready)
                }
            }
            .controlSize(.large)
            .padding(.horizontal, 20)
            .frame(height: 64)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .ignoresSafeArea()
    }

    private var hint: String {
        if !ready { return "Allow Camera and Accessibility to continue." }
        if calibrated { return "You're all set." }
        return "Next: look at a few dots on each display. About 30 seconds."
    }
}
