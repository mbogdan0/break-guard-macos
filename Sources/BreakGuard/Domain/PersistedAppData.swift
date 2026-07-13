import Foundation

// Snapshot of the timer at the moment "Take a Break Now" was pressed,
// so a manual break can be cancelled and the interrupted cycle restored.
struct ManualBreakOrigin: Codable, Equatable {
    var previous: SuspendedState
    // Time to the deadline when the break was requested.
    var remaining: TimeInterval
    // Used to exclude overlay time from focus credit on cancel.
    var capturedAt: Date
}

struct RuntimeState: Codable, Equatable {
    var timerState: TimerState
    var cycleViolated: Bool
    var cyclePostponements: Int
    var cycleStartDate: Date
    var preservedAt: Date?
    var preservedRemaining: TimeInterval?
    // Working time of the current cycle, captured when the break starts.
    var cycleFocusDuration: TimeInterval?
    // When the current/most recent break started; drives the completion count-up.
    var breakStartedAt: Date?
    var manualBreakOrigin: ManualBreakOrigin?
}

struct PersistedAppData: Codable, Equatable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var settings: AppSettings
    var focusTags: [FocusTag]
    var statistics: Statistics
    var runtime: RuntimeState
}
