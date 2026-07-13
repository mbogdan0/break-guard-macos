import XCTest
@testable import BreakGuard

final class WeeklyFocusSummaryTests: XCTestCase {
    // Fixed calendar and locale: the production default follows the user's
    // time zone and locale, which would make day boundaries and the
    // weekday/weekend split flaky.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.locale = Locale(identifier: "en_US")
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

    func testDaysAreCategorizedAsWeekdayOrWeekend() {
        let summaries = makeWeeklyFocusSummary(minutesByDay: [:], now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].category, .weekend) // Sun Jul 12
        XCTAssertEqual(summaries[1].category, .weekend) // Sat Jul 11
        XCTAssertEqual(summaries[2].category, .weekday) // Fri Jul 10
        XCTAssertEqual(summaries[6].category, .weekday) // Mon Jul 6
    }

    func testWeekendDayComparesAgainstOtherWeekendDaysOnly() {
        // Sunday Jul 12 compares against Sat Jul 11 and Sun Jul 5:
        // (100 + 200) / 2 = 150; today 210 → +40%. The weekday Thu Jul 9
        // must not feed the baseline.
        let history = [
            "2026-07-12": 210,
            "2026-07-11": 100,
            "2026-07-05": 200,
            "2026-07-09": 1000
        ]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].comparison, .delta(percent: 40))
    }

    func testWeekdayComparesAgainstAllOtherWeekdays() {
        // Friday Jul 10 compares against Thu Jul 9 and Mon Jul 6 (mixed
        // weekdays): (60 + 120) / 2 = 90; Friday 180 → +100%. Weekend days
        // must not feed the baseline.
        let history = [
            "2026-07-10": 180,
            "2026-07-09": 60,
            "2026-07-06": 120,
            "2026-07-11": 1000
        ]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[2].comparison, .delta(percent: 100))
    }

    func testBaselineIncludesDaysOutsideTheWindow() {
        // Sat Jun 27 sits outside the 7-day window but is still a weekend
        // baseline day: (100 + 200) / 2 = 150; today 100 → −33.3…% → −33%.
        let history = [
            "2026-07-12": 100,
            "2026-07-05": 100,
            "2026-06-27": 200
        ]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].comparison, .delta(percent: -33))
    }

    func testOwnDayIsExcludedFromItsBaseline() {
        // The only recorded weekend day is the one being shown: no
        // comparison, not a meaningless 0%.
        let history = ["2026-07-12": 120]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].comparison, .noHistory)
    }

    func testSingleBaselineDayIsNotEnoughForComparison() {
        // One other weekend day is not an average yet.
        let history = ["2026-07-12": 120, "2026-07-05": 100]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[0].comparison, .noHistory)
    }

    func testUntrackedDayGetsNoComparison() {
        // Sat Jul 11 has no recorded focus time: comparing it would render
        // as a meaningless "100% less".
        let history = ["2026-07-12": 120, "2026-07-05": 100, "2026-07-04": 80]
        let summaries = makeWeeklyFocusSummary(minutesByDay: history, now: now, calendar: calendar)

        XCTAssertEqual(summaries[1].minutes, 0)
        XCTAssertEqual(summaries[1].comparison, .noHistory)
    }

    func testZeroBaselineYieldsNoComparison() {
        let history = ["2026-07-12": 120, "2026-07-05": 0, "2026-07-04": 0]
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
