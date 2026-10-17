import XCTest
@testable import BreakGuard

private struct SleepClock: TimeProvider {
    var now: Date
}

final class LongSleepTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_700_000)

    private func sleepingMachine() -> StateMachine {
        var machine = StateMachine(clock: SleepClock(now: start))
        machine.clock = SleepClock(now: start.addingTimeInterval(10 * 60))
        _ = machine.tick()
        machine.beginDowntimeBreak()
        return machine
    }

    func testAutomaticCompletionMatchesContinueAcrossPacesModesAndBreakOrigins() {
        for pace in FocusPace.allCases {
            for harder in [false, true] {
                for manual in [false, true] {
                    for alreadyComplete in [false, true] {
                        for duration: TimeInterval in [3600, 7200, 8 * 3600] {
                            var settings = AppSettings.defaults
                            settings.focusPace = pace
                            settings.harderToSkipBreaks = harder
                            var base = StateMachine(settings: settings, clock: SleepClock(now: start))
                            base.extendFocus(by: 120)
                            base.runtime.taperedFocusSeconds = 3600
                            base.runtime.emergencyOverrideUsedAt = start.addingTimeInterval(-600)
                            base.clock = SleepClock(now: start.addingTimeInterval(600))
                            _ = base.tick()
                            if manual {
                                base.takeBreakNow()
                                base.startBreak()
                            } else {
                                base.beginDowntimeBreak()
                            }
                            if alreadyComplete {
                                base.clock = SleepClock(now: base.clock.now.addingTimeInterval(settings.breakDuration))
                                _ = base.tick()
                            }
                            base.beginDowntimeBreak()
                            base.clock = SleepClock(now: base.clock.now.addingTimeInterval(duration))
                            var automatic = base
                            automatic.restoreAfterSleep(sleepDuration: duration)
                            _ = automatic.tick()
                            var confirmed = base
                            _ = confirmed.tick()
                            confirmed.completeBreak()
                            _ = confirmed.tick()
                            XCTAssertEqual(automatic.data, confirmed.data,
                                           "pace=\(pace), harder=\(harder), manual=\(manual), complete=\(alreadyComplete), sleep=\(duration)")
                        }
                    }
                }
            }
        }
    }

    func testRepeatedRecoveryAfterOvernightRestDoesNotCreateAnotherBreak() {
        var machine = sleepingMachine()
        machine.clock = SleepClock(now: machine.clock.now.addingTimeInterval(7 * 3600))
        machine.restoreAfterSleep()
        let restored = machine.runtime
        guard case .working = restored.timerState else { return XCTFail("Expected a fresh cycle") }
        machine.clock = SleepClock(now: machine.clock.now.addingTimeInterval(1))
        machine.restoreAfterSleep()
        XCTAssertEqual(machine.runtime, restored)
    }

    func testRepeatedRecoveryAfterExpiredPauseDoesNotCreateAnotherBreak() {
        var machine = StateMachine(clock: SleepClock(now: start))
        _ = machine.tick()
        machine.suspend(until: start.addingTimeInterval(600))
        machine.clock = SleepClock(now: start.addingTimeInterval(601))
        machine.restoreAfterSleep()
        let restored = machine.runtime
        guard case .working = restored.timerState else { return XCTFail("Expected a fresh cycle") }
        machine.clock = SleepClock(now: machine.clock.now.addingTimeInterval(1))
        machine.restoreAfterSleep()
        XCTAssertEqual(machine.runtime, restored)
    }

    func testOneHourBoundary() {
        for duration: TimeInterval in [3599, 3600, 3601] {
            var machine = sleepingMachine()
            machine.clock = SleepClock(now: machine.clock.now.addingTimeInterval(duration))
            machine.restoreAfterSleep(sleepDuration: duration)
            _ = machine.tick()
            if duration < 3600 {
                XCTAssertEqual(machine.runtime.timerState, .breakCompleted)
            } else {
                guard case let .working(deadline, _) = machine.runtime.timerState else {
                    return XCTFail("A full hour of sleep must start a new cycle")
                }
                XCTAssertEqual(deadline.timeIntervalSince(machine.clock.now), machine.settings.effectiveWorkInterval)
                XCTAssertNil(machine.runtime.breakStartedAt)
                XCTAssertNil(machine.runtime.breakReadyAt)
            }
        }
    }

    func testOldBreakAndShortSleepStillRequireContinue() {
        var machine = sleepingMachine()
        machine.clock = SleepClock(now: machine.clock.now.addingTimeInterval(3600))
        machine.restoreAfterSleep(sleepDuration: 5 * 60)
        _ = machine.tick()
        XCTAssertEqual(machine.runtime.timerState, .breakCompleted)
    }

    func testLockWithoutSleepStillRequiresContinue() {
        var machine = sleepingMachine()
        machine.clock = SleepClock(now: machine.clock.now.addingTimeInterval(3600))
        machine.restoreAfterSleep()
        _ = machine.tick()
        XCTAssertEqual(machine.runtime.timerState, .breakCompleted)
    }

    func testLongSleepPreservesTaperingAndSkipQuotas() {
        var machine = sleepingMachine()
        machine.settings.focusPace = .tapering
        machine.settings.harderToSkipBreaks = true
        machine.runtime.taperedFocusSeconds = 60 * 60
        machine.runtime.emergencyOverrideUsedAt = start
        machine.runtime.dailySkipUsage.spend(at: machine.clock.now)
        machine.runtime.dailySkipUsage.spend(at: machine.clock.now)
        let usage = machine.runtime.dailySkipUsage
        machine.clock = SleepClock(now: machine.clock.now.addingTimeInterval(3600))
        machine.restoreAfterSleep(sleepDuration: 3600)
        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 70 * 60)
        XCTAssertEqual(machine.runtime.emergencyOverrideUsedAt, start)
        XCTAssertEqual(machine.runtime.dailySkipUsage, usage)
        let restored = machine.runtime
        machine.restoreAfterSleep(sleepDuration: 3600)
        XCTAssertEqual(machine.runtime, restored, "Repeated wake must not complete the cycle twice")
    }

    func testLongSleepDoesNotEndAnUnfinishedBreak() {
        var machine = sleepingMachine()
        machine.runtime.timerState = .breaking(deadline: machine.clock.now.addingTimeInterval(3700),
                                              startedAt: machine.clock.now, duration: 3700)
        machine.clock = SleepClock(now: machine.clock.now.addingTimeInterval(3600))
        machine.restoreAfterSleep(sleepDuration: 3600)
        guard case .breaking = machine.runtime.timerState else { return XCTFail("Required rest must finish first") }
    }

    func testLongSleepLeavesUserPauseUntilItsDeadline() {
        var machine = StateMachine(clock: SleepClock(now: start))
        machine.suspend(until: start.addingTimeInterval(7200))
        let paused = machine.runtime.timerState
        machine.beginDowntimeBreak()
        machine.clock = SleepClock(now: start.addingTimeInterval(3600))
        machine.restoreAfterSleep(sleepDuration: 3600)
        XCTAssertEqual(machine.runtime.timerState, paused)
    }

    func testSleepIsMeasuredSeparatelyAndWaitsForUnlock() {
        var activity = SessionActivity()
        XCTAssertTrue(activity.set(.screenLock, inactive: true, at: start))
        XCTAssertFalse(activity.set(.sleep, inactive: true, at: start.addingTimeInterval(3300)))
        XCTAssertFalse(activity.set(.sleep, inactive: false, at: start.addingTimeInterval(3600)))
        XCTAssertTrue(activity.isInactive)
        XCTAssertEqual(activity.longestSleepDuration, 300)
        XCTAssertTrue(activity.set(.screenLock, inactive: false, at: start.addingTimeInterval(4000)))
        XCTAssertEqual(activity.longestSleepDuration, 300)
    }

    func testDuplicateSleepAndWakeDoNotExtendTheMeasuredSleep() {
        var activity = SessionActivity()
        _ = activity.set(.screenLock, inactive: true, at: start)
        _ = activity.set(.sleep, inactive: true, at: start)
        _ = activity.set(.sleep, inactive: true, at: start.addingTimeInterval(600))
        _ = activity.set(.sleep, inactive: false, at: start.addingTimeInterval(3600))
        _ = activity.set(.sleep, inactive: false, at: start.addingTimeInterval(7200))
        XCTAssertTrue(activity.isInactive)
        XCTAssertEqual(activity.longestSleepDuration, 3600)
        _ = activity.set(.screenLock, inactive: false, at: start.addingTimeInterval(7200))
        _ = activity.set(.sleep, inactive: true, at: start.addingTimeInterval(8000))
        _ = activity.set(.sleep, inactive: false, at: start.addingTimeInterval(8010))
        XCTAssertEqual(activity.longestSleepDuration, 10)
    }

    func testSeparateShortSleepsDoNotAddUpToAnHour() {
        var activity = SessionActivity()
        _ = activity.set(.screenLock, inactive: true, at: start)
        for offset: TimeInterval in [0, 2400] {
            _ = activity.set(.sleep, inactive: true, at: start.addingTimeInterval(offset))
            _ = activity.set(.sleep, inactive: false, at: start.addingTimeInterval(offset + 1800))
        }
        _ = activity.set(.screenLock, inactive: false, at: start.addingTimeInterval(5000))
        XCTAssertEqual(activity.longestSleepDuration, 1800)
    }
}
