import AppKit

@MainActor
final class SleepWakeManager {
    private weak var appState: AppState?
    private var activity = SessionActivity()

    init(appState: AppState) {
        self.appState = appState
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        center.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionInactive), name: NSWorkspace.sessionDidResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionActive), name: NSWorkspace.sessionDidBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Screen lock does not imply system sleep, so it needs its own
        // observers; locked time counts as rest the same way sleep does.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(self, selector: #selector(screenLocked), name: Notification.Name("com.apple.screenIsLocked"), object: nil)
        distributed.addObserver(self, selector: #selector(screenUnlocked), name: Notification.Name("com.apple.screenIsUnlocked"), object: nil)
        // The screen saver can run before the lock engages (or with the
        // password requirement disabled, without any lock at all); that time
        // is rest, not focus, so it is treated exactly like a lock. When the
        // lock follows the saver, SessionActivity keeps the session inactive
        // until every reason has cleared.
        distributed.addObserver(self, selector: #selector(screenSaverStarted), name: Notification.Name("com.apple.screensaver.didstart"), object: nil)
        distributed.addObserver(self, selector: #selector(screenSaverStopped), name: Notification.Name("com.apple.screensaver.didstop"), object: nil)
    }

    private func set(_ reason: InactiveReason, inactive: Bool) {
        guard activity.set(reason, inactive: inactive) else { return }
        if activity.isInactive {
            appState?.handleSleepOrInactive()
        } else {
            appState?.handleWakeOrActive()
        }
    }

    @objc private func willSleep() { set(.sleep, inactive: true) }
    @objc private func didWake() { set(.sleep, inactive: false) }
    @objc private func sessionInactive() { set(.session, inactive: true) }
    @objc private func sessionActive() { set(.session, inactive: false) }
    @objc private func screenLocked() { set(.screenLock, inactive: true) }
    @objc private func screenUnlocked() { set(.screenLock, inactive: false) }
    @objc private func screenSaverStarted() { set(.screenSaver, inactive: true) }
    @objc private func screenSaverStopped() { set(.screenSaver, inactive: false) }
    @objc private func screensChanged() { appState?.startBreakIfDue() }
}
