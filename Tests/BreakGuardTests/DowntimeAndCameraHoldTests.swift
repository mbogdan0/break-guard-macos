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
