import Foundation

struct Statistics: Codable, Equatable {
    var currentCleanStreak: Int = 0
    var bestCleanStreak: Int = 0
    var completedBreaks: Int = 0
    var violatedCycles: Int = 0
    var totalPostponements: Int = 0
    var lastCompletedBreakDate: Date?
    // Daily totals, keyed by local-calendar day ("yyyy-MM-dd"). Pruned to the
    // last `focusHistoryRetentionDays` days; the lifetime total lives in
    // `totalFocusMinutes` so pruning never loses accumulated focus.
    var focusMinutesByDay: [String: Int] = [:]
    // Lifetime focus total, accumulated alongside focusMinutesByDay.
    var totalFocusMinutes: Int = 0

    static let empty = Statistics()

    // Day-level history kept for the weekly comparison: 4 weeks.
    static let focusHistoryRetentionDays = 28

    // Drops day entries older than the retention window (today inclusive).
    // The zero-padded keys sort lexicographically in date order, so a string
    // comparison against the cutoff key is exact.
    mutating func pruneFocusHistory(now: Date, calendar: Calendar = .current) {
        guard let cutoff = calendar.date(
            byAdding: .day,
            value: -(Self.focusHistoryRetentionDays - 1),
            to: calendar.startOfDay(for: now)
        ) else { return }
        let cutoffKey = FocusDay.key(for: cutoff, calendar: calendar)
        focusMinutesByDay = focusMinutesByDay.filter { $0.key >= cutoffKey }
    }
}

// totalFocusMinutes was a computed sum over focusMinutesByDay before the
// retention window existed. Files written by those builds lack the key, so
// the decoder seeds it from the full, not-yet-pruned history — the one moment
// the complete lifetime sum is still available. The init lives in an
// extension to keep the memberwise initializer.
extension Statistics {
    private enum CodingKeys: String, CodingKey {
        case currentCleanStreak, bestCleanStreak, completedBreaks,
             violatedCycles, totalPostponements, lastCompletedBreakDate,
             focusMinutesByDay, totalFocusMinutes
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentCleanStreak = try container.decode(Int.self, forKey: .currentCleanStreak)
        bestCleanStreak = try container.decode(Int.self, forKey: .bestCleanStreak)
        completedBreaks = try container.decode(Int.self, forKey: .completedBreaks)
        violatedCycles = try container.decode(Int.self, forKey: .violatedCycles)
        totalPostponements = try container.decode(Int.self, forKey: .totalPostponements)
        lastCompletedBreakDate = try container.decodeIfPresent(Date.self, forKey: .lastCompletedBreakDate)
        focusMinutesByDay = try container.decodeIfPresent([String: Int].self, forKey: .focusMinutesByDay) ?? [:]
        totalFocusMinutes = try container.decodeIfPresent(Int.self, forKey: .totalFocusMinutes)
            ?? focusMinutesByDay.values.reduce(0, +)
    }
}
