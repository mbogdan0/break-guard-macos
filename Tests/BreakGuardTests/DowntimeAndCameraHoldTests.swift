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
        machine.preserveForSleep(at: pauseStart)

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

    func testBackdatedIdleBracketCreditsFocusOnlyUpToLastInput() {
        let start = Date(timeIntervalSince1970: 300_000)
        var machine = makeMachine(at: start)

        // Last input 15 minutes in; idle noticed 10 minutes later.
        let lastInput = start.addingTimeInterval(15 * 60)
        let noticed = lastInput.addingTimeInterval(IdleAway.threshold)
        machine.clock = FakeClock(now: noticed)
        machine.preserveForSleep(at: lastInput)

        XCTAssertEqual(machine.runtime.preservedAt, lastInput)

        // Input returns two hours later: verified rest, credit stops at the
        // last input and lands on its day.
        let returned = start.addingTimeInterval(2 * 60 * 60)
        machine.clock = FakeClock(now: returned)
        machine.restoreAfterSleep()

        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: lastInput)], 15)
        XCTAssertEqual(machine.runtime.cycleStartDate, returned)
    }

    func testShortIdleBracketRestoresCountdownAndShiftsCycleStart() {
        let start = Date(timeIntervalSince1970: 400_000)
        var machine = makeMachine(at: start) { $0.breakDuration = 20 * 60 }

        let lastInput = start.addingTimeInterval(10 * 60)
        let noticed = lastInput.addingTimeInterval(IdleAway.threshold)
        machine.clock = FakeClock(now: noticed)
        machine.preserveForSleep(at: lastInput)

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

        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected a fresh working cycle")
        }
        XCTAssertEqual(machine.runtime.cycleStartDate, wake)
        XCTAssertEqual(
            deadline.timeIntervalSince(wake),
            machine.settings.effectiveWorkInterval,
            accuracy: 1
        )
        // Recovery is conservative: no statistics credit without a verified bracket.
        XCTAssertTrue(machine.statistics.focusMinutesByDay.isEmpty)
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

    func testCrashMidBreakRestartsTheBreakInsteadOfCompletingIt() {
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

        guard case let .breaking(deadline, _, duration) = machine.runtime.timerState else {
            return XCTFail("Expected the break to restart, got \(machine.runtime.timerState)")
        }
        XCTAssertEqual(deadline, relaunch.addingTimeInterval(duration))
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
        machine.preserveForSleep()
        machine.clock = FakeClock(now: lastFocus.addingTimeInterval(5 * 60 * 60 + 5 * 60))
        machine.restoreAfterSleep()
        XCTAssertGreaterThan(machine.runtime.taperedFocusSeconds, 0)

        // Morning restart 12 hours after the last focus. The intermediate
        // restart moved the closed cycle's end to only 7 hours ago — the old
        // reference — but no focus ran since, so tapering must reset.
        machine.clock = FakeClock(now: lastFocus.addingTimeInterval(12 * 60 * 60))
        machine.preserveForSleep()
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
        machine.preserveForSleep(at: lastInput)

        // The wake storm: sleep, wake, re-bracket, tick — every 15 minutes.
        var wake = lastInput.addingTimeInterval(15 * 60)
        let morning = localDate(2026, 8, 5, 7)
        while wake < morning {
            machine.clock = FakeClock(now: wake)
            machine.restoreAfterSleep()
            machine.preserveForSleep(at: lastInput)
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

        machine.preserveForSleep(at: lastInput)
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
        machine.preserveForSleep(at: lastInput)
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
        machine.preserveForSleep(at: lastInput)
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
        machine.preserveForSleep()

        machine.clock = FakeClock(now: bracket.addingTimeInterval(60 * 60))
        machine.restoreAfterSleep()

        XCTAssertEqual(
            machine.statistics.totalFocusMinutes,
            Int(StatisticsIntegrity.maxCreditablePerCycle / 60)
        )
    }

    // MARK: - Camera hold

    func testCameraHoldPinsCountdownAtTheRunway() {
        let start = Date(timeIntervalSince1970: 900_000)
        var machine = makeMachine(at: start)
        machine.cameraHoldActive = true
        let runway = machine.cameraHoldRunway
        XCTAssertEqual(runway, 2 * 60)

        // One minute short of the deadline: without the hold this is deep in
        // the warning window. With the lead equal to the runway the pin sits
        // exactly on the warning boundary, so the pinned state is .warning.
        var now = start.addingTimeInterval(29 * 60)
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .warning(deadline: now.addingTimeInterval(runway)))
        XCTAssertTrue(machine.isCameraHoldEngaged)

        // An hour of call later the break still has not fired.
        now = start.addingTimeInterval(90 * 60)
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .warning(deadline: now.addingTimeInterval(runway)))
        XCTAssertTrue(machine.isCameraHoldEngaged)
    }

    func testCameraHoldKeepsWorkingStateWhenLeadIsShorterThanRunway() {
        let start = Date(timeIntervalSince1970: 950_000)
        var machine = makeMachine(at: start) { $0.warningLeadTime = 60 }
        machine.cameraHoldActive = true
        let runway = machine.cameraHoldRunway
        XCTAssertEqual(runway, 2 * 60)

        // Pinned above the warning boundary: the warning fires only after the
        // call ends and the countdown falls to the lead.
        let now = start.addingTimeInterval(29 * 60)
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .working(
            deadline: now.addingTimeInterval(runway),
            warningDeadline: now.addingTimeInterval(runway - 60)
        ))
        XCTAssertTrue(machine.isCameraHoldEngaged)
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

        machine.cameraHoldActive = true
        XCTAssertEqual(
            machine.tick(),
            .warning(deadline: warningTime.addingTimeInterval(machine.cameraHoldRunway))
        )
    }

    func testEndingCallRunsFullWarningLeadBeforeBreakAndCountsHeldTimeAsFocus() {
        let start = Date(timeIntervalSince1970: 1_100_000)
        var machine = makeMachine(at: start)
        machine.cameraHoldActive = true
        let runway = machine.cameraHoldRunway

        // Long call across what would have been the break.
        let callEnd = start.addingTimeInterval(60 * 60)
        machine.clock = FakeClock(now: callEnd)
        _ = machine.tick()
        machine.cameraHoldActive = false

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

        machine.cameraHoldActive = true
        let runway = machine.cameraHoldRunway
        let now = start.addingTimeInterval(40 * 60) // past the postponed deadline
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .postponed(deadline: now.addingTimeInterval(runway)))
        XCTAssertTrue(machine.isCameraHoldEngaged)
    }

    func testCameraHoldNeverDismissesAnImposedBreak() {
        let start = Date(timeIntervalSince1970: 1_300_000)
        var machine = makeMachine(at: start)

        let due = start.addingTimeInterval(30 * 60)
        machine.clock = FakeClock(now: due)
        XCTAssertEqual(machine.tick(), .breakDue)

        machine.cameraHoldActive = true
        XCTAssertEqual(machine.tick(), .breakDue)
        XCTAssertFalse(machine.isCameraHoldEngaged)

        machine.startBreak()
        machine.clock = FakeClock(now: due.addingTimeInterval(machine.settings.breakDuration))
        XCTAssertEqual(machine.tick(), .breakCompleted)
    }

    func testCameraHoldIsInertFarFromTheDeadline() {
        let start = Date(timeIntervalSince1970: 1_400_000)
        var machine = makeMachine(at: start)
        machine.cameraHoldActive = true

        let now = start.addingTimeInterval(5 * 60)
        machine.clock = FakeClock(now: now)
        XCTAssertEqual(machine.tick(), .working(
            deadline: start.addingTimeInterval(30 * 60),
            warningDeadline: start.addingTimeInterval(28 * 60)
        ))
        XCTAssertFalse(machine.isCameraHoldEngaged)
    }
}
