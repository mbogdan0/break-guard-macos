import Foundation

// A convenience scale on top of the configured work interval, so switching
// between paces does not require editing the interval itself. Statistics
// always record the actual elapsed focus time.
enum FocusPace: String, Codable, CaseIterable {
    case moreBreaks
    case normal
    case deepFocus
    case tapering

    var title: String {
        switch self {
        case .moreBreaks: return "More Breaks"
        case .normal: return "Normal"
        case .deepFocus: return "Deep Focus"
        case .tapering: return "Tapering"
        }
    }

    var workIntervalMultiplier: Double {
        switch self {
        case .moreBreaks: return 0.8
        case .normal, .tapering: return 1.0
        case .deepFocus: return 1.2
        }
    }

    // Tapering shortens the focus window as fatigue accumulates. The measure
    // is time actually focused, not sessions completed: a session counter
    // rewards anyone who takes several short manual breaks in a row, since
    // each one closes a cycle. One accumulated focus minute costs one second
    // off the next window, so an 8-hour day trims a 30-minute window to ~22.
    static let taperingSecondsPerFocusMinute = 1.0

    // Non-configurable safety stop. The linear rule has no asymptote, so
    // without a bottom a long enough day — or a very short work interval —
    // would drive the window toward zero and fire breaks back to back.
    static let taperingMinimumInterval: TimeInterval = 7 * 60

    // Past this the penalty already exceeds the longest configurable window,
    // so further accumulation cannot change the outcome. Capping is not just
    // tidiness: the total is persisted as a JSON number, JSONEncoder throws on
    // infinity and NaN, and PersistenceStore.save() only logs that throw — a
    // poisoned value would silently freeze every future write.
    static let taperingFocusCeiling = TimeInterval(SettingsRange.workInterval.upperBound) * 60

    // Rejects NaN as well: every comparison against NaN is false, so it falls
    // to the zero branch rather than propagating.
    static func sanitizedTaperedFocus(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds > 0 else { return 0 }
        return min(seconds, taperingFocusCeiling)
    }

    static func taperingPenalty(forFocus focusSeconds: TimeInterval) -> TimeInterval {
        sanitizedTaperedFocus(focusSeconds) / 60 * taperingSecondsPerFocusMinute
    }
}

// The valid span of every configurable interval, in seconds. Shared by clamp()
// and the settings fields so both agree on one definition.
enum SettingsRange {
    static let workInterval: ClosedRange<Int> = 30...(240 * 60)
    static let breakDuration: ClosedRange<Int> = 30...(60 * 60)
    static let warningLeadTime: ClosedRange<Int> = 0...(30 * 60)
    static let postponeDuration: ClosedRange<Int> = 30...(120 * 60)
    // Hours without focus after which the tapering day starts over.
    static let taperingResetGapHours: ClosedRange<Int> = 1...24
}

// The once-a-week escape hatch offered at the bottom of a forced break's
// overlay. Fixed constants rather than settings: a configurable pressure
// valve is not a pressure valve.
enum EmergencyOverride {
    static let focusGrant: TimeInterval = 90 * 60
    static let cooldown: TimeInterval = 7 * 24 * 60 * 60
    // Longer than any postpone hold — this skips the break outright.
    static let holdDuration: TimeInterval = 5
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
    // A gap this long without focus means the workday ended: tapering
    // starts over and sessions run at full length again.
    var taperingResetGap: TimeInterval = 6 * 60 * 60
    // One extension per cycle, and after the first skip action (extend or
    // postpone) every further postponement demands a doubled hold.
    var harderToSkipBreaks: Bool = false

    static let defaults = AppSettings()

    // The interval a new work cycle actually runs for.
    var effectiveWorkInterval: TimeInterval {
        workInterval * focusPace.workIntervalMultiplier
    }

    // Fatigue-aware variant: in tapering mode the interval shrinks by one
    // second for every focus minute accumulated since the last long rest.
    // The inner min() matters — an interval already shorter than the safety
    // bottom must not be lengthened by it.
    func effectiveWorkInterval(taperedFocus: TimeInterval) -> TimeInterval {
        guard focusPace == .tapering else { return effectiveWorkInterval }
        let base = effectiveWorkInterval
        let penalty = FocusPace.taperingPenalty(forFocus: taperedFocus)
        return max(min(base, FocusPace.taperingMinimumInterval), base - penalty)
    }

    // How long before a new cycle's deadline the warning fires. clamp() bounds
    // the setting against the raw work interval, but the interval a cycle
    // actually runs can be shorter — a tapered window, or a scaled pace. A
    // lead at or past the whole window would open every cycle already warning,
    // which drains the signal of meaning, so the warning never eats more than
    // the back half of the window.
    func effectiveWarningLeadTime(for interval: TimeInterval) -> TimeInterval {
        max(0, min(warningLeadTime, interval / 2))
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
        let gapRange = (SettingsRange.taperingResetGapHours.lowerBound * 3600)...(SettingsRange.taperingResetGapHours.upperBound * 3600)
        taperingResetGap = clampSeconds(taperingResetGap, to: gapRange)
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
             workingHoursEnabled, weekdayWorkingHours, weekendWorkingHours,
             taperingResetGap, harderToSkipBreaks
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
        taperingResetGap = try container.decodeIfPresent(TimeInterval.self, forKey: .taperingResetGap) ?? defaults.taperingResetGap
        harderToSkipBreaks = try container.decodeIfPresent(Bool.self, forKey: .harderToSkipBreaks) ?? defaults.harderToSkipBreaks
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
