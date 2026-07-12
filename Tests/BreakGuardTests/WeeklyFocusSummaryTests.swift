import XCTest
@testable import BreakGuard

final class WeeklyFocusSummaryTests: XCTestCase {
    // Fixed calendar: the production default follows the user's time zone,
    // which would make day boundaries and weekdays flaky.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // Sunday, July 12, 2026, 15:00 UTC.
    private var now: Date { date(2026, 7, 12, hour: 15) }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    func testWindowCoversSevenDaysNewestFirst() {
        let summaries = makeWeeklyFocusSummary(minutesByDay: [:], now: now, calendar: calendar)

        XCTAssertEqual(summaries.count, 7)
        XCTAssertEqual(summaries.first?.date, date(2026, 7, 12))
        XCTAssertEqual(summaries.last?.date, date(2026, 7, 6))
        XCTAssertTrue(summaries.allSatisfy { $0.minutes == 0 && $0.comparison == .noHistory })
    }

    func testMinutesComeFromHistoryAndUntrackedDaysAreZero() {
        let history = ["2026-07-12": 90, "2026-07-10": 45]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].minutes, 90)
        XCTAssertEqual(summaries[1].minutes, 0)
        XCTAssertEqual(summaries[2].minutes, 45)
    }

    func testDeltaComparesAgainstOtherSameWeekdayAverage() {
        // Earlier Sundays averaged (100 + 200) / 2 = 150; today 210 → +40%.
        // June 28 sits outside the 7-day window but still feeds the baseline.
        let history = [
            "2026-07-12": 210,
            "2026-07-05": 100,
            "2026-06-28": 200
        ]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].comparison, .delta(percent: 40))
    }

    func testNegativeDeltaIsRounded() {
        // 100 vs a 150 average → −33.3…% rounded to −33%.
        let history = [
            "2026-07-12": 100,
            "2026-07-05": 100,
            "2026-06-28": 200
        ]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].comparison, .delta(percent: -33))
    }

    func testOwnDayIsExcludedFromItsBaseline() {
        // The only recorded Sunday is the one being shown: no comparison,
        // not a meaningless 0%.
        let history = ["2026-07-12": 120]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].comparison, .noHistory)
    }

    func testZeroBaselineYieldsNoComparison() {
        let history = ["2026-07-12": 120, "2026-07-05": 0]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].comparison, .noHistory)
    }

    func testDayKeyRoundTrips() {
        let day = date(2026, 7, 12)
        XCTAssertEqual(FocusDay.key(for: now, calendar: calendar), "2026-07-12")
        XCTAssertEqual(FocusDay.date(fromKey: "2026-07-12", calendar: calendar), day)
        XCTAssertNil(FocusDay.date(fromKey: "not-a-day", calendar: calendar))
    }
}
