import Foundation

struct StateMachine {
    var settings: AppSettings
    var statistics: Statistics
    var runtime: RuntimeState
    var clock: TimeProvider

    init(settings: AppSettings = .defaults, statistics: Statistics = .empty, clock: TimeProvider = SystemClock()) {
        var validated = settings
        validated.clamp()
        self.settings = validated
        self.statistics = statistics
        self.clock = clock
        let interval = validated.effectiveWorkInterval
        let warning = clock.now.addingTimeInterval(
            interval - validated.effectiveWarningLeadTime(for: interval)
        )
        let deadline = clock.now.addingTimeInterval(interval)
        self.runtime = RuntimeState(
            timerState: .working(deadline: deadline, warningDeadline: warning),
            cycleViolated: false,
            cyclePostponements: 0,
            cycleRegularPostponements: 0,
            focusExtended: false,
            cycleStartDate: clock.now,
            preservedAt: nil,
            preservedRemaining: nil,
            cycleFocusDuration: nil,
            breakStartedAt: nil,
            manualBreakOrigin: nil,
            taperedFocusSeconds: 0,
            emergencyOverrideUsedAt: nil
        )
    }

    init(data: PersistedAppData, clock: TimeProvider = SystemClock()) {
        var validated = data.settings
        validated.clamp()
        self.settings = validated
        self.statistics = data.statistics
        self.runtime = data.runtime
        self.clock = clock
        restoreAfterSleep()
        // After restore so focus credited during it lands before old days drop.
        statistics.pruneFocusHistory(now: clock.now)
    }

    private var normalSkipUsed: Bool {
        runtime.cyclePostponements > 0 || runtime.focusExtended
    }

    // Harder mode allows either one extension or one regular postponement.
    var canExtendFocus: Bool {
        !settings.harderToSkipBreaks || !normalSkipUsed
    }

    var canPostpone: Bool {
        !settings.harderToSkipBreaks || !normalSkipUsed
    }

    var postponeHoldTier: PostponeHoldTier {
        if settings.harderToSkipBreaks { return .harder }
        return runtime.cycleRegularPostponements > 0 ? .repeated : .standard
    }

    // When the weekly emergency override can be spent again; nil while it has
    // never been used. Rolling seven days from the last use, so it cannot be
    // spent twice across a weekend the way a calendar week would allow.
    var emergencyOverrideAvailableAt: Date? {
        runtime.emergencyOverrideUsedAt?.addingTimeInterval(EmergencyOverride.cooldown)
    }

    // The override exists for breaks the app imposed. A break the user started
    // themselves already has a penalty-free exit in cancelManualBreak().
    var canUseEmergencyOverride: Bool {
        guard runtime.manualBreakOrigin == nil,
              isBreakingOrDue(runtime.timerState) else { return false }
        guard let availableAt = emergencyOverrideAvailableAt else { return true }
        return clock.now >= availableAt
    }

    // Once-a-week escape hatch: trades the break for a long focus window even
    // in harder-to-skip mode. It ignores that mode's cost rather than handing
    // out extra allowance, so it spends both the extension and the free skip —
    // otherwise a 90-minute grant could immediately stack an extension on top.
    // Skipping a required break is a violation and is recorded as one.
    mutating func useEmergencyOverride() {
        guard canUseEmergencyOverride else { return }
        if !runtime.cycleViolated {
            runtime.cycleViolated = true
            statistics.currentCleanStreak = 0
            statistics.violatedCycles += 1
        }
        runtime.cyclePostponements += 1
        runtime.focusExtended = true
        runtime.emergencyOverrideUsedAt = clock.now
        runtime.timerState = .postponed(
            deadline: clock.now.addingTimeInterval(EmergencyOverride.focusGrant)
        )
    }

    var data: PersistedAppData {
        PersistedAppData(
            schemaVersion: PersistedAppData.currentSchemaVersion,
            settings: settings,
            statistics: statistics,
            runtime: runtime
        )
    }

    mutating func tick() -> TimerState {
        switch runtime.timerState {
        case let .working(deadline, warningDeadline):
            if clock.now >= deadline {
                runtime.timerState = .breakDue
            } else if settings.warningLeadTime > 0 && clock.now >= warningDeadline {
                runtime.timerState = .warning(deadline: deadline)
            }
        case let .warning(deadline):
            if clock.now >= deadline {
                runtime.timerState = .breakDue
            }
        case let .postponed(deadline):
            if clock.now >= deadline {
                runtime.timerState = .breakDue
            }
        case let .breaking(deadline, _, _):
            if clock.now >= deadline {
                runtime.timerState = .breakCompleted
            }
        case .breakDue, .breakCompleted, .suspended:
            break
        }
        return runtime.timerState
    }

    mutating func startBreak() {
        let duration = settings.breakDuration
        runtime.cycleFocusDuration = max(0, clock.now.timeIntervalSince(runtime.cycleStartDate))
        runtime.breakStartedAt = clock.now
        runtime.timerState = .breaking(
            deadline: clock.now.addingTimeInterval(duration),
            startedAt: clock.now,
            duration: duration
        )
    }

    mutating func completeBreak() {
        guard runtime.timerState == .breakCompleted else { return }

        creditFocus(minutes: creditedFocusMinutes(), on: clock.now)
        statistics.completedBreaks += 1
        statistics.lastCompletedBreakDate = clock.now
        if runtime.cycleViolated {
            statistics.currentCleanStreak = 0
        } else {
            statistics.currentCleanStreak += 1
            statistics.bestCleanStreak = max(statistics.bestCleanStreak, statistics.currentCleanStreak)
        }
        startWorkCycle()
    }

    mutating func startWorkCycle() {
        settings.clamp()
        // The focus of the cycle being closed adds to the tapering total,
        // unless it ended long enough ago that the workday started over.
        let closed = closedCycleFocus()
        let tapered: TimeInterval
        if clock.now.timeIntervalSince(closed.end) >= settings.taperingResetGap {
            tapered = 0
        } else {
            // Both terms are sanitized before the sum so a poisoned stored
            // value cannot make the total non-finite, and the sum is capped
            // again so it stays inside the encodable range.
            let banked = FocusPace.sanitizedTaperedFocus(runtime.taperedFocusSeconds)
            let earned = FocusPace.sanitizedTaperedFocus(closed.duration)
            tapered = FocusPace.sanitizedTaperedFocus(banked + earned)
        }
        let interval = settings.effectiveWorkInterval(taperedFocus: tapered)
        runtime = RuntimeState(
            timerState: .working(
                deadline: clock.now.addingTimeInterval(interval),
                warningDeadline: clock.now.addingTimeInterval(
                    interval - settings.effectiveWarningLeadTime(for: interval)
                )
            ),
            cycleViolated: false,
            cyclePostponements: 0,
            cycleRegularPostponements: 0,
            focusExtended: false,
            cycleStartDate: clock.now,
            preservedAt: nil,
            preservedRemaining: nil,
            cycleFocusDuration: nil,
            breakStartedAt: nil,
            manualBreakOrigin: nil,
            taperedFocusSeconds: tapered,
            // The weekly quota outlives the cycle that spent it.
            emergencyOverrideUsedAt: runtime.emergencyOverrideUsedAt
        )
    }

    // Where the focus of the cycle being closed ended, and how long it ran.
    // One definition so the minutes credited to statistics and the minutes
    // charged to tapering can never disagree.
    //
    // Only the break branch trusts the capture startBreak() took. Every exit
    // from a break now clears it, so a countdown state should never carry one
    // — the switch keeps that structural rather than relying on each future
    // exit path to remember, since a stale capture fails silently by
    // understating focus instead of crashing.
    private func closedCycleFocus() -> (end: Date, duration: TimeInterval) {
        switch runtime.timerState {
        case .breaking, .breakDue, .breakCompleted:
            let end = runtime.breakStartedAt ?? runtime.preservedAt ?? clock.now
            let duration = runtime.cycleFocusDuration
                ?? max(0, end.timeIntervalSince(runtime.cycleStartDate))
            return (end, duration)
        case .suspended, .working, .warning, .postponed:
            let end = runtime.preservedAt ?? clock.now
            return (end, max(0, end.timeIntervalSince(runtime.cycleStartDate)))
        }
    }

    mutating func postpone(by delay: TimeInterval) {
        let canPostponeInCurrentState: Bool
        if case .breakDue = runtime.timerState {
            canPostponeInCurrentState = true
        } else {
            canPostponeInCurrentState = isBreakingOrCompleted(runtime.timerState)
        }
        guard canPostpone, canPostponeInCurrentState else { return }
        if !runtime.cycleViolated {
            runtime.cycleViolated = true
            statistics.currentCleanStreak = 0
            statistics.violatedCycles += 1
        }
        runtime.cyclePostponements += 1
        runtime.cycleRegularPostponements += 1
        statistics.totalPostponements += 1
        // Postponing a manual break opts into the standard postpone contract;
        // the penalty-free exit is cancelManualBreak().
        runtime.manualBreakOrigin = nil
        // Postponing ends the break these describe, so the capture startBreak()
        // took must not outlive it — the next break re-takes it. Left behind,
        // it would understate the cycle's focus for anything that closes the
        // cycle from a break state without a fresh startBreak(), such as
        // sleeping through the moment the postponed break falls due.
        runtime.cycleFocusDuration = nil
        runtime.breakStartedAt = nil
        runtime.timerState = .postponed(deadline: clock.now.addingTimeInterval(delay))
    }

    // Only meaningful while a countdown is running: a no-op during a break,
    // its completion screen, or a pause, so a stray caller cannot restart an
    // in-progress break or silently destroy a suspension.
    mutating func takeBreakNow() {
        // Remember what the break interrupted so it can be cancelled from the
        // overlay. Scheduled breaks (tick reaching the deadline) never set
        // this, which is what distinguishes manual from scheduled breaks.
        switch runtime.timerState {
        case let .working(deadline, _):
            runtime.manualBreakOrigin = ManualBreakOrigin(
                previous: .working,
                remaining: max(1, deadline.timeIntervalSince(clock.now)),
                capturedAt: clock.now
            )
        case let .warning(deadline):
            runtime.manualBreakOrigin = ManualBreakOrigin(
                previous: .warning,
                remaining: max(1, deadline.timeIntervalSince(clock.now)),
                capturedAt: clock.now
            )
        case let .postponed(deadline):
            runtime.manualBreakOrigin = ManualBreakOrigin(
                previous: .postponed,
                remaining: max(1, deadline.timeIntervalSince(clock.now)),
                capturedAt: clock.now
            )
        case .breakDue, .breaking, .breakCompleted, .suspended:
            return
        }
        runtime.timerState = .breakDue
    }

    // Returns a manually started break to the state it interrupted. The time
    // spent on the overlay is not focus time, so the cycle start shifts
    // forward by that amount. Nothing is recorded in statistics.
    mutating func cancelManualBreak() {
        guard isBreakingOrDue(runtime.timerState),
              let origin = runtime.manualBreakOrigin else { return }
        runtime.cycleStartDate = runtime.cycleStartDate
            .addingTimeInterval(max(0, clock.now.timeIntervalSince(origin.capturedAt)))
        // Stale capture from startBreak(); re-captured when the next break starts.
        runtime.cycleFocusDuration = nil
        runtime.breakStartedAt = nil
        switch origin.previous {
        case .working, .warning:
            let deadline = clock.now.addingTimeInterval(origin.remaining)
            let warning = deadline.addingTimeInterval(-settings.warningLeadTime)
            runtime.timerState = clock.now >= warning && settings.warningLeadTime > 0
                ? .warning(deadline: deadline)
                : .working(deadline: deadline, warningDeadline: warning)
        case .postponed:
            runtime.timerState = .postponed(deadline: clock.now.addingTimeInterval(origin.remaining))
        }
        runtime.manualBreakOrigin = nil
    }

    // Planned-ahead extension of the current focus window. Unlike postponing
    // at the overlay, this happens before the break is due and records nothing.
    mutating func extendFocus(by delta: TimeInterval) {
        guard canExtendFocus else { return }
        switch runtime.timerState {
        case let .working(deadline, warningDeadline):
            runtime.timerState = .working(
                deadline: deadline.addingTimeInterval(delta),
                warningDeadline: warningDeadline.addingTimeInterval(delta)
            )
        case let .warning(deadline):
            // Return to working and re-arm the warning for the new deadline.
            let newDeadline = deadline.addingTimeInterval(delta)
            runtime.timerState = .working(
                deadline: newDeadline,
                warningDeadline: newDeadline.addingTimeInterval(-settings.warningLeadTime)
            )
        case let .postponed(deadline):
            runtime.timerState = .postponed(deadline: deadline.addingTimeInterval(delta))
        default:
            return
        }
        runtime.focusExtended = true
    }

    // Honor-system reset: the user rested away from the screen, so the cycle
    // restarts as if a break just ended. No statistics are recorded.
    mutating func markBreakTaken() {
        switch runtime.timerState {
        case .working, .warning, .postponed:
            startWorkCycle()
        default:
            break
        }
    }

    mutating func suspend(until: Date?) {
        let previous: SuspendedState
        let remaining: TimeInterval
        switch runtime.timerState {
        case let .working(deadline, _):
            previous = .working
            remaining = deadline.timeIntervalSince(clock.now)
        case let .warning(deadline):
            previous = .warning
            remaining = deadline.timeIntervalSince(clock.now)
        case let .postponed(deadline):
            previous = .postponed
            remaining = deadline.timeIntervalSince(clock.now)
        default:
            return
        }
        runtime.timerState = .suspended(previous: previous, remaining: max(1, remaining), until: until)
        runtime.preservedAt = clock.now
        runtime.preservedRemaining = max(1, remaining)
    }

    mutating func resume() {
        guard case let .suspended(previous, remaining, _) = runtime.timerState else { return }
        // A pause at least as long as a break means the user rested away from
        // the screen: start a fresh cycle instead of restoring the countdown.
        if let preservedAt = runtime.preservedAt,
           clock.now.timeIntervalSince(preservedAt) >= settings.breakDuration {
            finishCycleAfterVerifiedRest()
            return
        }
        // Paused time is not focus time: push the cycle start forward by the pause length.
        if let preservedAt = runtime.preservedAt {
            runtime.cycleStartDate = runtime.cycleStartDate
                .addingTimeInterval(max(0, clock.now.timeIntervalSince(preservedAt)))
        }
        switch previous {
        case .working, .warning:
            let deadline = clock.now.addingTimeInterval(remaining)
            let warning = deadline.addingTimeInterval(-settings.warningLeadTime)
            runtime.timerState = clock.now >= warning && settings.warningLeadTime > 0
                ? .warning(deadline: deadline)
                : .working(deadline: deadline, warningDeadline: warning)
        case .postponed:
            runtime.timerState = .postponed(deadline: clock.now.addingTimeInterval(remaining))
        }
        runtime.preservedAt = nil
        runtime.preservedRemaining = nil
    }

    mutating func preserveForSleep() {
        switch runtime.timerState {
        case .working, .warning, .postponed:
            suspend(until: nil)
        case let .breaking(deadline, startedAt, duration):
            let remaining = max(1, deadline.timeIntervalSince(clock.now))
            runtime.timerState = .breaking(deadline: clock.now.addingTimeInterval(remaining), startedAt: startedAt, duration: duration)
            runtime.preservedAt = clock.now
            runtime.preservedRemaining = remaining
        case .breakDue, .breakCompleted:
            // State stays as-is, but the timestamp lets restoreAfterSleep()
            // detect a pause long enough to count as a taken break.
            runtime.preservedAt = clock.now
        case .suspended:
            break
        }
    }

    mutating func restoreAfterSleep() {
        // A user-requested timed pause outlives sleep and relaunch: while its
        // end date is in the future the pause stays active; once it has
        // passed, the whole pause counted as rest, so a fresh cycle starts.
        if case let .suspended(_, _, until) = runtime.timerState, let until {
            if clock.now < until { return }
            finishCycleAfterVerifiedRest()
            return
        }

        // A pause at least as long as a break means the user certainly rested:
        // start a fresh cycle as if a break just ended, crediting the focus
        // accumulated before the downtime so statistics do not lose it.
        if let preservedAt = runtime.preservedAt,
           clock.now.timeIntervalSince(preservedAt) >= settings.breakDuration {
            finishCycleAfterVerifiedRest()
            return
        }

        switch runtime.timerState {
        case let .breaking(_, startedAt, duration):
            if let remaining = runtime.preservedRemaining {
                runtime.timerState = .breaking(
                    deadline: clock.now.addingTimeInterval(remaining),
                    startedAt: startedAt,
                    duration: duration
                )
                runtime.preservedAt = nil
                runtime.preservedRemaining = nil
            }
        case .suspended:
            resume()
        case let .working(deadline, _), let .warning(deadline), let .postponed(deadline):
            // Crash recovery: the app was killed without preserveForSleep(),
            // leaving an absolute deadline behind. If it is stale by at least
            // a break's worth of time, the downtime counts as a taken break.
            if runtime.preservedAt == nil,
               clock.now.timeIntervalSince(deadline) >= settings.breakDuration {
                // Without a preserved timestamp the stale deadline is the best
                // available end of the last focus; recording it lets
                // startWorkCycle() reset tapering after a long-dead deadline.
                // It also charges tapering the whole nominal interval even if
                // the machine died seconds into the cycle — an over-estimate
                // the reset gap clears, and cheaper than tracking liveness.
                runtime.preservedAt = deadline
                startWorkCycle()
            }
        case .breakDue, .breakCompleted:
            // Short downtime with the overlay up: keep the state, drop the stamp.
            runtime.preservedAt = nil
            runtime.preservedRemaining = nil
        }
    }

    // Downtime verified by the system (lock, sleep, screen saver, or an
    // expired timed pause) lasted at least a break, so the cycle it
    // interrupted ends here. The focus accumulated before the downtime is
    // credited to the day it actually happened; when the downtime caught a
    // break in progress or on its completion screen, the break itself also
    // counts as completed — the user rested exactly as instructed and should
    // not lose the break just because the screen locked before they returned
    // to confirm it.
    private mutating func finishCycleAfterVerifiedRest() {
        let closed = closedCycleFocus()
        switch runtime.timerState {
        case .breaking, .breakDue, .breakCompleted:
            statistics.completedBreaks += 1
            statistics.lastCompletedBreakDate = clock.now
            if runtime.cycleViolated {
                statistics.currentCleanStreak = 0
            } else {
                statistics.currentCleanStreak += 1
                statistics.bestCleanStreak = max(statistics.bestCleanStreak, statistics.currentCleanStreak)
            }
        case .suspended, .working, .warning, .postponed:
            break
        }
        let minutes = max(0, Int((closed.duration / 60).rounded()))
        if minutes > 0 {
            creditFocus(minutes: minutes, on: closed.end)
        }
        startWorkCycle()
    }

    private mutating func creditFocus(minutes: Int, on date: Date) {
        statistics.focusMinutesByDay[FocusDay.key(for: date), default: 0] += minutes
        statistics.totalFocusMinutes += minutes
        statistics.pruneFocusHistory(now: clock.now)
    }

    // Deliberately not closedCycleFocus(): the nominal interval is the safer
    // fallback here. This runs on the completeBreak() path, where a missing
    // cycleFocusDuration means a pre-capture file was restored mid-break, and
    // measuring from cycleStartDate would count the break itself as focus.
    private func creditedFocusMinutes() -> Int {
        let duration = runtime.cycleFocusDuration
            ?? settings.effectiveWorkInterval(taperedFocus: runtime.taperedFocusSeconds)
        return max(0, Int((duration / 60).rounded()))
    }

    private func isBreakingOrCompleted(_ state: TimerState) -> Bool {
        if case .breaking = state { return true }
        if case .breakCompleted = state { return true }
        return false
    }

    private func isBreakingOrDue(_ state: TimerState) -> Bool {
        if case .breaking = state { return true }
        if case .breakDue = state { return true }
        return false
    }
}
