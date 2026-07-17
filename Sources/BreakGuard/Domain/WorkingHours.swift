import Foundation

// A same-day time-of-day range, stored as minutes from local midnight.
// Overnight ranges (end before start) are not supported; clamp() keeps the
// end after the start instead of wrapping past midnight.
struct WorkingHoursRange: Codable, Equatable {
    var enabled: Bool = false
    var startMinutes: Int = 9 * 60
    var endMinutes: Int = 18 * 60

    static let minimumLength = 5

    mutating func clamp() {
        startMinutes = min(max(0, startMinutes), 24 * 60 - 1 - Self.minimumLength)
        endMinutes = min(max(startMinutes + Self.minimumLength, endMinutes), 24 * 60 - 1)
    }

    func contains(minutesFromMidnight minutes: Int) -> Bool {
        (startMinutes..<endMinutes).contains(minutes)
    }
}

extension AppSettings {
    // True only when the feature and the current day category's range are both
    // enabled and `now` falls outside [start, end).
    func isOutsideWorkingHours(at now: Date, calendar: Calendar = .current) -> Bool {
        guard workingHoursEnabled else { return false }
        let range = DayCategory(date: now, calendar: calendar) == .weekend
            ? weekendWorkingHours
            : weekdayWorkingHours
        guard range.enabled else { return false }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        return !range.contains(minutesFromMidnight: minutes)
    }
}
