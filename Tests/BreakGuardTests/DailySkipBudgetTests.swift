import XCTest
@testable import BreakGuard

private struct BudgetClock: TimeProvider {
    var now: Date
}

final class DailySkipBudgetTests: XCTestCase {
    private let start = Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 30, hour: 12))!

    private func machine(limit: Int = 3) -> StateMachine {
        var settings = AppSettings.defaults
        settings.harderToSkipBreaks = true
        settings.dailySkipLimit = limit
        return StateMachine(settings: settings, clock: BudgetClock(now: start))
    }

    func testExtensionsAndPostponementsShareADailyBudgetAcrossCycles() {
        var machine = machine()
        machine.extendFocus(by: 60)
        XCTAssertEqual(machine.dailySkipsRemaining, 2)
        XCTAssertFalse(machine.canExtendFocus)
        machine.startWorkCycle()
        machine.startBreak()
        machine.postpone(by: 60)
        XCTAssertEqual(machine.dailySkipsRemaining, 1)
        machine.startWorkCycle()
        machine.extendFocus(by: 60)
        machine.startWorkCycle()
        XCTAssertEqual(machine.dailySkipsRemaining, 0)
        XCTAssertFalse(machine.canExtendFocus)
        XCTAssertFalse(machine.canPostpone)
        let runtime = machine.runtime
        machine.extendFocus(by: 60)
        XCTAssertEqual(machine.runtime, runtime)
    }

    func testMidnightRestoresDailyAllowanceButNotTheCurrentCycleAllowance() {
        var machine = machine(limit: 1)
        machine.extendFocus(by: 60)
        let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        machine.clock = BudgetClock(now: Calendar.current.startOfDay(for: nextDay))
        XCTAssertEqual(machine.dailySkipsRemaining, 1)
        XCTAssertFalse(machine.canExtendFocus)
        machine.runtime.timerState = .working(deadline: machine.clock.now.addingTimeInterval(60), warningDeadline: machine.clock.now)
        machine.startWorkCycle()
        XCTAssertTrue(machine.canExtendFocus)
    }

    func testZeroBudgetStillAllowsWeeklyEmergencyOverride() {
        var machine = machine(limit: 0)
        XCTAssertFalse(machine.canPostpone)
        XCTAssertFalse(machine.canExtendFocus)
        machine.startBreak()
        XCTAssertTrue(machine.canUseEmergencyOverride)
        machine.useEmergencyOverride()
        XCTAssertEqual(machine.dailySkipsRemaining, 0)
        XCTAssertEqual(machine.runtime.emergencyOverrideUsedAt, start)
    }

    func testNormalModeIsUnlimitedButItsUsageCarriesIntoHarderMode() {
        var machine = machine(limit: 1)
        machine.settings.harderToSkipBreaks = false
        machine.extendFocus(by: 60)
        machine.extendFocus(by: 60)
        machine.startWorkCycle()
        XCTAssertTrue(machine.canExtendFocus)
        machine.settings.harderToSkipBreaks = true
        XCTAssertEqual(machine.dailySkipsRemaining, 0)
        XCTAssertFalse(machine.canExtendFocus)
    }

    func testRestartsAndResettingStatisticsOrSettingsDoNotRefillUsage() throws {
        var machine = machine()
        machine.extendFocus(by: 60)
        let encoded = try JSONEncoder.breakGuard.encode(machine.data)
        let restored = try JSONDecoder.breakGuard.decode(PersistedAppData.self, from: encoded)
        machine = StateMachine(data: restored, clock: BudgetClock(now: start))
        machine.statistics = .empty
        machine.settings = .defaults
        machine.settings.harderToSkipBreaks = true
        machine.startWorkCycle()
        XCTAssertEqual(machine.dailySkipsRemaining, 2)
        XCTAssertTrue(machine.canPostpone)
    }

    func testDeclinedAndInvalidActionsDoNotConsumeBudget() {
        var machine = machine()
        machine.postpone(by: 60) // No break to postpone.
        for duration in [0, -1, TimeInterval.nan, .infinity] {
            machine.extendFocus(by: duration)
        }
        machine.startBreak()
        for duration in [0, -1, TimeInterval.nan, .infinity] {
            machine.postpone(by: duration)
        }
        XCTAssertEqual(machine.dailySkipsRemaining, 3)
        XCTAssertEqual(machine.statistics.totalPostponements, 0)
    }

    func testManualBreakCancellationDoesNotConsumeBudget() {
        var machine = machine()
        machine.takeBreakNow()
        machine.startBreak()
        machine.clock = BudgetClock(now: start.addingTimeInterval(10))
        machine.cancelManualBreak()
        XCTAssertEqual(machine.dailySkipsRemaining, 3)
        XCTAssertTrue(machine.canExtendFocus)
    }

    func testCalendarDayResetAcrossDaylightSavingChange() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let before = calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30))!
        let stillToday = before.addingTimeInterval(24 * 3600)
        var usage = DailySkipUsage()
        usage.spend(at: before, calendar: calendar)
        XCTAssertEqual(usage.remaining(limit: 3, at: stillToday, calendar: calendar), 2)
        let tomorrow = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        XCTAssertEqual(usage.remaining(limit: 3, at: tomorrow, calendar: calendar), 3)
    }

    func testMovingClockBackwardsDoesNotRefillBudget() {
        var usage = DailySkipUsage()
        usage.spend(at: start)
        let yesterday = start.addingTimeInterval(-86400)
        XCTAssertEqual(usage.remaining(limit: 3, at: yesterday), 2)
        usage.spend(at: yesterday)
        XCTAssertEqual(usage.remaining(limit: 3, at: start), 1)
    }

    func testBudgetSettingsAreClampedAndIncreasesWeakenGuard() {
        var settings = AppSettings.defaults
        settings.dailySkipLimit = -10
        settings.clamp()
        XCTAssertEqual(settings.dailySkipLimit, 0)
        settings.dailySkipLimit = Int.max
        settings.clamp()
        XCTAssertEqual(settings.dailySkipLimit, 10)
        XCTAssertTrue(settings.weakensGuard(comparedTo: .defaults))
        settings = .defaults
        settings.holdBreaksWhileMicrophoneInUse = true
        XCTAssertTrue(settings.weakensGuard(comparedTo: .defaults))
    }
}
