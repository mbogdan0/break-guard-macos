import XCTest
@testable import BreakGuard

private struct FakeClock: TimeProvider {
    var now: Date
}

// Downtime bracketing added for the phantom-focus class of bugs (a machine
// that stays awake unattended, or wakes without a matching sleep signal),
// plus the camera-call break hold.
final class DowntimeAndCameraHoldTests: XCTestCase {
    private func makeMachine(
        at start: Date,
        configure: (inout AppSettings) -> Void = { _ in }
    ) -> StateMachine {
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        settings.warningLeadTime = 2 * 60
        settings.focusPace = .normal
        configure(&settings)
        return StateMachine(settings: settings, clock: FakeClock(now: start))
    }

    // MARK: - Timed pause expiry is one resolution, not two

    func testTickAndWakePathsResolveExpiredTimedPauseIdentically() {
        let start = Date(timeIntervalSince1970: 100_000)
        var machine = makeMachine(at: start)

        // 10 minutes of focus, then a pause until the next "morning".
        let pauseStart = start.addingTimeInterval(10 * 60)
        let until = pauseStart.addingTimeInterval(10 * 60 * 60)
        machine.clock = FakeClock(now: pauseStart)
        machine.suspend(until: until)

        let wakeTime = until.addingTimeInterval(5)
        var tickPath = machine
        tickPath.clock = FakeClock(now: wakeTime)
        _ = tickPath.tick()

        var wakePath = machine
        wakePath.clock = FakeClock(now: wakeTime)
        wakePath.restoreAfterSleep()

        XCTAssertEqual(tickPath.runtime.timerState, wakePath.runtime.timerState)
        XCTAssertEqual(tickPath.statistics.focusMinutesByDay, wakePath.statistics.focusMinutesByDay)
        // Both credit exactly the pre-pause focus, to the day the pause began.
        XCTAssertEqual(
            tickPath.statistics.focusMinutesByDay[FocusDay.key(for: pauseStart)],
            10
        )
        XCTAssertEqual(tickPath.runtime.cycleStartDate, wakeTime)
    }

    // The reported incident: the pause expires on an unattended machine, the
    // fresh cycle starts ticking, and back-dated idle bracketing must keep
    // that unattended cycle out of the statistics.
    func testIdleBracketAfterExpiredPauseCreditsNothingForUnattendedCycle() {
        let start = Date(timeIntervalSince1970: 200_000)
        var machine = makeMachine(at: start)

        let pauseStart = start.addingTimeInterval(5 * 60)
        let until = pauseStart.addingTimeInterval(8 * 60 * 60)
        machine.clock = FakeClock(now: pauseStart)
        machine.suspend(until: until)

        // Pause expires with nobody there; the tick starts a fresh cycle.
        machine.clock = FakeClock(now: until)
        _ = machine.tick()
        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected a fresh working cycle after the pause expired")
        }
        let baseline = machine.statistics.focusMinutesByDay

        // Ten minutes later idle detection brackets back to the last input,
        // which predates the unattended cycle entirely.
        let noticed = until.addingTimeInterval(IdleAway.threshold)
        machine.clock = FakeClock(now: noticed)
        machine.suspendForIdle(at: pauseStart)

        // The user returns 40 minutes after the pause expired.
        let returned = until.addingTimeInterval(40 * 60)
        machine.clock = FakeClock(now: returned)
        machine.restoreAfterSleep()

        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected a fresh working cycle on return")
        }
        XCTAssertEqual(machine.runtime.cycleStartDate, returned)
        // Not a single phantom minute from the unattended span.
        XCTAssertEqual(machine.statistics.focusMinutesByDay, baseline)
    }

    // MARK: - Back-dated idle bracket

    func testBackdatedIdleBracketExcludesTheSilentSpanFromFocus() {
        let start = Date(timeIntervalSince1970: 300_000)
        var machine = makeMachine(at: start)

        // Last input 15 minutes in; idle noticed 10 minutes later.
        let lastInput = start.addingTimeInterval(15 * 60)
        let noticed = lastInput.addingTimeInterval(IdleAway.threshold)
        machine.clock = FakeClock(now: noticed)
        machine.suspendForIdle(at: lastInput)

        XCTAssertEqual(machine.runtime.preservedAt, lastInput)

        // Input returns two hours later. Silence is not rest, so nothing is
        // credited and no break is invented — the cycle simply carries on with
        // its start pushed forward by exactly the span nobody was watching.
        let returned = start.addingTimeInterval(2 * 60 * 60)
        machine.clock = FakeClock(now: returned)
        machine.restoreAfterSleep()

        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected the countdown to resume, got \(machine.runtime.timerState)")
        }
        XCTAssertTrue(machine.statistics.focusMinutesByDay.isEmpty)
        XCTAssertEqual(machine.statistics.completedBreaks, 0)
        XCTAssertEqual(
            machine.runtime.cycleStartDate,
            start.addingTimeInterval(returned.timeIntervalSince(lastInput))
        )
    }

    func testShortIdleBracketRestoresCountdownAndShiftsCycleStart() {
        let start = Date(timeIntervalSince1970: 400_000)
        var machine = makeMachine(at: start) { $0.breakDuration = 20 * 60 }

        let lastInput = start.addingTimeInterval(10 * 60)
        let noticed = lastInput.addingTimeInterval(IdleAway.threshold)
        machine.clock = FakeClock(now: noticed)
        machine.suspendForIdle(at: lastInput)

        // Back 5 minutes after the bracket opened — shorter than a break.
        let returned = noticed.addingTimeInterval(5 * 60)
        machine.clock = FakeClock(now: returned)
        machine.restoreAfterSleep()

        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected the countdown to resume")
        }
        // The away span (last input → return) is excluded from focus.
        let away = returned.timeIntervalSince(lastInput)
        XCTAssertEqual(
            machine.runtime.cycleStartDate,
            start.addingTimeInterval(away)
        )
        XCTAssertTrue(machine.statistics.focusMinutesByDay.isEmpty)
    }

    // MARK: - Input silence is not rest

    // The reported bug, stated directly. Reading on screen counts as idle, and
    // the idle bracket back-dates to the last keystroke — which is *before* the
    // break began. Measuring rest from there let a single mouse move finish a
    // break the user had not taken a second of.
    func testIdleBeforeABreakDoesNotFinishIt() {
        let start = Date(timeIntervalSince1970: 900_000)
        var machine = makeMachine(at: start)

        // Last keystroke at 20 minutes; the user reads from there on.
        let lastInput = start.addingTimeInterval(20 * 60)
        machine.clock = FakeClock(now: lastInput)
        _ = machine.tick()

        // The break falls due at 30 minutes and starts.
        let due = start.addingTimeInterval(30 * 60)
        machine.clock = FakeClock(now: due)
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()

        // Idle detection notices the silence and brackets back to the keystroke.
        machine.suspendForIdle(at: lastInput)

        // Thirty seconds later the user jiggles the mouse.
        machine.clock = FakeClock(now: due.addingTimeInterval(30))
        machine.restoreAfterSleep()

        // The break is still running, with its own start and deadline intact.
        guard case let .breaking(deadline, startedAt, _) = machine.runtime.timerState else {
            return XCTFail("Expected the break to still be running, got \(machine.runtime.timerState)")
        }
        XCTAssertEqual(startedAt, due)
        XCTAssertEqual(deadline, due.addingTimeInterval(machine.settings.breakDuration))
        XCTAssertEqual(machine.statistics.completedBreaks, 0)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 0)
    }

    // The same silence during a countdown stops it — that part is about keeping
    // unattended minutes out of the statistics — but it may not restart the
    // cycle or credit anything.
    func testIdleDuringACountdownOnlyStopsTheClock() {
        let start = Date(timeIntervalSince1970: 910_000)
        var machine = makeMachine(at: start)

        let lastInput = start.addingTimeInterval(10 * 60)
        machine.clock = FakeClock(now: lastInput.addingTimeInterval(IdleAway.threshold))
        machine.suspendForIdle(at: lastInput)
        guard case .suspended = machine.runtime.timerState else {
            return XCTFail("Expected the countdown to stop, got \(machine.runtime.timerState)")
        }

        // Back well inside the reset gap: the same cycle carries on.
        machine.clock = FakeClock(now: lastInput.addingTimeInterval(25 * 60))
        machine.restoreAfterSleep()

        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected the countdown to resume, got \(machine.runtime.timerState)")
        }
        XCTAssertEqual(machine.statistics.completedBreaks, 0)
        XCTAssertTrue(machine.statistics.focusMinutesByDay.isEmpty)
    }

    // MARK: - Heartbeat-based crash/gap recovery

    func testHeartbeatRecoveryCatchesGapShorterThanRemainingInterval() {
        let start = Date(timeIntervalSince1970: 500_000)
        var machine = makeMachine(at: start)

        // Alive and ticking 5 minutes into the cycle.
        let lastAlive = start.addingTimeInterval(5 * 60)
        machine.clock = FakeClock(now: lastAlive)
        _ = machine.tick()

        // 10 unaccounted minutes later the deadline is still 15 minutes out,
        // so the old stale-deadline heuristic would have seen nothing.
        let wake = lastAlive.addingTimeInterval(10 * 60)
        machine.clock = FakeClock(now: wake)
        machine.restoreAfterSleep()

        // Time the app could not see is downtime, and downtime starts a break —
        // from where watching stopped, so the break already elapsed while the
        // process was gone. It does not hand back a fresh cycle on its own.
        guard case let .breaking(_, startedAt, _) = machine.runtime.timerState else {
            return XCTFail("Expected a break, got \(machine.runtime.timerState)")
        }
        // The heartbeat is minute-coarse, so the break starts at the last
        // minute the app can prove it was watching.
        XCTAssertEqual(startedAt, machine.runtime.lastTickAt)
        XCTAssertLessThanOrEqual(startedAt, lastAlive)
        XCTAssertEqual(machine.tick(), .breakCompleted)
        // Recovery is conservative: nothing credited until the user confirms.
        XCTAssertTrue(machine.statistics.focusMinutesByDay.isEmpty)
        XCTAssertEqual(machine.statistics.completedBreaks, 0)

        machine.completeBreak()
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected a fresh cycle after Continue")
        }
        XCTAssertEqual(machine.runtime.cycleStartDate, wake)
        XCTAssertEqual(
            deadline.timeIntervalSince(wake),
            machine.settings.effectiveWorkInterval,
            accuracy: 1
        )
        // Five minutes of watched focus preceded the gap; the gap itself none.
        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: lastAlive)], 5)
    }

    func testRestoreWithFreshHeartbeatLeavesRunningCycleAlone() {
        let start = Date(timeIntervalSince1970: 600_000)
        var machine = makeMachine(at: start)

        let now = start.addingTimeInterval(5 * 60)
        machine.clock = FakeClock(now: now)
        _ = machine.tick()
        let before = machine.runtime

        // A stray wake-side event with the app alive must be a no-op.
        machine.clock = FakeClock(now: now.addingTimeInterval(1))
        machine.restoreAfterSleep()
        XCTAssertEqual(machine.runtime, before)
    }

    // A break runs on wall clock, so dying inside one does not restart it: the
    // ten minutes the process was gone were ten minutes away from the screen,
    // which is what a break asks for. What survives is the confirmation.
    func testCrashMidBreakLeavesItElapsedAwaitingConfirmation() {
        let start = Date(timeIntervalSince1970: 700_000)
        var machine = makeMachine(at: start)

        let due = start.addingTimeInterval(30 * 60)
        machine.clock = FakeClock(now: due)
        _ = machine.tick()
        machine.startBreak()
        _ = machine.tick() // stamps the heartbeat during the break

        // Relaunch 10 minutes later: no sleep bracket, deadline long gone.
        let relaunch = due.addingTimeInterval(10 * 60)
        machine.clock = FakeClock(now: relaunch)
        machine.restoreAfterSleep()

        guard case let .breaking(deadline, startedAt, _) = machine.runtime.timerState else {
            return XCTFail("Expected the original break, got \(machine.runtime.timerState)")
        }
        XCTAssertEqual(startedAt, due)
        XCTAssertEqual(deadline, due.addingTimeInterval(machine.settings.breakDuration))
        XCTAssertEqual(machine.tick(), .breakCompleted)
        XCTAssertEqual(machine.statistics.completedBreaks, 0)
    }

    // MARK: - Tapering reset survives overnight administrative restarts

    // Regression: the reset gap used to be measured against the closed
    // cycle's end, and every unattended overnight restart (wake recovery, an
    // expired pause) moved that end forward — so a night away never looked
    // like 8 hours without focus, and tapering carried into the morning.
    func testTaperingResetsAfterUnattendedNightDespiteOvernightRestarts() {
        let start = Date(timeIntervalSince1970: 2_000_000)
        var machine = makeMachine(at: start) {
            $0.focusPace = .tapering
            $0.taperingResetGap = 8 * 60 * 60
        }

        // Bank a full cycle of tapering, then one attended tick.
        machine.clock = FakeClock(now: start.addingTimeInterval(30 * 60))
        _ = machine.tick()
        machine.startBreak()
        machine.clock = FakeClock(now: start.addingTimeInterval(32 * 60))
        _ = machine.tick()
        machine.completeBreak()
        XCTAssertGreaterThan(machine.runtime.taperedFocusSeconds, 0)

        let lastFocus = start.addingTimeInterval(42 * 60)
        machine.clock = FakeClock(now: lastFocus)
        _ = machine.tick()

        // Evening restart 5 hours after the last focus: inside the gap, so
        // tapering rightly carries.
        machine.clock = FakeClock(now: lastFocus.addingTimeInterval(5 * 60 * 60))
        machine.beginDowntimeBreak()
        machine.clock = FakeClock(now: lastFocus.addingTimeInterval(5 * 60 * 60 + 5 * 60))
        machine.restoreAfterSleep()
        XCTAssertGreaterThan(machine.runtime.taperedFocusSeconds, 0)

        // Morning restart 12 hours after the last focus. The intermediate
        // restart moved the closed cycle's end to only 7 hours ago — the old
        // reference — but no focus ran since, so tapering must reset.
        machine.clock = FakeClock(now: lastFocus.addingTimeInterval(12 * 60 * 60))
        machine.beginDowntimeBreak()
        machine.clock = FakeClock(now: lastFocus.addingTimeInterval(12 * 60 * 60 + 5 * 60))
        machine.restoreAfterSleep()
        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 0)
    }

    // MARK: - Tapering reset against a real night

    // Local-calendar anchored, because the day-boundary half of the reset rule
    // is evaluated in the user's own time zone.
    private func localDate(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        Calendar.current.date(
            from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
        )!
    }

    // Banks tapering and leaves the machine in a countdown, so the reset rule
    // has something to clear.
    private func machineWithBankedTapering(
        from start: Date,
        resetGap: TimeInterval = 8 * 60 * 60
    ) -> StateMachine {
        var machine = makeMachine(at: start) {
            $0.focusPace = .tapering
            $0.taperingResetGap = resetGap
        }
        machine.clock = FakeClock(now: start.addingTimeInterval(30 * 60))
        _ = machine.tick()
        machine.startBreak()
        machine.clock = FakeClock(now: start.addingTimeInterval(32 * 60))
        _ = machine.tick()
        machine.completeBreak()
        return machine
    }

    // Regression for the reported bug, end to end. A Mac that dark-wakes on a
    // timer posts a full wake every ~15 minutes all night, and each one runs
    // the reset rule. The night is 7h40m — under the configured 8-hour gap —
    // so before the day-boundary rule the morning inherited the whole previous
    // day's tapering.
    func testTaperingResetsAfterANightShorterThanTheConfiguredGap() {
        let start = localDate(2026, 8, 4, 12)
        var machine = machineWithBankedTapering(from: start)
        XCTAssertGreaterThan(machine.runtime.taperedFocusSeconds, 0)

        // Last real input at 23:20. The countdown keeps stamping until the idle
        // threshold notices, so the anchor lands 10 minutes late.
        let lastInput = localDate(2026, 8, 4, 23, 20)
        machine.clock = FakeClock(now: lastInput.addingTimeInterval(IdleAway.threshold))
        _ = machine.tick()

        // The idle bracket fires, back-dated to the last input.
        machine.beginDowntimeBreak(at: lastInput)

        // The wake storm: sleep, wake, re-bracket, tick — every 15 minutes.
        var wake = lastInput.addingTimeInterval(15 * 60)
        let morning = localDate(2026, 8, 5, 7)
        while wake < morning {
            machine.clock = FakeClock(now: wake)
            machine.restoreAfterSleep()
            machine.beginDowntimeBreak(at: lastInput)
            _ = machine.tick()
            wake = wake.addingTimeInterval(15 * 60)
        }

        machine.clock = FakeClock(now: morning)
        machine.restoreAfterSleep()

        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 0)
        // Nothing about the night may be credited as focus either.
        XCTAssertNil(machine.statistics.focusMinutesByDay[FocusDay.key(for: morning)])
    }

    // The anchor half of the fix, isolated inside a single calendar day so the
    // day-boundary rule cannot be what passes it. The bracket knows focus
    // stopped at 06:00; the heartbeat had already stamped 06:10, and measuring
    // from that stamp left the gap 5 minutes short of the 8-hour reset.
    func testIdleBracketRetreatsTheTaperingAnchorToTheLastInput() {
        let start = localDate(2026, 8, 4, 4)
        var machine = machineWithBankedTapering(from: start)

        let lastInput = localDate(2026, 8, 4, 6)
        machine.clock = FakeClock(now: lastInput.addingTimeInterval(IdleAway.threshold))
        _ = machine.tick()
        XCTAssertEqual(machine.runtime.lastFocusAt, lastInput.addingTimeInterval(IdleAway.threshold))

        machine.suspendForIdle(at: lastInput)
        XCTAssertEqual(machine.runtime.lastFocusAt, lastInput)

        // 8h05m after the last input, same calendar day.
        machine.clock = FakeClock(now: localDate(2026, 8, 4, 14, 5))
        machine.restoreAfterSleep()

        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 0)
    }

    // A gap well under the configured knob still ends the tapering day when it
    // crosses midnight.
    func testGapCrossingMidnightResetsTaperingBelowTheConfiguredGap() {
        let start = localDate(2026, 8, 4, 20)
        var machine = machineWithBankedTapering(from: start)

        let lastInput = localDate(2026, 8, 4, 23, 30)
        machine.beginDowntimeBreak(at: lastInput)
        machine.clock = FakeClock(now: localDate(2026, 8, 5, 4))
        machine.restoreAfterSleep()

        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 0)
    }

    // The same gap inside one day is just a long lunch, and tapering carries.
    func testSameDayGapUnderTheConfiguredGapDoesNotResetTapering() {
        let start = localDate(2026, 8, 4, 7)
        var machine = machineWithBankedTapering(from: start)
        let banked = machine.runtime.taperedFocusSeconds

        let lastInput = localDate(2026, 8, 4, 9)
        machine.beginDowntimeBreak(at: lastInput)
        machine.clock = FakeClock(now: localDate(2026, 8, 4, 13))
        machine.restoreAfterSleep()

        XCTAssertEqual(machine.runtime.taperedFocusSeconds, banked, accuracy: 0.001)
    }

    // Midnight alone must not hand a full window back to someone still at the
    // keyboard: the day-boundary rule needs a real gap behind it, and closing a
    // cycle at a break has only the break's worth.
    func testWorkingThroughMidnightDoesNotResetTapering() {
        let start = localDate(2026, 8, 4, 22)
        var machine = machineWithBankedTapering(from: start)
        let banked = machine.runtime.taperedFocusSeconds

        machine.clock = FakeClock(now: localDate(2026, 8, 4, 23, 58))
        _ = machine.tick()
        machine.startBreak()
        machine.clock = FakeClock(now: localDate(2026, 8, 5, 0, 1))
        _ = machine.tick()
        machine.completeBreak()

        XCTAssertGreaterThan(machine.runtime.taperedFocusSeconds, banked)
    }

    // MARK: - Statistics cap

    func testVerifiedRestCreditIsCappedPerCycle() {
        let start = Date(timeIntervalSince1970: 800_000)
        var machine = makeMachine(at: start)

        // A six-hour span that somehow slipped past every bracket.
        let bracket = start.addingTimeInterval(6 * 60 * 60)
        machine.clock = FakeClock(now: bracket)
        machine.beginDowntimeBreak()

        machine.clock = FakeClock(now: bracket.addingTimeInterval(60 * 60))
        machine.restoreAfterSleep()
        _ = machine.tick()
        machine.completeBreak()

        XCTAssertEqual(
            machine.statistics.totalFocusMinutes,
            Int(StatisticsIntegrity.maxCreditablePerCycle / 60)
        )
    }

    // MARK: - Camera hold

    func testCameraHoldPinsCountdownAtTheRunway() {
        let start = Date(timeIntervalSince1970: 900_000)
        var machine = makeMachine(at: start)
        machine.callHoldActive = true
        let runway = machine.callHoldRunway
        XCTAssertEqual(runway, 2 * 60)

        // One minute short of the deadline: without the hold this is deep in
        // the warning window. With the lead equal to the runway the pin sits
        // exactly on the warning boundary, so the pinned state is .warning.
        var now = start.addingTimeInterval(29 * 60)
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .warning(deadline: now.addingTimeInterval(runway)))
        XCTAssertTrue(machine.isCallHoldEngaged)

        // An hour of call later the break still has not fired.
        now = start.addingTimeInterval(90 * 60)
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .warning(deadline: now.addingTimeInterval(runway)))
        XCTAssertTrue(machine.isCallHoldEngaged)
    }

    func testCameraHoldKeepsWorkingStateWhenLeadIsShorterThanRunway() {
        let start = Date(timeIntervalSince1970: 950_000)
        var machine = makeMachine(at: start) { $0.warningLeadTime = 60 }
        machine.callHoldActive = true
        let runway = machine.callHoldRunway
        XCTAssertEqual(runway, 2 * 60)

        // Pinned above the warning boundary: the warning fires only after the
        // call ends and the countdown falls to the lead.
        let now = start.addingTimeInterval(29 * 60)
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .working(
            deadline: now.addingTimeInterval(runway),
            warningDeadline: now.addingTimeInterval(runway - 60)
        ))
        XCTAssertTrue(machine.isCallHoldEngaged)
    }

    func testCameraHoldPinsAnActiveWarningDeadline() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        var machine = makeMachine(at: start)

        // Reach the warning window first, then the call starts.
        let warningTime = start.addingTimeInterval(28 * 60 + 30)
        machine.clock = FakeClock(now: warningTime)
        guard case .warning = machine.tick() else {
            return XCTFail("Expected to be in the warning window")
        }

        machine.callHoldActive = true
        XCTAssertEqual(
            machine.tick(),
            .warning(deadline: warningTime.addingTimeInterval(machine.callHoldRunway))
        )
    }

    func testEndingCallRunsFullWarningLeadBeforeBreakAndCountsHeldTimeAsFocus() {
        let start = Date(timeIntervalSince1970: 1_100_000)
        var machine = makeMachine(at: start)
        machine.callHoldActive = true
        let runway = machine.callHoldRunway

        // Long call across what would have been the break.
        let callEnd = start.addingTimeInterval(60 * 60)
        machine.clock = FakeClock(now: callEnd)
        _ = machine.tick()
        machine.callHoldActive = false

        // The full warning lead still stands between the call and the break.
        let dueAt = callEnd.addingTimeInterval(runway)
        machine.clock = FakeClock(now: dueAt)
        XCTAssertEqual(machine.tick(), .breakDue)

        machine.startBreak()
        machine.clock = FakeClock(now: dueAt.addingTimeInterval(machine.settings.breakDuration))
        _ = machine.tick()
        machine.completeBreak()

        // The whole held hour counted as focus.
        XCTAssertGreaterThanOrEqual(machine.statistics.totalFocusMinutes, 60)
    }

    func testCameraHoldClampsPostponedDeadline() {
        let start = Date(timeIntervalSince1970: 1_200_000)
        var machine = makeMachine(at: start)

        machine.clock = FakeClock(now: start.addingTimeInterval(30 * 60))
        _ = machine.tick()
        machine.postpone(by: 4 * 60)

        machine.callHoldActive = true
        let runway = machine.callHoldRunway
        let now = start.addingTimeInterval(40 * 60) // past the postponed deadline
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .postponed(deadline: now.addingTimeInterval(runway)))
        XCTAssertTrue(machine.isCallHoldEngaged)
    }

    func testCameraHoldNeverDismissesAnImposedBreak() {
        let start = Date(timeIntervalSince1970: 1_300_000)
        var machine = makeMachine(at: start)

        let due = start.addingTimeInterval(30 * 60)
        machine.clock = FakeClock(now: due)
        XCTAssertEqual(machine.tick(), .breakDue)

        machine.callHoldActive = true
        XCTAssertEqual(machine.tick(), .breakDue)
        XCTAssertFalse(machine.isCallHoldEngaged)

        machine.startBreak()
        machine.clock = FakeClock(now: due.addingTimeInterval(machine.settings.breakDuration))
        XCTAssertEqual(machine.tick(), .breakCompleted)
    }

    func testCameraHoldIsInertFarFromTheDeadline() {
        let start = Date(timeIntervalSince1970: 1_400_000)
        var machine = makeMachine(at: start)
        machine.callHoldActive = true

        let now = start.addingTimeInterval(5 * 60)
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .working(
            deadline: start.addingTimeInterval(30 * 60),
            warningDeadline: start.addingTimeInterval(28 * 60)
        ))
        XCTAssertFalse(machine.isCallHoldEngaged)
    }
}
