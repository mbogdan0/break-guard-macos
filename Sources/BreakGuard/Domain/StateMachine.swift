import Foundation

struct StateMachine {
    var settings: AppSettings
    var statistics: Statistics
    var runtime: RuntimeState
    var clock: TimeProvider

    // A gap this long without focus means the workday ended: the tapering
    // session counter starts over and sessions run at full length again.
    static let taperingResetGap: TimeInterval = 6 * 60 * 60

    init(settings: AppSettings = .defaults, statistics: Statistics = .empty, clock: TimeProvider = SystemClock()) {
        var validated = settings
        validated.clamp()
        self.settings = validated
        self.statistics = statistics
        self.clock = clock
        let warning = clock.now.addingTimeInterval(max(0, validated.effectiveWorkInterval - validated.warningLeadTime))
        let deadline = clock.now.addingTimeInterval(validated.effectiveWorkInterval)
        self.runtime = RuntimeState(
            timerState: .working(deadline: deadline, warningDeadline: warning),
            cycleViolated: false,
            cyclePostponements: 0,
            focusExtended: false,
            cycleStartDate: clock.now,
            preservedAt: nil,
            preservedRemaining: nil,
            cycleFocusDuration: nil,
            breakStartedAt: nil,
            manualBreakOrigin: nil,
            completedFocusSessions: 0
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

        statistics.focusMinutesByDay[FocusDay.key(for: clock.now), default: 0] += creditedFocusMinutes()
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
        // The cycle being closed counts toward tapering unless the last focus
        // activity ended long enough ago that the workday started over.
        let lastFocusActivity = runtime.breakStartedAt ?? runtime.preservedAt
        let sessions: Int
        if let lastFocusActivity,
           clock.now.timeIntervalSince(lastFocusActivity) >= Self.taperingResetGap {
            sessions = 0
        } else {
            sessions = runtime.completedFocusSessions + 1
        }
        let interval = settings.effectiveWorkInterval(sessionsCompleted: sessions)
        runtime = RuntimeState(
            timerState: .working(
                deadline: clock.now.addingTimeInterval(interval),
                warningDeadline: clock.now.addingTimeInterval(max(0, interval - settings.warningLeadTime))
            ),
            cycleViolated: false,
            cyclePostponements: 0,
            focusExtended: false,
            cycleStartDate: clock.now,
            preservedAt: nil,
            preservedRemaining: nil,
            cycleFocusDuration: nil,
            breakStartedAt: nil,
            manualBreakOrigin: nil,
            completedFocusSessions: sessions
        )
    }

    mutating func postpone(by delay: TimeInterval) {
        let canPostpone: Bool
        if case .breakDue = runtime.timerState {
            canPostpone = true
        } else {
            canPostpone = isBreakingOrCompleted(runtime.timerState)
        }
        guard canPostpone else { return }
        if !runtime.cycleViolated {
            runtime.cycleViolated = true
            statistics.currentCleanStreak = 0
            statistics.violatedCycles += 1
        }
        runtime.cyclePostponements += 1
        statistics.totalPostponements += 1
        // Postponing a manual break opts into the standard postpone contract;
        // the penalty-free exit is cancelManualBreak().
        runtime.manualBreakOrigin = nil
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
        let focusEnd: Date
        let focusDuration: TimeInterval
        switch runtime.timerState {
        case .breaking, .breakDue, .breakCompleted:
            focusEnd = runtime.breakStartedAt ?? runtime.preservedAt ?? clock.now
            focusDuration = runtime.cycleFocusDuration
                ?? max(0, focusEnd.timeIntervalSince(runtime.cycleStartDate))
            statistics.completedBreaks += 1
            statistics.lastCompletedBreakDate = clock.now
            if runtime.cycleViolated {
                statistics.currentCleanStreak = 0
            } else {
                statistics.currentCleanStreak += 1
                statistics.bestCleanStreak = max(statistics.bestCleanStreak, statistics.currentCleanStreak)
            }
        case .suspended, .working, .warning, .postponed:
            focusEnd = runtime.preservedAt ?? clock.now
            focusDuration = max(0, focusEnd.timeIntervalSince(runtime.cycleStartDate))
        }
        let minutes = max(0, Int((focusDuration / 60).rounded()))
        if minutes > 0 {
            statistics.focusMinutesByDay[FocusDay.key(for: focusEnd), default: 0] += minutes
        }
        startWorkCycle()
    }

    private func creditedFocusMinutes() -> Int {
        let duration = runtime.cycleFocusDuration
            ?? settings.effectiveWorkInterval(sessionsCompleted: runtime.completedFocusSessions)
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
