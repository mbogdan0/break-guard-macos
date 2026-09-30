import XCTest
@testable import BreakGuard

private struct FakeClock: TimeProvider {
    var now: Date
}

final class BreakPressureTests: XCTestCase {
    // Same fixture as WorkingHoursTests: a fixed UTC gregorian calendar keeps
    // weekday classification and the minutes-from-midnight math independent of
    // the machine running the tests.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    // 2026-07-13 is a Monday, 2026-07-18 a Saturday.
    private let monday = "2026-07-13"
    private let saturday = "2026-07-18"

    private func date(_ day: String, _ hour: Int, _ minute: Int) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(day) \(String(format: "%02d:%02d", hour, minute))")!
    }

    // Harder mode on, the default 15:30–16:00 window enabled, working hours
    // 11:00–19:00 on weekdays and 12:00–16:00 at weekends.
    private var settings: AppSettings {
        var settings = AppSettings.defaults
        settings.harderToSkipBreaks = true
        settings.scheduledBreak.enabled = true
        settings.workingHoursEnabled = true
        settings.weekdayWorkingHours = WorkingHoursRange(
            enabled: true, startMinutes: 11 * 60, endMinutes: 19 * 60
        )
        settings.weekendWorkingHours = WorkingHoursRange(
            enabled: true, startMinutes: 12 * 60, endMinutes: 16 * 60
        )
        return settings
    }

    func testHarderModeIsTheMasterGate() {
        var settings = settings
        settings.harderToSkipBreaks = false
        // Both reasons would otherwise apply at these two moments.
        XCTAssertNil(settings.pressureReason(at: date(monday, 15, 45), calendar: calendar))
        XCTAssertNil(settings.pressureReason(at: date(monday, 21, 0), calendar: calendar))
    }

    func testScheduledBreakWindowIsStartInclusiveEndExclusive() {
        let settings = settings
        XCTAssertNil(settings.pressureReason(at: date(monday, 15, 29), calendar: calendar))
        XCTAssertEqual(
            settings.pressureReason(at: date(monday, 15, 30), calendar: calendar),
            .scheduledBreak
        )
        XCTAssertEqual(
            settings.pressureReason(at: date(monday, 15, 59), calendar: calendar),
            .scheduledBreak
        )
        // 16:00 is still inside working hours, so the window ending is the end
        // of the pressure, not a handover to the other reason.
        XCTAssertNil(settings.pressureReason(at: date(monday, 16, 0), calendar: calendar))
    }

    func testScheduledBreakIsWeekdaysOnly() {
        let settings = settings
        XCTAssertNil(settings.scheduledBreakWindow(containing: date(saturday, 15, 45), calendar: calendar))
        // The weekend working-hours range still applies at that hour.
        XCTAssertEqual(
            settings.pressureReason(at: date(saturday, 15, 45), calendar: calendar),
            nil
        )
        XCTAssertEqual(
            settings.pressureReason(at: date(saturday, 16, 30), calendar: calendar),
            .outsideWorkingHours
        )
    }

    func testDisabledWindowProducesNoScheduledBreak() {
        var settings = settings
        settings.scheduledBreak.enabled = false
        XCTAssertNil(settings.scheduledBreakWindow(containing: date(monday, 15, 45), calendar: calendar))
        XCTAssertNil(settings.pressureReason(at: date(monday, 15, 45), calendar: calendar))
    }

    func testScheduledBreakWinsOverOutsideWorkingHours() {
        var settings = settings
        // Working hours end at 15:00, so 15:45 is outside them and inside the
        // rest window at the same time.
        settings.weekdayWorkingHours = WorkingHoursRange(
            enabled: true, startMinutes: 11 * 60, endMinutes: 15 * 60
        )
        XCTAssertEqual(
            settings.pressureReason(at: date(monday, 15, 45), calendar: calendar),
            .scheduledBreak
        )
        XCTAssertEqual(
            settings.pressureReason(at: date(monday, 16, 15), calendar: calendar),
            .outsideWorkingHours
        )
    }

    func testWindowBoundsAreReportedForTheCard() {
        let window = settings.scheduledBreakWindow(
            containing: date(monday, 15, 45),
            calendar: calendar
        )
        XCTAssertEqual(window?.start, date(monday, 15, 30))
        XCTAssertEqual(window?.end, date(monday, 16, 0))
    }

    func testClampRepairsTheScheduledBreakRange() {
        var settings = AppSettings.defaults
        settings.scheduledBreak = WorkingHoursRange(
            enabled: true, startMinutes: 16 * 60, endMinutes: 15 * 60
        )
        settings.clamp()
        XCTAssertEqual(settings.scheduledBreak.startMinutes, 16 * 60)
        XCTAssertEqual(settings.scheduledBreak.endMinutes, 16 * 60 + WorkingHoursRange.minimumLength)
    }

    func testDefaultWindowIsHalfPastThreeToFourAndOff() {
        let defaults = AppSettings.defaults.scheduledBreak
        XCTAssertFalse(defaults.enabled)
        XCTAssertEqual(defaults.startMinutes, 15 * 60 + 30)
        XCTAssertEqual(defaults.endMinutes, 16 * 60)
    }

    // MARK: - Suppression

    private func machine(at now: Date, settings: AppSettings) -> StateMachine {
        StateMachine(settings: settings, clock: FakeClock(now: now))
    }

    func testPressureRunsWhileACountdownIsRunning() {
        let now = date(monday, 15, 45)
        let machine = machine(at: now, settings: settings)
        XCTAssertFalse(machine.isPressureSuppressed())
    }

    func testBreakStatesSuppressThePressure() {
        let now = date(monday, 15, 45)
        for state in [TimerState.breakDue, .breakCompleted] {
            var machine = machine(at: now, settings: settings)
            machine.runtime.timerState = state
            XCTAssertTrue(machine.isPressureSuppressed(), "\(state) should suppress")
        }
        var breaking = machine(at: now, settings: settings)
        breaking.startBreak()
        XCTAssertTrue(breaking.isPressureSuppressed())
    }

    func testPauseAndIdleBracketSuppressThePressure() {
        var machine = machine(at: date(monday, 15, 45), settings: settings)
        machine.suspend(until: nil)
        XCTAssertTrue(machine.isPressureSuppressed())
    }

    func testCameraHoldSuppressesThePressure() {
        var machine = machine(at: date(monday, 15, 45), settings: settings)
        machine.callHoldActive = true
        XCTAssertTrue(machine.isPressureSuppressed())
    }

    func testABreakInsideTheWindowSatisfiesIt() {
        let now = date(monday, 15, 45)
        let window = (start: date(monday, 15, 30), end: date(monday, 16, 0))
        var machine = machine(at: now, settings: settings)
        XCTAssertFalse(machine.isPressureSuppressed(satisfiedWindow: window))

        // A break completed before the window does not count.
        machine.statistics.lastCompletedBreakDate = date(monday, 15, 20)
        XCTAssertFalse(machine.isPressureSuppressed(satisfiedWindow: window))

        machine.statistics.lastCompletedBreakDate = date(monday, 15, 40)
        XCTAssertTrue(machine.isPressureSuppressed(satisfiedWindow: window))

        // Outside working hours passes no window, so the same break settles
        // nothing there.
        XCTAssertFalse(machine.isPressureSuppressed())
    }

    // MARK: - Card copy

    func testCardCopyDiffersByReason() {
        let end = date(monday, 16, 0)
        let scheduled = makeNudgePresentation(reason: .scheduledBreak, windowEnd: end)
        XCTAssertEqual(scheduled.title, "Break time")

        let afterHours = makeNudgePresentation(reason: .outsideWorkingHours, windowEnd: nil)
        XCTAssertEqual(afterHours.title, "Outside working hours")
        XCTAssertNotEqual(scheduled.message, afterHours.message)

        // One action either way: the card answers the pressure, it does not
        // offer to stop for the day.
        XCTAssertEqual(scheduled.primaryTitle, "Take a Break Now")
        XCTAssertEqual(afterHours.primaryTitle, "Take a Break Now")
    }
}
