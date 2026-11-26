import AppKit
import Combine
import IOKit.hid

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let output = DisplayOutput()
    private let preview = BoardView()
    let updates = AppUpdates()
    private var updateObserver: AnyCancellable?
    private let effectsStore = EffectSettingsStore()
    private let settingsBoard = BoardView()
    private let recorder = ShortcutRecorder()
    private lazy var effectsWindow = EffectsWindow(store: effectsStore, updates: updates, recorder: recorder, settingsBoard: settingsBoard, beside: previewWindow,
        selectOutput: { [weak self] in self?.setOutput($0) },
        requestAccess: { [weak self] in self?.openInputMonitoringSettings() })
    private var previewWindow: NSWindow?
    private var modeControl: NSSegmentedControl?
    private var titlebarControls: NSStackView?
    private var effectsPauseButton: NSButton?
    private var permissionButton: NSButton?
    private var permissionPoller: Timer?
    private var localKeyMonitor: Any?
    private var activityToken: NSObjectProtocol?
    private var requestedListenAccess = false
    private var sampleMode = false {
        didSet {
            if oldValue != sampleMode { preview.resetBeamHistory(matching: sampleMode ? nil : output.board) }
        }
    }
    private lazy var samples: (hints: [KeyHint], icons: [String: KeyArtwork]) = {
        let apps: [(UInt16, String)] = [(3, "com.apple.finder"), (1, "com.apple.Safari"),
            (8, "com.apple.calculator"), (45, "com.apple.Notes"), (17, "com.apple.Terminal"),
            (46, "com.apple.Music")]
        var hints: [KeyHint] = []
        var icons: [String: KeyArtwork] = [:]
        for (code, id) in apps {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) else { continue }
            hints.append(KeyHint(keyCode: code, label: url.deletingPathExtension().lastPathComponent,
                                 symbol: "app", iconID: id))
            icons[id] = KeyArtwork(NSWorkspace.shared.icon(forFile: url.path))
        }
        return (hints, icons)
    }()
    private var receiver: HintReceiver?
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let defaults = UserDefaults.standard
    private var captureError: CGError?
    private var observingDisplayChanges = false
    private var boards: [BoardView] { [output.board, preview] }
    private var settingsPreviewVisible: Bool { settingsBoard.window?.isVisible == true }
    private lazy var presses = PressMonitor(onKeyEvent: { [weak self] code, event in
        self?.handleKey(code, event)
    }, onReset: { [weak self] in
        self?.boards.forEach { $0.clearHeldKeys(from: .monitor) }
        self?.settingsBoard.clearHeldKeys()
        DictationBlobController.shared.stop()
        self?.recorder.cancel()
    })
    private lazy var rightOptionHID = KeyboardKeyHIDMonitor(usage: kHIDUsage_KeyboardRightAlt) { [weak self] held in
        self?.handleShortcutKey(DictationShortcut.rightOption, held: held)
    }

    private func handleShortcutKey(_ code: UInt16, held: Bool) {
        if recorder.keys != nil {
            recorder.receive(code, down: held)
        } else {
            DictationBlobController.shared.setKey(code, held: held)
        }
    }

    private func handleKey(_ code: UInt16, _ event: PressMonitor.KeyEvent) {
        // Some dictation apps consume the Right Option release. The hardware hold
        // wins over an early flagsChanged release; virtual keyboards can still use the tap.
        if !(code == DictationShortcut.rightOption && event == .up && rightOptionHID.isHeld) {
            switch event {
            case .down: handleShortcutKey(code, held: true)
            case .up: handleShortcutKey(code, held: false)
            case .tap:
                handleShortcutKey(code, held: true)
                handleShortcutKey(code, held: false)
            }
        }
        switch event {
        case .down: relayPress(code, source: .monitor, tracksRelease: true)
        case .up:
            boards.forEach { $0.releaseKey(code) }
            settingsBoard.releaseKey(code)
        case .tap: relayPress(code, source: .monitor)
        }
    }

    private func relayPress(_ code: UInt16, source: BoardView.Input, tracksRelease: Bool = false) {
        let beam = output.board.pulse(code, source: source, tracksRelease: tracksRelease)
        if settingsPreviewVisible {
            settingsBoard.pulse(code, source: source, matching: beam, tracksRelease: tracksRelease)
        }
        if (!sampleMode || source == .monitor), beam != nil || tracksRelease {
            preview.pulse(code, source: source, matching: beam, tracksRelease: tracksRelease)
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Use the cutout directly so the running Dock tile preserves its alpha.
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            let tile = NSApp.dockTile
            let imageView = NSImageView(frame: NSRect(origin: .zero, size: tile.size))
            imageView.image = icon
            imageView.imageScaling = .scaleProportionallyUpOrDown
            tile.contentView = imageView
            tile.display()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "kbd-display")
        observeUpdateReadiness()
        updates.start()
        installApplicationMenu()
        menu.delegate = self
        statusItem.menu = menu
        if CommandLine.arguments.contains("--music") {
            effectsStore.value.musicAmbient = true
        }
        effectsStore.onChange = { [weak self] settings in self?.applyEffects(settings) }
        DictationBlobController.shared.onStateChange = { [weak self] in
            guard let self else { return }
            if DictationBlobController.shared.isActive, self.activityToken == nil {
                self.activityToken = ProcessInfo.processInfo.beginActivity(
                    options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                    reason: "Live global keyboard display effects"
                )
            }
            self.boards.forEach { $0.wakeForDictationBlob() }
            if self.settingsPreviewVisible { self.settingsBoard.wakeForDictationBlob() }
        }
        applyEffects(effectsStore.value)
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [weak self] event in
            guard let self else { return event }
            let recording = self.recorder.keys != nil
            // The event tap covers our own windows too. AppKit's global fallback does not.
            if !self.presses.usesEventTap {
                self.presses.handleLocalEvent(event)
            }
            return recording ? nil : event
        }
        NotificationCenter.default.addObserver(self, selector: #selector(clearLocalHolds),
            name: NSWindow.didResignKeyNotification, object: nil)
        loadCalibration()
        var displayedProvider: HintProvider?
        receiver = HintReceiver(onIcon: { [weak self] id, image in
            guard let self else { return }
            self.output.board.icons[id] = image
            if !self.sampleMode { self.preview.icons[id] = image }
        }, onUpdate: { [weak self] frame in
            guard let self else { return }
            let live = self.output.board
            if displayedProvider != frame?.provider { live.icons.removeAll() }
            displayedProvider = frame?.provider
            live.hints = frame?.hints ?? []
            live.title = frame?.title
            let ids = Set(live.hints.compactMap(\.iconID))
            live.icons = live.icons.filter { ids.contains($0.key) }
            if let press = frame?.press { self.relayPress(press, source: .plugin) }
            if !self.sampleMode {
                self.applyPreviewMode()
            }
        })
        NotificationCenter.default.addObserver(self, selector: #selector(refresh),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        observingDisplayChanges = CGDisplayRegisterReconfigurationCallback(
            Self.displayReconfigured, Unmanaged.passUnretained(self).toOpaque()
        ) == .success
        NotificationCenter.default.addObserver(self, selector: #selector(retryGlobalMonitor),
            name: NSApplication.didBecomeActiveNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(wake),
            name: NSWorkspace.didWakeNotification, object: nil)
        refresh()
        ensureGlobalMonitoring()
    }

    func applicationDidResignActive(_ notification: Notification) {
        recorder.cancel()
        // Without global access a key released in another app cannot reach us.
        if !presses.isRunning {
            boards.forEach { $0.clearHeldKeys() }
            settingsBoard.clearHeldKeys()
            DictationBlobController.shared.stop()
        }
    }

    @objc private func retryGlobalMonitor() {
        ensureGlobalMonitoring()
    }

    private func ensureGlobalMonitoring() {
        // Prevent App Nap from throttling 60fps animations while typing in other apps.
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Live global keyboard display effects"
            )
        }
        if !presses.start() {
            if !requestedListenAccess && !PressMonitor.hasPermission {
                requestedListenAccess = true
                PressMonitor.requestPermission()
            }
            _ = presses.start()
        }
        if dictationEnabled { _ = rightOptionHID.start() }
        updateGlobalMonitorUI()
        if !presses.isRunning, permissionPoller == nil {
            let timer = Timer(timeInterval: 4, repeats: true) { [weak self] timer in
                guard let self else { timer.invalidate(); return }
                if self.presses.start() {
                    if self.dictationEnabled { _ = self.rightOptionHID.start() }
                    self.updateGlobalMonitorUI()
                    timer.invalidate()
                    self.permissionPoller = nil
                }
            }
            timer.tolerance = 1
            permissionPoller = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func updateGlobalMonitorUI() {
        effectsStore.keyboardMonitoringActive = presses.isRunning
        permissionButton?.isHidden = presses.isRunning
        if let controls = titlebarControls {
            controls.layoutSubtreeIfNeeded()
            controls.setFrameSize(controls.fittingSize)
        }
    }

    @objc private func openInputMonitoringSettings() {
        PressMonitor.requestPermission()
        ensureGlobalMonitoring()
        if !presses.isRunning, let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    private static let displayReconfigured: CGDisplayReconfigurationCallBack = { id, flags, context in
        guard let context else { return }
        let delegate = Unmanaged<AppDelegate>.fromOpaque(context).takeUnretainedValue()
        if flags.contains(.beginConfigurationFlag) && Thread.isMainThread {
            // Close the panel now. Capture changes wait until the callback returns.
            delegate.output.beginReconfiguration(of: id)
            return
        }
        DispatchQueue.main.async { [weak delegate] in
            guard let delegate, delegate.observingDisplayChanges else { return }
            if flags.contains(.beginConfigurationFlag) {
                delegate.output.beginReconfiguration(of: id)
            } else if delegate.output.endReconfiguration(of: id, flags: flags) {
                delegate.refresh()
            }
        }
    }

    private var exclusiveCapture: Bool { defaults.bool(forKey: "exclusiveCapture") }

    @objc private func refresh() {
        let selectedID = defaults.string(forKey: "selectedDisplay")
        captureError = output.refresh(selection: selectedID, exclusive: exclusiveCapture)
        let displays = NSScreen.screens.compactMap { screen -> KeyboardConnection.Display? in
            guard screen.canCapture, let id = screen.persistentID else { return nil }
            return .init(id: id, name: screen.localizedName)
        }
        let connection = KeyboardConnection(displays: displays, selectedID: selectedID,
                                            hasOutput: output.activeDisplayID != nil, captureFailed: captureError != nil)
        if connection != effectsStore.connection { effectsStore.connection = connection }
    }

    @objc private func wake() {
        boards.forEach { $0.clearHeldKeys() }
        settingsBoard.clearHeldKeys()
        DictationBlobController.shared.stop()
        ensureGlobalMonitoring()
        refresh()
        receiver?.requestState()
    }

    @objc private func clearLocalHolds() {
        boards.forEach { $0.clearHeldKeys(from: .local) }
    }

    private func observeUpdateReadiness() {
        guard let button = statusItem.button else { return }
        let dot = UpdateIndicator()
        dot.wantsLayer = true
        dot.layer?.backgroundColor = NSColor.systemOrange.cgColor
        dot.layer?.cornerRadius = 3
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.setAccessibilityElement(false)
        button.addSubview(dot)
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: 6), dot.heightAnchor.constraint(equalToConstant: 6),
            dot.centerXAnchor.constraint(equalTo: button.centerXAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: button.centerYAnchor, constant: -6)
        ])
        updateObserver = updates.$readyVersion.sink { version in
            dot.isHidden = version == nil
            let label = version.map { "kbd-display, update to \($0) ready" } ?? "kbd-display"
            button.setAccessibilityLabel(label)
            button.toolTip = label
        }
    }

    @objc private func restartToUpdate() { updates.restartToUpdate() }

    func menuNeedsUpdate(_ menu: NSMenu) {
        @discardableResult
        func item(_ title: String, _ action: Selector?) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }

        menu.removeAllItems()
        let selection = defaults.string(forKey: "selectedDisplay")
        let stop = item("Output Off", #selector(selectOutput(_:)))
        stop.state = selection == nil ? .on : .off
        for screen in NSScreen.screens where screen.canCapture {
            guard let uuid = screen.persistentID else { continue }
            let entry = item(screen.localizedName, #selector(selectOutput(_:)))
            entry.representedObject = uuid
            entry.state = selection == uuid ? .on : .off
        }
        #if DEBUG
        item("Exclusive Display Capture", #selector(toggleExclusiveCapture)).state = exclusiveCapture ? .on : .off
        #endif
        if let captureError {
            item("Capture failed (\(captureError.rawValue))", nil)
        } else if selection != nil && output.activeDisplayID == nil {
            item("Waiting for selected display", nil)
        } else if !NSScreen.screens.contains(where: { $0.canCapture }) {
            item("No secondary display connected", nil)
        }
        menu.addItem(.separator())
        #if DEBUG
        item("Debug Window…", #selector(showDebug))
        #endif
        item("Effects…", #selector(showEffects))
        item(effectsPauseTitle, #selector(toggleEffectsPause))
        if updates.readyVersion != nil { item("Restart to Update", #selector(restartToUpdate)) }
        #if DEBUG
        item("Calibrate…", #selector(calibrate))
        let music = item("Music Ambient", #selector(toggleMusicAmbient))
        music.state = effectsStore.value.musicAmbient ? .on : .off
        menu.addItem(.separator())
        item("Quit kbd-display", #selector(quit)).keyEquivalent = "q"
        #endif
    }

    @objc private func toggleExclusiveCapture() {
        defaults.set(!exclusiveCapture, forKey: "exclusiveCapture")
        refresh()
    }

    @objc private func selectOutput(_ sender: NSMenuItem) {
        setOutput(sender.representedObject as? String)
    }

    private func setOutput(_ id: String?) {
        defaults.set(id, forKey: "selectedDisplay")
        refresh()
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let application = NSMenu()
        main.addItem(withTitle: "kbd-display", action: nil, keyEquivalent: "").submenu = application
        application.addItem(withTitle: "Effects…", action: #selector(showEffects), keyEquivalent: ",").target = self
        application.addItem(.separator())
        application.addItem(withTitle: "Hide kbd-display", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        application.addItem(withTitle: "Quit kbd-display", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let window = NSMenu(title: "Window")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = window
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.mainMenu = main
        NSApp.windowsMenu = window
    }

    @objc private func showEffects() {
        effectsWindow.show()
    }

    @objc private func showDebug() { openPreview(sample: true) }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showEffects()
        return false
    }

    private func openPreview(sample: Bool) {
        sampleMode = sample
        preview.interactive = true
        if previewWindow == nil {
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 960, height: 360),
                                  styleMask: [.titled,.closable,.resizable], backing: .buffered, defer: false)
            window.title = "kbd-display Debug"
            let control = NSSegmentedControl(labels: ["Sample Apps", "Live Plugins"], trackingMode: .selectOne,
                                             target: self, action: #selector(changeMode(_:)))
            control.controlSize = .small
            control.sizeToFit()
            let accessory = NSTitlebarAccessoryViewController()
            accessory.layoutAttribute = .right
            let effects = NSButton(title: "Effects…", target: self, action: #selector(showEffects))
            effects.bezelStyle = .rounded
            effects.controlSize = .small
            let pause = NSButton(title: effectsPauseTitle, target: self, action: #selector(toggleEffectsPause))
            pause.bezelStyle = .rounded
            pause.controlSize = .small
            pause.setAccessibilityIdentifier("keyboardEffectsPause")
            effectsPauseButton = pause
            let perm = NSButton(title: "Grant Global Keys…", target: self, action: #selector(openInputMonitoringSettings))
            perm.bezelStyle = .rounded
            perm.controlSize = .small
            perm.contentTintColor = .systemOrange
            perm.toolTip = "Enable Input Monitoring so typing in other windows animates this floating preview."
            permissionButton = perm
            let controls = NSStackView(views: [perm, control, pause, effects])
            controls.spacing = 8
            controls.setFrameSize(controls.fittingSize)
            titlebarControls = controls
            accessory.view = controls
            window.addTitlebarAccessoryViewController(accessory)
            modeControl = control
            window.contentMinSize = NSSize(width: 576, height: 216)
            window.contentAspectRatio = Action75.canvas
            window.contentView = preview
            window.level = .floating
            window.hidesOnDeactivate = false
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isReleasedWhenClosed = false
            window.center()
            previewWindow = window
        }
        ensureGlobalMonitoring()
        modeControl?.selectedSegment = sampleMode ? 0 : 1
        applyPreviewMode()
        NSApp.activate(ignoringOtherApps: true)
        previewWindow?.makeKeyAndOrderFront(nil)
        previewWindow?.makeFirstResponder(preview)
    }

    @objc private func changeMode(_ sender: NSSegmentedControl) {
        sampleMode = sender.selectedSegment == 0
        applyPreviewMode()
        previewWindow?.makeFirstResponder(preview)
    }

    private func applyPreviewMode() {
        preview.keycapPreview = sampleMode ? .labeled : .none
        preview.hints = sampleMode ? samples.hints : output.board.hints
        preview.icons = sampleMode ? samples.icons : output.board.icons
        preview.title = sampleMode ? nil : output.board.title
    }

    private func loadCalibration() {
        let values = defaults.array(forKey: "boardRect") as? [Double] ?? []
        guard values.count == 4, values.allSatisfy(\.isFinite), values[2] > 0, values[3] > 0 else { return }
        for board in boards {
            board.boardRect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
        }
    }

    #if DEBUG
    @objc private func calibrate() {
        if output.activeDisplayID == nil { openPreview(sample: false) }
        boards.forEach { $0.calibration = true }
        defer { boards.forEach { $0.calibration = false } }
        let rect = output.board.boardRect
        let box = NSStackView()
        box.orientation = .vertical
        box.alignment = .trailing
        let fields = zip(["Left", "Top", "Width", "Height"], [rect.minX, rect.minY, rect.width, rect.height]).map { name, value in
            let field = NSTextField(string: String(Int(value.rounded())))
            field.widthAnchor.constraint(equalToConstant: 72).isActive = true
            box.addArrangedSubview(NSStackView(views: [NSTextField(labelWithString: name), field]))
            return field
        }
        box.frame.size = box.fittingSize
        let alert = NSAlert()
        alert.messageText = "Key grid in panel pixels"
        alert.accessoryView = box
        alert.addButton(withTitle: "Apply")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        while alert.runModal() == .alertFirstButtonReturn {
            let values = fields.compactMap { Int($0.stringValue) }
            if values.count == 4 && values.allSatisfy({ (-8192...8192).contains($0) }) && values[2] > 0 && values[3] > 0 {
                defaults.set(values, forKey: "boardRect")
                loadCalibration()
                break
            }
            alert.informativeText = "Enter whole pixel values within ±8192 and positive dimensions."
        }
    }

    #endif

    @objc private func toggleMusicAmbient() {
        effectsStore.value.musicAmbient.toggle()
    }

    private var effectsPauseTitle: String {
        effectsStore.isPaused ? "Resume Effects" : "Pause Effects"
    }

    private var dictationEnabled: Bool {
        !effectsStore.isPaused && effectsStore.value.dictationVoiceBlob
    }

    @objc private func toggleEffectsPause() {
        effectsStore.isPaused.toggle()
    }

    private func applyEffects(_ settings: EffectConfiguration) {
        let paused = effectsStore.isPaused
        for board in boards {
            board.effectsPaused = paused
            board.effects = settings
        }
        if paused { KeyboardSoundEngine.shared.stop() }
        if let button = effectsPauseButton, button.title != effectsPauseTitle {
            button.title = effectsPauseTitle
            updateGlobalMonitorUI()
        }

        DictationBlobController.shared.setShortcut(settings.dictationShortcut)
        DictationBlobController.shared.setEnabled(dictationEnabled)
        if dictationEnabled { _ = rightOptionHID.start() } else { rightOptionHID.stop() }
        var audioSettings = settings
        if paused { audioSettings.musicAmbient = false }
        MusicAmbientController.shared.configure(settings: audioSettings)
        if audioSettings.musicAmbient && activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                reason: "Live global keyboard display effects"
            )
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification: Notification) {
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        MusicAmbientController.shared.stop()
        DictationBlobController.shared.stop()
        rightOptionHID.stop()
        if observingDisplayChanges {
            observingDisplayChanges = false
            CGDisplayRemoveReconfigurationCallback(Self.displayReconfigured, Unmanaged.passUnretained(self).toOpaque())
        }
        output.release()
    }
}


/// Keep the status button clickable across the entire badge.
private final class UpdateIndicator: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
