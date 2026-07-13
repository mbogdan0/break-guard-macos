import Foundation

// Days are compared within two categories: workweek days against other
// workweek days, weekend days against other weekend days. The split follows
// the calendar's locale-aware notion of a weekend (Sat/Sun in most locales).
enum DayCategory: Equatable {
    case weekday
    case weekend

    init(date: Date, calendar: Calendar) {
        self = calendar.isDateInWeekend(date) ? .weekend : .weekday
    }

    var title: String { self == .weekend ? "weekend" : "weekday" }
}

// How a day's focus time relates to the user's history for its category.
enum DayCategoryComparison: Equatable {
    // Not enough recorded days in the category for a meaningful average.
    case noHistory
    // Percent difference from the average of all other recorded days in the
    // same category: +10 means 10% more than a typical such day.
    case delta(percent: Int)
}

// A single-day baseline is not an average worth comparing against, and a
// day without recorded focus time carries no signal — both read as noise
// ("100% less than your weekend average" on an untracked Saturday).
private let minimumBaselineDays = 2

struct DailyFocusSummary: Equatable, Identifiable {
    // Start of the summarized day in the local calendar.
    let date: Date
    let minutes: Int
    let category: DayCategory
    let comparison: DayCategoryComparison

    var id: Date { date }
}

// Summaries for the last 7 days (today first), each compared against the
// average of all *other* recorded days in the same category (weekday or
// weekend). A comparison appears only once the day itself is recorded and
// the baseline holds at least `minimumBaselineDays` days. Days absent from
// the history were simply not tracked, so they never drag a category's
// average toward zero.
func makeWeeklyFocusSummary(
    minutesByDay: [String: Int],
    now: Date = Date(),
    calendar: Calendar = .current
) -> [DailyFocusSummary] {
    var minutesByCategory: [DayCategory: [String: Int]] = [:]
    for (key, minutes) in minutesByDay {
        guard let date = FocusDay.date(fromKey: key, calendar: calendar) else { continue }
        minutesByCategory[DayCategory(date: date, calendar: calendar), default: [:]][key] = minutes
    }

    let today = calendar.startOfDay(for: now)
    return (0..<7).compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
        let key = FocusDay.key(for: date, calendar: calendar)
        let category = DayCategory(date: date, calendar: calendar)
        let baseline = (minutesByCategory[category] ?? [:]).filter { $0.key != key }.values
        let minutes = minutesByDay[key] ?? 0
        let comparison: DayCategoryComparison
        if minutes == 0 || baseline.count < minimumBaselineDays {
            comparison = .noHistory
        } else {
            let average = Double(baseline.reduce(0, +)) / Double(baseline.count)
            comparison = average > 0
                ? .delta(percent: Int(((Double(minutes) - average) / average * 100).rounded()))
                : .noHistory
        }
        return DailyFocusSummary(
            date: date,
            minutes: minutes,
            category: category,
            comparison: comparison
        )
    }
}
