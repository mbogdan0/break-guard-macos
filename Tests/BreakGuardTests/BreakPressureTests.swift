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

    private func date(_ day: String, _ hour: Int, _ minute: Int) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(day) \(String(format: "%02d:%02d", hour, minute))")!
    }

    // Harder mode on, working hours
    // 11:00–19:00 on weekdays and 12:00–16:00 at weekends.
    private var settings: AppSettings {
        var settings = AppSettings.defaults
        settings.harderToSkipBreaks = true
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
        // Work hours are quiet; after-hours pressure also needs Harder mode.
        XCTAssertNil(settings.pressureReason(at: date(monday, 15, 45), calendar: calendar))
        XCTAssertNil(settings.pressureReason(at: date(monday, 21, 0), calendar: calendar))
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

    // MARK: - Card copy

}
