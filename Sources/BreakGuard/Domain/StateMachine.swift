import Foundation

struct StateMachine {
    var settings: AppSettings
    var statistics: Statistics
    var runtime: RuntimeState
    var clock: TimeProvider
    // True while a camera is in use and the hold setting is on. Deliberately
    // transient — set by the owner before each tick(), never persisted: a
    // stale flag restored from disk could hold breaks with no call running.
    var cameraHoldActive = false

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
            emergencyOverrideUsedAt: nil,
            lastTickAt: nil,
            lastFocusAt: nil
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
        stampHeartbeat()
        if cameraHoldActive {
            applyCameraHold()
        }
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
        case let .suspended(_, _, until):
            // Both ways a timed pause can end — this tick and the wake path in
            // restoreAfterSleep() — resolve through resume(), which routes an
            // elapsed end date to finishCycleAfterVerifiedRest(). One
            // resolution, so which handler notices first cannot matter.
            if let until, clock.now >= until {
                resume()
            }
        case .breakDue, .breakCompleted:
            break
        }
        return runtime.timerState
    }

    // Minute-coarse liveness stamps. Coarse because the runtime is persisted
    // after every tick and the store skips byte-identical payloads — a
    // second-precise stamp would defeat that and write the file every second.
    // lastFocusAt only moves while a countdown is running: the owner suspends
    // an unattended countdown before ticking, so by contract a countdown tick
    // is a monitored second of focus.
    private mutating func stampHeartbeat() {
        let coarse = Date(
            timeIntervalSinceReferenceDate:
                (clock.now.timeIntervalSinceReferenceDate / 60).rounded(.down) * 60
        )
        if runtime.lastTickAt != coarse {
            runtime.lastTickAt = coarse
        }
        switch runtime.timerState {
        case .working, .warning, .postponed:
            if runtime.lastFocusAt != coarse {
                runtime.lastFocusAt = coarse
            }
        case .breakDue, .breaking, .breakCompleted, .suspended:
            break
        }
    }

    // The remaining time the hold pins the countdown at: never less than the
    // warning lead and never less than the fixed runway, so ending a call
    // always leaves that much between the user and the break.
    var cameraHoldRunway: TimeInterval {
        max(currentWarningLeadTime, CameraHold.minimumRunway)
    }

    // True when the hold is what is currently keeping the countdown still —
    // drives the menu bar's on-call indication and the warning-notification
    // suppression. The margin is two ticks so the owner can cancel a pending
    // warning before the pinned remaining time reaches its fire date.
    var isCameraHoldEngaged: Bool {
        guard cameraHoldActive else { return false }
        switch runtime.timerState {
        case let .working(deadline, _), let .warning(deadline), let .postponed(deadline):
            return deadline.timeIntervalSince(clock.now) <= cameraHoldRunway + 2
        case .breakDue, .breaking, .breakCompleted, .suspended:
            return false
        }
    }

    // While a camera runs, no countdown may fall below the runway: the
    // deadline is pushed ahead of now each tick, freezing the remaining time
    // there. cycleStartDate is deliberately untouched, so the whole call keeps
    // counting as focus. A warning state stays a warning — only its deadline
    // is pinned. States at or past .breakDue are left alone — turning a
    // camera on must not dismiss a break already imposed.
    private mutating func applyCameraHold() {
        let floor = clock.now.addingTimeInterval(cameraHoldRunway)
        switch runtime.timerState {
        case let .working(deadline, _) where deadline < floor:
            runtime.timerState = .working(
                deadline: floor,
                warningDeadline: floor.addingTimeInterval(-currentWarningLeadTime)
            )
        case let .warning(deadline) where deadline < floor:
            runtime.timerState = .warning(deadline: floor)
        case let .postponed(deadline) where deadline < floor:
            runtime.timerState = .postponed(deadline: floor)
        case .working, .warning, .postponed, .breakDue, .breaking, .breakCompleted, .suspended:
            break
        }
    }

    // `at` is when the break began, which can predate the call: downtime is
    // noticed after the fact, and the break started the moment the screen went
    // away. The deadline is absolute from there and nothing moves it again, so
    // the countdown is pure wall clock — time asleep inside a break counts
    // toward it, exactly as it would if the user had simply walked away.
    mutating func startBreak(at start: Date? = nil) {
        let begin = min(start ?? clock.now, clock.now)
        let duration = settings.breakDuration
        runtime.cycleFocusDuration = max(0, begin.timeIntervalSince(runtime.cycleStartDate))
        runtime.breakStartedAt = begin
        runtime.timerState = .breaking(
            deadline: begin.addingTimeInterval(duration),
            startedAt: begin,
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
        // unless the last monitored focus is long enough ago that the workday
        // started over. The gap is measured against lastFocusAt, not the
        // closed cycle's end: administrative restarts overnight (wake
        // recovery, an expired timed pause) move the cycle's end forward
        // without any focus happening, and each one would re-arm the gap —
        // carrying tapering into the next morning. The closed end is only the
        // legacy fallback for files that predate the stamp.
        //
        // This runs on every one of those restarts, and a machine that
        // dark-wakes on a timer runs it dozens of times a night, so the answer
        // has to depend only on the anchor and the clock — never on how many
        // times it was asked.
        let closed = closedCycleFocus()
        let lastFocus = runtime.lastFocusAt ?? closed.end
        let tapered: TimeInterval
        if taperingDayStartedOver(since: lastFocus) {
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
            emergencyOverrideUsedAt: runtime.emergencyOverrideUsedAt,
            // Liveness is orthogonal to cycles.
            lastTickAt: runtime.lastTickAt,
            lastFocusAt: runtime.lastFocusAt
        )
    }

    // Whether enough has passed since the last monitored focus that tapering
    // belongs to a new day. Two rules, because one number cannot serve both
    // jobs: the configurable gap covers a long break inside a single day, and
    // a shorter fixed gap covers a night, which is identified by the local
    // calendar day changing rather than by its length. Requiring a real gap on
    // the day-boundary rule is what keeps midnight from handing a full window
    // back to someone still working — startWorkCycle() runs from
    // completeBreak() with only a break's worth of gap.
    private func taperingDayStartedOver(since lastFocus: Date) -> Bool {
        let gap = clock.now.timeIntervalSince(lastFocus)
        if gap >= settings.taperingResetGap { return true }
        let crossedIntoNewDay = FocusDay.key(for: clock.now) != FocusDay.key(for: lastFocus)
        return crossedIntoNewDay && gap >= FocusPace.taperingOvernightGap
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
            let lead = currentWarningLeadTime
            let deadline = clock.now.addingTimeInterval(origin.remaining)
            let warning = deadline.addingTimeInterval(-lead)
            runtime.timerState = clock.now >= warning && lead > 0
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
                warningDeadline: newDeadline.addingTimeInterval(-currentWarningLeadTime)
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
        suspend(until: until, at: clock.now)
    }

    // `timestamp` is when the user actually left, which can predate the call:
    // idle detection only fires after the threshold of input silence, so it
    // back-dates the bracket to the last input and the silent span itself
    // never counts as focus.
    mutating func suspend(until: Date?, at timestamp: Date) {
        let at = min(timestamp, clock.now)
        let previous: SuspendedState
        let remaining: TimeInterval
        switch runtime.timerState {
        case let .working(deadline, _):
            previous = .working
            remaining = deadline.timeIntervalSince(at)
        case let .warning(deadline):
            previous = .warning
            remaining = deadline.timeIntervalSince(at)
        case let .postponed(deadline):
            previous = .postponed
            remaining = deadline.timeIntervalSince(at)
        default:
            return
        }
        runtime.timerState = .suspended(previous: previous, remaining: max(1, remaining), until: until)
        runtime.preservedAt = at
        runtime.preservedRemaining = max(1, remaining)
    }

    mutating func resume() {
        guard case let .suspended(previous, remaining, until) = runtime.timerState else { return }
        // An elapsed timed pause always counted as verified rest — the same
        // resolution restoreAfterSleep() applies — so the tick path and the
        // wake path cannot disagree about what an expired pause means.
        if let until, clock.now >= until {
            finishCycleAfterVerifiedRest()
            return
        }
        // Deliberately no "a long enough pause counts as a break" branch here.
        // The only suspension that reaches this point without an end date is
        // the idle bracket, and input silence is not rest — restoreAfterSleep()
        // owns the one case that may start a cycle without a confirmed break.
        //
        // Paused time is not focus time: push the cycle start forward by the pause length.
        if let preservedAt = runtime.preservedAt {
            runtime.cycleStartDate = runtime.cycleStartDate
                .addingTimeInterval(max(0, clock.now.timeIntervalSince(preservedAt)))
        }
        switch previous {
        case .working, .warning:
            let lead = currentWarningLeadTime
            let deadline = clock.now.addingTimeInterval(remaining)
            let warning = deadline.addingTimeInterval(-lead)
            runtime.timerState = clock.now >= warning && lead > 0
                ? .warning(deadline: deadline)
                : .working(deadline: deadline, warningDeadline: warning)
        case .postponed:
            runtime.timerState = .postponed(deadline: clock.now.addingTimeInterval(remaining))
        }
        runtime.preservedAt = nil
        runtime.preservedRemaining = nil
    }

    // The screen going away — sleep, lock, screen saver, or a tick gap that
    // proves the process lost time — is the moment a break starts. Any
    // duration counts: a ten-second saver is still the user leaving, and the
    // app is not in the business of deciding that for them.
    //
    // Nothing here ever ends a break. A break already running keeps its own
    // wall-clock deadline, and only completeBreak() credits one.
    mutating func beginDowntimeBreak(at timestamp: Date) {
        let at = min(timestamp, clock.now)
        switch runtime.timerState {
        case .working, .warning, .postponed, .breakDue:
            startBreak(at: at)
        case .breaking, .breakCompleted:
            // Already resting; the deadline stands.
            break
        case .suspended:
            // A user-requested pause owns the state until it expires.
            break
        }
    }

    mutating func beginDowntimeBreak() {
        beginDowntimeBreak(at: clock.now)
    }

    // Input silence on a machine that is still awake. Deliberately weaker than
    // downtime: nobody has verified the user left, only that they stopped
    // typing, which reading a long page does too. So this stops the countdown —
    // keeping unattended minutes out of the focus statistics — and does nothing
    // else. It never starts a break, never credits one, never restarts a cycle.
    //
    // Back-dated because idle is noticed only after the threshold of silence
    // has already elapsed, so the bracket runs from the last real input.
    mutating func suspendForIdle(at timestamp: Date) {
        let at = min(timestamp, clock.now)
        // The bracket knows when focus actually stopped; the heartbeat went on
        // stamping until the absence was noticed, up to IdleAway.threshold
        // later, and a countdown that fell due in the meantime froze the stamp
        // at that moment rather than at the last input. The tapering reset
        // measures from this stamp, so it retreats with the bracket — left
        // ahead, a night shorter than the reset gap plus the overshoot carries
        // the whole previous day into the morning.
        //
        // Ahead of the switch, so it also covers the states that only record a
        // timestamp, and unconditional because moving the anchor earlier is
        // always the conservative direction.
        if let stamped = runtime.lastFocusAt, stamped > at {
            runtime.lastFocusAt = at
        }
        switch runtime.timerState {
        case .working, .warning, .postponed:
            suspend(until: nil, at: at)
        case .breaking, .breakCompleted, .breakDue:
            // A break in progress is already wall-clock; silence adds nothing
            // to it and must not shorten the wait for the Continue click.
            break
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

        // The work session ended. This is the one thing that starts a fresh
        // cycle without the user confirming a break, and it is deliberately the
        // same predicate that resets tapering: a night gives both a clean cycle
        // and a clean accumulator, while a two-hour lunch gives neither — the
        // user comes back to the completion screen and clicks.
        //
        // Anything shorter is left exactly as it is. A break in progress keeps
        // its wall-clock deadline and waits for Continue; a countdown resumes
        // where it stopped. Nothing else here may credit a break.
        // downtimeStart is the evidence that the user was away at all; the last
        // monitored focus is what the length is measured from. They differ once
        // absences chain — an evening lock followed by a morning wake starts
        // its break at the lock, and measuring from there would forget the
        // hours of nothing before it and re-arm the gap on every restart.
        if let awayFrom = downtimeStart,
           taperingDayStartedOver(since: runtime.lastFocusAt ?? awayFrom) {
            // Focus ended when the user left, not now. Without this the whole
            // absence is measured as focus and charged to both the statistics
            // and the tapering accumulator — a night away would arrive in the
            // morning as eight hours of work.
            if runtime.preservedAt == nil {
                runtime.preservedAt = awayFrom
            }
            finishCycleAfterVerifiedRest()
            return
        }

        switch runtime.timerState {
        case .breaking, .breakCompleted, .breakDue:
            // The deadline is absolute and time away counted toward it, so a
            // break slept through has simply elapsed: tick() moves it to the
            // completion screen, which waits for the click like any other.
            runtime.preservedAt = nil
            runtime.preservedRemaining = nil
        case .suspended:
            resume()
        case .working, .warning, .postponed:
            // Crash recovery: the app was killed with an absolute deadline
            // behind it. The heartbeat says when it stopped watching, and time
            // it could not see is downtime — which by the rules above starts a
            // break rather than quietly restarting the cycle.
            if runtime.preservedAt == nil, hasHeartbeatGap, let lastTick = runtime.lastTickAt {
                beginDowntimeBreak(at: lastTick)
            }
        }
    }

    // When the user stopped being at the machine, as far as anything here can
    // tell: the bracket if one was taken, otherwise the last tick that watched
    // a countdown. Nil when the app has been running all along, which is the
    // case where nothing may be inferred at all.
    private var downtimeStart: Date? {
        if let preservedAt = runtime.preservedAt { return preservedAt }
        switch runtime.timerState {
        case .breaking, .breakCompleted, .breakDue:
            // breakStartedAt, not the .breaking payload: a break that elapsed
            // during the downtime is already .breakCompleted, and the answer
            // must not change just because the countdown ran out mid-absence.
            if let startedAt = runtime.breakStartedAt { return startedAt }
        case .working, .warning, .postponed, .suspended:
            break
        }
        guard hasHeartbeatGap else { return nil }
        return lastWatchedMoment
    }

    // The latest moment the app can show it was still watching a countdown.
    // The heartbeat when there is one; otherwise the cycle's own deadline,
    // which is all a file written before the heartbeat existed leaves behind.
    private var lastWatchedMoment: Date? {
        if let lastTick = runtime.lastTickAt { return lastTick }
        switch runtime.timerState {
        case let .working(deadline, _), let .warning(deadline), let .postponed(deadline):
            return deadline
        case .breaking, .breakDue, .breakCompleted, .suspended:
            return nil
        }
    }

    // True when the process demonstrably lost time: no tick has stamped the
    // heartbeat for well over its minute-coarse granularity. A missing stamp
    // (pre-heartbeat file) also counts — the only way to observe that is a
    // relaunch, which is itself a gap.
    private var hasHeartbeatGap: Bool {
        guard let lastTick = runtime.lastTickAt else { return true }
        return clock.now.timeIntervalSince(lastTick) >= 150
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
        // The cap is defense in depth: no cycle legitimately runs that long,
        // so an excess is a monitoring gap that slipped past every bracket.
        let duration = min(closed.duration, StatisticsIntegrity.maxCreditablePerCycle)
        let minutes = max(0, Int((duration / 60).rounded()))
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

    // The warning lead of the cycle in progress. Cycle construction caps the
    // lead at half the window, but the interval a cycle actually runs is not
    // stored, so the paths that re-anchor a deadline mid-cycle reconstruct it
    // from the pace and the tapering total captured at cycle start — the same
    // basis creditedFocusMinutes() falls back to. Reading warningLeadTime raw
    // here would re-arm a warning the cycle's own rule forbids: with a lead
    // past half the window, resuming, cancelling a manual break, or extending
    // during the warning would land back in .warning early or immediately.
    private var currentWarningLeadTime: TimeInterval {
        settings.effectiveWarningLeadTime(
            for: settings.effectiveWorkInterval(taperedFocus: runtime.taperedFocusSeconds)
        )
    }

    // Deliberately not closedCycleFocus(): the nominal interval is the safer
    // fallback here. This runs on the completeBreak() path, where a missing
    // cycleFocusDuration means a pre-capture file was restored mid-break, and
    // measuring from cycleStartDate would count the break itself as focus.
    private func creditedFocusMinutes() -> Int {
        let duration = runtime.cycleFocusDuration
            ?? settings.effectiveWorkInterval(taperedFocus: runtime.taperedFocusSeconds)
        let capped = min(duration, StatisticsIntegrity.maxCreditablePerCycle)
        return max(0, Int((capped / 60).rounded()))
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
