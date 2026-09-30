import XCTest
@testable import BreakGuard

private struct ActionClock: TimeProvider { var now: Date }

final class BreakActionRaceTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_700_000)

    func testLatePostponeAndOverrideCannotSkipAnElapsedBreakBeforeTheNextTick() {
        var machine = StateMachine(clock: ActionClock(now: start))
        machine.startBreak()
        machine.clock = ActionClock(now: start.addingTimeInterval(machine.settings.breakDuration))
        let before = machine.data
        machine.postpone(by: 60)
        machine.useEmergencyOverride()
        XCTAssertEqual(machine.data, before)
        _ = machine.tick()
        XCTAssertEqual(machine.runtime.timerState, .breakCompleted)
        machine.postpone(by: 60)
        XCTAssertEqual(machine.runtime.timerState, .breakCompleted)
        XCTAssertEqual(machine.statistics.totalPostponements, 0)
    }

    func testLateExtensionCannotRescueAnElapsedFocusWindowBeforeTheNextTick() {
        var machine = StateMachine(clock: ActionClock(now: start))
        machine.clock = ActionClock(now: start.addingTimeInterval(machine.settings.workInterval))
        let before = machine.data
        machine.extendFocus(by: 60)
        XCTAssertEqual(machine.data, before)
        _ = machine.tick()
        XCTAssertEqual(machine.runtime.timerState, .breakDue)
    }

    func testDuplicateBreakStartDoesNotRestartTheTimer() {
        var machine = StateMachine(clock: ActionClock(now: start))
        machine.startBreak()
        let before = machine.runtime
        machine.clock = ActionClock(now: start.addingTimeInterval(10))
        machine.startBreak()
        XCTAssertEqual(machine.runtime, before)
    }

    func testLateManualBreakRequestCannotMakeARequiredBreakCancellable() {
        var machine = StateMachine(clock: ActionClock(now: start))
        machine.clock = ActionClock(now: start.addingTimeInterval(machine.settings.workInterval))
        machine.takeBreakNow()
        machine.startBreak()
        XCTAssertNil(machine.runtime.manualBreakOrigin)
        let before = machine.runtime
        machine.cancelManualBreak()
        XCTAssertEqual(machine.runtime, before)
    }

    func testRestBeforePostponementIsExcludedFromFocusAndTapering() {
        var machine = StateMachine(clock: ActionClock(now: start))
        machine.clock = ActionClock(now: start.addingTimeInterval(30 * 60))
        machine.startBreak()
        machine.clock = ActionClock(now: start.addingTimeInterval(31 * 60))
        machine.postpone(by: 5 * 60)
        machine.clock = ActionClock(now: start.addingTimeInterval(36 * 60))
        _ = machine.tick()
        machine.startBreak()
        machine.clock = ActionClock(now: start.addingTimeInterval(38 * 60))
        _ = machine.tick()
        machine.completeBreak()
        XCTAssertEqual(machine.statistics.totalFocusMinutes, 35)
        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 35 * 60)
    }

    func testRestBeforeOverrideIsExcludedFromFocusAndTapering() {
        var machine = StateMachine(clock: ActionClock(now: start))
        machine.clock = ActionClock(now: start.addingTimeInterval(30 * 60))
        machine.startBreak()
        machine.clock = ActionClock(now: start.addingTimeInterval(31 * 60))
        machine.useEmergencyOverride()
        machine.clock = ActionClock(now: start.addingTimeInterval(32 * 60))
        machine.takeBreakNow()
        machine.startBreak()
        machine.clock = ActionClock(now: start.addingTimeInterval(34 * 60))
        _ = machine.tick()
        machine.completeBreak()
        XCTAssertEqual(machine.statistics.totalFocusMinutes, 31)
        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 31 * 60)
    }
}
