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

    func testCleanBreakIncrementsStreak() {
        let start = Date(timeIntervalSince1970: 3_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.breakDuration = 60
        var machine = StateMachine(settings: settings, clock: clock)

        machine.takeBreakNow()
        machine.startBreak()
        clock.now = start.addingTimeInterval(61)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakCompleted)
        machine.completeBreak(classification: .tag(id: "work"))

        XCTAssertEqual(machine.statistics.completedBreaks, 1)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 1)
        XCTAssertEqual(machine.statistics.bestCleanStreak, 1)
        XCTAssertEqual(machine.statistics.focusSessionsByTag["work"], 1)
    }

    func testDefaultFocusTagsAreWorkAndStudy() {
        let machine = StateMachine()
        XCTAssertEqual(machine.focusTags, FocusTag.defaults)
        XCTAssertEqual(machine.focusTags.map(\.name), ["Work", "Study"])
    }

    func testFocusTagValidationRenameAndDeletionCleanup() throws {
        var machine = StateMachine()

        XCTAssertThrowsError(try machine.addFocusTag(named: "   ")) { error in
            XCTAssertEqual(error as? FocusTagNameError, .empty)
        }
        XCTAssertThrowsError(try machine.addFocusTag(named: "work")) { error in
            XCTAssertEqual(error as? FocusTagNameError, .duplicate)
        }
        XCTAssertThrowsError(try machine.addFocusTag(named: String(repeating: "a", count: 25))) { error in
            XCTAssertEqual(error as? FocusTagNameError, .tooLong)
        }

        let custom = try machine.addFocusTag(named: "  Writing  ")
        machine.statistics.focusSessionsByTag[custom.id] = 3
        try machine.renameFocusTag(id: custom.id, to: "Planning")
        XCTAssertEqual(machine.focusTags.last?.name, "Planning")
        XCTAssertEqual(machine.statistics.focusSessionsByTag[custom.id], 3)

        machine.deleteFocusTag(id: custom.id)
        XCTAssertFalse(machine.focusTags.contains(where: { $0.id == custom.id }))
        XCTAssertNil(machine.statistics.focusSessionsByTag[custom.id])
    }

    func testTaggedAndSkippedBreakCompletion() {
        let start = Date(timeIntervalSince1970: 5_000)
        var machine = completedBreakMachine(start: start)

        machine.completeBreak(classification: .tag(id: "study"))
        XCTAssertEqual(machine.statistics.completedBreaks, 1)
        XCTAssertEqual(machine.statistics.focusSessionsByTag["study"], 1)
        XCTAssertEqual(machine.statistics.skippedFocusSessions, 0)

        machine.runtime.timerState = .breakCompleted
        machine.completeBreak(classification: .skipped)
        XCTAssertEqual(machine.statistics.completedBreaks, 2)
        XCTAssertEqual(machine.statistics.focusSessionsByTag["study"], 1)
        XCTAssertEqual(machine.statistics.skippedFocusSessions, 1)
    }

    func testCompletionIsIgnoredOutsideCompletedStateOrForUnknownTag() {
        var machine = StateMachine()
        machine.completeBreak(classification: .tag(id: "work"))
        XCTAssertEqual(machine.statistics, .empty)

        machine.runtime.timerState = .breakCompleted
        machine.completeBreak(classification: .tag(id: "missing"))
        XCTAssertEqual(machine.statistics, .empty)
        XCTAssertEqual(machine.runtime.timerState, .breakCompleted)
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

        clock.now = start.addingTimeInterval(20 * 60)
        machine.clock = clock
        machine.resume()
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 25 * 60, accuracy: 0.1)
    }

    private func completedBreakMachine(start: Date) -> StateMachine {
        var settings = AppSettings.defaults
        settings.breakDuration = 60
        var clock = FakeClock(now: start)
        var machine = StateMachine(settings: settings, clock: clock)
        machine.takeBreakNow()
        machine.startBreak()
        clock.now = start.addingTimeInterval(61)
        machine.clock = clock
        _ = machine.tick()
        return machine
    }
}
