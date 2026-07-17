import Foundation

// A convenience scale on top of the configured work interval, so switching
// between paces does not require editing the interval itself. Statistics
// always record the actual elapsed focus time.
enum FocusPace: String, Codable, CaseIterable {
    case moreBreaks
    case normal
    case deepFocus

    var title: String {
        switch self {
        case .moreBreaks: return "More Breaks"
        case .normal: return "Normal"
        case .deepFocus: return "Deep Focus"
        }
    }

    var workIntervalMultiplier: Double {
        switch self {
        case .moreBreaks: return 0.8
        case .normal: return 1.0
        case .deepFocus: return 1.2
        }
    }
}

// The valid span of every configurable interval, in seconds. Shared by clamp()
// and the settings fields so both agree on one definition.
enum SettingsRange {
    static let workInterval: ClosedRange<Int> = 30...(240 * 60)
    static let breakDuration: ClosedRange<Int> = 30...(60 * 60)
    static let warningLeadTime: ClosedRange<Int> = 0...(30 * 60)
    static let postponeDuration: ClosedRange<Int> = 30...(120 * 60)
}

struct AppSettings: Codable, Equatable {
    var workInterval: TimeInterval = 30 * 60
    var focusPace: FocusPace = .normal
    var breakDuration: TimeInterval = 2 * 60
    var warningLeadTime: TimeInterval = 60
    var firstPostponeDuration: TimeInterval = 2 * 60
    var secondPostponeDuration: TimeInterval = 15 * 60
    var notificationSound: Bool = true
    var launchAtLogin: Bool = true
    var showSecondsInMenuBar: Bool = true
    var coarseSecondsInMenuBar: Bool = false
    var workingHoursEnabled: Bool = false
    var weekdayWorkingHours = WorkingHoursRange(enabled: true)
    var weekendWorkingHours = WorkingHoursRange(enabled: false)

    static let defaults = AppSettings()

    // The interval a new work cycle actually runs for.
    var effectiveWorkInterval: TimeInterval {
        workInterval * focusPace.workIntervalMultiplier
    }

    mutating func clamp() {
        workInterval = clampSeconds(workInterval, to: SettingsRange.workInterval)
        breakDuration = clampSeconds(breakDuration, to: SettingsRange.breakDuration)
        warningLeadTime = clampSeconds(warningLeadTime, to: SettingsRange.warningLeadTime)
        firstPostponeDuration = clampSeconds(firstPostponeDuration, to: SettingsRange.postponeDuration)
        secondPostponeDuration = clampSeconds(secondPostponeDuration, to: SettingsRange.postponeDuration)
        warningLeadTime = min(warningLeadTime, workInterval)
        weekdayWorkingHours.clamp()
        weekendWorkingHours.clamp()
    }
}

// Settings fields are added over time without bumping the schema version, so
// files written by older builds lack the newer keys. A plain synthesized
// decode would reject such a file — discarding all user data — so every field
// falls back to its default instead. The init lives in an extension to keep
// the memberwise initializer.
extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case workInterval, focusPace, breakDuration, warningLeadTime,
             firstPostponeDuration, secondPostponeDuration, notificationSound,
             launchAtLogin, showSecondsInMenuBar, coarseSecondsInMenuBar,
             workingHoursEnabled, weekdayWorkingHours, weekendWorkingHours
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.defaults
        workInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .workInterval) ?? defaults.workInterval
        focusPace = try container.decodeIfPresent(FocusPace.self, forKey: .focusPace) ?? defaults.focusPace
        breakDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .breakDuration) ?? defaults.breakDuration
        warningLeadTime = try container.decodeIfPresent(TimeInterval.self, forKey: .warningLeadTime) ?? defaults.warningLeadTime
        firstPostponeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .firstPostponeDuration) ?? defaults.firstPostponeDuration
        secondPostponeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .secondPostponeDuration) ?? defaults.secondPostponeDuration
        notificationSound = try container.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? defaults.notificationSound
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        showSecondsInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showSecondsInMenuBar) ?? defaults.showSecondsInMenuBar
        coarseSecondsInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .coarseSecondsInMenuBar) ?? defaults.coarseSecondsInMenuBar
        workingHoursEnabled = try container.decodeIfPresent(Bool.self, forKey: .workingHoursEnabled) ?? defaults.workingHoursEnabled
        weekdayWorkingHours = try container.decodeIfPresent(WorkingHoursRange.self, forKey: .weekdayWorkingHours) ?? defaults.weekdayWorkingHours
        weekendWorkingHours = try container.decodeIfPresent(WorkingHoursRange.self, forKey: .weekendWorkingHours) ?? defaults.weekendWorkingHours
    }
}

// Intervals are entered to the second, so they are stored to the second. The
// bounds are applied before rounding: a decoded value too large for Int would
// otherwise trap on conversion. Comparisons against NaN are all false, so it
// would survive the bounds and trap too.
private func clampSeconds(_ value: TimeInterval, to range: ClosedRange<Int>) -> TimeInterval {
    guard !value.isNaN else { return TimeInterval(range.lowerBound) }
    let bounded = min(max(value, TimeInterval(range.lowerBound)), TimeInterval(range.upperBound))
    return TimeInterval(Int(bounded.rounded()))
}
