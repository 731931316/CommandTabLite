import AppKit
import ApplicationServices
import Carbon
import CoreGraphics
import Darwin
import OSLog

/// Unified log for lifecycle, permission, and switcher failures.
let log = Logger(subsystem: "local.commandtablite", category: "Switcher")

/// Transparent container using top-to-bottom coordinates for the switcher layout.
private final class SwitcherContentView: NSView {
    /// Keeps pointer movement available while the nonactivating panel is not the key window.
    private var pointerTrackingArea: NSTrackingArea?
    /// Matches the measured top and bottom spacing of the native switcher.
    override var isFlipped: Bool { true }

    /// Allows selecting a candidate with the first click on this nonactivating panel.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Tracks actual pointer movement over the complete visible candidate surface.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let pointerTrackingArea { removeTrackingArea(pointerTrackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area)
        pointerTrackingArea = area
    }
}

/// Floating panel that displays application candidates without activating itself.
final class SwitcherPanel: NSPanel {
    /// True while the candidate panel is visible.
    var isShowingCandidates = false
    /// Candidates currently represented by the panel.
    private var candidates: [SwitcherCandidate] = []
    /// Index selected for activation when Command is released.
    private var selectedIndex = 0
    /// Fixed candidate cards retained until this invocation is dismissed.
    private var cards: [NSView] = []
    /// Selected application name, positioned beneath its card.
    private var selectedTitle: NSTextField?
    /// Observes clicks delivered to this app while the switcher is visible.
    private var localMouseMonitor: Any?
    /// Observes outside clicks delivered to other applications.
    private var globalMouseMonitor: Any?
    /// Last observed pointer position, preventing a stationary cursor from overriding keyboard navigation.
    private var lastPointerLocation: NSPoint?

    /// Creates the switcher panel and configures its desktop behavior.
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 186),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        acceptsMouseMovedEvents = true
    }

    /// Opens the panel on the active screen or moves its current selection.
    func advance(_ direction: Int, using catalog: ApplicationCatalog) {
        if !isShowingCandidates {
            candidates = catalog.candidates()
            guard !candidates.isEmpty else { NSSound.beep(); return }
            // A foreground app with no expanded windows must not seed navigation inside the deferred group.
            let frontIndex = candidates.firstIndex { $0.isCurrent && !$0.shouldSortLast }
            selectedIndex = frontIndex ?? (direction > 0 ? candidates.count - 1 : 0)
            buildLayout()
            centerOnActiveScreen()
            isShowingCandidates = true
            lastPointerLocation = NSEvent.mouseLocation
            startMouseMonitoring()
            log.debug("Switcher opened with \(self.candidates.count) fixed candidate cards")
        }
        selectedIndex = (selectedIndex + direction + candidates.count) % candidates.count
        updateSelection()
        orderFrontRegardless()
    }

    /// Activates the selected application and dismisses the panel.
    func commit() {
        guard isShowingCandidates else { return }
        let selected = candidates[selectedIndex]
        dismiss()
        if selected.activate() {
            log.info("Activation requested for \(selected.bundleIdentifier ?? "unknown", privacy: .public)")
        } else {
            log.error("Failed to activate \(selected.bundleIdentifier ?? "unknown", privacy: .public)")
        }
    }

    /// Dismisses without activating an application.
    func dismiss() {
        isShowingCandidates = false
        // Remove both monitors before clearing the selection so later mouse or modifier events cannot commit it.
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        localMouseMonitor = nil
        globalMouseMonitor = nil
        lastPointerLocation = nil
        candidates = []
        cards = []
        selectedTitle = nil
        orderOut(nil)
    }

    /// Watches local candidate clicks and outside clicks for this invocation only.
    private func startMouseMonitoring() {
        let pointerEvents: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .mouseMoved]
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            guard let self, self.isShowingCandidates else { return event }
            let point = event.window?.convertPoint(toScreen: event.locationInWindow) ?? NSEvent.mouseLocation
            if event.type == .mouseMoved {
                self.handlePointerMovement(at: point)
                return event
            }
            let belongsToPanel = event.window === self
            self.handleMouseClick(at: point, isPrimary: event.type == .leftMouseDown)
            // Consume clicks on the floating panel; clicks on another app window keep their normal behavior.
            return belongsToPanel ? nil : event
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: pointerEvents) { [weak self] event in
            if event.type == .mouseMoved {
                self?.handlePointerMovement(at: NSEvent.mouseLocation)
            } else {
                self?.handleMouseClick(at: NSEvent.mouseLocation, isPrimary: event.type == .leftMouseDown)
            }
        }
        if localMouseMonitor == nil || globalMouseMonitor == nil {
            log.warning("A mouse monitor could not be installed for the switcher")
        }
    }

    /// Moves the highlight to the hovered card without committing or moving the candidate row.
    private func handlePointerMovement(at screenPoint: NSPoint) {
        guard isShowingCandidates, let root = contentView else { return }
        defer { lastPointerLocation = screenPoint }
        if let previous = lastPointerLocation, hypot(previous.x - screenPoint.x, previous.y - screenPoint.y) < 0.5 { return }
        let point = root.convert(convertPoint(fromScreen: screenPoint), from: nil)
        guard let index = cards.firstIndex(where: { $0.frame.contains(point) }), index != selectedIndex else { return }
        selectedIndex = index
        updateSelection()
        log.debug("Pointer selected candidate \(index)")
    }

    /// Commits a clicked candidate or cancels when a click falls outside the candidate cards.
    private func handleMouseClick(at screenPoint: NSPoint, isPrimary: Bool) {
        guard isShowingCandidates, let root = contentView else { return }
        let point = root.convert(convertPoint(fromScreen: screenPoint), from: nil)
        if isPrimary, let index = cards.firstIndex(where: { $0.frame.contains(point) }) {
            selectedIndex = index
            log.debug("Mouse selected candidate \(index)")
            commit()
        } else {
            log.info("Switcher canceled by a click outside a candidate")
            dismiss()
        }
    }

    /// Places the panel on the display containing the pointer.
    private func centerOnActiveScreen() {
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        setFrameOrigin(NSPoint(x: frame.midX - self.frame.width / 2, y: frame.midY - self.frame.height / 2))
    }

    /// Creates a fixed row measured against the native switcher on this Mac.
    private func buildLayout() {
        let screen = NSScreen.screens.first { $0.frame.contains(NSEvent.mouseLocation) } ?? NSScreen.main
        let availableWidth = (screen?.frame.width ?? 1280) - 80
        // Keep every candidate in place; shrink the complete row only when it exceeds the display.
        let scale = min(1, (availableWidth - 32) / (CGFloat(candidates.count) * 134 + 2))
        let cardSize = 136 * scale
        let iconSize = 128 * scale
        let step = 134 * scale
        let width = CGFloat(candidates.count) * step + 2 * scale + 32
        let height = cardSize + 50
        setContentSize(NSSize(width: width, height: height))

        let root = SwitcherContentView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        let effect = NSVisualEffectView(frame: root.bounds)
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.appearance = NSAppearance(named: .aqua)
        // Mask the compositor's material itself, so it cannot leave rectangular corners outside the rounded panel.
        effect.maskImage = NSImage(size: root.bounds.size, flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 24, yRadius: 24).fill()
            return true
        }
        root.addSubview(effect)
        // A subtle dark tint brings AppKit's HUD material close to the native switcher over wallpaper.
        let tint = NSView(frame: root.bounds)
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.15).cgColor
        tint.layer?.cornerRadius = 24
        root.addSubview(tint)
        cards = []
        for (index, app) in candidates.enumerated() {
            let card = NSView(frame: NSRect(x: 16 + CGFloat(index) * step, y: 25, width: cardSize, height: cardSize))
            card.wantsLayer = true
            card.layer?.cornerRadius = 10 * scale
            let icon = NSImageView(frame: NSRect(x: (cardSize - iconSize) / 2, y: (cardSize - iconSize) / 2, width: iconSize, height: iconSize))
            icon.image = app.icon
            // Application icons commonly report a 32-point natural size; allow their high-resolution representation to fill the target.
            icon.imageScaling = .scaleProportionallyUpOrDown
            card.addSubview(icon)
            root.addSubview(card)
            cards.append(card)
        }
        let title = NSTextField(labelWithString: "")
        title.alignment = .center
        // Medium-weight, high-contrast text remains readable over the translucent HUD background.
        title.font = .systemFont(ofSize: 15, weight: .medium)
        title.textColor = NSColor(calibratedWhite: 0.08, alpha: 1)
        title.lineBreakMode = .byTruncatingMiddle
        root.addSubview(title)
        selectedTitle = title
        contentView = root
        invalidateShadow()
    }

    /// Moves only the highlight and name while preserving all candidate positions.
    private func updateSelection() {
        for (index, card) in cards.enumerated() {
            card.layer?.backgroundColor = index == selectedIndex
                ? NSColor.black.withAlphaComponent(0.14).cgColor
                : NSColor.clear.cgColor
        }
        guard let title = selectedTitle, let root = contentView else { return }
        let card = cards[selectedIndex]
        title.stringValue = candidates[selectedIndex].displayName
        let titleWidth = min(max(card.frame.width, title.intrinsicContentSize.width + 8), root.bounds.width - 8)
        let titleX = min(max(4, card.frame.midX - titleWidth / 2), root.bounds.width - titleWidth - 4)
        // Align the native text field to backing pixels even when candidate cards are scaled.
        title.frame = root.backingAlignedRect(
            NSRect(x: titleX, y: card.frame.maxY + 3, width: titleWidth, height: 20),
            options: .alignAllEdgesNearest
        )
    }
}

/// Menu bar application that owns the switcher lifecycle and recovery controls.
private final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Running application catalog and preferences.
    private let catalog = ApplicationCatalog()
    /// Candidate panel shared by keyboard handlers.
    private let panel = SwitcherPanel()
    /// Custom keyboard shortcut controller.
    private var hotkeys: HotkeyController!
    /// Settings window retained while the application runs.
    private var settings: SettingsWindowController!
    /// Menu bar item used to access settings and recovery.
    private var statusItem: NSStatusItem!
    /// Menu item displaying the currently saved shortcut.
    private var shortcutMenuItem: NSMenuItem!
    /// Polls for permission recovery without repeatedly prompting or registering an active shortcut.
    private var recoveryTimer: Timer?
    /// Records explicit menu intent so automatic recovery respects "Disable shortcut".
    private var wantsShortcut = true
    /// Bounds retries after registration failures while Accessibility is available.
    private var nextRetry = Date.distantPast
    /// Exponential backoff between failed registrations, capped at thirty seconds.
    private var retryDelay: TimeInterval = 2

    /// Creates UI, requests Accessibility permission, then attempts safe takeover.
    func applicationDidFinishLaunching(_ notification: Notification) {
        hotkeys = HotkeyController(panel: panel, catalog: catalog)
        settings = SettingsWindowController(catalog: catalog, hotkeys: hotkeys)
        settings.onShortcutChanged = { [weak self] in
            // Applying a shortcut explicitly enables it, including subsequent automatic recovery.
            self?.wantsShortcut = true
            self?.nextRetry = .distantPast
            self?.refreshShortcutMenu()
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⌘⇥"
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        shortcutMenuItem = NSMenuItem(title: "Shortcut: \(hotkeys.currentShortcut.displayName)", action: nil, keyEquivalent: "")
        menu.addItem(shortcutMenuItem)
        menu.addItem(NSMenuItem(title: "Enable shortcut", action: #selector(enable), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Disable shortcut", action: #selector(restore), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        for item in menu.items { item.target = self }
        statusItem.menu = menu
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        recoverShortcutIfNeeded()
        recoveryTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.recoverShortcutIfNeeded()
        }
        recoveryTimer?.tolerance = 0.5
    }

    /// Restores native switching before the application terminates normally.
    func applicationWillTerminate(_ notification: Notification) {
        recoveryTimer?.invalidate()
        hotkeys.stop()
    }

    /// Restores takeover after permission becomes available, with bounded registration retries.
    private func recoverShortcutIfNeeded() {
        guard wantsShortcut else { return }
        guard AXIsProcessTrusted() else {
            if hotkeys.isEnabled {
                log.warning("Accessibility access lost; restoring system shortcut while waiting")
                hotkeys.stop()
            }
            nextRetry = .distantPast
            retryDelay = 2
            return
        }
        guard !hotkeys.isEnabled, Date() >= nextRetry else { return }
        if hotkeys.start() {
            retryDelay = 2
            log.info("Saved shortcut enabled after startup or permission recovery")
        } else {
            nextRetry = Date().addingTimeInterval(retryDelay)
            retryDelay = min(retryDelay * 2, 30)
            log.warning("Shortcut registration unavailable; automatic retry scheduled")
        }
    }

    /// Opens the per-application settings window.
    @objc private func openSettings() { settings.present() }

    /// Keeps the menu description synchronized after a saved shortcut change.
    private func refreshShortcutMenu() {
        shortcutMenuItem.title = "Shortcut: \(hotkeys.currentShortcut.displayName)"
    }

    /// Retries takeover after permission is granted.
    @objc private func enable() {
        wantsShortcut = true
        nextRetry = .distantPast
        recoverShortcutIfNeeded()
        if !hotkeys.isEnabled { NSSound.beep() }
    }

    /// Restores system shortcuts and disables the replacement handlers.
    @objc private func restore() {
        wantsShortcut = false
        hotkeys.stop()
    }

    /// Quits through the regular lifecycle so restoration runs first.
    @objc private func quit() { NSApp.terminate(nil) }
}

/// Restores the native shortcuts without launching the GUI, for emergency recovery.
private func restoreFromCommandLine() {
    let restored = NativeShortcutControl().setSystemSwitcherEnabled(true)
    fputs(restored ? "System Command-Tab restored.\n" : "Unable to restore system Command-Tab.\n", stderr)
    exit(restored ? 0 : 1)
}

/// Starts the menu bar app or its explicit shortcut recovery command.
@main
private enum CommandTabLiteMain {
    /// Keeps the delegate alive for the complete AppKit event loop.
    static func main() {
        if CommandLine.arguments.contains("--restore-system-shortcuts") { restoreFromCommandLine() }
        let instance = SingleInstanceGuard()
        guard instance.acquire() else { return }
        let application = NSApplication.shared
        let delegate = AppDelegate()
        application.delegate = delegate
        withExtendedLifetime((delegate, instance)) { application.run() }
    }
}
