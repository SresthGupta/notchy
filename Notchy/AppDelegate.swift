import AppKit
import KeyboardShortcuts
import ScreenCaptureKit
import SwiftUI

extension KeyboardShortcuts.Name {
    static let togglePanel = Self("togglePanel", default: .init(.n, modifiers: [.command, .option]))
    static let screenshotToClaude = Self("screenshotToClaude", default: .init(.f, modifiers: [.command, .option]))
}
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var panel: TerminalPanel!
    private var notchWindow: NotchWindow?
    private let sessionStore = SessionStore.shared
    private var hoverHideTimer: Timer?
    private var hoverGlobalMonitor: Any?
    private var hoverLocalMonitor: Any?
    // KeyboardShortcuts manages its own handler lifecycle internally via static registrations
    /// Screenshot captured but not yet sent (waiting for prompt input)
    private var pendingScreenshotPath: String?
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
        setupHotkeys()
        checkPermissions()
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
        notchWindow?.onPromptSubmit = { [weak self] text in
            self?.handlePromptSubmit(text: text)
        }
        notchWindow?.onPromptDismiss = { [weak self] in
            self?.handlePromptDismiss()
        }
        if stealthMode {
            notchWindow?.sharingType = .none
        }
    }

    private func setupHotkeys() {
        // Force-reset the toggle shortcut to Cmd+Option+N
        // (KeyboardShortcuts persists user prefs in UserDefaults; the old Cmd+Option+D
        // binding may be cached from a previous run and conflicts with Dock show/hide)
        KeyboardShortcuts.reset(.togglePanel)

        KeyboardShortcuts.onKeyUp(for: .togglePanel) { [weak self] in
            self?.togglePanel()
        }
        KeyboardShortcuts.onKeyUp(for: .screenshotToClaude) { [weak self] in
            self?.captureAndSendScreenshot()
        }
    }

    // MARK: - Permission Checking

    private func checkPermissions() {
        // AXIsProcessTrustedWithOptions with prompt: true automatically opens
        // System Settings > Accessibility if not trusted. No additional alert needed.
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // MARK: - Screenshot Capture

    private static let defaultScreenshotPrompt = "Help me with what you see on my screen."

    func captureAndSendScreenshot() {
        guard pendingScreenshotPath == nil else { return } // ignore rapid double-press
        Task {
            guard let path = await captureScreenshot() else { return }
            await MainActor.run {
                self.pendingScreenshotPath = path
                if let nw = self.notchWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    nw.showPromptInput()
                } else {
                    // No notch window (user disabled it) -- send with default prompt
                    self.sendScreenshot(path: path, prompt: Self.defaultScreenshotPrompt)
                    self.pendingScreenshotPath = nil
                }
            }
        }
    }

    /// Captures the screen (excluding Notchy windows) and returns the temp file path, or nil on failure.
    private func captureScreenshot() async -> String? {
        let mouseLocation = NSEvent.mouseLocation
        guard let targetScreen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main else { return nil }
        guard let displayID = targetScreen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID else { return nil }

        var notchyWindowIDs: Set<CGWindowID> = [CGWindowID(panel.windowNumber)]
        if let nw = notchWindow {
            notchyWindowIDs.insert(CGWindowID(nw.windowNumber))
        }

        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let scDisplay = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
            let excludedWindows = content.windows.filter { notchyWindowIDs.contains(CGWindowID($0.windowID)) }

            let filter = SCContentFilter(display: scDisplay, excludingWindows: excludedWindows)
            let config = SCStreamConfiguration()
            config.width = scDisplay.width * 2
            config.height = scDisplay.height * 2
            config.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)

            let timestamp = Int(Date().timeIntervalSince1970 * 1000)
            let path = "/tmp/notchy-screenshot-\(timestamp).png"
            let url = URL(fileURLWithPath: path)
            let rep = NSBitmapImageRep(cgImage: image)
            guard let pngData = rep.representation(using: .png, properties: [:]) else { return nil }
            try pngData.write(to: url)
            return path
        } catch {
            await MainActor.run { [weak self] in
                guard self?.stealthMode != true else {
                    print("[Notchy] Screenshot failed (alert suppressed in stealth mode). Grant Screen Recording permission in System Settings.")
                    return
                }
                let alert = NSAlert()
                alert.messageText = "Screenshot Failed"
                alert.informativeText = "Notchy needs Screen Recording permission. Grant it in System Settings > Privacy & Security > Screen Recording, then restart Notchy."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }
            return nil
        }
    }

    /// Sends a screenshot + prompt to the active Claude session, creating one if needed.
    private func sendScreenshot(path: String, prompt: String) {
        if sessionStore.activeSessionId == nil {
            sessionStore.createQuickSession(name: "Screen Help")
        }
        guard let activeId = sessionStore.activeSessionId else { return }

        if !panel.isVisible {
            panelOpenedViaHover = false
            NSApp.activate(ignoringOtherApps: true)
            showPanelBelowStatusItem()
        }

        let sendBlock = {
            TerminalManager.shared.sendText(to: activeId, text: "\(path) \(prompt)\r")
        }
        if TerminalManager.shared.terminalIfExists(for: activeId) != nil {
            sendBlock()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                sendBlock()
            }
        }
    }

    /// Called by NotchWindow when the user submits a prompt.
    private func handlePromptSubmit(text: String) {
        guard let path = pendingScreenshotPath else { return }
        pendingScreenshotPath = nil
        let prompt = text.isEmpty ? Self.defaultScreenshotPrompt : text
        // Delay to let collapse animation finish before opening panel
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
            self?.sendScreenshot(path: path, prompt: prompt)
        }
    }

    /// Called by NotchWindow when the user dismisses the prompt.
    private func handlePromptDismiss() {
        pendingScreenshotPath = nil
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
            // Activate the app so the panel doesn't immediately resign key
            NSApp.activate(ignoringOtherApps: true)
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
        notchWindow?.setStealthOutline(stealthMode)
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
