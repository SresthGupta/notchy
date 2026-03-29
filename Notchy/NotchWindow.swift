import AppKit
import SwiftUI

/// An invisible window that sits behind the notch area.
/// When the mouse hovers over the notch or any additional hover rect, it fires a callback to show the main panel.
/// Expands downward with a bounce animation when any session is working.
class NotchWindow: NSPanel {
    private var mouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var screenObserver: Any?
    private var statusObserver: Any?
    var onHover: (() -> Void)?
    /// Additional rects (in screen coordinates) that should also trigger hover.
    /// Each closure is called at check-time so the rect stays up-to-date.
    var additionalHoverRects: [() -> NSRect] = []
    /// Closure to check if the main panel is currently visible.
    /// When the panel is visible, the notch stays in hover-grown size.
    var isPanelVisible: (() -> Bool)?

    /// Detected notch dimensions (updated on screen change).
    private var notchWidth: CGFloat = 180
    private var notchHeight: CGFloat = 37

    /// Whether the notch is currently expanded (wider, for working state)
    private var isExpanded = false

    /// Whether the prompt input is currently showing
    var isShowingPrompt = false

    /// Event monitor for click-outside detection during prompt mode
    private var clickOutsideMonitor: Any?
    /// Event monitor for Escape key during prompt mode
    private var escapeKeyMonitor: Any?

    /// Callback fired when the user submits a prompt (text may be empty for default)
    var onPromptSubmit: ((String) -> Void)?
    /// Callback fired when the user dismisses the prompt
    var onPromptDismiss: (() -> Void)?

    /// Debounce timer for collapsing — prevents rapid expand/collapse cycling
    /// when terminal status flickers between .working and .idle.
    private var collapseDebounceTimer: Timer?

    /// Whether the mouse is currently hovering over the notch
    private var isHovered = false
    /// The pill-shaped background view shown when expanded
    private let pillView = NotchPillView()

    /// SwiftUI content overlay shown inside the pill when expanded
    private var pillContentHost: NSHostingView<NotchPillContent>?

    init(onHover: @escaping () -> Void) {
        self.onHover = onHover

        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )

        isFloatingPanel = true
        level = .statusBar
        backgroundColor = .clear
        hasShadow = false
        isOpaque = false
        animationBehavior = .none
        hidesOnDeactivate = false
        isMovableByWindowBackground = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        ignoresMouseEvents = false
        alphaValue = 1

        // Set up the pill view (always visible)
        if let cv = contentView {
            pillView.frame = cv.bounds
            pillView.autoresizingMask = [.width, .height]
            pillView.alphaValue = 1
            cv.addSubview(pillView)
            cv.wantsLayer = true
            cv.layer?.masksToBounds = false

            // SwiftUI content overlay inside the pill
            let hostView = NSHostingView(rootView: NotchPillContent())
            hostView.frame = cv.bounds
            hostView.autoresizingMask = [.width, .height]
            hostView.alphaValue = 1
            hostView.wantsLayer = true
            hostView.layer?.backgroundColor = .clear
            cv.addSubview(hostView)
            pillContentHost = hostView
        }

        // Accept file drags so hovering a dragged file over the notch opens the panel
        registerForDraggedTypes([.fileURL, .URL])

        detectNotchSize()
        positionAtNotch()
        orderFrontRegardless()
        setupTracking()
        observeScreenChanges()
        observeStatusChanges()
    }

    // MARK: - Drag destination (treat drag-over like hover)

    func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        onHover?()
        return .generic
    }

    func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        return .generic
    }

    func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // We don't actually accept the drop — just trigger the hover
        return false
    }

    deinit {
        teardownPromptEventMonitors()
        if let monitor = mouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let monitor = localMouseMonitor {
            NSEvent.removeMonitor(monitor)
        }
        if let observer = screenObserver {
            NotificationCenter.default.removeObserver(observer)
        }
        if let observer = statusObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - Expand / Collapse

    private func observeStatusChanges() {
        statusObserver = NotificationCenter.default.addObserver(
            forName: .NotchyNotchStatusChanged,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            if !(self?.isExpanded ?? false) {
                self?.updateExpansionState()
            }
            else {
                self?.collapseDebounceTimer?.invalidate()
                self?.collapseDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: false) { [weak self] _ in
                    guard let self, self.isExpanded else { return }
                    self.collapseDebounceTimer = nil
                    self.updateExpansionState()
                }
            }
        }
        // Also poll on a timer to catch status changes from the observation timer
        Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            self?.updateExpansionState()
        }
    }

    private func updateExpansionState() {
        guard !isShowingPrompt else { return } // prompt mode takes priority
        let shouldExpand = NotchDisplayState.current != .idle

        if shouldExpand && !isExpanded {
            collapseDebounceTimer?.invalidate()
            collapseDebounceTimer = nil
            expandWithBounce()
        } else if !shouldExpand && isExpanded {
            // Debounce collapse to avoid rapid cycling when terminal status
            // flickers between .working and .idle during transitions.
            guard collapseDebounceTimer == nil else { return }
            collapseDebounceTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                guard let self else { return }
                self.collapseDebounceTimer = nil
                // Re-check — state may have changed during the debounce
                if NotchDisplayState.current == .idle && self.isExpanded {
                    self.collapse()
                }
            }
        } else if shouldExpand && isExpanded {
            // Still expanded and should be — cancel any pending collapse
            collapseDebounceTimer?.invalidate()
            collapseDebounceTimer = nil
        }
    }

    private func expandWithBounce() {
        isExpanded = true
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame

        let targetWidth: CGFloat = notchWidth + 80
        var targetFrame = NSRect(
            x: screenFrame.midX - targetWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: targetWidth,
            height: notchHeight
        )
        if isHovered {
            targetFrame = applyHoverGrow(to: targetFrame)
        }

        // Show pill view and content
        pillView.alphaValue = 1
        pillContentHost?.alphaValue = 1

        // Bounce animation using display link
        let startFrame = frame
        let startTime = CACurrentMediaTime()
        let duration: Double = 0.6

        let displayLink = CVDisplayLinkWrapper { [weak self] in
            guard let self else { return false }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)

            // Spring/bounce curve
            let bounce = Self.bounceEase(t)

            let currentX = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * bounce
            let currentWidth = startFrame.width + (targetFrame.width - startFrame.width) * bounce

            DispatchQueue.main.async {
                self.setFrame(
                    NSRect(x: currentX, y: targetFrame.origin.y, width: currentWidth, height: targetFrame.height),
                    display: true
                )
            }
            return t < 1.0
        }
        displayLink.start()
    }

    private func collapse() {
        isExpanded = false

        // Fade out the status content but keep the pill visible
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.pillContentHost?.animator().alphaValue = 0
        }

        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame

        var targetFrame = NSRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )
        if isHovered {
            targetFrame = applyHoverGrow(to: targetFrame)
        }

        let startFrame = frame
        let startTime = CACurrentMediaTime()
        let duration: Double = 0.3

        let displayLink = CVDisplayLinkWrapper { [weak self] in
            guard let self else { return false }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)

            // Ease out
            let ease = 1.0 - pow(1.0 - t, 3.0)

            let currentX = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * ease
            let currentWidth = startFrame.width + (targetFrame.width - startFrame.width) * ease

            DispatchQueue.main.async {
                self.setFrame(
                    NSRect(x: currentX, y: targetFrame.origin.y, width: currentWidth, height: targetFrame.height),
                    display: true
                )
                if t >= 1.0 {
                    // Show the idle content once collapse animation finishes
                    self.pillContentHost?.alphaValue = 1
                }
            }
            return t < 1.0
        }
        displayLink.start()
    }

    // MARK: - Prompt Expansion / Collapse

    private static let promptExpandedWidth: CGFloat = 350
    private static let promptExpandedHeight: CGFloat = 55

    private func expandForPrompt() {
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame

        let targetWidth = Self.promptExpandedWidth
        let targetHeight = Self.promptExpandedHeight
        let targetFrame = NSRect(
            x: screenFrame.midX - targetWidth / 2,
            y: screenFrame.maxY - targetHeight,
            width: targetWidth,
            height: targetHeight
        )

        pillView.isPromptMode = true
        pillView.alphaValue = 1
        pillContentHost?.alphaValue = 1

        let startFrame = frame
        let startTime = CACurrentMediaTime()
        let duration: Double = 0.5

        let displayLink = CVDisplayLinkWrapper { [weak self] in
            guard let self else { return false }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)
            let bounce = Self.bounceEase(t)

            let currentX = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * bounce
            let currentY = startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * bounce
            let currentWidth = startFrame.width + (targetFrame.width - startFrame.width) * bounce
            let currentHeight = startFrame.height + (targetFrame.height - startFrame.height) * bounce

            DispatchQueue.main.async {
                self.setFrame(
                    NSRect(x: currentX, y: currentY, width: currentWidth, height: currentHeight),
                    display: true
                )
            }
            return t < 1.0
        }
        displayLink.start()
    }

    private func collapseFromPrompt() {
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame

        let targetFrame = NSRect(
            x: screenFrame.midX - notchWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: notchWidth,
            height: notchHeight
        )

        // Fade out content first
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            self.pillContentHost?.animator().alphaValue = 0
        }

        let startFrame = frame
        let startTime = CACurrentMediaTime()
        let duration: Double = 0.3

        let displayLink = CVDisplayLinkWrapper { [weak self] in
            guard let self else { return false }
            let elapsed = CACurrentMediaTime() - startTime
            let t = min(elapsed / duration, 1.0)
            let ease = 1.0 - pow(1.0 - t, 3.0)

            let currentX = startFrame.origin.x + (targetFrame.origin.x - startFrame.origin.x) * ease
            let currentY = startFrame.origin.y + (targetFrame.origin.y - startFrame.origin.y) * ease
            let currentWidth = startFrame.width + (targetFrame.width - startFrame.width) * ease
            let currentHeight = startFrame.height + (targetFrame.height - startFrame.height) * ease

            DispatchQueue.main.async {
                self.setFrame(
                    NSRect(x: currentX, y: currentY, width: currentWidth, height: currentHeight),
                    display: true
                )
                if t >= 1.0 {
                    self.pillView.isPromptMode = false
                    self.pillContentHost?.alphaValue = 1
                }
            }
            return t < 1.0
        }
        displayLink.start()
    }

    /// Spring / bounce easing — overshoots then settles
    private static func bounceEase(_ t: Double) -> Double {
        let omega = 12.0  // frequency
        let zeta = 0.4    // damping
        return 1.0 - exp(-zeta * omega * t) * cos(sqrt(1.0 - zeta * zeta) * omega * t)
    }

    // MARK: - Notch size detection

    private func detectNotchSize() {
        guard let screen = NSScreen.builtIn else { return }

        if #available(macOS 12.0, *),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            // Notch spans the gap between the two auxiliary areas
            notchWidth = right.minX - left.maxX
            notchHeight = screen.frame.maxY - min(left.minY, right.minY)
        } else {
            // No notch (external display, older Mac) — use sensible defaults
            let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
            notchWidth = 180
            notchHeight = max(menuBarHeight, 25)
        }
    }

    // MARK: - Positioning

    private func positionAtNotch() {
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let x = screenFrame.midX - notchWidth / 2
        let y = screenFrame.maxY - notchHeight
        setFrame(NSRect(x: x, y: y, width: notchWidth, height: notchHeight), display: true)
    }

    // MARK: - Mouse tracking

    private func setupTracking() {
        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            self?.checkMouse()
        }
        // Local monitor catches events when the mouse is over this window itself
        // (global monitors only fire for events outside the app's windows)
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.checkMouse()
            return event
        }
    }

    private func checkMouse() {
        guard !isShowingPrompt else { return }
        let mouseLocation = NSEvent.mouseLocation

        // Check the notch area itself
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let effectiveWidth = isExpanded ? notchWidth + 80 : notchWidth
        let notchRect = NSRect(
            x: screenFrame.midX - effectiveWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: effectiveWidth,
            height: notchHeight + 1  // +1 so the top screen edge (maxY) is inside the rect
        )

        let mouseInNotch = notchRect.contains(mouseLocation)
        let mouseInAdditional = additionalHoverRects.contains { $0().contains(mouseLocation) }

        if mouseInNotch || mouseInAdditional {
            if !isHovered {
                isHovered = true
                hoverGrow()
            }
            onHover?()
            return
        }

        if isHovered {
            // Keep hover-grown size while the panel is visible
            let panelShowing = isPanelVisible?() ?? false
            if !panelShowing {
                isHovered = false
                hoverShrink()
            }
        }
    }

    /// Called when the panel hides — forces the notch back to normal size.
    func endHover() {
        guard isHovered else { return }
        isHovered = false
        hoverShrink()
    }

    func setStealthOutline(_ visible: Bool, animated: Bool = true) {
        pillView.setStealthOutline(visible, animated: animated)
    }

    // MARK: - Hover grow / shrink

    private static let hoverGrowX: CGFloat = 0 + NotchPillView.earRadius * 2  // extra width for ear protrusions
    private static let hoverGrowY: CGFloat = 2

    /// Applies hover grow offset to any frame.
    private func applyHoverGrow(to rect: NSRect) -> NSRect {
        NSRect(
            x: rect.origin.x - Self.hoverGrowX / 2,
            y: rect.origin.y - Self.hoverGrowY,
            width: rect.width + Self.hoverGrowX,
            height: rect.height + Self.hoverGrowY
        )
    }

    private func hoverGrow() {
        guard !isShowingPrompt else { return }
        pillView.isHovered = true
        pillContentHost?.rootView = NotchPillContent(isHovering: true)
        setFrame(applyHoverGrow(to: frame), display: true)
    }

    private func hoverShrink() {
        guard !isShowingPrompt else { return }
        pillView.isHovered = false
        pillContentHost?.rootView = NotchPillContent(isHovering: false)
        guard let screen = NSScreen.builtIn else { return }
        let screenFrame = screen.frame
        let baseWidth = isExpanded ? notchWidth + 80 : notchWidth
        let targetFrame = NSRect(
            x: screenFrame.midX - baseWidth / 2,
            y: screenFrame.maxY - notchHeight,
            width: baseWidth,
            height: notchHeight
        )
        setFrame(targetFrame, display: true)
    }

    // MARK: - Observers

    private func observeScreenChanges() {
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.detectNotchSize()
            self?.positionAtNotch()
        }
    }

    override var canBecomeKey: Bool { isShowingPrompt }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        if isShowingPrompt {
            dismissPrompt()
        }
    }

    // MARK: - Prompt Input

    func showPromptInput() {
        guard !isShowingPrompt else { return }
        isShowingPrompt = true

        // Suppress any pending status-driven collapse
        collapseDebounceTimer?.invalidate()
        collapseDebounceTimer = nil

        NSApp.activate(ignoringOtherApps: true)
        makeKeyAndOrderFront(nil)

        expandForPrompt()

        // Swap content to prompt input
        pillContentHost?.rootView = NotchPillContent(isHovering: false, isPromptMode: true, onPromptSubmit: { [weak self] text in
            self?.submitPrompt(text: text)
        })

        // Set up click-outside and Escape detection
        setupPromptEventMonitors()
    }

    func submitPrompt(text: String) {
        guard isShowingPrompt else { return }
        isShowingPrompt = false
        teardownPromptEventMonitors()

        // Swap content back before collapsing
        pillContentHost?.rootView = NotchPillContent(isHovering: isHovered)

        collapseFromPrompt()
        onPromptSubmit?(text)
    }

    func dismissPrompt() {
        guard isShowingPrompt else { return }
        isShowingPrompt = false
        teardownPromptEventMonitors()

        pillContentHost?.rootView = NotchPillContent(isHovering: isHovered)

        collapseFromPrompt()
        onPromptDismiss?()
    }

    private func setupPromptEventMonitors() {
        // Escape key
        escapeKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.dismissPrompt()
                return nil // consume the event
            }
            return event
        }

        // Click outside
        clickOutsideMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self, self.isShowingPrompt else { return }
            let mouseLocation = NSEvent.mouseLocation
            if !self.frame.contains(mouseLocation) {
                self.dismissPrompt()
            }
        }
    }

    private func teardownPromptEventMonitors() {
        if let monitor = escapeKeyMonitor {
            NSEvent.removeMonitor(monitor)
            escapeKeyMonitor = nil
        }
        if let monitor = clickOutsideMonitor {
            NSEvent.removeMonitor(monitor)
            clickOutsideMonitor = nil
        }
    }
}

// MARK: - NSScreen helper

extension NSScreen {
    /// Returns the built-in display (the one with the notch), or the main screen as fallback.
    static var builtIn: NSScreen? {
        screens.first { screen in
            let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID ?? 0
            return CGDisplayIsBuiltin(id) != 0
        } ?? main
    }
}

// MARK: - Notch pill background view

/// A view that draws a rounded pill shape extending below the notch.
/// When hovered, curved protrusions ("ears") appear at the bottom-left and bottom-right,
/// creating a smooth concave transition out from the notch body.
class NotchPillView: NSView {
    var isHovered: Bool = false {
        didSet {
            guard isHovered != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    var isPromptMode: Bool = false {
        didSet {
            guard isPromptMode != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    private let shapeLayer = CAShapeLayer()
    private let stealthLineLayer = CAShapeLayer()
    static let earRadius: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = false
        layer?.backgroundColor = .clear
        shapeLayer.fillColor = NSColor.black.cgColor
        layer?.addSublayer(shapeLayer)

        stealthLineLayer.strokeColor = NSColor(red: 0.78, green: 0.66, blue: 0.20, alpha: 1).cgColor
        stealthLineLayer.lineWidth = 2.0
        stealthLineLayer.fillColor = nil
        stealthLineLayer.opacity = 0
        layer?.addSublayer(stealthLineLayer)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        updateShape()
    }

    private func updateShape() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let ear = Self.earRadius
        shapeLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)

        let path = CGMutablePath()

        if isPromptMode {
            // Larger rounded rectangle for the prompt input
            let cr: CGFloat = 12
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w, y: cr))
            path.addQuadCurve(
                to: CGPoint(x: w - cr, y: 0),
                control: CGPoint(x: w, y: 0)
            )
            path.addLine(to: CGPoint(x: cr, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: cr),
                control: CGPoint(x: 0, y: 0)
            )
            path.closeSubpath()
            shapeLayer.path = path
            return
        }

        if isHovered {
            // Main body is inset by ear on each side; ears fill the extra space
            let bodyLeft = ear
            let bodyRight = w - ear

            // Left ear tip (bottom-left corner of view)
            path.move(to: CGPoint(x: 0, y: 0))
            // Concave curve up into the main body's left edge
            path.addQuadCurve(
                to: CGPoint(x: bodyLeft, y: ear),
                control: CGPoint(x: bodyLeft , y: 0)
            )
            // Left edge up to top
            path.addLine(to: CGPoint(x: bodyLeft, y: h))
            // Top edge
            path.addLine(to: CGPoint(x: bodyRight, y: h))
            // Right edge down
            path.addLine(to: CGPoint(x: bodyRight, y: ear))
            // Concave curve out to right ear tip
            path.addQuadCurve(
                to: CGPoint(x: w, y: 0),
                control: CGPoint(x: bodyRight, y: 0)
            )
            path.closeSubpath()
        } else {
            let cr: CGFloat = 9.5
            path.move(to: CGPoint(x: 0, y: h))
            path.addLine(to: CGPoint(x: w, y: h))
            path.addLine(to: CGPoint(x: w, y: cr))
            path.addQuadCurve(
                to: CGPoint(x: w - cr, y: 0),
                control: CGPoint(x: w, y: 0)
            )
            path.addLine(to: CGPoint(x: cr, y: 0))
            path.addQuadCurve(
                to: CGPoint(x: 0, y: cr),
                control: CGPoint(x: 0, y: 0)
            )
            path.closeSubpath()
        }

        shapeLayer.path = path
        updateStealthLine()
    }

    private func updateStealthLine() {
        let w = bounds.width
        let h = bounds.height
        guard w > 0, h > 0 else { return }

        let ear = Self.earRadius
        stealthLineLayer.frame = CGRect(x: 0, y: 0, width: w, height: h)

        let linePath = CGMutablePath()
        if isPromptMode {
            let cr: CGFloat = 12
            // Match the prompt box rounded rect shape
            linePath.move(to: CGPoint(x: 0, y: h))
            linePath.addLine(to: CGPoint(x: 0, y: cr))
            linePath.addQuadCurve(
                to: CGPoint(x: cr, y: 0),
                control: CGPoint(x: 0, y: 0)
            )
            linePath.addLine(to: CGPoint(x: w - cr, y: 0))
            linePath.addQuadCurve(
                to: CGPoint(x: w, y: cr),
                control: CGPoint(x: w, y: 0)
            )
            linePath.addLine(to: CGPoint(x: w, y: h))
        } else if isHovered {
            let bodyLeft = ear
            let bodyRight = w - ear
            // Left side down, left ear curve, right ear curve, right side up
            linePath.move(to: CGPoint(x: bodyLeft, y: h))
            linePath.addLine(to: CGPoint(x: bodyLeft, y: ear))
            linePath.addQuadCurve(
                to: CGPoint(x: 0, y: 0),
                control: CGPoint(x: bodyLeft, y: 0)
            )
            linePath.move(to: CGPoint(x: w, y: 0))
            linePath.addQuadCurve(
                to: CGPoint(x: bodyRight, y: ear),
                control: CGPoint(x: bodyRight, y: 0)
            )
            linePath.addLine(to: CGPoint(x: bodyRight, y: h))
        } else {
            let cr: CGFloat = 9.5
            // Left side down, bottom corners, bottom edge, right side up
            linePath.move(to: CGPoint(x: 0, y: h))
            linePath.addLine(to: CGPoint(x: 0, y: cr))
            linePath.addQuadCurve(
                to: CGPoint(x: cr, y: 0),
                control: CGPoint(x: 0, y: 0)
            )
            linePath.addLine(to: CGPoint(x: w - cr, y: 0))
            linePath.addQuadCurve(
                to: CGPoint(x: w, y: cr),
                control: CGPoint(x: w, y: 0)
            )
            linePath.addLine(to: CGPoint(x: w, y: h))
        }
        stealthLineLayer.path = linePath
    }

    func setStealthOutline(_ visible: Bool, animated: Bool = true) {
        let targetOpacity: Float = visible ? 1 : 0
        if animated {
            let anim = CABasicAnimation(keyPath: "opacity")
            anim.fromValue = stealthLineLayer.opacity
            anim.toValue = targetOpacity
            anim.duration = 0.3
            anim.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stealthLineLayer.add(anim, forKey: "stealthFade")
        }
        stealthLineLayer.opacity = targetOpacity
    }
}

// MARK: - Notch display state

enum NotchDisplayState: Equatable {
    case idle
    case working
    case waitingForInput
    case taskCompleted

    /// Hierarchy: .taskCompleted (always shown) > .waitingForInput > .working > .idle
    static var current: NotchDisplayState {
        let sessions = SessionStore.shared.sessions
        if sessions.contains(where: { $0.terminalStatus == .taskCompleted }) {
            return .taskCompleted
        }
        if sessions.contains(where: { $0.terminalStatus == .waitingForInput }) {
            return .waitingForInput
        }
        if sessions.contains(where: { $0.terminalStatus == .working }) {
            return .working
        }
        return .idle
    }
}

// MARK: - Notch pill SwiftUI content

struct NotchPillContent: View {
    var isHovering: Bool = false
    var isPromptMode: Bool = false
    var onPromptSubmit: ((String) -> Void)?
    private var displayState: NotchDisplayState { .current }

    var body: some View {
        if isPromptMode {
            PromptInputView(onSubmit: { text in
                onPromptSubmit?(text)
            })
        } else {
            statusContent
        }
    }

    private var statusContent: some View {
        ZStack {
            HStack {

                if displayState != .idle {

                    Rectangle()
                        .foregroundColor(.clear)
                        .frame(width: 18, height: 18)
                        .overlay(alignment: .leading) {
                            BotFaceView()
                                .frame(width: 20, height: 15)
                                .mask(RoundedRectangle(cornerRadius: 5))
                        }

                    Spacer()

                    switch displayState {
                    case .taskCompleted:
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.green)
                            .transition(.scale.combined(with: .opacity))
                    case .waitingForInput:
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundColor(.yellow)
                            .transition(.scale.combined(with: .opacity))
                    case .working:
                        SpinnerView()
                            .frame(width: 14, height: 14)
                            .transition(.scale.combined(with: .opacity))
                    case .idle:
                        EmptyView()
                    }
                }
            }
            .animation(.easeInOut(duration: 0.25), value: displayState)
            .padding(.horizontal, 12 + (isHovering ? NotchPillView.earRadius : 0))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .offset(y: isHovering ? -3 : -2)
        .onChange(of: displayState) {
            NotificationCenter.default.post(name: .NotchyNotchStatusChanged, object: nil)
        }
    }
}

struct PromptInputView: View {
    @State private var promptText = ""
    @FocusState private var isFocused: Bool
    var onSubmit: (String) -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "camera.fill")
                .font(.system(size: 13, weight: .medium))
                .foregroundColor(.white.opacity(0.5))

            TextField("Ask about your screen...", text: $promptText)
                .textFieldStyle(.plain)
                .font(.system(size: 14, weight: .regular))
                .foregroundColor(.white)
                .focused($isFocused)
                .onSubmit {
                    onSubmit(promptText)
                }

            Image(systemName: "return")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(.white.opacity(0.3))
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.clear)
        .onAppear {
            // Slight delay to let the window become key first
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                isFocused = true
            }
        }
    }
}

struct SpinnerView: View {
    @State private var isAnimating = false

    var body: some View {
        Circle()
            .trim(from: 0.05, to: 0.8)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2, lineCap: .round))
            .rotationEffect(.degrees(isAnimating ? 360 : 0))
            .animation(.linear(duration: 0.8).repeatForever(autoreverses: false), value: isAnimating)
            .onAppear { isAnimating = true }
    }
}

// MARK: - CVDisplayLink wrapper for smooth animation

/// Drives a frame-by-frame animation callback on the display refresh rate.
class CVDisplayLinkWrapper {
    private var displayLink: CVDisplayLink?
    private let callback: () -> Bool  // return true to keep running
    private var stopped = false

    init(callback: @escaping () -> Bool) {
        self.callback = callback
    }

    func start() {
        CVDisplayLinkCreateWithActiveCGDisplays(&displayLink)
        guard let displayLink else { return }

        let opaqueWrapper = Unmanaged.passRetained(self)
        CVDisplayLinkSetOutputCallback(displayLink, { (_, _, _, _, _, userInfo) -> CVReturn in
            guard let userInfo else { return kCVReturnError }
            let wrapper = Unmanaged<CVDisplayLinkWrapper>.fromOpaque(userInfo).takeUnretainedValue()
            guard !wrapper.stopped else { return kCVReturnSuccess }
            let keepRunning = wrapper.callback()
            if !keepRunning {
                // Stop immediately on this thread to prevent further callbacks
                wrapper.stopped = true
                if let link = wrapper.displayLink {
                    CVDisplayLinkStop(link)
                }
                // Release the retained reference on main
                DispatchQueue.main.async {
                    wrapper.displayLink = nil
                    Unmanaged<CVDisplayLinkWrapper>.fromOpaque(userInfo).release()
                }
            }
            return kCVReturnSuccess
        }, opaqueWrapper.toOpaque())

        CVDisplayLinkStart(displayLink)
    }

    func stop() {
        stopped = true
        guard let displayLink else { return }
        CVDisplayLinkStop(displayLink)
        self.displayLink = nil
    }
}
