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
    @Published var dailySkipsRemaining = AppSettings.defaults.dailySkipLimit
    // Focus accumulated since the last tapering reset; the settings pane
    // derives the penalty from it with FocusPace.taperingPenalty(forFocus:).
    @Published var taperedFocusSeconds: TimeInterval = 0
    // True while the weekly emergency override can be spent on this break.
    @Published var canUseEmergencyOverride = false
    // Why a recurring reminder is active. Nil means no pressure.
    @Published var pressureReason: PressureReason?
    // Whether the same weekly quota can still be spent from the nudge card.
    @Published var canSpendOverrideOnPressure = true
    // When the override becomes available again; nil while never used.
    @Published var emergencyOverrideAvailableAt: Date?
    // Whether the overlay's emergency disclosure is open. Lives here, not in
    // the view: one BreakOverlayView exists per screen, and a local @State
    // would leave the other monitors collapsed.
    @Published var emergencyDisclosureExpanded = false
    @Published var notificationAccessStatus: NotificationAccessStatus = .checking
    @Published var loginStatusDescription = "Unknown"
    @Published var notificationTestMessage: String?
    // The selected devices currently holding the countdown. Device activity
    // is evidence of media use, not proof that the user is on a call.
    @Published private(set) var callHoldActivity = CallActivity()
    var isCallHoldActive: Bool { callHoldActivity.isActive }

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
    private var nudgeManager: NudgeWindowManager?
    private var settingsWindow: NSWindow?
    // What the settings were when the pane was opened, so closing it can charge
    // for the net loosening rather than for every stepper click on the way.
    private var settingsSnapshot: AppSettings?
    // A charge whose confirmation was taken off the screen before it could be
    // answered. The snapshot above stays parked and the question comes back
    // once the screen is the user's again — reverting a whole settings visit on
    // a question nobody saw would be the app answering for them.
    private var settingsChargeDeferred = false
    // Quitting must never stop to argue about settings.
    private var isTerminating = false
    // When the dismissed nudge card is allowed back. In memory by design, like
    // the call-hold edge below: a relaunch showing the card again is the
    // correct answer, not a bug — the pressure never went away.
    private var pressureReminder = PressureReminderState()
    private let callActivityClient: CallActivityClient
    private var callActivity = CallActivity()
    private var sessionInactive = false
    // A call is presence even without keyboard or mouse input. When it ends,
    // idle detection must not backdate absence across the entire call.
    private var lastCallActivityAt: Date?
    private let idleSeconds: () -> TimeInterval
    // Engagement from the previous tick, to catch the transitions: engaging
    // cancels the pending warning notification, releasing re-arms it.
    private var callHoldWasEngaged = false
    // True while the countdown is bracketed because input went silent.
    private var idleSuspensionActive = false
    // Second-precise liveness for tick-gap detection. The persisted heartbeat
    // in RuntimeState is minute-coarse; this one lives only in memory.
    private var lastTickAt: Date?
    // Well past any plausible timer slippage on a live machine; anything
    // longer means the process lost time no sleep notification accounted for.
    private static let tickGapThreshold: TimeInterval = 90

    init(
        persistence: PersistenceStore,
        notifications: NotificationManager,
        loginItems: LoginItemManager,
        clock: TimeProvider = SystemClock(),
        idleSeconds: @escaping () -> TimeInterval = AppState.systemIdleSeconds,
        callActivityClient: CallActivityClient = SystemCallActivityClient()
    ) {
        self.persistence = persistence
        self.notifications = notifications
        self.loginItems = loginItems
        self.idleSeconds = idleSeconds
        self.callActivityClient = callActivityClient
        if let data = persistence.load() {
            logger.info("State restoration from persisted data")
            self.machine = StateMachine(data: data, clock: clock)
        } else {
            logger.info("State restoration using defaults")
            self.machine = StateMachine(clock: clock)
        }
        self.settings = machine.settings
        self.statistics = machine.statistics
        self.timerState = machine.runtime.timerState
        self.isFocusExtended = machine.runtime.focusExtended
        self.canPostpone = machine.canPostpone
        self.postponeHoldTier = machine.postponeHoldTier
        self.canExtendFocus = machine.canExtendFocus
        self.dailySkipsRemaining = machine.dailySkipsRemaining
        self.taperedFocusSeconds = machine.runtime.taperedFocusSeconds
        self.canUseEmergencyOverride = machine.canUseEmergencyOverride
        self.canSpendOverrideOnPressure = machine.canSpendOverrideOnPressure
        self.emergencyOverrideAvailableAt = machine.emergencyOverrideAvailableAt
    }

    func start() {
        logger.info("Application launch")
        overlayManager = OverlayScreenManager(appState: self)
        nudgeManager = NudgeWindowManager(appState: self)
        notifications.configure()
        notifications.requestAuthorizationIfNeeded()
        refreshNotificationStatus()
        applyLaunchAtLoginPreference()
        refreshLoginStatus()
        startUITimer()
        tick()
    }

    func stop() {
        logger.info("Application stopping")
        isTerminating = true
        uiTimer?.invalidate()
        // Deliberately nothing about breaks here. Quitting is not the screen
        // going away, and the heartbeat already records where watching stopped
        // — relaunch reads that gap and decides, so a quit-and-relaunch inside
        // a couple of minutes simply carries on.
        publish()
        notifications.cancelWarning()
        overlayManager?.hideAll()
        nudgeManager?.hideAll()
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
        guard !sessionInactive, !isTerminating else { return }
        machine.takeBreakNow()
        publishAndReconcile()
    }

    func cancelManualBreak() {
        guard !sessionInactive, !isTerminating else { return }
        machine.cancelManualBreak()
        logger.info("Manual break cancelled")
        publishAndReconcile()
    }

    // Total rest so far on the completion screen (now − break start).
    // publish() is equality-gated, so this count-up refreshes through the
    // uiTick subject, which fires every second regardless.
    func totalRestTime(at now: Date = Date()) -> TimeInterval {
        guard timerState == .breakCompleted, let start = machine.runtime.breakStartedAt else { return 0 }
        return max(0, now.timeIntervalSince(start))
    }

    func startBreakIfDue() {
        guard !sessionInactive, timerState == .breakDue else { return }
        machine.startBreak()
        logger.info("Break start")
        publishAndReconcile()
    }

    func postpone(seconds: TimeInterval) {
        guard !sessionInactive, !isTerminating else { return }
        machine.postpone(by: seconds)
        logger.info("Postponed for \(seconds, privacy: .public) seconds")
        publishAndReconcile()
    }

    func completeBreak() {
        guard !sessionInactive, !isTerminating else { return }
        machine.completeBreak()
        logger.info("Break completed")
        publishAndReconcile()
    }

    func useEmergencyOverride() {
        guard !sessionInactive, !isTerminating else { return }
        machine.useEmergencyOverride()
        logger.info("Weekly emergency override spent")
        publishAndReconcile()
    }

    // Same weekly quota as the break overlay's override, spent from the nudge
    // card instead. It buys quiet only: no break is skipped and the countdown
    // is untouched, so nothing is recorded against the streak.
    func spendPressureOverride() {
        guard !sessionInactive, !isTerminating else { return }
        machine.spendOverrideOnPressure()
        logger.info("Weekly emergency override spent on break pressure")
        publishAndReconcile()
    }

    // Holding the dismiss button buys ninety seconds of quiet.
    func dismissNudgeCard() {
        guard !sessionInactive, !isTerminating else { return }
        pressureReminder.dismiss(at: machine.clock.now)
        logger.info("Nudge card dismissed")
        reconcilePressure()
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
        guard !sessionInactive, !isTerminating else { return }
        machine.extendFocus(by: minutes * 60)
        logger.info("Focus window extended by \(minutes, privacy: .public) minutes")
        publishAndReconcile()
    }

    func resumeNow() {
        guard !sessionInactive, !isTerminating else { return }
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

    // The caller may pass the date it already showed the user. With harder
    // mode's three-minute gate on the confirmation, recomputing here can land
    // on the far side of 9 AM and pause until *tomorrow* after promising today
    // — a narrow window, but the dialog's promise is the one that must hold.
    func pauseUntilNextMorning(until promised: Date? = nil) {
        guard !sessionInactive, !isTerminating else { return }
        guard let until = promised ?? nextMorningResumeDate() else { return }
        machine.suspend(until: until)
        logger.info("Paused until next morning")
        publishAndReconcile()
    }

    func showSettings() {
        refreshNotificationStatus()
        refreshLoginStatus()
        // One snapshot per visit, not per open call. Keyed on the snapshot
        // itself rather than on the window being visible: a miniaturized
        // window reports isVisible == false, so that test let a visit be
        // re-baselined — loosen, miniaturize, reopen, close, no charge.
        // The visit ends where the snapshot is cleared, in confirmSettingsVisit.
        if settingsSnapshot == nil {
            settingsSnapshot = settings
        }
        // Reopening the pane makes the visit live again, so a charge deferred
        // by an interrupted confirmation goes back to being levied on close
        // rather than interrupting the editing that is now under way.
        settingsChargeDeferred = false
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
        // Registered once, on the single window this app ever builds — it is
        // reused across opens rather than rebuilt, so this cannot stack.
        NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.confirmSettingsVisit() }
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // Harder mode charges for a trip to the settings pane, once, on the net
    // difference. Edits still apply as they are made — gating each write would
    // open a dialog per stepper click — and Cancel puts the whole visit back.
    private func confirmSettingsVisit() {
        guard !isTerminating, let snapshot = settingsSnapshot else { return }
        settingsSnapshot = nil
        settingsChargeDeferred = false
        // Harder mode at either end of the visit is what makes this worth
        // charging for: on at the start catches the pane being used to switch
        // it off and loosen everything else in one trip.
        guard snapshot.harderToSkipBreaks || settings.harderToSkipBreaks,
              settings.weakensGuard(comparedTo: snapshot) else { return }
        switch confirmHonestly(
            message: "Keep the settings you just loosened? ⚙️",
            informative: "You gave yourself more room in there — a longer stretch before the next break, a shorter one when it arrives, or one less thing watching. That is allowed, and it is also exactly what the tired end of a long day asks for. Be honest about which of the two this is; Cancel puts everything back the way you found it.",
            confirmTitle: "Keep Them",
            gate: SkipConfirmGate.loosenSettingsSeconds
        ) {
        case .confirmed:
            logger.info("Loosened settings kept after confirmation")
        case .aborted:
            // Alone among the confirmations, this one's safe branch is a write:
            // it undoes a whole settings visit. An abort is not an answer, so
            // taking it as Cancel would discard the user's edits over a
            // question they never got to see. Park the snapshot instead and ask
            // again once the screen is theirs — the debt outlives the break.
            logger.info("Settings charge deferred — confirmation interrupted")
            settingsSnapshot = snapshot
            settingsChargeDeferred = true
        case .declined:
            logger.info("Loosened settings reverted after confirmation")
            // Everything except the toggle that is priced at its own gate.
            // Reverting that one would either discard a switch-off already paid
            // for at 90 seconds, or — if it was switched on during the visit —
            // loosen the guard from the branch meant to be the safe one.
            var reverted = snapshot
            reverted.harderToSkipBreaks = settings.harderToSkipBreaks
            updateSettings(reverted)
        }
    }

    // A deferred charge comes back as soon as the screen is the user's again.
    // Without this the question would wait for the next visit to the pane,
    // which may never come — and the loosening would have been free.
    //
    // Both guards also make this safe against its own confirmation: the alert
    // spins a nested run loop that keeps the 1 s tick running, and by then the
    // flag is already clear and a confirmation is already open.
    private func retryDeferredSettingsCharge() {
        guard settingsChargeDeferred, !isConfirmationOpen else { return }
        switch timerState {
        case .working, .warning:
            confirmSettingsVisit()
        case .breakDue, .breaking, .breakCompleted, .postponed, .suspended:
            break
        }
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
        tick()
        save()
    }

    // Harder mode is the switch every other gate hangs from, so leaving it is
    // gated too — otherwise the cheapest way past a 30-second confirmation is
    // one click on the Settings tab. Turning it on stays instant.
    //
    // The caller writes nothing itself: on Cancel the setting must be exactly
    // as it was, and the toggle that already drew itself in the off position
    // has to be told to look again.
    func setHarderToSkipBreaks(_ enabled: Bool) {
        guard settings.harderToSkipBreaks != enabled else { return }
        if enabled {
            var updated = settings
            updated.harderToSkipBreaks = true
            updateSettings(updated)
            return
        }
        let answer = confirmHonestly(
            message: "Turn off Harder to skip breaks? 🛡️",
            informative: "Turning this off removes the daily skip budget, the limit of one skip per cycle, and scheduled reminders. Has something changed, or is this a break you do not want to take?",
            confirmTitle: "Turn It Off",
            gate: SkipConfirmGate.disableHarderModeSeconds
        )
        // A decline and an abort agree here: the safe branch writes nothing.
        guard answer == .confirmed else {
            logger.info("Harder mode kept on after confirmation")
            // Nothing changed, so nothing publishes on its own.
            objectWillChange.send()
            return
        }
        logger.info("Harder mode switched off")
        var updated = settings
        updated.harderToSkipBreaks = false
        updateSettings(updated)
    }

    func resetStatistics() {
        machine.statistics = .empty
        statistics = .empty
        save()
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

    // Sleep, lock, and the screen saver all mean the same thing: the screen
    // went away, so the break starts now. Length is not judged — a saver that
    // blinks for ten seconds is still the user leaving.
    func handleSleepOrInactive() {
        logger.info("Sleep or inactive session")
        sessionInactive = true
        callActivity = CallActivity()
        machine.callHoldActive = false
        callHoldWasEngaged = false
        machine.beginDowntimeBreak()
        abortOpenConfirmation()
        notifications.cancelWarning()
        overlayManager?.hideAll()
        nudgeManager?.hideAll()
        publish()
        save()
    }

    func handleWakeOrActive() {
        logger.info("Wake or active session")
        sessionInactive = false
        machine.restoreAfterSleep()
        // The wake just accounted for the downtime: reset the in-memory
        // heartbeat so the next tick does not bracket the same gap again, and
        // drop any idle bracket — the sleep path owned the state from here.
        lastTickAt = machine.clock.now
        idleSuspensionActive = false
        tick()
    }

    private func startUITimer() {
        uiTimer?.invalidate()
        let timer = makeUITimer()
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .modalPanel)
        uiTimer = timer
    }

    func makeUITimer() -> Timer {
        Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            // The timer runs on the main run loop. A queued MainActor task
            // waits for a synchronous modal confirmation to return, turning
            // its waiting time into a false monitoring gap.
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func tick() {
        guard !sessionInactive, !isTerminating else { return }
        let now = machine.clock.now
        // A tick gap without a sleep signal is downtime no notification
        // bracketed — a wake nobody asked for, a missed willSleep. Bracket it
        // after the fact from the last observed tick, so the gap can never
        // count as focus.
        if let lastTick = lastTickAt, now.timeIntervalSince(lastTick) >= Self.tickGapThreshold {
            logger.info("Tick gap of \(Int(now.timeIntervalSince(lastTick)), privacy: .public)s — bracketing as downtime")
            machine.beginDowntimeBreak(at: lastTick)
            machine.restoreAfterSleep()
            idleSuspensionActive = false
        }
        lastTickAt = now

        // One fresh snapshot owns both idle detection and the hold. There is
        // no independent timer or queued device callback that can strand an
        // old true flag or re-enter tick() while settings are being published.
        let activity = callActivityClient.read(includeMicrophone: machine.settings.holdBreaksWhileMicrophoneInUse)
        if activity != callActivity {
            logger.info("Media activity: camera=\(activity.cameraInUse, privacy: .public), microphone=\(activity.microphoneInUse, privacy: .public)")
        }
        callActivity = activity
        updateIdleSuspension(now: now)
        machine.callHoldActive = callActivity.selected(for: machine.settings).isActive

        let previous = machine.runtime.timerState
        let current = machine.tick()
        if current != previous {
            logger.info("State transition")
        }
        reconcileCallHoldWarning()
        publish()
        reconcileStateEffects()
        save()
        uiTick.send()
    }

    // The hold pins the deadline by advancing it every tick, so the pending
    // warning notification must be handled on the engagement edges: cancelled
    // when the hold engages (it would fire mid-call), re-armed when the hold
    // releases. A pinned .working re-arms through reconcileStateEffects(); a
    // pinned .warning has no scheduling path there, so it re-arms here.
    private func reconcileCallHoldWarning() {
        let engaged = machine.isCallHoldEngaged
        defer { callHoldWasEngaged = engaged }
        if engaged, !callHoldWasEngaged {
            notifications.cancelWarning()
        }
        if !engaged, callHoldWasEngaged, case let .warning(deadline) = machine.runtime.timerState {
            // The runway starts now; tell the user the break is coming, and
            // say so in terms of the runway rather than the configured lead —
            // the hold pinned the deadline there, so that is the time the user
            // actually has.
            notifications.scheduleWarning(
                at: machine.clock.now.addingTimeInterval(1),
                breakAt: deadline,
                settings: machine.settings
            )
        }
    }

    // Sleep and lock notifications cannot see a machine that stays awake with
    // nobody at it, so input silence is the backstop. The bracket is
    // back-dated to the last input, so the silent span never counts as focus.
    private func updateIdleSuspension(now: Date) {
        // A call is presence without input; never treat it as absence.
        if callActivity.cameraInUse || (callActivity.microphoneInUse && machine.settings.holdBreaksWhileMicrophoneInUse) {
            lastCallActivityAt = now
            if idleSuspensionActive {
                machine.restoreAfterSleep()
                idleSuspensionActive = false
            }
            return
        }
        let inputIdle = idleSeconds()
        let idle = min(inputIdle, lastCallActivityAt.map { max(0, now.timeIntervalSince($0)) } ?? inputIdle)
        if idleSuspensionActive {
            if idle < IdleAway.threshold {
                logger.info("Input returned — restoring from idle suspension")
                machine.restoreAfterSleep()
                idleSuspensionActive = false
            }
        } else if idle >= IdleAway.threshold {
            // A user-requested pause (or a sleep bracket) already owns the
            // state; idle must not re-stamp its timestamps.
            if case .suspended = machine.runtime.timerState { return }
            logger.info("Idle for \(Int(idle), privacy: .public)s — suspending countdown")
            machine.suspendForIdle(at: now.addingTimeInterval(-idle))
            idleSuspensionActive = true
        }
    }

    // Seconds since the last user input, taken as the freshest across the
    // event types real input produces. kCGAnyInputEventType is not exposed to
    // Swift, and a per-type minimum is just as cheap at once per second.
    nonisolated private static let idleEventTypes: [CGEventType] = [
        .leftMouseDown, .rightMouseDown, .otherMouseDown,
        .mouseMoved, .leftMouseDragged, .rightMouseDragged,
        .scrollWheel, .keyDown, .flagsChanged
    ]

    nonisolated private static func systemIdleSeconds() -> TimeInterval {
        idleEventTypes
            .map { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) }
            .min() ?? 0
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
        setIfChanged(\.dailySkipsRemaining, machine.dailySkipsRemaining)
        setIfChanged(\.taperedFocusSeconds, machine.runtime.taperedFocusSeconds)
        setIfChanged(\.canUseEmergencyOverride, machine.canUseEmergencyOverride)
        setIfChanged(\.canSpendOverrideOnPressure, machine.canSpendOverrideOnPressure)
        setIfChanged(\.emergencyOverrideAvailableAt, machine.emergencyOverrideAvailableAt)
        setIfChanged(\.callHoldActivity, machine.isCallHoldEngaged
                     ? callActivity.selected(for: machine.settings) : CallActivity())
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
        guard !sessionInactive, !isTerminating else { return }
        switch timerState {
        case let .working(deadline, warningDeadline):
            overlayManager?.hideAll()
            // While the call hold pins the countdown, the warning deadline
            // advances every tick; rescheduling against it would fire a
            // notification every second into the call.
            if !isCallHoldActive {
                notifications.scheduleWarning(at: warningDeadline, breakAt: deadline, settings: settings)
            }
        case .warning:
            overlayManager?.hideAll()
        case .breakDue:
            notifications.cancelWarning()
            // Before the overlay goes up, not after: it covers the whole
            // screen at `.screenSaver`, and a confirmation left running behind
            // it would keep swallowing the clicks meant for the break.
            //
            // `abortModal()` only unwinds the modal loop on its next pass, so
            // the break waits out the tick that ordered the alert away rather
            // than racing it. The state is still .breakDue a second later.
            guard !abortOpenConfirmation() else { return }
            startBreakIfDue()
        case .breaking, .breakCompleted:
            notifications.cancelWarning()
            guard !abortOpenConfirmation() else { return }
            overlayManager?.showOnAllScreens()
            overlayManager?.bringToFront()
        case .postponed:
            overlayManager?.hideAll()
            notifications.cancelWarning()
        case .suspended:
            overlayManager?.hideAll()
            notifications.cancelWarning()
        }
        reconcilePressure()
        retryDeferredSettingsCharge()
        // Polling notification settings is an XPC round-trip; the status label
        // only needs to stay live while someone can actually see it.
        if settingsWindow?.isVisible == true {
            refreshNotificationStatus()
        }
    }

    // Runs on every tick for as long as the pressure does, which can be a whole
    // evening, so the manager below is written to cost nothing when nothing
    // changed — see NudgeWindowManager.
    private func reconcilePressure() {
        let now = machine.clock.now
        let reason = settings.pressureReason(at: now)
        // The satisfaction rule only exists for the scheduled break: a break
        // taken inside the window is the window's whole purpose. Outside
        // working hours a two-minute break settles nothing.
        let window = reason == .scheduledBreak
            ? settings.scheduledBreakWindow(containing: now)
            : nil
        guard let reason, !machine.isPressureSuppressed(satisfiedWindow: window) else {
            setIfChanged(\.pressureReason, nil)
            // A dismissal belongs to the episode it was made in. Once the
            // pressure lifts — a break, a call, the end of the window — the
            // next one starts with the card up rather than serving out the
            // remainder of a dismissal nobody remembers asking for.
            pressureReminder.update(reason: nil)
            nudgeManager?.hideAll()
            return
        }
        setIfChanged(\.pressureReason, reason)
        pressureReminder.update(reason: reason)
        nudgeManager?.show(
            makeNudgePresentation(reason: reason, windowEnd: window?.end),
            // Keep the card clear of a modal confirmation's clicks.
            showCard: pressureReminder.shouldShowCard(at: now) && !isConfirmationOpen
        )
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
