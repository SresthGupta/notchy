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
    private var hotkeyMonitor: Any?
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
            UserDefaults.standard.bool(forKey: "stealthMode")
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
        // Global monitor: fires when another app is focused (Cmd+Shift+Space = keyCode 49)
        hotkeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.shift)
            else { return }
            DispatchQueue.main.async { self?.togglePanel() }
        }
        // Local monitor: fires when Notchy itself is focused
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 49,
                  event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.shift)
            else { return event }
            DispatchQueue.main.async { self?.togglePanel() }
            return nil
        }

        // Screenshot hotkey: Cmd+Shift+S (global)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 1,  // S key
                  event.modifierFlags.contains(.command),
                  event.modifierFlags.contains(.shift)
            else { return }
            DispatchQueue.main.async { self?.captureAndSendScreenshot() }
        }
    }

    // MARK: - Screenshot Capture

    func captureAndSendScreenshot() {
        guard let activeId = sessionStore.activeSessionId else { return }
        guard TerminalManager.shared.terminalIfExists(for: activeId) != nil else { return }

        // Find the screen containing the mouse cursor
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return }
        guard let displayID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return }

        Task {
            do {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
                guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { return }

                // Exclude Notchy windows from capture
                let notchyWindowIDs: Set<CGWindowID> = {
                    var ids: Set<CGWindowID> = [CGWindowID(self.panel.windowNumber)]
                    if let nw = self.notchWindow {
                        ids.insert(CGWindowID(nw.windowNumber))
                    }
                    return ids
                }()
                let excludedWindows = content.windows.filter { notchyWindowIDs.contains(CGWindowID($0.windowID)) }

                let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)
                let config = SCStreamConfiguration()
                config.width = scDisplay.width * 2
                config.height = scDisplay.height * 2
                config.showsCursor = false

                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

                // Save to temp file
                let timestamp = Int(Date().timeIntervalSince1970)
                let path = "/tmp/notchy-screenshot-\(timestamp).png"
                let url = URL(fileURLWithPath: path)
                let rep = NSBitmapImageRep(cgImage: image)
                guard let pngData = rep.representation(using: .png, properties: [:]) else { return }
                try pngData.write(to: url)

                // Send to active terminal session
                await MainActor.run {
                    TerminalManager.shared.sendText(to: activeId, text: "\(path) Help me with what you see on my screen.\n")
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
