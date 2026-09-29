import AppKit
import ApplicationServices

/// Tracks actual focus on a shared monotonic clock for application and individual-window candidates.
final class CandidateRecency {
    /// Retains the process identity as well as the AX reference, avoiding title-based collisions.
    private struct WindowVisit {
        /// Running owner also lets cleanup distinguish terminated processes from reused PIDs.
        let app: NSRunningApplication
        /// Accessibility identity survives changes to a window's title.
        let window: AXUIElement
        /// Latest observed focus sequence.
        var sequence: UInt64
    }
    /// Application-level visits use the same key as persistent application grouping.
    private var applications: [String: UInt64] = [:]
    /// Window history contains only windows actually focused during this session.
    private var windows: [WindowVisit] = []
    /// Monotonic event order is unaffected by wall-clock changes.
    private var sequence: UInt64 = 0
    /// Last focus is retained to deduplicate workspace, AX and timer notifications.
    private var lastApp: NSRunningApplication?
    /// Last successfully observed window used to deduplicate focus callbacks.
    private var lastWindow: AXUIElement?

    /// Matches the catalog's application grouping, with a process fallback for unbundled applications.
    private func key(_ app: NSRunningApplication) -> String {
        app.bundleIdentifier.map { "bundle:\($0)" } ?? "pid:\(app.processIdentifier)"
    }

    /// Records actual foreground focus; missing AX data does not erase a known focus in the same app.
    func record(app: NSRunningApplication, window: AXUIElement?) {
        let sameProcess = lastApp?.processIdentifier == app.processIdentifier && lastApp?.isTerminated == false
        if sameProcess {
            if window == nil { return }
            if let window, let lastWindow, CFEqual(window, lastWindow) { return }
        }
        sequence += 1
        applications[key(app)] = sequence
        lastApp = app
        lastWindow = window
        if let window {
            if let index = windows.firstIndex(where: {
                !$0.app.isTerminated && $0.app.processIdentifier == app.processIdentifier && CFEqual($0.window, window)
            }) {
                windows[index].sequence = sequence
            } else {
                windows.append(WindowVisit(app: app, window: window, sequence: sequence))
            }
        }
        log.debug("Recorded foreground usage: pid=\(app.processIdentifier), window=\(window != nil), sequence=\(self.sequence)")
    }

    /// Removes closed windows only after a complete inventory; partial full-screen reads must retain history.
    func pruneWindows(of app: NSRunningApplication, keeping current: [AXUIElement], complete: Bool) {
        guard complete else { return }
        // Allow a restored AX reference to be recorded again after an app briefly reports no windows.
        if lastApp?.processIdentifier == app.processIdentifier, let lastWindow,
           !current.contains(where: { CFEqual(lastWindow, $0) }) {
            self.lastWindow = nil
        }
        windows.removeAll { visit in
            visit.app.processIdentifier == app.processIdentifier && !current.contains { CFEqual(visit.window, $0) }
        }
    }

    /// Removes exited processes and application records with no remaining running owner.
    func prune(among running: [NSRunningApplication]) {
        let liveKeys = Set(running.filter { !$0.isTerminated }.map(key))
        applications = applications.filter { liveKeys.contains($0.key) }
        windows.removeAll { $0.app.isTerminated }
        if lastApp?.isTerminated == true { lastApp = nil; lastWindow = nil }
    }

    /// Looks up an exact window; unvisited split windows must not inherit their sibling's app recency.
    private func rank(_ candidate: SwitcherCandidate) -> UInt64 {
        guard let window = candidate.window else { return applications[key(candidate.application)] ?? 0 }
        return windows.first(where: {
            !$0.app.isTerminated && $0.app.processIdentifier == candidate.application.processIdentifier && CFEqual($0.window, window)
        })?.sequence ?? 0
    }

    /// Preserves normal/minimized/windowless groups, then interleaves entries by actual usage within each group.
    func sorted(_ candidates: [SwitcherCandidate]) -> [SwitcherCandidate] {
        let ranked = candidates.enumerated().map { (index: $0.offset, candidate: $0.element, rank: rank($0.element)) }
        return ranked.sorted {
            if $0.candidate.priority != $1.candidate.priority { return $0.candidate.priority.rawValue < $1.candidate.priority.rawValue }
            if $0.rank != $1.rank { return $0.rank > $1.rank }
            // Stable fallback preserves existing order until an unknown window is actually focused.
            return $0.index < $1.index
        }.map(\.candidate)
    }
}
