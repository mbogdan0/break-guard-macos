import Foundation
import ServiceManagement
import os

final class LoginItemManager {
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "LoginItem")

    func enable() {
        do {
            try SMAppService.mainApp.register()
            logger.info("Login item registration requested")
        } catch {
            logger.error("Login item registration failed: \(error.localizedDescription)")
        }
    }

    func disable() {
        do {
            try SMAppService.mainApp.unregister()
            logger.info("Login item unregistered")
        } catch {
            logger.error("Login item unregister failed: \(error.localizedDescription)")
        }
    }

    func statusDescription() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            return "Enabled"
        case .notRegistered:
            return "Disabled"
        case .requiresApproval:
            return "Requires Approval"
        case .notFound:
            return "Not Found"
        @unknown default:
            return "Unknown"
        }
    }
}
