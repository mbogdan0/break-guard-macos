import XCTest
@testable import BreakGuard

final class WorkingHoursTests: XCTestCase {
    // A fixed calendar keeps weekday/weekend classification and the
    // minutes-from-midnight math independent of the machine running the tests.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    // 2026-07-13 is a Monday, 2026-07-18 a Saturday.
    private func date(_ day: String, _ hour: Int, _ minute: Int) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: "\(day) \(String(format: "%02d:%02d", hour, minute))")!
    }

    private var settings: AppSettings {
        var settings = AppSettings.defaults
        settings.workingHoursEnabled = true
        settings.weekdayWorkingHours = WorkingHoursRange(
            enabled: true, startMinutes: 11 * 60, endMinutes: 19 * 60
        )
        settings.weekendWorkingHours = WorkingHoursRange(
            enabled: true, startMinutes: 12 * 60, endMinutes: 16 * 60
        )
        return settings
    }

    func testContainsIsStartInclusiveEndExclusive() {
        let range = WorkingHoursRange(enabled: true, startMinutes: 11 * 60, endMinutes: 19 * 60)
        XCTAssertFalse(range.contains(minutesFromMidnight: 11 * 60 - 1))
        XCTAssertTrue(range.contains(minutesFromMidnight: 11 * 60))
        XCTAssertTrue(range.contains(minutesFromMidnight: 19 * 60 - 1))
        XCTAssertFalse(range.contains(minutesFromMidnight: 19 * 60))
    }

    func testClampRepairsOutOfBoundsAndInvertedRanges() {
        var negative = WorkingHoursRange(enabled: true, startMinutes: -30, endMinutes: -10)
        negative.clamp()
        XCTAssertEqual(negative.startMinutes, 0)
        XCTAssertEqual(negative.endMinutes, WorkingHoursRange.minimumLength)

        var oversized = WorkingHoursRange(enabled: true, startMinutes: 25 * 60, endMinutes: 26 * 60)
        oversized.clamp()
        XCTAssertEqual(oversized.startMinutes, 24 * 60 - 1 - WorkingHoursRange.minimumLength)
        XCTAssertEqual(oversized.endMinutes, 24 * 60 - 1)

        // An end at or before the start is pushed after it, never wrapped
        // overnight.
        var inverted = WorkingHoursRange(enabled: true, startMinutes: 19 * 60, endMinutes: 11 * 60)
        inverted.clamp()
        XCTAssertEqual(inverted.startMinutes, 19 * 60)
        XCTAssertEqual(inverted.endMinutes, 19 * 60 + WorkingHoursRange.minimumLength)
    }

    func testDefaultRangeSurvivesClampUnchanged() {
        var range = WorkingHoursRange(enabled: true)
        range.clamp()
        XCTAssertEqual(range, WorkingHoursRange(enabled: true))
    }

    func testOutsideWorkingHoursOnAWeekday() {
        let monday = "2026-07-13"
        XCTAssertTrue(settings.isOutsideWorkingHours(at: date(monday, 10, 0), calendar: calendar))
        XCTAssertFalse(settings.isOutsideWorkingHours(at: date(monday, 11, 0), calendar: calendar))
        XCTAssertFalse(settings.isOutsideWorkingHours(at: date(monday, 18, 59), calendar: calendar))
        XCTAssertTrue(settings.isOutsideWorkingHours(at: date(monday, 19, 0), calendar: calendar))
        XCTAssertTrue(settings.isOutsideWorkingHours(at: date(monday, 23, 30), calendar: calendar))
    }

    func testWeekendUsesTheWeekendRange() {
        let saturday = "2026-07-18"
        // 11:00 is inside the weekday range but outside the weekend one.
        XCTAssertTrue(settings.isOutsideWorkingHours(at: date(saturday, 11, 0), calendar: calendar))
        XCTAssertFalse(settings.isOutsideWorkingHours(at: date(saturday, 12, 0), calendar: calendar))
        XCTAssertTrue(settings.isOutsideWorkingHours(at: date(saturday, 16, 0), calendar: calendar))
    }

    func testDisabledMasterToggleTurnsTheFeatureOff() {
        var settings = settings
        settings.workingHoursEnabled = false
        XCTAssertFalse(settings.isOutsideWorkingHours(at: date("2026-07-13", 3, 0), calendar: calendar))
    }

    func testDisabledCategoryShowsNormalColorsThatDay() {
        var settings = settings
        settings.weekendWorkingHours.enabled = false
        XCTAssertFalse(settings.isOutsideWorkingHours(at: date("2026-07-18", 3, 0), calendar: calendar))
        // The weekday range keeps working.
        XCTAssertTrue(settings.isOutsideWorkingHours(at: date("2026-07-13", 3, 0), calendar: calendar))
    }

    func testSettingsClampRepairsWorkingHoursRanges() {
        var settings = AppSettings.defaults
        settings.weekdayWorkingHours = WorkingHoursRange(enabled: true, startMinutes: 900, endMinutes: 600)
        settings.clamp()
        XCTAssertEqual(settings.weekdayWorkingHours.startMinutes, 900)
        XCTAssertEqual(settings.weekdayWorkingHours.endMinutes, 900 + WorkingHoursRange.minimumLength)
    }
}
