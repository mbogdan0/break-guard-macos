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
    // Legacy skip-action counter. Regular postponements and the emergency
    // override increment it; focusExtended accounts for an extension.
    var cyclePostponements: Int
    // Actual postpone-button uses in this cycle. Kept separately so Extend
    // Focus and the emergency override do not escalate holds in normal mode.
    var cycleRegularPostponements: Int
    // True once the current focus window was extended; keeps the menu bar in
    // its caution color until a new cycle starts.
    var focusExtended: Bool
    var cycleStartDate: Date
    var preservedAt: Date?
    var preservedRemaining: TimeInterval?
    // Working time of the current cycle, captured when the break starts.
    var cycleFocusDuration: TimeInterval?
    // When the current/most recent break started; drives the completion count-up.
    var breakStartedAt: Date?
    var manualBreakOrigin: ManualBreakOrigin?
    // Seconds actually focused since the last reset gap; drives the tapering
    // pace. 0 means the next window runs at full length.
    var taperedFocusSeconds: TimeInterval
    // When the weekly emergency override was last spent. Lives here rather
    // than in AppSettings or Statistics because "Restore Defaults" and "Reset
    // Statistics" replace those wholesale, which would refill the quota.
    var emergencyOverrideUsedAt: Date?
}

// Fields are added after schema 3 shipped without bumping the version. Older
// files lack the newer keys, and a plain synthesized decode would reject them
// — discarding all user statistics — so the decoder falls back to defaults
// instead. The init lives in an extension to keep the memberwise initializer.
extension RuntimeState {
    private enum CodingKeys: String, CodingKey {
        case timerState, cycleViolated, cyclePostponements,
             cycleRegularPostponements, focusExtended,
             cycleStartDate, preservedAt, preservedRemaining,
             cycleFocusDuration, breakStartedAt, manualBreakOrigin,
             taperedFocusSeconds, emergencyOverrideUsedAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        timerState = try container.decode(TimerState.self, forKey: .timerState)
        cycleViolated = try container.decode(Bool.self, forKey: .cycleViolated)
        let legacySkipCount = try container.decode(Int.self, forKey: .cyclePostponements)
        cyclePostponements = legacySkipCount
        focusExtended = try container.decodeIfPresent(Bool.self, forKey: .focusExtended) ?? false
        let decodedCycleStartDate = try container.decode(Date.self, forKey: .cycleStartDate)
        cycleStartDate = decodedCycleStartDate
        preservedAt = try container.decodeIfPresent(Date.self, forKey: .preservedAt)
        preservedRemaining = try container.decodeIfPresent(TimeInterval.self, forKey: .preservedRemaining)
        cycleFocusDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .cycleFocusDuration)
        breakStartedAt = try container.decodeIfPresent(Date.self, forKey: .breakStartedAt)
        manualBreakOrigin = try container.decodeIfPresent(ManualBreakOrigin.self, forKey: .manualBreakOrigin)
        taperedFocusSeconds = try container.decodeIfPresent(TimeInterval.self, forKey: .taperedFocusSeconds) ?? 0
        let decodedOverrideUsedAt = try container.decodeIfPresent(Date.self, forKey: .emergencyOverrideUsedAt)
        emergencyOverrideUsedAt = decodedOverrideUsedAt

        // Older builds counted an emergency override in cyclePostponements.
        // Infer the regular count once for an in-progress legacy cycle; after
        // this build saves, the explicit field removes the ambiguity.
        let overrideUsedInCurrentCycle = decodedOverrideUsedAt.map { $0 >= decodedCycleStartDate } ?? false
        cycleRegularPostponements = max(
            0,
            try container.decodeIfPresent(Int.self, forKey: .cycleRegularPostponements)
                ?? legacySkipCount - (overrideUsedInCurrentCycle ? 1 : 0)
        )
    }
}

struct PersistedAppData: Codable, Equatable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var settings: AppSettings
    var statistics: Statistics
    var runtime: RuntimeState
}
