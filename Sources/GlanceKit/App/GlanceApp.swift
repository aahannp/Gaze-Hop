// OWNER: App worker. Menu bar shell wiring tracker -> hub -> engine -> focus.
import AppKit
import SwiftUI
import Carbon.HIToolbox
import UserNotifications

public enum GlanceApp {
    private static var delegate: AppController?

    public static func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let d = AppController()
        delegate = d
        app.delegate = d
        app.run()
    }
}

final class AppController: NSObject, NSApplicationDelegate {
    private let store = SettingsStore()
    private let hub = PoseHub()
    private let tracker: PoseSource = CameraPoseTracker()
    private let mapper: GazeMapper = RegressionGazeMapper()
    private let focus: FocusController = AXFocusController()
    private let input: InputActivityMonitoring = InputMonitor()
    private let calibrator: Calibrating = CalibrationController()
    private let overlay = GazeOverlay()
    private var engine: SwitchEngine!

    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var driftItem: NSMenuItem!
    private var inputWarnItem: NSMenuItem!
    private var inputStarted = false
    private var permissionTimer: Timer?
    private var hotKey: HotKey?
    private var welcomeWindow: NSWindow?
    private var settingsWindow: NSWindow?

    private var calibrating = false
    private var suspendReasons = Set<String>()
    private var reconfigWork: DispatchWorkItem?
    private var lastCameraError: String?

    private let arrangementKey = "glance.displayArrangement"
    private let welcomeShownKey = "glance.welcomeShown"

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? mapper.load()

        engine = SwitchEngine(mapper: mapper, focus: focus, input: input, settings: { [weak self] in
            self?.store.settings ?? Settings()
        })
        engine.onStateChange = { [weak self] in self?.overlay.update($0) }
        engine.onDriftSuggested = { [weak self] in self?.suggestRecalibration(reason: "Gaze accuracy seems to have dropped.") }

        hub.observe { [weak self] pose in
            guard let self, !self.calibrating, self.mapper.isCalibrated else { return }
            self.engine.handle(pose: pose)
        }
        tracker.onPose = { [hub] in hub.publish($0) }

        store.onChange = { [weak self] old, new in self?.settingsChanged(old, new) }

        buildStatusItem()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.togglePause()
        }
        if hotKey == nil { NSLog("Glance: could not register ⇧⌘G hotkey") }
        observeSystemEvents()

        focus.startTracking()
        ensureInputMonitor()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.ensureInputMonitor()
        }
        overlay.setVisible(store.settings.showGazeDot)
        refreshStatusIcon()

        let firstLaunch = !UserDefaults.standard.bool(forKey: welcomeShownKey)
        if firstLaunch || !Permissions.cameraGranted || !Permissions.accessibilityGranted || !Permissions.inputMonitoringGranted {
            showWelcome()
        } else if !mapper.isCalibrated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startCalibration() }
        } else {
            updateCamera()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.stop(); input.stop()
    }

    // MARK: Status item & menu

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        pauseItem = NSMenuItem(title: "Pause Tracking", action: #selector(togglePauseAction), keyEquivalent: "g")
        pauseItem.keyEquivalentModifierMask = [.command, .shift]
        driftItem = NSMenuItem(title: "⚠︎ Accuracy dropped — Recalibrate", action: #selector(recalibrateAction), keyEquivalent: "")
        driftItem.isHidden = true
        inputWarnItem = NSMenuItem(title: "⚠︎ Input Monitoring missing — Fix…", action: #selector(openWelcome), keyEquivalent: "")
        inputWarnItem.target = self
        inputWarnItem.isHidden = true
        menu.addItem(inputWarnItem)
        menu.addItem(pauseItem)
        menu.addItem(driftItem)
        menu.addItem(item("Recalibrate…", #selector(recalibrateAction), key: "r"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ","))
        menu.addItem(item("Welcome Guide", #selector(openWelcome)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Glance Switch", #selector(quit), key: "q"))
        statusItem.menu = menu
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        return i
    }

    private func refreshStatusIcon() {
        let paused = store.settings.paused
        pauseItem.title = paused ? "Resume Tracking" : "Pause Tracking"
        let img = NSImage(systemSymbolName: paused ? "eye.slash" : "eye", accessibilityDescription: "Glance Switch")
        img?.isTemplate = true
        statusItem.button?.image = img
        var tip = paused ? "Glance Switch — paused" : "Glance Switch"
        if let e = lastCameraError { tip += "\nCamera: \(e)" }
        statusItem.button?.toolTip = tip
    }

    @objc private func togglePauseAction() { togglePause() }
    @objc private func recalibrateAction() { recalibrate() }
    @objc private func quit() { NSApp.terminate(nil) }

    func togglePause() { store.settings.paused.toggle() }

    // MARK: Settings changes

    private func settingsChanged(_ old: Settings, _ new: Settings) {
        if old.paused != new.paused { engine.reset(); refreshStatusIcon() }
        if old.showGazeDot != new.showGazeDot { overlay.setVisible(new.showGazeDot) }
        if old.cameraID != new.cameraID, tracker.isRunning { tracker.stop() }
        updateCamera()
    }

    // MARK: Camera gating

    /// Camera runs only when tracking is wanted (or calibrating), and the system is awake and unlocked.
    /// The listen-only event tap can't be created until Input Monitoring is granted, and
    /// the monitor never retries on its own, so (re)start it whenever permission appears.
    /// start() is idempotent.
    private func ensureInputMonitor() {
        let granted = Permissions.inputMonitoringGranted
        if granted, !inputStarted {
            input.start()
            inputStarted = true
        } else if !granted {
            inputStarted = false
        }
        inputWarnItem?.isHidden = granted
        if !granted { statusItem?.button?.toolTip = "Glance Switch — Input Monitoring not granted: typing protection is off" }
    }

    private func updateCamera() {
        ensureInputMonitor()
        let wantTracking = !store.settings.paused && mapper.isCalibrated
        let want = (wantTracking || calibrating) && suspendReasons.isEmpty && Permissions.cameraGranted
        if want, !tracker.isRunning {
            do {
                try tracker.start(cameraID: store.settings.cameraID)
                lastCameraError = nil
            } catch {
                lastCameraError = error.localizedDescription
                NSLog("Glance: camera start failed: \(error)")
            }
            refreshStatusIcon()
        } else if !want, tracker.isRunning {
            tracker.stop()
            engine.reset()
        }
    }

    // MARK: System events

    private func observeSystemEvents() {
        let ws = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Notification.Name, String)] = [
            (NSWorkspace.willSleepNotification, NSWorkspace.didWakeNotification, "sleep"),
            (NSWorkspace.screensDidSleepNotification, NSWorkspace.screensDidWakeNotification, "screens"),
        ]
        for (start, end, reason) in pairs {
            ws.addObserver(forName: start, object: nil, queue: .main) { [weak self] _ in self?.suspend(reason, true) }
            ws.addObserver(forName: end, object: nil, queue: .main) { [weak self] _ in self?.suspend(reason, false) }
        }
        let dc = DistributedNotificationCenter.default()
        let dpairs: [(String, String, String)] = [
            ("com.apple.screenIsLocked", "com.apple.screenIsUnlocked", "lock"),
            ("com.apple.screensaver.didstart", "com.apple.screensaver.didstop", "screensaver"),
        ]
        for (start, end, reason) in dpairs {
            dc.addObserver(forName: .init(start), object: nil, queue: .main) { [weak self] _ in self?.suspend(reason, true) }
            dc.addObserver(forName: .init(end), object: nil, queue: .main) { [weak self] _ in self?.suspend(reason, false) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.displaysReconfigured() }
    }

    private func suspend(_ reason: String, _ on: Bool) {
        if on { suspendReasons.insert(reason) } else { suspendReasons.remove(reason) }
        if on, calibrating { calibrator.cancel() }
        updateCamera()
        if !on, reason == "sleep" || reason == "screens" { displaysReconfigured() }
    }

    /// Displays changed or the Mac woke: reload the profile for the current arrangement.
    /// A matching saved profile resumes silently; otherwise ask to recalibrate.
    private func displaysReconfigured() {
        reconfigWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.calibrating else { return }
            self.engine.reset()
            if self.tracker.isRunning { self.tracker.stop() }
            try? self.mapper.load()
            self.updateCamera()   // stays off while uncalibrated, i.e. tracking is paused until done
            guard !self.mapper.isCalibrated, Permissions.cameraGranted, Permissions.accessibilityGranted,
                  self.welcomeWindow?.isVisible != true else { return }
            self.promptRecalibrate()
        }
        reconfigWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private var promptShowing = false
    private func promptRecalibrate() {
        guard !promptShowing, !calibrating else { return }
        promptShowing = true
        driftItem.isHidden = false
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Your displays changed — Recalibrate now?"
        alert.informativeText = "Glance Switch has no calibration for this display arrangement, so tracking is paused until you recalibrate."
        alert.addButton(withTitle: "Recalibrate")
        alert.addButton(withTitle: "Later")
        let response = alert.runModal()
        promptShowing = false
        if response == .alertFirstButtonReturn { startCalibration() }
    }

    private static func arrangementSignature() -> String {
        Displays.all().sorted { $0.id < $1.id }
            .map { "\($0.id):\(Int($0.frame.minX)),\(Int($0.frame.minY)),\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .joined(separator: ";")
    }

    // MARK: Calibration

    func recalibrate() {
        guard !calibrating else { return }
        mapper.reset()
        startCalibration(restoreOnCancel: true)
    }

    func resetCalibration() {
        mapper.reset()
        try? mapper.save()
        startCalibration()
    }

    private func startCalibration(restoreOnCancel: Bool = false) {
        guard !calibrating else { return }
        guard Permissions.cameraGranted else { showWelcome(); return }
        ensureInputMonitor()
        driftItem.isHidden = true
        calibrating = true
        updateCamera()
        NSApp.activate(ignoringOtherApps: true)
        calibrator.run(hub: hub, mapper: mapper) { [weak self] ok in
            guard let self else { return }
            self.calibrating = false
            if ok {
                UserDefaults.standard.set(Self.arrangementSignature(), forKey: self.arrangementKey)
                self.engine.clearDriftNotice()
            } else if restoreOnCancel {
                try? self.mapper.load()   // calibration saves only on success, so this restores the old model
            }
            self.engine.reset()
            self.updateCamera()
        }
    }

    private func suggestRecalibration(reason: String) {
        driftItem.isHidden = false
        statusItem.button?.toolTip = "Glance Switch — \(reason) Choose Recalibrate."
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "Glance Switch"
            c.body = "\(reason) Recalibrate from the menu bar for best results."
            center.add(UNNotificationRequest(identifier: "glance.recalibrate", content: c, trigger: nil))
        }
    }

    // MARK: Windows

    @objc private func openWelcome() { showWelcome() }
    @objc private func openSettings() { showSettings() }

    private func showWelcome() {
        UserDefaults.standard.set(true, forKey: welcomeShownKey)
        if welcomeWindow == nil {
            let view = WelcomeView { [weak self] in
                self?.welcomeWindow?.close()
                self?.ensureInputMonitor()
                if self?.mapper.isCalibrated == true, !(self?.store.settings.paused ?? false) {
                    self?.updateCamera()
                }
                self?.recalibrateOrCalibrate()
            }
            welcomeWindow = makeWindow(title: "Welcome to Glance Switch", content: view)
        }
        present(welcomeWindow!)
    }

    private func recalibrateOrCalibrate() {
        mapper.isCalibrated ? recalibrate() : startCalibration()
    }

    private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(store: store,
                                    onRecalibrate: { [weak self] in self?.recalibrate() },
                                    onResetCalibration: { [weak self] in self?.resetCalibration() })
            settingsWindow = makeWindow(title: "Glance Switch Settings", content: view)
        }
        present(settingsWindow!)
    }

    private func makeWindow<V: View>(title: String, content: V) -> NSWindow {
        let host = NSHostingController(rootView: content)
        let w = NSWindow(contentViewController: host)
        w.title = title
        w.styleMask = [.titled, .closable]
        w.isReleasedWhenClosed = false
        w.center()
        return w
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
