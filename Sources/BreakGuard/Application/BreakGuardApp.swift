import AppKit
import SwiftUI
import os

@main
final class BreakGuardApp: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var menuBarController: MenuBarController!
    private var sleepWakeManager: SleepWakeManager!
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "Lifecycle")

    static func main() {
        let app = NSApplication.shared
        let delegate = BreakGuardApp()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        logger.info("Application did finish launching")
        appState = AppState(
            persistence: PersistenceStore(),
            notifications: NotificationManager(),
            loginItems: LoginItemManager()
        )
        menuBarController = MenuBarController(appState: appState)
        sleepWakeManager = SleepWakeManager(appState: appState)
        appState.start()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        appState?.stop()
        return .terminateNow
    }
}
