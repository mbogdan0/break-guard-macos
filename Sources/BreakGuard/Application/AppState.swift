import AppKit
import Combine
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
    @Published var timerState: TimerState
    // True while a break started via "Take a Break Now" can still be cancelled.
    @Published var isManualBreak = false
    // True once the current focus window was extended; drives the yellow
    // menu bar pill until a new cycle starts.
    @Published var isFocusExtended = false
    // Whether a regular postponement is still allowed under the current
    // cycle's skip policy, and which hold-time tier its buttons use.
    @Published var canPostpone = true
    @Published var postponeHoldTier: PostponeHoldTier = .standard
    // False once harder mode's single normal skip action is used up.
    @Published var canExtendFocus = true
    // Focus accumulated since the last tapering reset; the settings pane
    // derives the penalty from it with FocusPace.taperingPenalty(forFocus:).
    @Published var taperedFocusSeconds: TimeInterval = 0
    // True while the weekly emergency override can be spent on this break.
    @Published var canUseEmergencyOverride = false
    // When the override becomes available again; nil while never used.
    @Published var emergencyOverrideAvailableAt: Date?
    // Whether the overlay's emergency disclosure is open. Lives here, not in
    // the view: one BreakOverlayView exists per screen, and a local @State
    // would leave the other monitors collapsed.
    @Published var emergencyDisclosureExpanded = false
    @Published var notificationAccessStatus: NotificationAccessStatus = .checking
    @Published var loginStatusDescription = "Unknown"
    @Published var notificationTestMessage: String?

    // Fires once per UI-timer second, after publish(), for observers whose
    // display is time-derived (menu bar countdown) rather than state-derived.
    // publish() only fires objectWillChange on real changes, so those
    // observers cannot ride the @Published stream for their refresh.
    let uiTick = PassthroughSubject<Void, Never>()

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
        self.timerState = machine.runtime.timerState
        self.isFocusExtended = machine.runtime.focusExtended
        self.canPostpone = machine.canPostpone
        self.postponeHoldTier = machine.postponeHoldTier
        self.canExtendFocus = machine.canExtendFocus
        self.taperedFocusSeconds = machine.runtime.taperedFocusSeconds
        self.canUseEmergencyOverride = machine.canUseEmergencyOverride
        self.emergencyOverrideAvailableAt = machine.emergencyOverrideAvailableAt
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

    func breakRemaining(at now: Date = Date()) -> TimeInterval {
        if case let .breaking(deadline, _, _) = timerState {
            return max(0, deadline.timeIntervalSince(now))
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
    func totalRestTime(at now: Date = Date()) -> TimeInterval {
        guard timerState == .breakCompleted, let start = machine.runtime.breakStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(start))
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

    func postpone(seconds: TimeInterval) {
        machine.postpone(by: seconds)
        logger.info("Postponed for \(seconds, privacy: .public) seconds")
        publishAndReconcile()
    }

    func completeBreak() {
        machine.completeBreak()
        logger.info("Break completed")
        publishAndReconcile()
    }

    func useEmergencyOverride() {
        machine.useEmergencyOverride()
        logger.info("Weekly emergency override spent")
        publishAndReconcile()
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

    // The next 9:00 AM — today's if it has not passed yet, otherwise tomorrow's.
    func nextMorningResumeDate(after date: Date = Date()) -> Date? {
        Calendar.current.nextDate(
            after: date,
            matching: DateComponents(hour: 9, minute: 0),
            matchingPolicy: .nextTime
        )
    }

    func pauseUntilNextMorning() {
        guard let until = nextMorningResumeDate() else { return }
        machine.suspend(until: until)
        logger.info("Paused until next morning")
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
        // These depend on harderToSkipBreaks, so a toggle must not wait for
        // the next tick to publish.
        canPostpone = machine.canPostpone
        postponeHoldTier = machine.postponeHoldTier
        canExtendFocus = machine.canExtendFocus
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
        uiTick.send()
    }

    private func publishAndReconcile() {
        publish()
        reconcileStateEffects()
        save()
    }

    private func publish() {
        setIfChanged(\.settings, machine.settings)
        setIfChanged(\.statistics, machine.statistics)
        setIfChanged(\.timerState, machine.runtime.timerState)
        setIfChanged(\.isManualBreak, machine.runtime.manualBreakOrigin != nil)
        setIfChanged(\.isFocusExtended, machine.runtime.focusExtended)
        setIfChanged(\.canPostpone, machine.canPostpone)
        setIfChanged(\.postponeHoldTier, machine.postponeHoldTier)
        setIfChanged(\.canExtendFocus, machine.canExtendFocus)
        setIfChanged(\.taperedFocusSeconds, machine.runtime.taperedFocusSeconds)
        setIfChanged(\.canUseEmergencyOverride, machine.canUseEmergencyOverride)
        setIfChanged(\.emergencyOverrideAvailableAt, machine.emergencyOverrideAvailableAt)
        // The disclosure belongs to one break: collapse it once that break is
        // over so the next overlay opens closed on every screen.
        switch timerState {
        case .breakDue, .breaking, .breakCompleted:
            break
        default:
            setIfChanged(\.emergencyDisclosureExpanded, false)
        }
    }

    // publish() runs every second, but @Published fires objectWillChange on
    // every assignment. Skipping the no-op assignments keeps steady-state
    // ticks from re-evaluating every observing view (most visibly the break
    // overlay, whose hold-to-confirm fill competes for main-thread frames).
    private func setIfChanged<T: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<AppState, T>,
        _ value: T
    ) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
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
        // Polling notification settings is an XPC round-trip; the status label
        // only needs to stay live while someone can actually see it.
        if settingsWindow?.isVisible == true {
            refreshNotificationStatus()
        }
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
