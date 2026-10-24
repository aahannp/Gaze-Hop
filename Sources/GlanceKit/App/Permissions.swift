// OWNER: App worker.
import AppKit
import AVFoundation
import ApplicationServices

enum Permissions {
    static var cameraStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .video) }
    static var cameraGranted: Bool { cameraStatus == .authorized }
    static var accessibilityGranted: Bool { AXIsProcessTrusted() }
    static var inputMonitoringGranted: Bool { CGPreflightListenEventAccess() }

    static func requestCamera(_ done: (() -> Void)? = nil) {
        if cameraStatus == .notDetermined {
            AVCaptureDevice.requestAccess(for: .video) { _ in DispatchQueue.main.async { done?() } }
        } else {
            if !cameraGranted { openPane("Privacy_Camera") }
            done?()
        }
    }

    static func requestAccessibility() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(opts) { openPane("Privacy_Accessibility") }
    }

    static func requestInputMonitoring() {
        if !CGRequestListenEventAccess() { openPane("Privacy_ListenEvent") }
    }

    static func openPane(_ anchor: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") {
            NSWorkspace.shared.open(url)
        }
    }
}
