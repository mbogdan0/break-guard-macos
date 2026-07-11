import AppKit
import SwiftUI
import UserNotifications
import os

enum NotificationAccessStatus: Equatable {
    case checking
    case notRequested
    case enabled(timeSensitive: Bool, sound: Bool)
    case alertsDisabled
    case disabled

    var description: String {
        switch self {
        case .checking: return "Checking…"
        case .notRequested: return "Not requested"
        case let .enabled(timeSensitive, sound):
            let delivery = timeSensitive ? "Time Sensitive" : "Regular"
            return sound ? "Allowed · \(delivery)" : "Allowed · \(delivery) · System sound off"
        case .alertsDisabled: return "Alerts disabled"
        case .disabled: return "Disabled"
        }
    }

    var needsSettingsLink: Bool {
        switch self {
        case .alertsDisabled, .disabled: return true
        default: return false
        }
    }

    var canSendTest: Bool {
        switch self {
        case .checking, .alertsDisabled, .disabled: return false
        case .notRequested, .enabled: return true
        }
    }

    init(capabilities: NotificationCapabilities) {
        switch capabilities.authorizationStatus {
        case .notDetermined:
            self = .notRequested
        case .denied:
            self = .disabled
        case .authorized, .provisional, .ephemeral:
            if capabilities.canPresentAlerts {
                self = .enabled(
                    timeSensitive: capabilities.supportsTimeSensitive,
                    sound: capabilities.soundSetting == .enabled
                )
            } else {
                self = .alertsDisabled
            }
        @unknown default:
            self = .checking
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings: AppSettings
    @Published var statistics: Statistics
    @Published var focusTags: [FocusTag]
    @Published var timerState: TimerState
    // True while a break started via "Take a Break Now" can still be cancelled.
    @Published var isManualBreak = false
    @Published var notificationAccessStatus: NotificationAccessStatus = .checking
    @Published var loginStatusDescription = "Unknown"
    @Published var notificationTestMessage: String?

    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "AppState")
    private let persistence: PersistenceStore
    private let notifications: NotificationManager
    private let loginItems: LoginItemManager
    private var machine: StateMachine
    private var uiTimer: Timer?
    private var overlayManager: OverlayScreenManager?
    private var settingsWindow: NSWindow?

    init(
        persistence: PersistenceStore,
        notifications: NotificationManager,
        loginItems: LoginItemManager
    ) {
        self.persistence = persistence
        self.notifications = notifications
        self.loginItems = loginItems
        if let data = persistence.load() {
            logger.info("State restoration from persisted data")
            self.machine = StateMachine(data: data)
        } else {
            logger.info("State restoration using defaults")
            self.machine = StateMachine()
        }
        self.settings = machine.settings
        self.statistics = machine.statistics
        self.focusTags = machine.focusTags
        self.timerState = machine.runtime.timerState
    }

    func start() {
        logger.info("Application launch")
        overlayManager = OverlayScreenManager(appState: self)
        notifications.configure()
        notifications.requestAuthorizationIfNeeded()
        refreshNotificationStatus()
        applyLaunchAtLoginPreference()
        refreshLoginStatus()
        startUITimer()
        reconcileStateEffects()
        save()
    }

    func stop() {
        logger.info("Application stopping")
        uiTimer?.invalidate()
        machine.preserveForSleep()
        publish()
        notifications.cancelWarning()
        overlayManager?.hideAll()
        save()
    }

    func breakRemaining() -> TimeInterval {
        if case let .breaking(deadline, _, _) = timerState {
            return max(0, deadline.timeIntervalSince(Date()))
        }
        return 0
    }

    func isBreakCompleteAllowed() -> Bool {
        timerState == .breakCompleted
    }

    func takeBreakNow() {
        machine.takeBreakNow()
        publishAndReconcile()
    }

    func cancelManualBreak() {
        machine.cancelManualBreak()
        logger.info("Manual break cancelled")
        publishAndReconcile()
    }

    // Total rest so far on the completion screen (now − break start). Refreshes
    // through the 1-second tick(), which publishes even when values are equal;
    // if publishing is ever equality-gated, this count-up stalls.
    func totalRestTime() -> TimeInterval {
        guard timerState == .breakCompleted, let start = machine.runtime.breakStartedAt else { return 0 }
        return max(0, Date().timeIntervalSince(start))
    }

    func startBreakIfDue() {
        guard timerState == .breakDue else { return }
        machine.startBreak()
        logger.info("Break start")
        publishAndReconcile()
    }

    func markBreakTaken() {
        machine.markBreakTaken()
        logger.info("User marked an off-screen break as taken")
        publishAndReconcile()
    }

    func postpone(minutes: Double) {
        machine.postpone(by: minutes * 60)
        logger.info("Postponed for \(minutes, privacy: .public) minutes")
        publishAndReconcile()
    }

    func completeBreak(classification: FocusClassification) {
        machine.completeBreak(classification: classification)
        logger.info("Break completion classified")
        publishAndReconcile()
    }

    @discardableResult
    func addFocusTag(named name: String) -> String? {
        do {
            try machine.addFocusTag(named: name)
            publishAndSave()
            return nil
        } catch let error as FocusTagNameError {
            return error.message
        } catch {
            return "Unable to add the tag."
        }
    }

    @discardableResult
    func renameFocusTag(id: String, to name: String) -> String? {
        do {
            try machine.renameFocusTag(id: id, to: name)
            publishAndSave()
            return nil
        } catch let error as FocusTagNameError {
            return error.message
        } catch {
            return "Unable to rename the tag."
        }
    }

    func deleteFocusTag(id: String) {
        machine.deleteFocusTag(id: id)
        publishAndSave()
    }

    func focusMinutes(for tagID: String) -> Int {
        statistics.focusMinutesByTag[tagID, default: 0]
    }

    func sendTestNotification() {
        notificationTestMessage = "Scheduling test notification…"
        notifications.sendTestNotification(settings: settings) { [weak self] result in
            Task { @MainActor in
                switch result {
                case .success(.queued):
                    self?.notificationTestMessage = "Test notification queued…"
                case .success(.delivered):
                    self?.notificationTestMessage = "Test notification delivered."
                case .success(.notDelivered):
                    self?.notificationTestMessage = "Queued, but no delivery was observed."
                case let .failure(error):
                    self?.notificationTestMessage = error.localizedDescription
                }
                self?.refreshNotificationStatus()
            }
        }
    }

    func extendFocus(minutes: Double) {
        machine.extendFocus(by: minutes * 60)
        logger.info("Focus window extended by \(minutes, privacy: .public) minutes")
        publishAndReconcile()
    }

    func resumeNow() {
        machine.resume()
        publishAndReconcile()
    }

    func showSettings() {
        refreshNotificationStatus()
        refreshLoginStatus()
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = SettingsView(appState: self)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BreakGuard Settings"
        window.minSize = NSSize(width: 540, height: 560)
        window.contentView = NSHostingView(rootView: view)
        window.center()
        window.isReleasedWhenClosed = false
        window.makeKeyAndOrderFront(nil)
        settingsWindow = window
        NSApp.activate(ignoringOtherApps: true)
    }

    func updateSettings(_ updated: AppSettings) {
        var validated = updated
        validated.clamp()
        let launchAtLoginChanged = machine.settings.launchAtLogin != validated.launchAtLogin
        machine.settings = validated
        settings = validated
        if launchAtLoginChanged {
            applyLaunchAtLoginPreference()
            refreshLoginStatus()
        }
        save()
    }

    func resetStatistics() {
        machine.statistics = .empty
        statistics = .empty
        save()
    }

    func restoreDefaultSettings() {
        updateSettings(.defaults)
    }

    func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func openLoginItemSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.LoginItems-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    func handleSleepOrInactive() {
        logger.info("Sleep or inactive session")
        machine.preserveForSleep()
        notifications.cancelWarning()
        publish()
        save()
    }

    func handleWakeOrActive() {
        logger.info("Wake or active session")
        machine.restoreAfterSleep()
        publishAndReconcile()
    }

    private func startUITimer() {
        uiTimer?.invalidate()
        uiTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        RunLoop.main.add(uiTimer!, forMode: .common)
    }

    private func tick() {
        let previous = machine.runtime.timerState
        if case let .suspended(_, _, until) = previous, let until, Date() >= until {
            machine.resume()
        }
        let current = machine.tick()
        if current != previous {
            logger.info("State transition")
        }
        publish()
        reconcileStateEffects()
        save()
    }

    private func publishAndReconcile() {
        publish()
        reconcileStateEffects()
        save()
    }

    private func publishAndSave() {
        publish()
        save()
    }

    private func publish() {
        settings = machine.settings
        statistics = machine.statistics
        focusTags = machine.focusTags
        timerState = machine.runtime.timerState
        isManualBreak = machine.runtime.manualBreakOrigin != nil
    }

    private func reconcileStateEffects() {
        switch timerState {
        case let .working(_, warningDeadline):
            overlayManager?.hideAll()
            notifications.scheduleWarning(at: warningDeadline, settings: settings)
        case .warning:
            overlayManager?.hideAll()
        case .breakDue:
            notifications.cancelWarning()
            startBreakIfDue()
        case .breaking, .breakCompleted:
            notifications.cancelWarning()
            overlayManager?.showOnAllScreens()
            overlayManager?.bringToFront()
        case .postponed:
            overlayManager?.hideAll()
            notifications.cancelWarning()
        case .suspended:
            overlayManager?.hideAll()
            notifications.cancelWarning()
        }
        refreshNotificationStatus()
    }

    private func save() {
        persistence.save(machine.data)
    }

    private func refreshNotificationStatus() {
        notifications.capabilities { [weak self] capabilities in
            Task { @MainActor in
                self?.notificationAccessStatus = NotificationAccessStatus(capabilities: capabilities)
            }
        }
    }

    private func applyLaunchAtLoginPreference() {
        if settings.launchAtLogin {
            loginItems.enable()
        } else {
            loginItems.disable()
        }
    }

    private func refreshLoginStatus() {
        loginStatusDescription = loginItems.statusDescription()
    }
}
