import AppKit
import ScreenCaptureKit
import SwiftUI
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: TerminalPanel!
    private var notchWindow: NotchWindow?
    private let sessionStore = SessionStore.shared
    private var hoverHideTimer: Timer?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?
    private var eventTap: CFMachPort?
    /// Whether the panel was opened via notch hover (vs status item click)
    private var panelOpenedViaHover = false
    private let hoverMargin: CGFloat = 15
    private let hoverHideDelay: TimeInterval = 0.06

    private var replaceNotch: Bool {
        get {
            if UserDefaults.standard.object(forKey: "replaceNotch") == nil { return true }
            return UserDefaults.standard.bool(forKey: "replaceNotch")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "replaceNotch")
        }
    }

    private var stealthMode: Bool {
        get {
            if UserDefaults.standard.object(forKey: "stealthMode") == nil { return true }
            return UserDefaults.standard.bool(forKey: "stealthMode")
        }
        set {
            UserDefaults.standard.set(newValue, forKey: "stealthMode")
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupStatusItem()
        setupPanel()
        if replaceNotch {
            setupNotchWindow()
        }
        setupHotkey()
        applyStealthMode()
        // Detect in background so launch isn't blocked
        sessionStore.detectAllXcodeProjectsAsync()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(named: "menuIcon") //NSImage(systemSymbolName: "terminal", accessibilityDescription: "Notchy")
            button.image?.isTemplate = true  // lets macOS handle light/dark mode
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
    }

    private func setupPanel() {
        panel = TerminalPanel(sessionStore: sessionStore)
        // When the panel hides for any reason, clean up hover tracking
        NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self, !self.panel.isVisible else { return }
            self.notchWindow?.endHover()
            self.panelOpenedViaHover = false
            self.stopHoverTracking()
        }
        // When panel becomes key (user clicked on it), stop hover tracking
        // since resign-key will handle hiding from here
        NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if self.panelOpenedViaHover {
                self.panelOpenedViaHover = false
                self.stopHoverTracking()
            }
        }
    }

    private func setupNotchWindow() {
        notchWindow = NotchWindow { [weak self] in
            self?.notchHovered()
        }
        notchWindow?.isPanelVisible = { [weak self] in
            self?.panel.isVisible ?? false
        }
        if stealthMode {
            notchWindow?.sharingType = .none
        }
    }

    private func setupHotkey() {
        // CGEvent tap intercepts key events at the session level before any app
        // processes them. Requires Accessibility permission.
        //
        // Hotkeys:
        //   Cmd+Shift+D -> toggle panel
        //   Cmd+Shift+F -> screenshot

        let callback: CGEventTapCallBack = { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
            guard type == .keyDown else {
                // If the tap is disabled by the system (timeout), re-enable it
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    if let refcon {
                        let appDelegate = Unmanaged<AppDelegate>.fromOpaque(refcon).takeUnretainedValue()
                        if let tap = appDelegate.eventTap {
                            CGEvent.tapEnable(tap: tap, enable: true)
                        }
                    }
                    return Unmanaged.passRetained(event)
                }
                return Unmanaged.passRetained(event)
            }

            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            let flags = event.flags

            let hasCmd = flags.contains(.maskCommand)
            let hasShift = flags.contains(.maskShift)

            if hasCmd && hasShift {
                // Cmd+Shift+D (keyCode 2) -> toggle panel
                if keyCode == 2 {
                    DispatchQueue.main.async {
                        (NSApp.delegate as? AppDelegate)?.togglePanel()
                    }
                    return nil  // consume the event
                }
                // Cmd+Shift+F (keyCode 3) -> screenshot
                if keyCode == 3 {
                    DispatchQueue.main.async {
                        (NSApp.delegate as? AppDelegate)?.captureAndSendScreenshot()
                    }
                    return nil  // consume the event
                }
            }

            return Unmanaged.passRetained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("[Notchy] Failed to create event tap. Check Accessibility permissions in System Settings > Privacy & Security > Accessibility.")
            return
        }

        self.eventTap = tap

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // MARK: - Screenshot Capture

    func captureAndSendScreenshot() {
        guard let activeId = sessionStore.activeSessionId else { return }
        guard TerminalManager.shared.terminalIfExists(for: activeId) != nil else { return }

        // Find the screen containing the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        guard let displayID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }

        // Capture window numbers on main thread before entering async Task
        var notchyWindowIDs: Set<CGWindowID> = [CGWindowID(panel.windowNumber)]
        if let nw = notchWindow {
            notchyWindowIDs.insert(CGWindowID(nw.windowNumber))
        }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { return }
                let excludedWindows = content.windows.filter { notchyWindowIDs.contains(CGWindowID($0.windowID)) }

                let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)
                let config = SCStreamConfiguration()
                config.width = scDisplay.width * 2
                config.height = scDisplay.height * 2
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

                // Save to temp file
                let timestamp = Int(Date().timeIntervalSince1970 * 1000)
                let path = "/tmp/notchy-screenshot-\(timestamp).png"
                let url = URL(fileURLWithPath: path)
                let rep = NSBitmapImageRep(cgImage: image)
                guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
                try pngData.write(to: url)

                // Send to active terminal session
                await MainActor.run {
                    TerminalManager.shared.sendText(to: activeId, text: "\(path) Help me with what you see on my screen.\r")
                }
            } catch {
                // Silent failure -- no visible indication during stealth usage
            }
        }
    }

    private func notchHovered() {
        guard !panel.isVisible else { return }
        showPanelBelowNotch()
        panelOpenedViaHover = true
        startHoverTracking()
        sessionStore.detectAndSwitchAsync()
    }

    private func showPanelBelowNotch() {
        guard let screen = NSScreen.builtIn else { return }
        panel.showPanelCentered(on: screen)
    }

    // MARK: - Hover-to-hide tracking

    private func startHoverTracking() {
        stopHoverTracking()
        hoverGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.checkHoverBounds()
        }
        hoverLocalMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkHoverBounds()
            return event
        }
    }

    private func stopHoverTracking() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
        if let monitor = hoverGlobalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverGlobalMonitor = nil
        }
        if let monitor = hoverLocalMonitor {
            NSEvent.removeMonitor(monitor)
            hoverLocalMonitor = nil
        }
    }

    private func checkHoverBounds() {
        guard panel.isVisible, panelOpenedViaHover, !sessionStore.isPinned, !sessionStore.isShowingDialog else {
            cancelHoverHide()
            return
        }

        let mouse = NSEvent.mouseLocation
        let inNotch = notchWindow?.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse) ?? false
        let inPanel = panel.frame.insetBy(dx: -hoverMargin, dy: -hoverMargin).contains(mouse)

        if inNotch || inPanel {
            cancelHoverHide()
        } else {
            scheduleHoverHide()
        }
    }

    private func scheduleHoverHide() {
        guard hoverHideTimer == nil else { return }
        hoverHideTimer = Timer.scheduledTimer(withTimeInterval: hoverHideDelay, repeats: false) { [weak self] _ in
            guard let self else { return }
            // Re-check one more time before hiding (mouse may have returned)
            let mouse = NSEvent.mouseLocation
            let inNotch = self.notchWindow?.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse) ?? false
            let inPanel = self.panel.frame.insetBy(dx: -self.hoverMargin, dy: -self.hoverMargin).contains(mouse)
            if !inNotch && !inPanel && !self.sessionStore.isPinned && !self.sessionStore.isShowingDialog {
                self.panel.hidePanel()
                self.notchWindow?.endHover()
                self.panelOpenedViaHover = false
                self.stopHoverTracking()
            }
        }
    }

    private func cancelHoverHide() {
        hoverHideTimer?.invalidate()
        hoverHideTimer = nil
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        showContextMenu()
    }

    private func togglePanel() {
        if panel.isVisible {
            panel.hidePanel()
            notchWindow?.endHover()
            panelOpenedViaHover = false
            stopHoverTracking()
        } else {
            panelOpenedViaHover = false
            // Show panel immediately
            showPanelBelowStatusItem()

            // Then detect projects in background
            sessionStore.detectAndSwitchAsync()
        }
    }

    private func showContextMenu() {
        let menu = NSMenu()

        let notchItem = NSMenuItem(
            title: "Show in notch...",
            action: #selector(toggleReplaceNotch),
            keyEquivalent: ""
        )
        notchItem.target = self
        notchItem.state = replaceNotch ? .on : .off
        menu.addItem(notchItem)

        let stealthItem = NSMenuItem(
            title: "Stealth Mode",
            action: #selector(toggleStealthMode),
            keyEquivalent: ""
        )
        stealthItem.target = self
        stealthItem.state = stealthMode ? .on : .off
        menu.addItem(stealthItem)

        menu.addItem(.separator())

        if !sessionStore.sessions.isEmpty {
            for session in sessionStore.sessions {
                let item = NSMenuItem(
                    title: session.projectName,
                    action: #selector(selectSession(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                menu.addItem(item)
            }
            menu.addItem(.separator())
        }

        let newItem = NSMenuItem(
            title: "New Session",
            action: #selector(createNewSession),
            keyEquivalent: "n"
        )
        newItem.target = self
        menu.addItem(newItem)
        menu.addItem(.separator())

        // Checkpoint section
//        let eligibleSessions = sessionStore.checkpointEligibleSessions
//        if !eligibleSessions.isEmpty {
//            menu.addItem(.separator())
//
//            let headingItem = NSMenuItem(title: "Checkpoint", action: nil, keyEquivalent: "")
//            headingItem.isEnabled = false
//            menu.addItem(headingItem)
//
//            let saveItem = NSMenuItem(
//                title: "Save...",
//                action: nil,
//                keyEquivalent: ""
//            )
//            let saveMenu = NSMenu()
//            for session in eligibleSessions {
//                let item = NSMenuItem(
//                    title: session.projectName,
//                    action: #selector(createCheckpoint(_:)),
//                    keyEquivalent: ""
//                )
//                item.target = self
//                item.representedObject = session.id
//                saveMenu.addItem(item)
//            }
//            saveItem.submenu = saveMenu
//            menu.addItem(saveItem)
//
//            let restoreItem = NSMenuItem(
//                title: "Restore from…",
//                action: nil,
//                keyEquivalent: ""
//            )
//            let restoreMenu = NSMenu()
//            for session in eligibleSessions {
//                guard let dir = session.projectPath else { continue }
//                let projectDir = (dir as NSString).deletingLastPathComponent
//                let hasCheckpoint = !CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir).isEmpty
//                guard hasCheckpoint else { continue }
//                let item = NSMenuItem(
//                    title: session.projectName,
//                    action: #selector(restoreLastCheckpoint(_:)),
//                    keyEquivalent: ""
//                )
//                item.target = self
//                item.representedObject = session.id
//                restoreMenu.addItem(item)
//            }
//            if restoreMenu.items.count > 0 {
//                restoreItem.submenu = restoreMenu
//                menu.addItem(restoreItem)
//            }
//        }

//        menu.addItem(.separator())

        let reloadItem = NSMenuItem(
            title: "Dev Reload",
            action: #selector(devReload),
            keyEquivalent: "r"
        )
        reloadItem.target = self
        menu.addItem(reloadItem)

        let quitItem = NSMenuItem(
            title: "Quit Notchy",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func selectSession(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID else { return }
        sessionStore.selectSession(sessionId)
        showPanelBelowStatusItem()
    }

    @objc private func createCheckpoint(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID else { return }
        sessionStore.createCheckpoint(for: sessionId)
    }

    @objc private func restoreLastCheckpoint(_ sender: NSMenuItem) {
        guard let sessionId = sender.representedObject as? UUID,
              let session = sessionStore.sessions.first(where: { $0.id == sessionId }),
              let dir = session.projectPath else { return }
        let projectDir = (dir as NSString).deletingLastPathComponent
        guard let latest = CheckpointManager.shared.checkpoints(for: session.projectName, in: projectDir).first else { return }
        sessionStore.restoreCheckpoint(latest, for: sessionId)
    }

    private func applyStealthMode() {
        let sharingType: NSWindow.SharingType = stealthMode ? .none : .readOnly
        panel.sharingType = sharingType
        notchWindow?.sharingType = sharingType
    }

    @objc private func devReload() {
        // Build the project, then relaunch the app
        let projectDir = "/Users/sresthgupta/Agents/Apps/notchy"
        let appPath = Bundle.main.bundlePath

        DispatchQueue.global(qos: .userInitiated).async {
            let build = Process()
            build.executableURL = URL(fileURLWithPath: "/usr/bin/xcodebuild")
            build.arguments = ["-project", "\(projectDir)/Notchy.xcodeproj", "-scheme", "Notchy", "-configuration", "Debug", "build"]
            build.currentDirectoryURL = URL(fileURLWithPath: projectDir)
            try? build.run()
            build.waitUntilExit()

            guard build.terminationStatus == 0 else {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "Build Failed"
                    alert.informativeText = "xcodebuild exited with code \(build.terminationStatus)"
                    alert.runModal()
                }
                return
            }

            // Relaunch after a short delay
            DispatchQueue.main.async {
                let task = Process()
                task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                task.arguments = ["-n", appPath]
                try? task.run()
                NSApp.terminate(nil)
            }
        }
    }

    @objc private func toggleStealthMode() {
        stealthMode = !stealthMode
        applyStealthMode()
    }

    @objc private func toggleReplaceNotch() {
        replaceNotch = !replaceNotch
        if replaceNotch {
            setupNotchWindow()
        } else {
            notchWindow?.orderOut(nil)
            notchWindow = nil
        }
    }

    @objc private func createNewSession() {
        sessionStore.createQuickSession()
        showPanelBelowStatusItem()
    }

    private func showPanelBelowStatusItem() {
        if let button = statusItem.button,
           let window = button.window {
            let buttonRect = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonRect)
            panel.showPanel(below: screenRect)
        }
    }

}
