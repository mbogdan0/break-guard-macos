import AppKit

@MainActor
final class SleepWakeManager {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }

    @objc private func willSleep() { appState?.handleSleepOrInactive() }
    @objc private func didWake() { appState?.handleWakeOrActive() }
    @objc private func sessionInactive() { appState?.handleSleepOrInactive() }
    @objc private func sessionActive() { appState?.handleWakeOrActive() }
    @objc private func screensChanged() { appState?.startBreakIfDue() }
}
