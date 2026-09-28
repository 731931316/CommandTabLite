import Foundation
import OSLog
import ServiceManagement

/// Manages the main application's login item through the system's persistent registration.
final class LaunchAtLoginController {
    /// The main bundle's login item; its status remains authoritative across application launches.
    private let service = SMAppService.mainApp
    /// Last operation failure presented in the settings window, without exposing system paths.
    private(set) var errorDescription: String?

    /// Whether macOS currently allows the application to launch when the user logs in.
    var isEnabled: Bool { service.status == .enabled }

    /// Whether registration exists but still needs the user's approval in System Settings.
    var requiresApproval: Bool { service.status == .requiresApproval }

    /// Explains the actual system registration state in the settings window.
    var statusText: String {
        switch service.status {
        case .enabled:
            return "已开启：登录 Mac 后自动启动"
        case .notRegistered:
            return "未开启"
        case .requiresApproval:
            return "需要在系统设置的“登录项”中允许启动"
        case .notFound:
            return "尚未找到自启动记录，可勾选尝试开启"
        @unknown default:
            return "暂时无法读取登录项状态"
        }
    }

    /// Applies an explicit user choice and reports whether the system accepted the request.
    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        errorDescription = nil
        let previousStatus = service.status
        // A pending registration must be approved by the user, rather than registered again.
        if enabled && (previousStatus == .enabled || previousStatus == .requiresApproval) {
            log.debug("Login item already registered; status=\(previousStatus.rawValue)")
            return true
        }
        if !enabled && (previousStatus == .notRegistered || previousStatus == .notFound) {
            log.debug("Login item is already disabled; status=\(previousStatus.rawValue)")
            return true
        }
        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
            let currentStatus = service.status
            log.info("Login item preference updated: requested=\(enabled), status=\(currentStatus.rawValue)")
            if currentStatus == .requiresApproval {
                log.warning("Login item needs approval in System Settings")
            }
            // Re-read macOS status; never display a local preference as successful registration.
            let accepted = enabled
                ? currentStatus == .enabled || currentStatus == .requiresApproval
                : currentStatus == .notRegistered || currentStatus == .notFound
            if !accepted {
                errorDescription = "系统尚未应用开机自启动设置，请稍后重试"
                log.warning("Login item status does not match requested preference")
            }
            return accepted
        } catch {
            let systemError = error as NSError
            log.error("Login item update failed: domain=\(systemError.domain, privacy: .public), code=\(systemError.code)")
            if service.status == .requiresApproval && enabled {
                // macOS can return a denied error while retaining a registration awaiting consent.
                log.warning("Login item registration awaits user approval")
                return true
            }
            errorDescription = enabled
                ? "无法开启开机自启动，请检查应用签名及系统设置中的登录项"
                : "无法关闭开机自启动，请在系统设置的“登录项”中检查"
            return false
        }
    }

    /// Discards stale operation errors when reopening settings; all status values are read live.
    func refresh() {
        errorDescription = nil
        log.debug("Refreshed login item status: \(self.service.status.rawValue)")
    }

    /// Opens Apple's login items panel after the user chooses to review the required approval.
    func openSystemSettings() {
        log.info("Opening System Settings for login item approval")
        SMAppService.openSystemSettingsLoginItems()
    }
}
