import Foundation

// Usage belongs to the local calendar day, survives cycles and restarts, and
// is tracked in both modes so toggling harder mode cannot refill the budget.
struct DailySkipUsage: Codable, Equatable {
    var count = 0
    var lastUsedAt: Date?

    func used(at now: Date, calendar: Calendar = .current) -> Int {
        guard let lastUsedAt else { return 0 }
        // A clock moved backwards must not refill today's allowance.
        guard now < lastUsedAt || calendar.isDate(now, inSameDayAs: lastUsedAt) else { return 0 }
        return min(max(0, count), SettingsRange.dailySkipLimit.upperBound)
    }

    func remaining(limit: Int, at now: Date, calendar: Calendar = .current) -> Int {
        max(0, limit - used(at: now, calendar: calendar))
    }

    mutating func spend(at now: Date, calendar: Calendar = .current) {
        count = min(used(at: now, calendar: calendar) + 1, SettingsRange.dailySkipLimit.upperBound)
        lastUsedAt = max(lastUsedAt ?? now, now)
    }
}
