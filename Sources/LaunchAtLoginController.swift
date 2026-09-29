import Foundation
import CoreServices
import OSLog
import ServiceManagement

/// Combines modern registration with legacy login items left by earlier installations.
final class LaunchAtLoginController {
    /// New registrations always use Apple's current service management API.
    private let service = SMAppService.mainApp
    /// Retained legacy list and matching items from the latest successful system read.
    private var legacyList: LSSharedFileList?
    /// Entries positively identified as belonging to this application.
    private var legacyItems: [LSSharedFileListItem] = []
    /// An incomplete legacy read must never be interpreted as an empty login item list.
    private var legacyReadFailed = false
    /// Last operation failure presented without exposing system paths.
    private(set) var errorDescription: String?

    /// Loads existing registrations before the first settings presentation.
    init() { refresh() }

    /// Legacy session login entries launch automatically even when SMAppService reports unregistered.
    var isEnabled: Bool {
        service.status != .requiresApproval && (service.status == .enabled || !legacyItems.isEmpty)
    }

    /// Pending system approval takes precedence because the same entry can appear in both APIs.
    var requiresApproval: Bool { service.status == .requiresApproval }

    /// Allows the UI to display an indeterminate state instead of falsely reporting disabled.
    var isStatusUnknown: Bool { legacyReadFailed && !isEnabled && !requiresApproval }

    /// Explains the combined registration state rather than a locally saved preference.
    var statusText: String {
        if isEnabled { return "已开启：登录 Mac 后自动启动" }
        if requiresApproval { return "需要在系统设置的“登录项”中允许启动" }
        if legacyReadFailed { return "暂时无法完整读取登录项，请在系统设置中检查" }
        switch service.status {
        case .notRegistered, .notFound: return "未开启"
        case .enabled: return "已开启：登录 Mac 后自动启动"
        case .requiresApproval: return "需要在系统设置的“登录项”中允许启动"
        @unknown default: return "暂时无法读取登录项状态"
        }
    }

    /// Reads only this user's legacy login items using the deprecated public compatibility API.
    private func readLegacyItems() {
        legacyItems = []
        legacyList = nil
        legacyReadFailed = false
        guard let list = LSSharedFileListCreate(nil, kLSSharedFileListSessionLoginItems.takeUnretainedValue(), nil)?.takeRetainedValue(),
              let snapshot = LSSharedFileListCopySnapshot(list, nil)?.takeRetainedValue() else {
            legacyReadFailed = true
            log.warning("Unable to read legacy login item list")
            return
        }
        legacyList = list
        let currentURL = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let identifier = Bundle.main.bundleIdentifier
        // Avoid disk mounting and user interaction while resolving registrations.
        let flags = LSSharedFileListResolutionFlags(kLSSharedFileListDoNotMountVolumes | kLSSharedFileListNoUserInteraction)
        for item in snapshot as! [LSSharedFileListItem] {
            var resolutionError: Unmanaged<CFError>?
            guard let resolved = LSSharedFileListItemCopyResolvedURL(item, flags, &resolutionError)?.takeRetainedValue() else {
                _ = resolutionError?.takeRetainedValue()
                legacyReadFailed = true
                continue
            }
            let url = (resolved as URL).standardizedFileURL.resolvingSymlinksInPath()
            let sameIdentifier = identifier != nil && Bundle(url: url)?.bundleIdentifier == identifier
            // Never match names: another application may have the same display name.
            if sameIdentifier || url == currentURL { legacyItems.append(item) }
        }
        log.debug("Legacy login items read: matching=\(self.legacyItems.count), incomplete=\(self.legacyReadFailed)")
    }

    /// Applies an explicit user choice without creating a second registration.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        refresh()
        if enabled && (isEnabled || requiresApproval) {
            log.debug("Login item already exists; registration skipped")
            return true
        }
        // Unknown entries could include this application; refuse a blind registration or cleanup.
        guard !legacyReadFailed else {
            errorDescription = "无法完整读取现有登录项，请先在系统设置的“登录项”中检查"
            log.warning("Login item update blocked because system enumeration is incomplete")
            return false
        }
        do {
            if enabled {
                try service.register()
            } else {
                // Remove only positively identified entries belonging to this application.
                if let list = legacyList {
                    for item in legacyItems {
                        let result = LSSharedFileListItemRemove(list, item)
                        guard result == noErr else {
                            throw NSError(domain: NSOSStatusErrorDomain, code: Int(result))
                        }
                    }
                }
                if service.status == .enabled || service.status == .requiresApproval {
                    try service.unregister()
                }
            }
            readLegacyItems()
            let accepted = enabled ? isEnabled || requiresApproval
                : !legacyReadFailed && !isEnabled && !requiresApproval
            if !accepted {
                errorDescription = "系统尚未应用开机自启动设置，请在系统设置中检查"
                log.warning("Login item status does not match requested preference")
            }
            log.info("Login item preference updated: requested=\(enabled), accepted=\(accepted)")
            return accepted
        } catch {
            // A partial removal or pending approval must be reflected immediately in the UI.
            readLegacyItems()
            let systemError = error as NSError
            log.error("Login item update failed: domain=\(systemError.domain, privacy: .public), code=\(systemError.code)")
            if enabled && (isEnabled || requiresApproval) { return true }
            errorDescription = enabled
                ? "无法开启开机自启动，请检查应用签名及系统设置中的登录项"
                : "无法完全关闭开机自启动，请在系统设置的“登录项”中检查"
            return false
        }
    }

    /// Refreshes both registration sources whenever settings becomes active.
    func refresh() {
        errorDescription = nil
        readLegacyItems()
        log.debug("Refreshed login item status: \(self.service.status.rawValue)")
    }

    /// Opens Apple's login items panel for approval or manual inspection.
    func openSystemSettings() {
        log.info("Opening System Settings for login item approval")
        SMAppService.openSystemSettingsLoginItems()
    }
}
