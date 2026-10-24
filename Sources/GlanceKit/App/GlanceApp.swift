// OWNER: App worker. App shell wiring tracker -> hub -> engine -> focus.
// UI worker: main window, menus and status (the "Status item & menus" and "Windows" sections).
import AppKit
import SwiftUI
import Combine
import Carbon.HIToolbox
import UserNotifications

public enum GlanceApp {
    private static var delegate: AppController?

    public static func run() {
        let app = NSApplication.shared
        // A regular Dock app with a main window (Info.plist still says LSUIElement; this overrides it).
        app.setActivationPolicy(.regular)
        let d = AppController()
        delegate = d
        app.delegate = d
        app.run()
    }
}

/// Implemented by mappers that can tell the eye model has no samples yet (RegressionGazeMapper's
/// `needsEyeCalibration`; add `extension RegressionGazeMapper: EyeCalibrationReporting {}` once it lands).
protocol EyeCalibrationReporting: AnyObject { var needsEyeCalibration: Bool { get } }

extension RegressionGazeMapper: EyeCalibrationReporting {}

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = SettingsStore()
    private let hub = PoseHub()
    private var tracker: PoseSource = PoseTrackerFactory.make()
    private let mapper: RegressionGazeMapper = RegressionGazeMapper()
    private let focus: FocusController = AXFocusController()
    private let input: InputActivityMonitoring = InputMonitor()
    private let calibrator: Calibrating = CalibrationController()
    private let overlay = GazeOverlay()
    private lazy var liveModel = LiveFaceModel(hub: hub)
    private var liveWindow: NSWindow?
    private var engine: SwitchEngine!

    private let status = AppStatus()
    private let router = SettingsRouter()
    private var subscriptions = Set<AnyCancellable>()

    private var statusItem: NSStatusItem!
    private var statusLineItem: NSMenuItem!
    private var pauseItem: NSMenuItem!
    private var driftItem: NSMenuItem!
    private var inputWarnItem: NSMenuItem!
    private var updateItem: NSMenuItem!
    private var inputStarted = false
    private var permissionTimer: Timer?
    private var hotKey: HotKey?
    private var welcomeWindow: NSWindow?
    private var mainWindow: NSWindow?
    /// First run: open the main window once the first calibration ends.
    private var showMainAfterCalibration = false

    private var calibrating = false
    private var suspendReasons = Set<String>()
    private var reconfigWork: DispatchWorkItem?
    private var lastCameraError: String?

    private let arrangementKey = "glance.displayArrangement"
    private let welcomeShownKey = "glance.welcomeShown"

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        mapper.trackerKind = trackerKind      // before load(): profiles are keyed by tracker kind
        try? mapper.load()
        syncMapperMode()
        liveModel.onVisibilityChange = { [weak self] in self?.updateCamera() }

        engine = SwitchEngine(mapper: mapper, focus: focus, input: input, settings: { [weak self] in
            self?.store.settings ?? Settings()
        })
        engine.onStateChange = { [weak self] state in
            self?.overlay.update(state)
            self?.liveModel.update(state: state)
            self?.status.update { $0.currentDisplay = state.currentDisplay }   // publishes only on a switch
        }
        engine.onDriftSuggested = { [weak self] in self?.suggestRecalibration(reason: "Gaze accuracy seems to have dropped.") }

        hub.observe { [weak self] pose in
            guard let self, !self.calibrating, self.mapper.isCalibrated else { return }
            self.engine.handle(pose: pose)
        }
        tracker.onPose = { [hub] in hub.publish($0) }

        store.onChange = { [weak self] old, new in self?.settingsChanged(old, new) }

        buildMainMenu()
        buildStatusItem()
        status.$value.removeDuplicates().sink { [weak self] in self?.applyStatus($0) }.store(in: &subscriptions)
        Updater.shared.$state.removeDuplicates().sink { [weak self] in self?.applyUpdateState($0) }.store(in: &subscriptions)
        Updater.shared.start()
        hotKey = HotKey(keyCode: UInt32(kVK_ANSI_G), modifiers: UInt32(cmdKey | shiftKey)) { [weak self] in
            self?.togglePause()
        }
        if hotKey == nil { NSLog("GazeHop: could not register ⇧⌘G hotkey") }
        observeSystemEvents()

        focus.startTracking()
        ensureInputMonitor()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.ensureInputMonitor()
        }
        overlay.setVisible(store.settings.showGazeDot)
        refreshStatus()

        // Input Monitoring is optional (typing protection); the menu and Overview flag it when missing.
        let firstLaunch = !UserDefaults.standard.bool(forKey: welcomeShownKey)
        if firstLaunch || !Permissions.cameraGranted || !Permissions.accessibilityGranted {
            showWelcome()
        } else if !mapper.isCalibrated {
            showMainAfterCalibration = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.startCalibration() }
        } else {
            updateCamera()
            showMainWindow()
        }
    }

    /// Dock icon clicked (or the app opened again): bring the main window back.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if let w = welcomeWindow, w.isVisible { present(w) } else { showMainWindow() }
        return false
    }

    func applicationWillTerminate(_ notification: Notification) {
        tracker.stop(); input.stop()
    }

    // MARK: Status item & menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusLineItem = item("Tracking", #selector(openMainWindowAction))
        menu.addItem(statusLineItem)
        inputWarnItem = item("Allow Input Monitoring…", #selector(openWelcome), symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
        inputWarnItem.isHidden = true
        menu.addItem(inputWarnItem)
        driftItem = item("Accuracy Dropped — Recalibrate…", #selector(recalibrateAction), symbol: "exclamationmark.triangle.fill", tint: .systemOrange)
        driftItem.isHidden = true
        menu.addItem(driftItem)
        updateItem = item("Update Available…", #selector(openUpdates), symbol: "arrow.down.circle.fill", tint: .controlAccentColor)
        updateItem.isHidden = true
        menu.addItem(updateItem)
        menu.addItem(.separator())
        pauseItem = item("Pause Tracking", #selector(togglePauseAction), key: "g", symbol: "pause")
        pauseItem.keyEquivalentModifierMask = [.command, .shift]
        menu.addItem(pauseItem)
        menu.addItem(item("Recalibrate…", #selector(recalibrateAction), key: "r", symbol: "scope"))
        menu.addItem(item("Live Face…", #selector(openLiveFace), symbol: "face.smiling"))
        menu.addItem(.separator())
        menu.addItem(item("Settings…", #selector(openSettings), key: ",", symbol: "gearshape"))
        menu.addItem(item("Check for Updates…", #selector(checkForUpdatesAction), symbol: "arrow.triangle.2.circlepath"))
        menu.addItem(.separator())
        menu.addItem(item("Quit GazeHop", #selector(quit), key: "q", symbol: "power"))
        statusItem.menu = menu
    }

    /// The app menu bar shown while GazeHop is the active app.
    private func buildMainMenu() {
        let app = NSMenu(title: "GazeHop")
        app.addItem(item("About GazeHop", #selector(openAbout)))
        app.addItem(item("Check for Updates…", #selector(checkForUpdatesAction)))
        app.addItem(.separator())
        app.addItem(item("Settings…", #selector(openSettings), key: ","))
        app.addItem(.separator())
        let services = NSMenuItem(title: "Services", action: nil, keyEquivalent: "")
        services.submenu = NSMenu(title: "Services")
        NSApp.servicesMenu = services.submenu
        app.addItem(services)
        app.addItem(.separator())
        app.addItem(NSMenuItem(title: "Hide GazeHop", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        let hideOthers = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        app.addItem(hideOthers)
        app.addItem(NSMenuItem(title: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: ""))
        app.addItem(.separator())
        app.addItem(item("Quit GazeHop", #selector(quit), key: "q"))

        let file = NSMenu(title: "File")
        file.addItem(NSMenuItem(title: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(redo)
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))

        let tracking = NSMenu(title: "Tracking")
        tracking.addItem(item("Pause Tracking", #selector(togglePauseAction)))   // ⇧⌘G is the global hotkey
        tracking.addItem(item("Recalibrate…", #selector(recalibrateAction), key: "r"))
        tracking.addItem(item("Live Face…", #selector(openLiveFace)))
        tracking.delegate = self

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        window.addItem(NSMenuItem(title: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: ""))
        window.addItem(.separator())
        window.addItem(item("GazeHop", #selector(openMainWindowAction), key: "0"))
        window.addItem(.separator())
        window.addItem(NSMenuItem(title: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: ""))
        NSApp.windowsMenu = window

        let help = NSMenu(title: "Help")
        help.addItem(item("GazeHop on GitHub", #selector(openProjectPage)))
        NSApp.helpMenu = help

        let main = NSMenu()
        for m in [app, file, edit, tracking, window, help] {
            let top = NSMenuItem(title: m.title, action: nil, keyEquivalent: "")
            top.submenu = m
            main.addItem(top)
        }
        NSApp.mainMenu = main
    }

    private func item(_ title: String, _ action: Selector, key: String = "", symbol: String? = nil,
                      tint: NSColor? = nil) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: key)
        i.target = self
        if let symbol { i.image = Self.menuImage(symbol, tint: tint) }
        return i
    }

    private static func menuImage(_ name: String, tint: NSColor? = nil, size: CGFloat = 13) -> NSImage? {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
        var config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        if let tint { config = config.applying(.init(paletteColors: [tint])) }
        let out = img.withSymbolConfiguration(config)
        out?.isTemplate = tint == nil
        return out
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshStatus()
        let paused = status.value.paused
        for item in menu.items where item.action == #selector(togglePauseAction) {
            item.title = paused ? "Resume Tracking" : "Pause Tracking"
        }
    }

    /// Recomputes the slow-changing status. Publishes (and redraws anything) only if it changed.
    private func refreshStatus() {
        status.update {
            $0.paused = store.settings.paused
            $0.calibrated = mapper.isCalibrated
            $0.calibrating = calibrating
            $0.needsEyeCalibration = (mapper as? EyeCalibrationReporting)?.needsEyeCalibration ?? false
            $0.cameraAllowed = Permissions.cameraGranted
            $0.accessibilityAllowed = Permissions.accessibilityGranted
            $0.inputMonitoringAllowed = Permissions.inputMonitoringGranted
            $0.cameraError = lastCameraError
            $0.suspended = !suspendReasons.isEmpty
            $0.trackerKind = trackerKind
            $0.displayCount = max(Displays.all().count, 1)
        }
    }

    /// Menu bar icon, tooltip and menu lines for the current status.
    private func applyStatus(_ v: AppStatusValue) {
        guard statusItem != nil else { return }
        let summary = StatusSummary(v)
        let img: NSImage?
        if v.calibrating { img = BrandMark.menuBarImage(.calibrating) }
        else if summary.tone == .attention {
            img = NSImage(systemSymbolName: "eye.trianglebadge.exclamationmark", accessibilityDescription: "GazeHop")
            img?.isTemplate = true
        }
        else if v.paused { img = BrandMark.menuBarImage(.paused) }
        else { img = BrandMark.menuBarImage(.tracking) }
        statusItem.button?.image = img

        var tip = "GazeHop — \(StatusSummary.menuLine(v))"
        if let e = v.cameraError { tip += "\nCamera: \(e)" }
        if !v.inputMonitoringAllowed { tip += "\nInput Monitoring is off, so typing protection is off." }
        if !driftItem.isHidden { tip += "\nAccuracy dropped. Choose Recalibrate." }
        statusItem.button?.toolTip = tip

        let line = StatusSummary.menuLine(v)
        statusLineItem.attributedTitle = NSAttributedString(string: line, attributes: [
            .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold),
        ])
        statusLineItem.title = line
        statusLineItem.image = Self.menuImage("circle.fill", tint: summary.nsColor, size: 9)
        statusLineItem.toolTip = summary.detail
        pauseItem.title = v.paused ? "Resume Tracking" : "Pause Tracking"
        pauseItem.image = Self.menuImage(v.paused ? "play" : "pause")
        inputWarnItem.isHidden = v.inputMonitoringAllowed
    }

    private func applyUpdateState(_ state: UpdateState) {
        guard updateItem != nil else { return }
        switch state {
        case .available(let version, _):
            updateItem.title = "Update to \(UpdateStatusView.display(version))…"
            updateItem.isHidden = false
        case .downloading(let p):
            updateItem.title = "Downloading Update… \(Formats.percent(min(max(p, 0), 1)))"
            updateItem.isHidden = false
        case .installing:
            updateItem.title = "Installing Update…"
            updateItem.isHidden = false
        default:
            updateItem.isHidden = true
        }
    }

    @objc private func togglePauseAction() { togglePause() }
    @objc private func recalibrateAction() { recalibrateOrCalibrate() }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func openUpdates() { showMainWindow(pane: .about) }
    @objc private func openAbout() { showMainWindow(pane: .about) }
    @objc private func checkForUpdatesAction() {
        showMainWindow(pane: .about)
        Updater.shared.checkNow()
    }
    @objc private func openProjectPage() {
        if let url = URL(string: "https://github.com/\(Updater.repo)") { NSWorkspace.shared.open(url) }
    }

    // MARK: Tracker choice

    /// "vision" or "mesh" (MediaPipe), whichever the live tracker is.
    private var trackerKind: String { tracker is MeshPoseTracker ? "mesh" : "vision" }

    /// Settings → Eye tracker. Persists the choice, swaps the tracker live and re-keys the calibration.
    /// Never opens calibration by itself; the Settings button does that when the user asks.
    private func switchTracker(to kind: String) {
        UserDefaults.standard.set(kind, forKey: PoseTrackerFactory.defaultsKey)
        guard kind != trackerKind else { return }
        tracker.onPose = nil
        tracker.stop()
        tracker = PoseTrackerFactory.make()                  // falls back to Vision if the models are missing
        tracker.onPose = { [hub] in hub.publish($0) }        // the hub is the subscription point; observers stay
        engine.reset()
        mapper.trackerKind = trackerKind
        try? mapper.load()
        syncMapperMode()
        updateCamera()   // starts it again if tracking is wanted (calibrated) or the live view is open
    }

    func togglePause() { store.settings.paused.toggle() }

    // MARK: Settings changes

    /// The mapper's mode/weight mirror Settings; keep them in step on launch and every change.
    private func syncMapperMode() {
        store.settings.apply(to: mapper)
        liveModel.mode = store.settings.gazeMode
        liveModel.eyeWeight = store.settings.eyeWeight
        liveModel.calibrated = mapper.isCalibrated
    }

    private func settingsChanged(_ old: Settings, _ new: Settings) {
        if old.gazeMode != new.gazeMode || old.eyeWeight != new.eyeWeight { syncMapperMode() }
        if old.paused != new.paused { engine.reset() }
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
        refreshStatus()
    }

    private func updateCamera() {
        liveModel.calibrated = mapper.isCalibrated
        ensureInputMonitor()
        let wantTracking = !store.settings.paused && mapper.isCalibrated
        let want = (wantTracking || calibrating || liveModel.isVisible) && suspendReasons.isEmpty && Permissions.cameraGranted
        if want, !tracker.isRunning {
            do {
                try tracker.start(cameraID: store.settings.cameraID)
                lastCameraError = nil
            } catch {
                lastCameraError = error.localizedDescription
                NSLog("GazeHop: camera start failed: \(error)")
            }
        } else if !want, tracker.isRunning {
            tracker.stop()
            engine.reset()
        }
        refreshStatus()
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
        alert.messageText = "Your displays changed. Recalibrate now?"
        alert.informativeText = "GazeHop has no calibration for this display arrangement, so tracking is paused until you recalibrate."
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
        refreshStatus()
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
            if self.showMainAfterCalibration {
                self.showMainAfterCalibration = false
                self.showMainWindow()
            }
        }
    }

    private func suggestRecalibration(reason: String) {
        driftItem.isHidden = false
        applyStatus(status.value)
        guard Bundle.main.bundleIdentifier != nil else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let c = UNMutableNotificationContent()
            c.title = "GazeHop"
            c.body = "\(reason) Recalibrate from the menu bar for best results."
            center.add(UNNotificationRequest(identifier: "glance.recalibrate", content: c, trigger: nil))
        }
    }

    // MARK: Windows

    @objc private func openWelcome() { showWelcome() }
    @objc private func openSettings() { showMainWindow() }
    @objc private func openMainWindowAction() { showMainWindow() }
    @objc private func openLiveFace() { showLiveFace() }

    private func showLiveFace() {
        if liveWindow == nil {
            liveModel.calibrated = mapper.isCalibrated
            let w = makeWindow(title: "Live Face", content: LiveFacePanel(model: liveModel).frame(width: 380, height: 640))
            w.styleMask = [.titled, .closable, .miniaturizable]
            // Dropping the content view on close fires onDisappear, which stops the hub subscription and rendering.
            onClose(w) { [weak self] in
                self?.liveWindow?.contentViewController = nil
                self?.liveWindow = nil
            }
            liveWindow = w
        }
        present(liveWindow!)
    }

    /// The main window: Overview, settings and updates. Closing it leaves GazeHop running in the menu bar.
    private func showMainWindow(pane: SettingsPane? = nil) {
        if let pane { router.pane = pane }
        if mainWindow == nil {
            let actions = MainWindowActions(
                setPaused: { [weak self] in self?.store.settings.paused = $0 },
                recalibrate: { [weak self] in self?.recalibrateOrCalibrate() },
                resetCalibration: { [weak self] in self?.resetCalibration() },
                changeTracker: { [weak self] in self?.switchTracker(to: $0) },
                showSetupGuide: { [weak self] in self?.showWelcome() },
                checkForUpdates: { Updater.shared.checkNow() },
                installUpdate: { Updater.shared.installUpdate() })
            let view = SettingsView(router: router, store: store, status: status, updater: .shared,
                                    meshAvailable: MeshModelPaths.locate() != nil,
                                    cameras: CameraPoseTracker.availableCameras(),
                                    actions: actions,
                                    live: { [liveModel] in AnyView(LiveFacePanel(model: liveModel)) })
            refreshStatus()
            let w = WindowChrome.main(view)
            if !w.setFrameUsingName(WindowChrome.mainAutosaveName) { w.center() }
            w.setFrameAutosaveName(WindowChrome.mainAutosaveName)
            // Dropping the content stops the live view, so the camera can turn off while the window is closed.
            onClose(w) { [weak self] in
                self?.mainWindow?.contentViewController = nil
                self?.mainWindow = nil
            }
            mainWindow = w
        }
        present(mainWindow!)
    }

    private func showWelcome() {
        UserDefaults.standard.set(true, forKey: welcomeShownKey)
        if welcomeWindow == nil {
            let view = WelcomeView(
                calibrated: mapper.isCalibrated,
                onContinue: { [weak self] in
                    guard let self else { return }
                    self.welcomeWindow?.close()
                    self.ensureInputMonitor()
                    if self.mapper.isCalibrated {
                        self.updateCamera()
                        self.showMainWindow()
                    } else {
                        self.showMainAfterCalibration = true
                        self.startCalibration()
                    }
                },
                onRecalibrate: { [weak self] in
                    self?.welcomeWindow?.close()
                    self?.recalibrate()
                },
                onLater: { [weak self] in
                    self?.welcomeWindow?.close()
                    self?.showMainWindow()
                })
            let w = WindowChrome.panel(view, title: "Welcome to GazeHop", size: WelcomeView.size)
            w.center()
            // Dropping the content stops the permission polling.
            onClose(w) { [weak self] in
                self?.welcomeWindow?.contentViewController = nil
                self?.welcomeWindow = nil
            }
            welcomeWindow = w
        }
        present(welcomeWindow!)
    }

    private func recalibrateOrCalibrate() {
        mapper.isCalibrated ? recalibrate() : startCalibration()
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

    /// Runs `body` once when `w` is about to close.
    private func onClose(_ w: NSWindow, _ body: @escaping () -> Void) {
        var token: NSObjectProtocol?
        token = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: w, queue: .main) { _ in
            if let token { NotificationCenter.default.removeObserver(token) }
            body()
        }
    }

    private func present(_ w: NSWindow) {
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }
}
