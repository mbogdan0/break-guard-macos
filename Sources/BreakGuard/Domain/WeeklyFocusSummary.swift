import Foundation

// How a day's focus time relates to the user's history for that weekday.
enum WeekdayComparison: Equatable {
    // No other recorded day falls on the same weekday.
    case noHistory
    // Percent difference from the average of all other recorded same-weekday
    // days: +10 means 10% more than a typical such day.
    case delta(percent: Int)
}

struct DailyFocusSummary: Equatable, Identifiable {
    // Start of the summarized day in the local calendar.
    let date: Date
    let minutes: Int
    let comparison: WeekdayComparison

    var id: Date { date }
}

// Summaries for the last 7 days (today first), each compared against the
// average of all *other* recorded days that fall on the same weekday. Days
// absent from the history were simply not tracked, so they never drag a
// weekday's average toward zero.
func makeWeeklyFocusSummary(
    minutesByDay: [String: Int],
    now: Date = Date(),
    calendar: Calendar = .current
) -> [DailyFocusSummary] {
    var minutesByWeekday: [Int: [String: Int]] = [:]
    for (key, minutes) in minutesByDay {
        guard let date = FocusDay.date(fromKey: key, calendar: calendar) else { continue }
        minutesByWeekday[calendar.component(.weekday, from: date), default: [:]][key] = minutes
    }

    let today = calendar.startOfDay(for: now)
    return (0..<7).compactMap { offset in
        guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
        let key = FocusDay.key(for: date, calendar: calendar)
        let sameWeekday = minutesByWeekday[calendar.component(.weekday, from: date)] ?? [:]
        let baseline = sameWeekday.filter { $0.key != key }.values
        let comparison: WeekdayComparison
        if baseline.isEmpty {
            comparison = .noHistory
        } else {
            let average = Double(baseline.reduce(0, +)) / Double(baseline.count)
            let minutes = minutesByDay[key] ?? 0
            comparison = average > 0
                ? .delta(percent: Int(((Double(minutes) - average) / average * 100).rounded()))
                : .noHistory
        }
        return DailyFocusSummary(
            date: date,
            minutes: minutesByDay[key] ?? 0,
            comparison: comparison
        )
    }
}
