import XCTest
@testable import BreakGuard

private struct FakeClock: TimeProvider {
    var now: Date
}

final class StateMachineTests: XCTestCase {
    func testWorkingTransitionsToWarningAndBreakDue() {
        let start = Date(timeIntervalSince1970: 1_000)
        var settings = AppSettings.defaults
        settings.workInterval = 10 * 60
        settings.warningLeadTime = 60
        var clock = FakeClock(now: start)
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(9 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .warning(deadline: start.addingTimeInterval(10 * 60)))

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
    }

    func testFocusPaceScalesTheWorkInterval() {
        let start = Date(timeIntervalSince1970: 1_500)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.warningLeadTime = 60

        let cases: [(FocusPace, TimeInterval)] = [
            (.moreBreaks, 24 * 60),
            (.normal, 30 * 60),
            (.deepFocus, 36 * 60)
        ]
        for (pace, expected) in cases {
            settings.focusPace = pace
            let machine = StateMachine(settings: settings, clock: FakeClock(now: start))
            guard case let .working(deadline, warningDeadline) = machine.runtime.timerState else {
                return XCTFail("Expected working state for \(pace)")
            }
            XCTAssertEqual(deadline, start.addingTimeInterval(expected))
            XCTAssertEqual(warningDeadline, start.addingTimeInterval(expected - 60))
        }
    }

    func testFocusPaceCycleCreditsActualElapsedMinutes() {
        let start = Date(timeIntervalSince1970: 1_600)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 60
        settings.focusPace = .deepFocus
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(36 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()

        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: clock.now)], 36)
    }

    func testFirstPostponementViolatesCycleOnce() {
        let start = Date(timeIntervalSince1970: 2_000)
        var clock = FakeClock(now: start)
        var machine = StateMachine(clock: clock)

        machine.takeBreakNow()
        machine.postpone(by: 120)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 0)
        XCTAssertEqual(machine.statistics.violatedCycles, 1)
        XCTAssertEqual(machine.statistics.totalPostponements, 1)

        clock.now = start.addingTimeInterval(10)
        machine.clock = clock
        machine.runtime.timerState = .breakDue
        machine.postpone(by: 120)
        XCTAssertEqual(machine.statistics.violatedCycles, 1)
        XCTAssertEqual(machine.statistics.totalPostponements, 2)
    }

    func testTakeBreakNowDoesNotDestroySuspension() {
        let start = Date(timeIntervalSince1970: 4_200)
        let clock = FakeClock(now: start)
        var machine = StateMachine(clock: clock)
        machine.suspend(until: start.addingTimeInterval(3_600))
        let suspended = machine.runtime.timerState

        machine.takeBreakNow()

        XCTAssertEqual(machine.runtime.timerState, suspended)
        XCTAssertNil(machine.runtime.manualBreakOrigin)
    }

    func testTakeBreakNowIsNoOpDuringBreakAndCompletion() {
        let start = Date(timeIntervalSince1970: 4_300)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 10 * 60
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        let breaking = machine.runtime.timerState

        clock.now = clock.now.addingTimeInterval(30)
        machine.clock = clock
        machine.takeBreakNow()
        XCTAssertEqual(machine.runtime.timerState, breaking)
        XCTAssertNil(machine.runtime.manualBreakOrigin)

        clock.now = clock.now.addingTimeInterval(31)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.takeBreakNow()
        XCTAssertEqual(machine.runtime.timerState, .breakCompleted)
    }

    func testCleanBreakIncrementsStreakAndCreditsElapsedFocusMinutes() {
        let start = Date(timeIntervalSince1970: 3_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(7 * 60)
        machine.clock = clock
        machine.takeBreakNow()
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()

        XCTAssertEqual(machine.statistics.completedBreaks, 1)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 1)
        XCTAssertEqual(machine.statistics.bestCleanStreak, 1)
        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: clock.now)], 7)
    }

    func testFullWorkIntervalCreditsIntervalMinutes() {
        let start = Date(timeIntervalSince1970: 3_500)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()

        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: clock.now)], 30)
    }

    func testPostponedTimeCountsTowardFocusMinutes() {
        let start = Date(timeIntervalSince1970: 3_600)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 10 * 60
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.postpone(by: 5 * 60)

        clock.now = start.addingTimeInterval(15 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()

        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: clock.now)], 15)
    }

    func testSuspendedTimeIsExcludedFromFocusMinutes() {
        let start = Date(timeIntervalSince1970: 3_700)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        // Work 5 minutes, pause 30 seconds (short enough to resume in place),
        // then work the remaining 25.
        clock.now = start.addingTimeInterval(5 * 60)
        machine.clock = clock
        machine.suspend(until: nil)

        clock.now = start.addingTimeInterval(5 * 60 + 30)
        machine.clock = clock
        machine.resume()

        clock.now = start.addingTimeInterval(30 * 60 + 30)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()

        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: clock.now)], 30)
    }

    func testExtendFocusShiftsWorkingDeadlinesWithoutRecordingStatistics() {
        let start = Date(timeIntervalSince1970: 6_000)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.warningLeadTime = 60
        let clock = FakeClock(now: start)
        var machine = StateMachine(settings: settings, clock: clock)

        machine.extendFocus(by: 35 * 60)

        guard case let .working(deadline, warningDeadline) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline, start.addingTimeInterval(65 * 60))
        XCTAssertEqual(warningDeadline, start.addingTimeInterval(64 * 60))
        XCTAssertEqual(machine.statistics, .empty)
        XCTAssertFalse(machine.runtime.cycleViolated)
        XCTAssertTrue(machine.runtime.focusExtended)
    }

    func testExtendFocusDuringWarningRearmsTheWarning() {
        let start = Date(timeIntervalSince1970: 6_100)
        var settings = AppSettings.defaults
        settings.workInterval = 10 * 60
        settings.warningLeadTime = 60
        var clock = FakeClock(now: start)
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(9 * 60 + 30)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .warning(deadline: start.addingTimeInterval(10 * 60)))

        machine.extendFocus(by: 15 * 60)
        guard case let .working(deadline, warningDeadline) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline, start.addingTimeInterval(25 * 60))
        XCTAssertEqual(warningDeadline, start.addingTimeInterval(24 * 60))

        clock.now = start.addingTimeInterval(24 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .warning(deadline: start.addingTimeInterval(25 * 60)))

        clock.now = start.addingTimeInterval(25 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
    }

    func testExtendFocusShiftsPostponedDeadline() {
        let start = Date(timeIntervalSince1970: 6_200)
        let clock = FakeClock(now: start)
        var machine = StateMachine(clock: clock)

        machine.takeBreakNow()
        machine.postpone(by: 5 * 60)
        machine.extendFocus(by: 15 * 60)

        XCTAssertEqual(machine.runtime.timerState, .postponed(deadline: start.addingTimeInterval(20 * 60)))
        XCTAssertTrue(machine.runtime.focusExtended)
    }

    func testExtendFocusIsIgnoredDuringBreakAndSuspension() {
        let start = Date(timeIntervalSince1970: 6_300)
        let clock = FakeClock(now: start)
        var machine = StateMachine(clock: clock)

        machine.takeBreakNow()
        machine.startBreak()
        let breakingState = machine.runtime.timerState
        machine.extendFocus(by: 15 * 60)
        XCTAssertEqual(machine.runtime.timerState, breakingState)
        XCTAssertFalse(machine.runtime.focusExtended)

        var suspendedMachine = StateMachine(clock: clock)
        suspendedMachine.suspend(until: nil)
        let suspendedState = suspendedMachine.runtime.timerState
        suspendedMachine.extendFocus(by: 15 * 60)
        XCTAssertEqual(suspendedMachine.runtime.timerState, suspendedState)
        XCTAssertFalse(suspendedMachine.runtime.focusExtended)
    }

    func testFocusExtendedClearsWhenANewCycleStarts() {
        let start = Date(timeIntervalSince1970: 6_500)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 10 * 60
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        // Completed break clears the flag.
        machine.extendFocus(by: 5 * 60)
        XCTAssertTrue(machine.runtime.focusExtended)
        clock.now = start.addingTimeInterval(15 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()
        XCTAssertFalse(machine.runtime.focusExtended)

        // "Just Took a Break" clears it too.
        machine.extendFocus(by: 5 * 60)
        XCTAssertTrue(machine.runtime.focusExtended)
        machine.markBreakTaken()
        XCTAssertFalse(machine.runtime.focusExtended)
    }

    func testExtendedCycleCreditsTheExtraFocusMinutes() {
        let start = Date(timeIntervalSince1970: 6_400)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 60
        var clock = FakeClock(now: start)
        var machine = StateMachine(settings: settings, clock: clock)

        machine.extendFocus(by: 35 * 60)

        clock.now = start.addingTimeInterval(65 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()

        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: clock.now)], 65)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 1)
        XCTAssertEqual(machine.statistics.violatedCycles, 0)
    }

    func testMarkBreakTakenRestartsCycleWithoutRecordingStatistics() {
        let start = Date(timeIntervalSince1970: 3_800)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        // 20 minutes in, with a postponement already on the cycle.
        clock.now = start.addingTimeInterval(20 * 60)
        machine.clock = clock
        machine.takeBreakNow()
        machine.postpone(by: 5 * 60)
        let statisticsBefore = machine.statistics

        machine.markBreakTaken()

        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 30 * 60, accuracy: 0.1)
        XCTAssertEqual(machine.statistics, statisticsBefore)
        XCTAssertFalse(machine.runtime.cycleViolated)
        XCTAssertEqual(machine.runtime.cyclePostponements, 0)
        XCTAssertEqual(machine.runtime.cycleStartDate, clock.now)
    }

    func testMarkBreakTakenIsIgnoredDuringBreakAndSuspension() {
        let start = Date(timeIntervalSince1970: 3_900)
        let clock = FakeClock(now: start)
        var machine = StateMachine(clock: clock)

        machine.takeBreakNow()
        machine.startBreak()
        let breakingState = machine.runtime.timerState
        machine.markBreakTaken()
        XCTAssertEqual(machine.runtime.timerState, breakingState)

        var suspendedMachine = StateMachine(clock: clock)
        suspendedMachine.suspend(until: nil)
        let suspendedState = suspendedMachine.runtime.timerState
        suspendedMachine.markBreakTaken()
        XCTAssertEqual(suspendedMachine.runtime.timerState, suspendedState)
    }

    func testCompletedBreaksCreditDailyMinutes() {
        // Midday UTC keeps every event on one local calendar day in any zone.
        let start = Date(timeIntervalSince1970: 50_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        // Three same-day cycles, every completion counts.
        for focusMinutes in [10, 5, 7] {
            clock.now = clock.now.addingTimeInterval(TimeInterval(focusMinutes * 60))
            machine.clock = clock
            machine.takeBreakNow()
            machine.startBreak()
            clock.now = clock.now.addingTimeInterval(61)
            machine.clock = clock
            _ = machine.tick()
            machine.completeBreak()
        }

        XCTAssertEqual(machine.statistics.focusMinutesByDay, [FocusDay.key(for: clock.now): 22])
        XCTAssertEqual(machine.statistics.completedBreaks, 3)
    }

    func testCompletionIsIgnoredOutsideCompletedState() {
        var machine = StateMachine()
        machine.completeBreak()
        XCTAssertEqual(machine.statistics, .empty)
    }

    // MARK: - Long-pause reset

    func testShortPauseResumesWithPreservedRemaining() {
        let start = Date(timeIntervalSince1970: 7_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(5 * 60)
        machine.clock = clock
        machine.preserveForSleep()

        // Pause shorter than the break duration: resume where we left off.
        clock.now = clock.now.addingTimeInterval(60)
        machine.clock = clock
        machine.restoreAfterSleep()

        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 25 * 60, accuracy: 0.1)
        // A short pause resumes in place and credits nothing.
        XCTAssertEqual(machine.statistics, .empty)
    }

    func testPauseAtLeastBreakDurationStartsFreshCycle() {
        let start = Date(timeIntervalSince1970: 7_100)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(5 * 60)
        machine.clock = clock
        machine.preserveForSleep()

        clock.now = clock.now.addingTimeInterval(2 * 60)
        machine.clock = clock
        machine.restoreAfterSleep()

        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 30 * 60, accuracy: 0.1)
        XCTAssertEqual(machine.runtime.cycleStartDate, clock.now)
        XCTAssertEqual(machine.runtime.cyclePostponements, 0)
        // The 5 minutes of focus before the downtime are credited to the day
        // they happened, but no break is counted for an arbitrary lock.
        let dayKey = FocusDay.key(for: start.addingTimeInterval(5 * 60))
        XCTAssertEqual(machine.statistics.focusMinutesByDay, [dayKey: 5])
        XCTAssertEqual(machine.statistics.completedBreaks, 0)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 0)
    }

    func testLongSleepDuringBreakStartsFreshCycle() {
        let start = Date(timeIntervalSince1970: 7_200)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        machine.takeBreakNow()
        machine.startBreak()
        machine.preserveForSleep()

        clock.now = clock.now.addingTimeInterval(3 * 60)
        machine.clock = clock
        machine.restoreAfterSleep()

        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertNil(machine.runtime.breakStartedAt)
        XCTAssertNil(machine.runtime.manualBreakOrigin)
        // The sleep finished the break: it counts as completed and the focus
        // captured at startBreak() is credited.
        XCTAssertEqual(machine.statistics.completedBreaks, 1)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 1)
        let dayKey = FocusDay.key(for: start.addingTimeInterval(10 * 60))
        XCTAssertEqual(machine.statistics.focusMinutesByDay, [dayKey: 10])
    }

    func testDowntimeWithBreakDueResetsOnlyAfterLongPause() {
        let start = Date(timeIntervalSince1970: 7_300)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 10 * 60
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)

        // Short downtime keeps the pending break.
        machine.preserveForSleep()
        clock.now = clock.now.addingTimeInterval(30)
        machine.clock = clock
        machine.restoreAfterSleep()
        XCTAssertEqual(machine.runtime.timerState, .breakDue)
        XCTAssertNil(machine.runtime.preservedAt)

        // A long one counts as the break itself: completed, with the focus
        // up to the preservation moment (10.5 min, rounded) credited.
        machine.preserveForSleep()
        clock.now = clock.now.addingTimeInterval(2 * 60)
        machine.clock = clock
        machine.restoreAfterSleep()
        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(machine.statistics.completedBreaks, 1)
        let dayKey = FocusDay.key(for: start.addingTimeInterval(10 * 60 + 30))
        XCTAssertEqual(machine.statistics.focusMinutesByDay, [dayKey: 11])
    }

    func testInitFromPersistedDataAppliesLongPauseReset() {
        let start = Date(timeIntervalSince1970: 7_400)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(5 * 60)
        machine.clock = clock
        machine.preserveForSleep()

        // Relaunch hours later: the downtime counts as a taken break.
        let relaunch = FakeClock(now: start.addingTimeInterval(9 * 3600))
        let restored = StateMachine(data: machine.data, clock: relaunch)

        guard case let .working(deadline, _) = restored.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(relaunch.now), 30 * 60, accuracy: 0.1)
        XCTAssertEqual(restored.runtime.cycleStartDate, relaunch.now)
    }

    func testStaleDeadlineAfterCrashStartsFreshCycle() {
        let start = Date(timeIntervalSince1970: 7_500)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 10 * 60
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        // The app was killed without preserveForSleep(): the persisted state is
        // still .working with an absolute deadline. Long after that deadline,
        // restoration starts a fresh cycle.
        clock.now = start.addingTimeInterval(12 * 60)
        machine.clock = clock
        machine.restoreAfterSleep()

        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 10 * 60, accuracy: 0.1)

        // A deadline that is not yet stale is left untouched.
        var freshMachine = StateMachine(settings: settings, clock: FakeClock(now: start))
        let stateBefore = freshMachine.runtime.timerState
        freshMachine.restoreAfterSleep()
        XCTAssertEqual(freshMachine.runtime.timerState, stateBefore)
    }

    // MARK: - Manual breaks

    func testTakeBreakNowRecordsManualOriginAndScheduledDoesNot() {
        let start = Date(timeIntervalSince1970: 8_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        machine.takeBreakNow()

        let origin = machine.runtime.manualBreakOrigin
        XCTAssertEqual(origin?.previous, .working)
        XCTAssertEqual(origin?.remaining ?? 0, 20 * 60, accuracy: 0.1)
        XCTAssertEqual(origin?.capturedAt, clock.now)

        // A scheduled break (deadline reached through tick) sets no origin.
        var scheduled = StateMachine(settings: settings, clock: FakeClock(now: start))
        var scheduledClock = FakeClock(now: start.addingTimeInterval(30 * 60))
        scheduled.clock = scheduledClock
        XCTAssertEqual(scheduled.tick(), .breakDue)
        scheduled.startBreak()
        XCTAssertNil(scheduled.runtime.manualBreakOrigin)

        // And cancel does nothing for it.
        scheduledClock.now = scheduledClock.now.addingTimeInterval(30)
        scheduled.clock = scheduledClock
        let breakingState = scheduled.runtime.timerState
        scheduled.cancelManualBreak()
        XCTAssertEqual(scheduled.runtime.timerState, breakingState)
    }

    func testCancelManualBreakRestoresRemainingAndExcludesOverlayTime() {
        let start = Date(timeIntervalSince1970: 8_100)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        // 18 minutes in, take a manual break with 12 minutes remaining.
        clock.now = start.addingTimeInterval(18 * 60)
        machine.clock = clock
        machine.takeBreakNow()
        machine.startBreak()

        // Sit on the overlay for 3 minutes, then cancel.
        clock.now = clock.now.addingTimeInterval(3 * 60)
        machine.clock = clock
        machine.cancelManualBreak()

        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 12 * 60, accuracy: 0.1)
        XCTAssertNil(machine.runtime.manualBreakOrigin)
        XCTAssertNil(machine.runtime.breakStartedAt)
        XCTAssertNil(machine.runtime.cycleFocusDuration)
        XCTAssertEqual(machine.statistics, .empty)

        // Finish the cycle: the 3 overlay minutes must not be credited.
        clock.now = clock.now.addingTimeInterval(12 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()
        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: clock.now)], 30)
    }

    func testCancelManualBreakLandsInWarningWhenInsideLeadTime() {
        let start = Date(timeIntervalSince1970: 8_200)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 10 * 60
        settings.warningLeadTime = 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(9 * 60 + 30)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .warning(deadline: start.addingTimeInterval(10 * 60)))

        machine.takeBreakNow()
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(10)
        machine.clock = clock
        machine.cancelManualBreak()

        XCTAssertEqual(machine.runtime.timerState, .warning(deadline: clock.now.addingTimeInterval(30)))
    }

    func testCancelIsIgnoredOutsideABreak() {
        let start = Date(timeIntervalSince1970: 8_300)
        let clock = FakeClock(now: start)
        var machine = StateMachine(clock: clock)

        let stateBefore = machine.runtime.timerState
        machine.cancelManualBreak()
        XCTAssertEqual(machine.runtime.timerState, stateBefore)
    }

    func testPostponeDuringManualBreakClearsOriginAndRecordsViolation() {
        let start = Date(timeIntervalSince1970: 8_400)
        let clock = FakeClock(now: start)
        var machine = StateMachine(clock: clock)

        machine.takeBreakNow()
        machine.startBreak()
        machine.postpone(by: 2 * 60)

        XCTAssertNil(machine.runtime.manualBreakOrigin)
        XCTAssertTrue(machine.runtime.cycleViolated)
        XCTAssertEqual(machine.statistics.violatedCycles, 1)
        XCTAssertEqual(machine.runtime.timerState, .postponed(deadline: start.addingTimeInterval(2 * 60)))
    }

    func testManualBreakRunToCompletionCreditsNormallyAndClearsOrigin() {
        let start = Date(timeIntervalSince1970: 8_500)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        machine.takeBreakNow()
        machine.startBreak()
        XCTAssertEqual(machine.runtime.breakStartedAt, clock.now)

        clock.now = clock.now.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()

        XCTAssertEqual(machine.statistics.completedBreaks, 1)
        XCTAssertEqual(machine.statistics.focusMinutesByDay[FocusDay.key(for: clock.now)], 10)
        XCTAssertNil(machine.runtime.manualBreakOrigin)
        XCTAssertNil(machine.runtime.breakStartedAt)
    }

    func testSuspendPreservesRemainingTime() {
        let start = Date(timeIntervalSince1970: 4_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(5 * 60)
        machine.clock = clock
        machine.suspend(until: start.addingTimeInterval(10 * 60))

        guard case let .suspended(previous, remaining, _) = machine.runtime.timerState else {
            return XCTFail("Expected suspended state")
        }
        XCTAssertEqual(previous, .working)
        XCTAssertEqual(remaining, 25 * 60, accuracy: 0.1)

        // Resume before the pause reaches a break's length: pick up in place.
        clock.now = start.addingTimeInterval(5 * 60 + 30)
        machine.clock = clock
        machine.resume()
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 25 * 60, accuracy: 0.1)
    }

    func testResumeAfterLongPauseStartsFreshCycle() {
        let start = Date(timeIntervalSince1970: 4_100)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(5 * 60)
        machine.clock = clock
        machine.suspend(until: start.addingTimeInterval(12 * 3600))

        // Resuming after a pause at least as long as a break restarts the cycle.
        clock.now = start.addingTimeInterval(20 * 60)
        machine.clock = clock
        machine.resume()

        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 30 * 60, accuracy: 0.1)
        XCTAssertEqual(machine.runtime.cycleStartDate, clock.now)
        // The 5 minutes of focus before the pause survive in the day total.
        let dayKey = FocusDay.key(for: start.addingTimeInterval(5 * 60))
        XCTAssertEqual(machine.statistics.focusMinutesByDay, [dayKey: 5])
        XCTAssertEqual(machine.statistics.completedBreaks, 0)
    }

    func testTimedPauseSurvivesSleepWakeWhileActive() {
        let start = Date(timeIntervalSince1970: 4_200)
        var clock = FakeClock(now: start)
        var machine = StateMachine(clock: clock)

        let until = start.addingTimeInterval(12 * 3600)
        machine.suspend(until: until)
        let paused = machine.runtime.timerState

        // Sleep leaves an active timed pause untouched…
        machine.preserveForSleep()
        XCTAssertEqual(machine.runtime.timerState, paused)

        // …and waking before the end date keeps it active.
        clock.now = start.addingTimeInterval(6 * 3600)
        machine.clock = clock
        machine.restoreAfterSleep()
        XCTAssertEqual(machine.runtime.timerState, paused)
    }

    func testExpiredTimedPauseStartsFreshCycleAfterWake() {
        let start = Date(timeIntervalSince1970: 4_300)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        machine.suspend(until: start.addingTimeInterval(12 * 3600))

        // Waking after the end date means the whole pause was rest.
        clock.now = start.addingTimeInterval(13 * 3600)
        machine.clock = clock
        machine.restoreAfterSleep()

        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 30 * 60, accuracy: 0.1)
        // The pause started with no focus accumulated, so nothing is credited.
        XCTAssertEqual(machine.statistics, .empty)
    }

    // The reported bug: the user rested through the break, walked away, the
    // screen saver locked the screen, and unlocking after >= breakDuration
    // used to discard the completion screen together with the whole cycle's
    // focus. The rest is system-verified, so the break must count and the
    // focus must be credited.
    func testLongLockDuringBreakCompletedCountsBreakAndCreditsFocus() {
        let start = Date(timeIntervalSince1970: 4_400)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(2 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)

        // Screen saver / lock engages on the completion screen…
        machine.preserveForSleep()
        clock.now = clock.now.addingTimeInterval(2 * 60 + 15)
        machine.clock = clock
        machine.restoreAfterSleep()

        // …and unlocking starts a fresh cycle with everything credited.
        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(machine.runtime.cycleStartDate, clock.now)
        XCTAssertEqual(machine.statistics.completedBreaks, 1)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 1)
        XCTAssertEqual(machine.statistics.lastCompletedBreakDate, clock.now)
        let dayKey = FocusDay.key(for: start.addingTimeInterval(30 * 60))
        XCTAssertEqual(machine.statistics.focusMinutesByDay, [dayKey: 30])
    }

    func testExpiredTimedPauseCreditsFocusToPauseStartDay() {
        // Anchor to real local-calendar days so the pause spans midnight.
        let dayStart = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 200_000))
        let start = dayStart.addingTimeInterval(12 * 3600) // noon
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        var machine = StateMachine(settings: settings, clock: clock)

        // 25 minutes of focus, then "Pause Until 9 AM".
        clock.now = start.addingTimeInterval(25 * 60)
        machine.clock = clock
        machine.suspend(until: dayStart.addingTimeInterval(33 * 3600))

        // Waking the next morning after the end date starts a fresh cycle;
        // the focus belongs to the day it happened, not the day of the wake.
        clock.now = dayStart.addingTimeInterval(34 * 3600)
        machine.clock = clock
        machine.restoreAfterSleep()

        guard case .working = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(machine.statistics.focusMinutesByDay, [FocusDay.key(for: start): 25])
        XCTAssertEqual(machine.statistics.completedBreaks, 0)
    }

    // Runs one full focus-break cycle on a machine whose deadline is due now.
    private func completeCycle(_ machine: inout StateMachine, _ clock: inout FakeClock) {
        machine.runtime.timerState = .breakDue
        machine.startBreak()
        clock.now = clock.now.addingTimeInterval(machine.settings.breakDuration + 1)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak()
    }

    func testTaperingShortensSuccessiveCycles() {
        let start = Date(timeIntervalSince1970: 5_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        settings.focusPace = .tapering
        var machine = StateMachine(settings: settings, clock: clock)

        // The first session runs at full length.
        guard case let .working(firstDeadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(firstDeadline, start.addingTimeInterval(30 * 60))
        XCTAssertEqual(machine.runtime.completedFocusSessions, 0)

        clock.now = firstDeadline
        machine.clock = clock
        completeCycle(&machine, &clock)

        XCTAssertEqual(machine.runtime.completedFocusSessions, 1)
        guard case let .working(secondDeadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        let expected = 30 * 60 * FocusPace.taperingMultiplier(sessionsCompleted: 1)
        XCTAssertEqual(secondDeadline.timeIntervalSince(clock.now), expected, accuracy: 0.001)
        XCTAssertLessThan(expected, 30 * 60)
    }

    func testTaperingCountsHonorSystemBreaks() {
        let start = Date(timeIntervalSince1970: 5_500)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.focusPace = .tapering
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(20 * 60)
        machine.clock = clock
        machine.markBreakTaken()

        XCTAssertEqual(machine.runtime.completedFocusSessions, 1)
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        let expected = 30 * 60 * FocusPace.taperingMultiplier(sessionsCompleted: 1)
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), expected, accuracy: 0.001)
    }

    func testTaperingResetsAfterSixHourGap() {
        let start = Date(timeIntervalSince1970: 6_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        settings.focusPace = .tapering
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        completeCycle(&machine, &clock)
        XCTAssertEqual(machine.runtime.completedFocusSessions, 1)

        // Lock the screen for 7 hours: the workday is over.
        machine.preserveForSleep()
        clock.now = clock.now.addingTimeInterval(7 * 3600)
        machine.clock = clock
        machine.restoreAfterSleep()

        XCTAssertEqual(machine.runtime.completedFocusSessions, 0)
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline, clock.now.addingTimeInterval(30 * 60))
    }

    func testTaperingSurvivesShortVerifiedRest() {
        let start = Date(timeIntervalSince1970: 6_500)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        settings.focusPace = .tapering
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        completeCycle(&machine, &clock)
        XCTAssertEqual(machine.runtime.completedFocusSessions, 1)

        // A one-hour lunch away from the screen ends the cycle but not the day.
        machine.preserveForSleep()
        clock.now = clock.now.addingTimeInterval(3600)
        machine.clock = clock
        machine.restoreAfterSleep()

        XCTAssertEqual(machine.runtime.completedFocusSessions, 2)
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        let expected = 30 * 60 * FocusPace.taperingMultiplier(sessionsCompleted: 2)
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), expected, accuracy: 0.001)
    }

    func testTaperingResetsAfterCrashWithLongDeadDeadline() {
        let start = Date(timeIntervalSince1970: 7_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        settings.focusPace = .tapering
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        completeCycle(&machine, &clock)
        XCTAssertEqual(machine.runtime.completedFocusSessions, 1)

        // The app was killed mid-focus and relaunched 8 hours later: no
        // preserved timestamp, only a long-dead deadline.
        let data = machine.data
        clock.now = clock.now.addingTimeInterval(8 * 3600)
        let relaunched = StateMachine(data: data, clock: clock)

        XCTAssertEqual(relaunched.runtime.completedFocusSessions, 0)
        guard case let .working(deadline, _) = relaunched.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline, clock.now.addingTimeInterval(30 * 60))
    }

    func testSessionCountDoesNotAffectOtherPaces() {
        let start = Date(timeIntervalSince1970: 7_500)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.breakDuration = 2 * 60
        settings.focusPace = .normal
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        completeCycle(&machine, &clock)

        // The counter still tracks sessions (so switching to Tapering mid-day
        // picks up where the day is), but Normal ignores it.
        XCTAssertEqual(machine.runtime.completedFocusSessions, 1)
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline, clock.now.addingTimeInterval(30 * 60))
    }
}
