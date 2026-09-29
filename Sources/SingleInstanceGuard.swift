import AppKit
import Darwin
import Foundation

/// Holds a per-user process lock across application copies and releases it automatically on exit.
final class SingleInstanceGuard {
    /// Open descriptor owning the advisory lock for this process's lifetime.
    private var descriptor: Int32 = -1

    /// Rejects an already-running copy before creating menus or touching system shortcuts.
    func acquire() -> Bool {
        guard descriptor == -1 else { return true }
        let identifier = Bundle.main.bundleIdentifier ?? "local.commandtablite"
        let current = NSRunningApplication.current
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .filter {
                guard $0.processIdentifier != getpid(), !$0.isTerminated else { return false }
                // Deterministic precedence prevents two simultaneous launches from both yielding.
                if let otherDate = $0.launchDate, let currentDate = current.launchDate, otherDate != currentDate {
                    return otherDate < currentDate
                }
                return $0.processIdentifier < current.processIdentifier
            }
        // Older installed builds do not hold our lock, so also detect those running copies.
        if !peers.isEmpty {
            log.info("Another application copy is running; duplicate startup canceled")
            return false
        }
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory,
                in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent(identifier, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("instance.lock").path
            let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            // A nonblocking kernel lock prevents simultaneous launches from both owning the shortcut.
            guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
                let failure = errno
                close(fd)
                if failure == EWOULDBLOCK {
                    log.info("Another copy holds the startup lock; duplicate startup canceled")
                } else {
                    log.error("Cannot acquire startup lock: errno=\(failure)")
                }
                return false
            }
            descriptor = fd
            log.info("Acquired single-instance startup lock")
            return true
        } catch {
            log.error("Cannot prepare single-instance lock: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    /// Closes the descriptor without unlinking the file, preserving lock identity for future launches.
    deinit {
        if descriptor >= 0 { close(descriptor) }
    }
}
