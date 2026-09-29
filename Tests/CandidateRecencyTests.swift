import AppKit
import ApplicationServices
import OSLog

/// Standalone regression logger; tests never activate apps or edit user preferences.
let log = Logger(subsystem: "local.commandtablite.tests", category: "CandidateRecency")

/// Exercises history and ordering with distinct AX identity markers, never queried as real windows.
@main
enum CandidateRecencyTests {
    /// Creates a named fixture with controlled priority and accessibility identity.
    static func candidate(_ name: String, app: NSRunningApplication, window: AXUIElement?,
                          priority: CandidatePriority = .normal) -> SwitcherCandidate {
        SwitcherCandidate(application: app, window: window, displayName: name, isCurrent: false, priority: priority)
    }

    /// Verifies independent window history, mixed app/window ordering, deduplication and safe pruning.
    static func main() {
        guard let app = NSWorkspace.shared.runningApplications.first(where: { !$0.isTerminated && $0.bundleIdentifier != nil }) else {
            fatalError("A running application is needed as fixture owner")
        }
        // Distinct elements represent same-owner windows, including windows whose visible titles could match.
        let a = AXUIElementCreateApplication(101)
        let b = AXUIElementCreateApplication(102)
        let c = AXUIElementCreateApplication(103)
        let first = candidate("A", app: app, window: a)
        let second = candidate("B", app: app, window: b)
        let third = candidate("C", app: app, window: c)
        let tracker = CandidateRecency()
        tracker.record(app: app, window: a)
        tracker.record(app: app, window: b)
        tracker.record(app: app, window: c)
        assert(tracker.sorted([first, second, third]).map(\.displayName) == ["C", "B", "A"])
        tracker.record(app: app, window: a)
        assert(tracker.sorted([first, second, third]).map(\.displayName) == ["A", "C", "B"])
        // Missing focus and repeated notifications must not erase known history.
        tracker.record(app: app, window: nil)
        tracker.record(app: app, window: a)
        assert(tracker.sorted([first, second, third]).map(\.displayName) == ["A", "C", "B"])
        let minimized = candidate("A", app: app, window: a, priority: .minimized)
        let empty = candidate("Empty", app: app, window: nil, priority: .windowless)
        assert(tracker.sorted([empty, minimized, second, third]).map(\.displayName) == ["C", "B", "A", "Empty"])
        tracker.pruneWindows(of: app, keeping: [b], complete: false)
        assert(tracker.sorted([first, second, third]).map(\.displayName) == ["A", "C", "B"])
        tracker.pruneWindows(of: app, keeping: [b], complete: true)
        assert(tracker.sorted([first, second, third]).map(\.displayName) == ["B", "A", "C"])
        tracker.record(app: app, window: a)
        assert(tracker.sorted([second, first, third]).map(\.displayName) == ["A", "B", "C"])
        // Stable unknown entries do not acquire the last-used sibling's rank.
        let fresh = CandidateRecency()
        assert(fresh.sorted([third, first, second]).map(\.displayName) == ["C", "A", "B"])
        // Another real owner provides a distinct bundle key; no windows are activated or queried.
        guard let other = NSWorkspace.shared.runningApplications.first(where: {
            !$0.isTerminated && $0.bundleIdentifier != app.bundleIdentifier
        }) else { fatalError("A second running app is needed for cross-app fixtures") }
        let interleaved = CandidateRecency()
        let otherWindow = candidate("Other", app: other, window: b)
        interleaved.record(app: app, window: a)
        interleaved.record(app: other, window: b)
        interleaved.record(app: app, window: c)
        assert(interleaved.sorted([first, third, otherWindow]).map(\.displayName) == ["C", "Other", "A"])
        let unsplit = candidate("Unsplit", app: app, window: nil)
        assert(interleaved.sorted([otherWindow, unsplit]).map(\.displayName) == ["Unsplit", "Other"])
        interleaved.record(app: other, window: b)
        assert(interleaved.sorted([unsplit, otherWindow]).map(\.displayName) == ["Other", "Unsplit"])
        // Repeated sampling leaves the shared rank tied between an app and its current window.
        let tied = candidate("Other app", app: other, window: nil)
        interleaved.record(app: other, window: b)
        assert(interleaved.sorted([tied, otherWindow]).map(\.displayName) == ["Other app", "Other"])
        print("PASS: 12 window recency, cross-app, priority and cleanup regressions")
    }
}
