// OWNER: App worker. Stub — replace with the menu bar app.
import AppKit

public enum GlanceApp {
    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
