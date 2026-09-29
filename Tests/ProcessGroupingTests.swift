import AppKit
import ApplicationServices
import OSLog

/// Supplies the catalog's production logger when compiling this standalone regression executable.
let log = Logger(subsystem: "local.commandtablite.tests", category: "ProcessGrouping")

/// Regression cases for application grouping without changing preferences or activating windows.
@main
enum ProcessGroupingTests {
    /// Creates a candidate with a controlled window state for grouping tests.
    static func candidate(_ app: NSRunningApplication, _ priority: CandidatePriority,
                          window: AXUIElement? = nil, current: Bool = false) -> SwitcherCandidate {
        SwitcherCandidate(application: app, window: window, displayName: "Fixture",
                          isCurrent: current, priority: priority)
    }

    /// Checks deduplication, split-window ownership, priority, and the all-windowless fallback.
    static func main() {
        let app = NSRunningApplication.current
        let empty = candidate(app, .windowless)
        let minimized = candidate(app, .minimized)
        let normal = candidate(app, .normal)
        // Fake AX references are only identity markers; no accessibility operations are performed on them.
        let first = AXUIElementCreateApplication(app.processIdentifier)
        let second = AXUIElementCreateApplication(app.processIdentifier)
        let window = candidate(app, .normal, window: first)
        let minimizedWindow = candidate(app, .minimized, window: second)

        assert(ApplicationCatalog.uniqueApplications([app, app]).count == 1)
        assert(ApplicationCatalog.consolidateProcesses([]).isEmpty)
        assert(ApplicationCatalog.consolidateProcesses([empty, empty]).count == 1)
        assert(ApplicationCatalog.consolidateProcesses([empty, minimized, normal]).first?.priority == .normal)
        assert(ApplicationCatalog.consolidateProcesses([empty, minimized]).first?.priority == .minimized)
        let split = ApplicationCatalog.consolidateProcesses([empty, window, minimizedWindow])
        assert(split.count == 2 && split.allSatisfy { $0.window != nil })
        assert(split[0].window === first && split[1].window === second)
        assert(ApplicationCatalog.consolidateProcesses([normal, candidate(app, .normal, current: true)]).first?.isCurrent == true)
        // A failed window read is an app-level placeholder and must not duplicate known split windows.
        assert(ApplicationCatalog.consolidateProcesses([normal, window]).count == 1)
        let ordered = ApplicationCatalog.prioritizeOpenWindows([minimizedWindow, window, empty])
        assert(ordered.map(\.priority) == [.normal, .minimized, .windowless])
        print("PASS: 10 grouping and ordering regression checks")

        let chrome = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == "com.google.Chrome" }
        if chrome.count >= 2 {
            assert(ApplicationCatalog.uniqueApplications(chrome).count == 1)
            let entries = [candidate(chrome[0], .windowless), candidate(chrome[1], .normal)]
            let merged = ApplicationCatalog.consolidateProcesses(entries)
            assert(merged.count == 1 && merged[0].application.processIdentifier == chrome[1].processIdentifier)
            let splitProcesses = ApplicationCatalog.consolidateProcesses([
                candidate(chrome[0], .normal, window: first),
                candidate(chrome[1], .minimized, window: second), empty
            ])
            assert(splitProcesses.count == 3)
            assert(splitProcesses[0].application.processIdentifier == chrome[0].processIdentifier)
            assert(splitProcesses[1].application.processIdentifier == chrome[1].processIdentifier)
            print("PASS: live Chrome instances share one setting and retain their own window owners")
        } else {
            print("SKIP: multiple live Chrome processes are not available")
        }
    }
}
