import Foundation

struct Statistics: Codable, Equatable {
    var currentCleanStreak: Int = 0
    var bestCleanStreak: Int = 0
    var completedBreaks: Int = 0
    var violatedCycles: Int = 0
    var totalPostponements: Int = 0
    var lastCompletedBreakDate: Date?
    var focusMinutesByTag: [String: Int] = [:]
    var skippedFocusMinutes: Int = 0
    // Tag-independent daily totals, keyed by local-calendar day ("yyyy-MM-dd").
    var focusMinutesByDay: [String: Int] = [:]

    static let empty = Statistics()

    var totalFocusMinutes: Int {
        focusMinutesByTag.values.reduce(0, +) + skippedFocusMinutes
    }
}
