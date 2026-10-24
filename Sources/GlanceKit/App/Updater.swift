// Updates, the same way Relay and Task Notes do them: ask GitHub for the newest release of this app, and
// if it is newer, download its .dmg. Unlike them we also install it: verify the new app is signed by the
// same team with the same bundle id, swap it into place and relaunch.
//
// CONTRACT (Lead): the UI (Settings → Updates, the "Check for Updates…" menu item) builds against this
// surface only. The packaging worker owns the implementation and may add private members freely.

import Foundation
import Combine

public enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate
    case available(version: String, notes: String)
    case downloading(progress: Double)      // 0...1
    case installing
    case failed(String)
}

public final class Updater: ObservableObject {
    public static let shared = Updater()

    /// GitHub `owner/repo` whose latest release is checked.
    public static let repo = "aahannp/gazehop"

    @Published public private(set) var state: UpdateState = .idle
    @Published public private(set) var lastChecked: Date?

    /// CFBundleShortVersionString of the running app.
    public var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    /// Check on launch and every few hours (defaults key `glance.update.auto`, default on).
    public var automaticallyChecks: Bool {
        get { UserDefaults.standard.object(forKey: "glance.update.auto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "glance.update.auto") }
    }

    /// Start the periodic background check (call once at launch). Never shows UI by itself.
    public func start() {}

    /// Check GitHub now; result lands in `state`.
    public func checkNow() {}

    /// Download, verify (same Team ID + bundle id), replace the installed app and relaunch.
    public func installUpdate() {}

    init() {}
}
