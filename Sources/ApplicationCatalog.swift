import AppKit
import ApplicationServices
import OSLog

/// Controls when a running application participates in the switcher.
enum VisibilityRule: Int, CaseIterable {
    /// Includes a running application whether or not it currently has a window.
    case always = 0
    /// Requires at least one accessible standard window, including minimized windows.
    case withWindow = 1
    /// Excludes the application; value 2 is reserved for migration from the removed policy.
    case never = 3

    /// Chinese label shown in the configuration window.
    var title: String {
        switch self {
        case .always: return "始终显示"
        case .withWindow: return "仅有窗口时显示"
        case .never: return "不参与切换"
        }
    }
}

/// Persists visibility and window grouping independently for each bundle identifier.
final class RuleStore {
    /// Existing preference key retained for compatibility with earlier versions.
    private let visibilityKey = "ApplicationVisibilityRules"
    /// Preference key containing applications whose windows appear separately.
    private let splittingKey = "ApplicationWindowSplitting"
    /// Preference domain used for both loading and saving settings.
    private let defaults: UserDefaults
    /// Explicit visibility rules, including applications that are currently closed.
    private(set) var rules: [String: VisibilityRule]
    /// Explicit window grouping choices, retained when applications exit.
    private var splitting: [String: Bool]

    /// Loads preferences and permanently migrates the removed windowless-only policy to always visible.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        var saved = defaults.dictionary(forKey: visibilityKey) as? [String: Int] ?? [:]
        let migratedCount = saved.values.filter { $0 == 2 }.count
        if migratedCount > 0 {
            // Preserve the remaining stable identifiers and unknown values while updating only the retired policy.
            saved = saved.mapValues { $0 == 2 ? VisibilityRule.always.rawValue : $0 }
            defaults.set(saved, forKey: visibilityKey)
            log.info("Migrated \(migratedCount) windowless-only visibility rules to always visible")
        }
        rules = saved.compactMapValues(VisibilityRule.init(rawValue:))
        splitting = defaults.dictionary(forKey: splittingKey) as? [String: Bool] ?? [:]
    }

    /// Returns the application's saved visibility rule or the default rule.
    func rule(for bundleID: String) -> VisibilityRule {
        rules[bundleID] ?? .always
    }

    /// Saves a visibility change immediately to the application's preferences domain.
    func set(_ rule: VisibilityRule, for bundleID: String) {
        rules[bundleID] = rule
        defaults.set(rules.mapValues(\.rawValue), forKey: visibilityKey)
        log.info("Saved application visibility rule: \(bundleID, privacy: .public), rule=\(rule.rawValue)")
    }

    /// Returns whether individual windows should have separate candidate cards.
    func splitWindows(for bundleID: String) -> Bool {
        splitting[bundleID] ?? false
    }

    /// Saves the application's window grouping choice independently of visibility.
    func setSplitWindows(_ enabled: Bool, for bundleID: String) {
        splitting[bundleID] = enabled
        defaults.set(splitting, forKey: splittingKey)
        log.info("Saved application window splitting: \(bundleID, privacy: .public), enabled=\(enabled)")
    }
}

/// Orders candidates from visible windows through minimized windows to windowless applications.
enum CandidatePriority: Int {
    /// At least one normal window is available, or its accessibility state is unknown.
    case normal = 0
    /// This window, or every window of an unsplit application, is minimized.
    case minimized = 1
    /// The application has a confirmed empty standard-window list.
    case windowless = 2
}

/// One selectable application or a specific accessible window of that application.
struct SwitcherCandidate {
    /// Invalidates delayed window work when a newer candidate is activated on the main thread.
    private static var activationGeneration: UInt64 = 0
    /// Running process that owns this candidate.
    let application: NSRunningApplication
    /// Exact accessibility window when the application's windows are split.
    let window: AXUIElement?
    /// Application name, optionally followed by a window title, for presentation only.
    let displayName: String
    /// Workspace-provided application icon.
    var icon: NSImage? { application.icon }
    /// Stable identifier used for settings and non-sensitive diagnostics.
    var bundleIdentifier: String? { application.bundleIdentifier }
    /// Whether this candidate represents the foreground application or focused window.
    let isCurrent: Bool
    /// Snapshot grouping calculated at invocation time; split windows carry their own priority.
    var priority: CandidatePriority = .normal
    /// Whether the current foreground candidate must yield initial Tab navigation to a normal candidate.
    var shouldSortLast: Bool { priority != .normal }

    /// Begins activation; a true return means a request was issued, not that a window is visible.
    @discardableResult
    func activate() -> Bool {
        Self.activationGeneration &+= 1
        let generation = Self.activationGeneration
        guard !application.isTerminated else {
            log.warning("Cannot activate a terminated candidate")
            return false
        }
        let element = AXUIElementCreateApplication(application.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        // Unhide first so hidden-and-minimized windows can respond to restoration.
        if application.isHidden, !application.unhide() {
            log.warning("Application could not be unhidden before activation")
        }
        let target = window ?? preferredWindow(in: element)
        // An empty AX window list needs a reopen event; activation alone cannot recreate a closed window.
        if window == nil, target == nil, hasNoWindows(in: element) {
            return reopenApplication()
        }
        let needsRestoration = target.map { minimizedState($0) == true } ?? false
        if let target {
            AXUIElementSetMessagingTimeout(target, 0.15)
            restoreIfMinimized(target)
        }
        let accepted = application.activate(options: [])
        guard accepted else {
            log.error("Application rejected the activation request")
            return false
        }
        guard let target else {
            log.info("Application activation requested without an accessible window")
            return true
        }
        bringForward(target, in: element)
        // Dock animations may finish after the first AX request; verify with bounded retries.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.verifyRestoration(target, in: element, generation: generation, needsRestoration: needsRestoration, retriesRemaining: 2)
        }
        log.info("Window activation requested; restoration verification pending")
        return true
    }

    /// Confirms an empty unfiltered window list, keeping failed reads and auxiliary windows distinct.
    private func hasNoWindows(in element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard status == .success, let windows = value as? [AXUIElement] else {
            log.warning("Cannot confirm a windowless application: AX error \(status.rawValue)")
            return false
        }
        return windows.isEmpty
    }

    /// Asks Launch Services to reopen the existing application, as opening its Dock icon would.
    private func reopenApplication() -> Bool {
        guard let url = application.bundleURL else {
            log.error("Cannot reopen an application without its bundle URL")
            return application.activate(options: [])
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.createsNewApplicationInstance = false
        configuration.addsToRecentItems = false
        configuration.promptsUserIfNeeded = false
        // Let the application handle reopening; do not create documents or activate again in the callback.
        NSWorkspace.shared.openApplication(at: url, configuration: configuration) { reopened, error in
            if let error {
                let systemError = error as NSError
                log.error("Application reopen failed: domain=\(systemError.domain, privacy: .public), code=\(systemError.code)")
            } else if reopened != nil {
                log.info("Application reopen request accepted")
            } else {
                log.warning("Application reopen completed without a running application")
            }
        }
        log.info("Application reopen requested after confirming zero windows")
        return true
    }

    /// Prefers an existing visible focused/main window, restoring only one when all are minimized.
    private func preferredWindow(in element: AXUIElement) -> AXUIElement? {
        guard let windows = ApplicationCatalog.standardWindows(of: application), !windows.isEmpty else {
            return nil
        }
        let visible = windows.filter { minimizedState($0) == false }
        let eligible = visible.isEmpty ? windows : visible
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
               let value, let matching = eligible.first(where: { CFEqual($0, value) }) {
                return matching
            }
        }
        return eligible.first
    }

    /// Reads minimization without treating a failed AX read as a restored window.
    private func minimizedState(_ target: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, kAXMinimizedAttribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    /// Restores only the chosen window and records failure without exposing its title.
    private func restoreIfMinimized(_ target: AXUIElement) {
        guard minimizedState(target) == true else { return }
        let result = AXUIElementSetAttributeValue(target, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        if result == .success {
            log.debug("Minimized window restoration requested")
        } else {
            log.warning("Window restoration request failed: AX error \(result.rawValue)")
        }
    }

    /// Attempts the supported main, focus, and raise operations for the selected window.
    private func bringForward(_ target: AXUIElement, in element: AXUIElement) {
        let mainResult = AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, kCFBooleanTrue)
        let focusResult = AXUIElementSetAttributeValue(element, kAXFocusedWindowAttribute as CFString, target)
        let raiseResult = AXUIElementPerformAction(target, kAXRaiseAction as CFString)
        log.debug("Window activation AX results: main=\(mainResult.rawValue), focus=\(focusResult.rawValue), raise=\(raiseResult.rawValue)")
        if raiseResult != .success {
            log.warning("Selected window could not be raised: AX error \(raiseResult.rawValue)")
        }
    }

    /// Verifies after animation and retries at most twice without reactivating an abandoned app.
    private func verifyRestoration(_ target: AXUIElement, in element: AXUIElement, generation: UInt64, needsRestoration: Bool, retriesRemaining: Int) {
        guard generation == Self.activationGeneration else {
            log.debug("Obsolete window restoration verification cancelled")
            return
        }
        guard !application.isTerminated else {
            log.warning("Window restoration verification stopped because the application exited")
            return
        }
        guard application.isActive else {
            log.debug("Window restoration verification stopped because the application is no longer active")
            return
        }
        guard let minimized = minimizedState(target) else {
            log.warning("Selected window disappeared or its minimized state is unavailable")
            return
        }
        if !minimized {
            // Only restored windows need a second raise after the Dock animation.
            if needsRestoration { bringForward(target, in: element) }
            log.info("Selected window verified as not minimized")
            return
        }
        guard retriesRemaining > 0 else {
            log.error("Selected window remains minimized after bounded restoration attempts")
            return
        }
        restoreIfMinimized(target)
        bringForward(target, in: element)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
            self.verifyRestoration(target, in: element, generation: generation, needsRestoration: needsRestoration, retriesRemaining: retriesRemaining - 1)
        }
    }

}

/// Tracks recent applications and creates candidates using persistent per-app policies.
final class ApplicationCatalog {
    /// Per-application preferences shared with the configuration interface.
    let ruleStore: RuleStore
    /// Application identifiers ordered by their latest activation.
    private var recentBundleIDs: [String] = []
    /// Observer retained while the catalog tracks foreground application changes.
    private var activationObserver: NSObjectProtocol?

    /// Window and application usage share one clock so split entries can interleave across apps.
    private let recency = CandidateRecency()
    /// Observes focus changes in the foreground process without subscribing to every background app.
    private var focusObserver: AXObserver?
    /// Process currently connected to the focus observer.
    private var observedPID: pid_t?
    /// Retries after permission recovery and covers applications that omit focus notifications.
    private var focusTimer: Timer?

    /// Initializes settings and begins observing application activation order.
    init(ruleStore: RuleStore = RuleStore()) {
        self.ruleStore = ruleStore
        if let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            recentBundleIDs = [frontID]
        }
        activationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let id = app.bundleIdentifier else { return }
            self?.recordActivation(id)
            self?.observeForegroundFocus()
        }
        observeForegroundFocus()
        focusTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.observeForegroundFocus()
        }
        focusTimer?.tolerance = 0.1
    }

    /// Removes the workspace observer when this catalog is released.
    deinit {
        focusTimer?.invalidate()
        if let focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
        }
        if let activationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationObserver)
        }
    }

    /// Updates the recent application order without changing an open candidate panel.
    private func recordActivation(_ id: String) {
        recentBundleIDs.removeAll { $0 == id }
        recentBundleIDs.insert(id, at: 0)
    }

    /// Samples actual foreground focus; merely highlighting a candidate never changes usage history.
    private func observeForegroundFocus() {
        guard AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        let pid = app.processIdentifier
        if observedPID != pid || focusObserver == nil {
            if let focusObserver {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes)
            }
            focusObserver = nil
            observedPID = pid
            var observer: AXObserver?
            let status = AXObserverCreate(pid, { _, _, _, context in
                guard let context else { return }
                let catalog = Unmanaged<ApplicationCatalog>.fromOpaque(context).takeUnretainedValue()
                catalog.observeForegroundFocus()
            }, &observer)
            if status == .success, let observer {
                let element = AXUIElementCreateApplication(pid)
                AXUIElementSetMessagingTimeout(element, 0.15)
                let result = AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString,
                    Unmanaged.passUnretained(self).toOpaque())
                if result != .success {
                    log.debug("Focus notification unavailable; using sampling: pid=\(pid), AX error=\(result.rawValue)")
                }
                focusObserver = observer
                CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        recency.record(app: app, window: focusedWindow(of: app))
    }

    /// Returns all eligible processes; window collection must retain every process of an application.
    func runningApplications() -> [NSRunningApplication] {
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let ownID = Bundle.main.bundleIdentifier
        return NSWorkspace.shared.runningApplications.filter { app in
            // Exclude this process and background helpers regardless of user preferences.
            app.activationPolicy == .regular && !app.isTerminated && app.processIdentifier != ownPID
                && (ownID == nil || app.bundleIdentifier != ownID)
        }.sorted { lhs, rhs in
            let left = recentBundleIDs.firstIndex(of: lhs.bundleIdentifier ?? "") ?? Int.max
            let right = recentBundleIDs.firstIndex(of: rhs.bundleIdentifier ?? "") ?? Int.max
            if left != right { return left < right }
            return (lhs.localizedName ?? "").localizedStandardCompare(rhs.localizedName ?? "") == .orderedAscending
        }
    }

    /// Builds one snapshot in normal, minimized, then windowless priority while preserving ties.
    func candidates() -> [SwitcherCandidate] {
        observeForegroundFocus()
        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let snapshot = runningApplications().flatMap { app -> [SwitcherCandidate] in
            let bundleID = app.bundleIdentifier ?? ""
            let rule = ruleStore.rule(for: bundleID)
            guard rule != .never else { return [] }
            let split = ruleStore.splitWindows(for: bundleID)
            // Read each application's window list once for filtering, splitting, and ordering.
            let inventory = Self.windowInventory(of: app)
            let windows = inventory.windows
            if let windows { recency.pruneWindows(of: app, keeping: windows, complete: inventory.isComplete) }
            if rule == .withWindow, windows?.isEmpty != false { return [] }
            let appName = app.localizedName ?? bundleID
            let isFront = app.processIdentifier == frontPID
            guard split, let windows, !windows.isEmpty else {
                // Confirm an empty list before assigning the last group; incomplete or unreadable state remains normal.
                let priority: CandidatePriority
                if inventory.isComplete, windows?.isEmpty == true {
                    priority = .windowless
                } else if inventory.isComplete, windows.map({ $0.allSatisfy { Self.isMinimized($0) == true } }) == true {
                    // Stop after the first normal or unreadable window; only every minimized window qualifies.
                    priority = .minimized
                } else {
                    priority = .normal
                }
                return [SwitcherCandidate(application: app, window: nil, displayName: appName,
                                          isCurrent: isFront, priority: priority)]
            }
            let focused = isFront ? focusedWindow(of: app) : nil
            var result = windows.enumerated().map { index, window in
                let title = windowTitle(window)
                let label = title.isEmpty ? "窗口 \(index + 1)" : title
                let current = isFront && focused.map { CFEqual(window, $0) } == true
                return SwitcherCandidate(application: app, window: window,
                                         displayName: "\(appName) — \(label)", isCurrent: current,
                                         priority: Self.isMinimized(window) == true ? .minimized : .normal)
            }
            if let currentIndex = result.firstIndex(where: \.isCurrent), currentIndex != 0 {
                // Order only the new snapshot, preserving every other window's AX order.
                let current = result.remove(at: currentIndex)
                result.insert(current, at: 0)
            }
            // If focused-window information is unavailable, keep only real window candidates.
            return result
        }
        // Sort after merging processes, otherwise merging would regroup recently used windows by app.
        let candidates = Self.consolidateProcesses(snapshot)
        recency.prune(among: NSWorkspace.shared.runningApplications)
        return recency.sorted(candidates)
    }

    /// Groups processes by the same identifier used to persist application rules.
    private static func applicationKey(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier.map { "bundle:\($0)" } ?? "pid:\(app.processIdentifier)"
    }

    /// Returns one settings row per application without removing processes from window collection.
    static func uniqueApplications(_ applications: [NSRunningApplication]) -> [NSRunningApplication] {
        var seen = Set<String>()
        return applications.filter { seen.insert(applicationKey($0)).inserted }
    }

    /// Merges process-level candidates while retaining the owner of every split window.
    static func consolidateProcesses(_ candidates: [SwitcherCandidate]) -> [SwitcherCandidate] {
        var groups: [String: [SwitcherCandidate]] = [:]
        var order: [String] = []
        for candidate in candidates {
            let key = applicationKey(candidate.application)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(candidate)
        }
        let result = order.flatMap { key -> [SwitcherCandidate] in
            let group = groups[key]!
            let windows = group.filter { $0.window != nil }
            // Split applications show real windows from every process, without empty-process placeholders.
            if !windows.isEmpty { return windows }
            // App-level entries prefer a process with an expanded window, then a minimized window.
            // When all processes are windowless, keep one entry for the saved "always" policy.
            let representative = group.dropFirst().reduce(group[0]) { best, candidate in
                if candidate.priority.rawValue < best.priority.rawValue { return candidate }
                if candidate.priority == best.priority && candidate.isCurrent { return candidate }
                return best
            }
            return [representative]
        }
        log.debug("Consolidated process candidates: \(candidates.count) entries into \(result.count) application/window candidates")
        return result
    }

    /// Stably partitions individual candidates into three priorities without changing their intra-group order.
    static func prioritizeOpenWindows(_ candidates: [SwitcherCandidate]) -> [SwitcherCandidate] {
        var normal: [SwitcherCandidate] = []
        var minimized: [SwitcherCandidate] = []
        var windowless: [SwitcherCandidate] = []
        for candidate in candidates {
            switch candidate.priority {
            case .normal: normal.append(candidate)
            case .minimized: minimized.append(candidate)
            case .windowless: windowless.append(candidate)
            }
        }
        log.debug("Candidate snapshot grouped: normal=\(normal.count), minimized=\(minimized.count), windowless=\(windowless.count)")
        return normal + minimized + windowless
    }

    /// Reads one window's minimized state without classifying an accessibility failure as minimized.
    private static func isMinimized(_ window: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &value)
        guard result == .success, let minimized = value as? Bool else {
            log.warning("Window minimized state unavailable for ordering: AX error \(result.rawValue)")
            return nil
        }
        return minimized
    }

    /// Reads standard application windows, including minimized windows and other Spaces when exposed.
    fileprivate static func standardWindows(of app: NSRunningApplication) -> [AXUIElement]? {
        windowInventory(of: app).windows
    }

    /// Preserves classification failures separately from known windows, preventing false whole-app minimization.
    private static func windowInventory(of app: NSRunningApplication) -> (windows: [AXUIElement]?, isComplete: Bool) {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXWindowsAttribute as CFString, &value)
        guard result == .success, let windows = value as? [AXUIElement] else {
            log.warning("Window state unavailable for \(app.bundleIdentifier ?? "unknown", privacy: .public): AX error \(result.rawValue)")
            return (nil, false)
        }
        // Some full-screen applications expose no AXWindows while their focused/main window remains accessible.
        let fallback = windows.isEmpty ? focusedStandardWindows(in: element) : []
        let discovered = windows.isEmpty ? fallback : windows
        var standard: [AXUIElement] = []
        // Missing subroles are common in third-party apps; distinguish that from an unreachable window.
        var hasUnknownWindow = false
        for window in discovered {
            AXUIElementSetMessagingTimeout(window, 0.15)
            var subrole: CFTypeRef?
            let status = AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
            if status == .success, let name = subrole as? String {
                if name == kAXStandardWindowSubrole { standard.append(window) }
                continue
            }
            var role: CFTypeRef?
            let roleStatus = AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
            if roleStatus == .success, let name = role as? String {
                if name == kAXWindowRole { standard.append(window) }
            } else {
                hasUnknownWindow = true
                log.warning("Window classification unavailable: AX error \(roleStatus.rawValue)")
            }
        }
        // A focused-window fallback proves presence, but cannot prove this is the complete window list.
        return (standard.isEmpty && hasUnknownWindow ? nil : standard, !hasUnknownWindow && fallback.isEmpty)
    }

    /// Recovers valid focused/main standard windows when a full-screen app reports an empty AXWindows list.
    private static func focusedStandardWindows(in element: AXUIElement) -> [AXUIElement] {
        var recovered: [AXUIElement] = []
        for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                  let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { continue }
            let window = unsafeBitCast(value, to: AXUIElement.self)
            guard !recovered.contains(where: { CFEqual($0, window) }) else { continue }
            AXUIElementSetMessagingTimeout(window, 0.15)
            var role: CFTypeRef?
            var subrole: CFTypeRef?
            var minimized: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role) == .success,
                  role as? String == kAXWindowRole,
                  AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole) == .success,
                  subrole as? String == kAXStandardWindowSubrole,
                  AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized) == .success,
                  minimized is Bool else { continue }
            recovered.append(window)
        }
        if !recovered.isEmpty {
            log.info("Recovered \(recovered.count) standard full-screen window references outside AXWindows")
        }
        return recovered
    }

    /// Resolves the focused window to seed selection at the current window's position.
    private func focusedWindow(of app: NSRunningApplication) -> AXUIElement? {
        let element = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(element, 0.15)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXFocusedWindowAttribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeBitCast(value, to: AXUIElement.self)
    }

    /// Reads a title for on-screen disambiguation without writing it to diagnostics.
    private func windowTitle(_ window: AXUIElement) -> String {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &value) == .success else { return "" }
        return (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}
