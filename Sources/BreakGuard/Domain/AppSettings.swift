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
    // each one closes a cycle. One accumulated focus minute costs 1.2 seconds
    // off the next window, so an 8-hour day trims a 30-minute window to ~20.
    static let taperingSecondsPerFocusMinute = 1.2

    // The most tapering may ever take off a window, reached after 10 hours of
    // accumulated focus. Past that the day is already long enough that
    // shortening the window further would only stack breaks on breaks, and the
    // rule stops being about fatigue and starts being about attrition.
    static let taperingMaximumPenalty: TimeInterval = 12 * 60

    // Non-configurable safety stop, and not made redundant by the penalty cap
    // above: the cap bounds what is subtracted, this bounds what is left. A
    // short enough work interval still lands under it — anything below
    // taperingMaximumPenalty + this would otherwise fire breaks back to back.
    static let taperingMinimumInterval: TimeInterval = 10 * 60

    // A gap that crosses into a new local day ends the tapering day well before
    // the configurable gap does. Without it the reset gap has to be tuned under
    // the length of a night, and any night shorter than the setting carries the
    // whole previous day over. Deliberately longer than any break or meal and
    // shorter than any night, so working straight through midnight is never
    // mistaken for a new day.
    static let taperingOvernightGap: TimeInterval = 3 * 60 * 60

    // A bound on the accumulator itself, not on its effect — the penalty cap
    // already makes anything past 10 hours indistinguishable. This one is
    // about storage: the total is persisted as a JSON number, JSONEncoder
    // throws on infinity and NaN, and PersistenceStore.save() only logs that
    // throw — a poisoned value would silently freeze every future write.
    static let taperingFocusCeiling: TimeInterval = 240 * 60 * 60

    // Rejects NaN as well: every comparison against NaN is false, so it falls
    // to the zero branch rather than propagating.
    static func sanitizedTaperedFocus(_ seconds: TimeInterval) -> TimeInterval {
        guard seconds > 0 else { return 0 }
        return min(seconds, taperingFocusCeiling)
    }

    // The cap is applied here rather than at the call site so no caller can
    // reconstruct the uncapped figure — the settings pane reports this number
    // to the user, and it has to be the one the interval math actually used.
    static func taperingPenalty(forFocus focusSeconds: TimeInterval) -> TimeInterval {
        min(
            sanitizedTaperedFocus(focusSeconds) / 60 * taperingSecondsPerFocusMinute,
            taperingMaximumPenalty
        )
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
    static let dailySkipLimit: ClosedRange<Int> = 0...10
}

// The once-a-week escape hatch offered at the bottom of a forced break's
// overlay. Fixed constants rather than settings: a configurable pressure
// valve is not a pressure valve.
enum EmergencyOverride {
    static let focusGrant: TimeInterval = 90 * 60
    static let cooldown: TimeInterval = 7 * 24 * 60 * 60
    // Short on purpose, and the one piece of friction that does not scale with
    // harder mode. The weekly quota is what makes this hard to abuse, so the
    // hold only has to be deliberate enough to not fire on a stray click —
    // pricing it off the ladder would charge twice for the same decision.
    static let holdDuration: TimeInterval = 3
}

// Absence inferred from input silence. Sleep and lock notifications cannot
// see a machine that stays awake with nobody at it (insomnia with the lid
// closed, a wake nobody asked for), so input idle is the backstop that keeps
// unattended hours out of the focus statistics.
enum IdleAway {
    // Long enough that reading or watching something rarely trips it, short
    // enough that an unattended machine cannot fabricate much focus. The
    // known cost: fully passive viewing with zero input for this long
    // suspends the countdown.
    static let threshold: TimeInterval = 10 * 60
}

// While a selected call device is in use the countdown stays above the warning
// window, so a break cannot interrupt a call — and when the call ends the
// full warning lead still stands between the user and the break.
enum CallHold {
    // Floor for the guaranteed post-call runway when the warning lead is
    // configured shorter (or zero).
    static let minimumRunway: TimeInterval = 2 * 60
}

// Defense in depth for the statistics: no single cycle can legitimately run
// anywhere near this long, so anything above it is a monitoring gap that
// slipped through, not focus.
enum StatisticsIntegrity {
    static let maxCreditablePerCycle: TimeInterval = 4 * 60 * 60
}

enum PostponeHoldTier: Equatable {
    case standard
    case harder
    case repeated
}

// The actions that skip or silence rest go through a confirmation whose confirm
// button stays disabled for a fixed count, shown in parentheses on the button
// itself. The point is not the wait but the reflex it breaks: a dialog whose
// default button is already under the pointer is dismissed before the question
// is read.
//
// One ladder, priced by how much rest the action removes, and one rule for the
// two modes: these are the harder-mode counts, and normal mode pays half. An
// action costs the same wherever it is reached from, and no action is free.
enum SkipConfirmGate {
    static let extendShortSeconds: TimeInterval = 12
    static let extendLongSeconds: TimeInterval = 30
    // At or under this the shorter gate applies. The short extension is the
    // one that still resembles a decision rather than a whole afternoon.
    static let extendShortThresholdMinutes: Double = 15
    // Much longer than any extension's, because this one silences every
    // reminder until the morning — the largest single thing the app can be
    // told to stop doing.
    static let pauseUntilMorningSeconds: TimeInterval = 180
    // Priced with the pause above: quitting silences the same reminders, and
    // for longer. This is the only way out — the app is an accessory with no
    // Cmd+Q — so the menu item carries the whole weight of the decision.
    static let quitAppSeconds: TimeInterval = 180
    // Switching harder mode off is the move that removes every other gate at
    // once, so it is the one gate that has to survive its own removal. Turning
    // it *on* is never gated — friction belongs on the way out, not in.
    // Never halved: it is only reachable while harder mode is on.
    static let disableHarderModeSeconds: TimeInterval = 90
    // Charged once per visit to the settings pane, on the net loosening. Also
    // never halved — the charge only exists when harder mode was on at one end
    // of the visit, so there is no normal-mode case to price.
    static let loosenSettingsSeconds: TimeInterval = 5 * 60

    // Normal mode pays half of every count above. One rule instead of a
    // per-action table of exceptions, and the ordering survives the halving.
    static func scaled(_ seconds: TimeInterval, harderToSkipBreaks: Bool) -> TimeInterval {
        harderToSkipBreaks ? seconds : seconds / 2
    }

    static func extendSeconds(forMinutes minutes: Double, harderToSkipBreaks: Bool) -> TimeInterval {
        let base = minutes <= extendShortThresholdMinutes ? extendShortSeconds : extendLongSeconds
        return scaled(base, harderToSkipBreaks: harderToSkipBreaks)
    }

    static func pauseSeconds(harderToSkipBreaks: Bool) -> TimeInterval {
        scaled(pauseUntilMorningSeconds, harderToSkipBreaks: harderToSkipBreaks)
    }

    static func quitSeconds(harderToSkipBreaks: Bool) -> TimeInterval {
        scaled(quitAppSeconds, harderToSkipBreaks: harderToSkipBreaks)
    }
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
    // The daily rest window. Weekdays only, deliberately not configurable:
    // a scheduled break that can be moved to the weekend is a break nobody
    // takes. Pressure only runs while harderToSkipBreaks is on.
    var scheduledBreak = WorkingHoursRange(
        enabled: false,
        startMinutes: 15 * 60 + 30,
        endMinutes: 16 * 60
    )
    // A gap this long without focus means the workday ended: tapering
    // starts over and sessions run at full length again.
    var taperingResetGap: TimeInterval = 6 * 60 * 60
    // Harder mode allows one normal skip action per cycle: either extending
    // focus or postponing a break. The weekly override remains an exception.
    var harderToSkipBreaks: Bool = false
    var dailySkipLimit: Int = 3
    // Freeze the countdown just above the warning window while any camera is
    // in use, so a break never lands mid-call. The held time still counts as
    // focus.
    var holdBreaksWhileOnCamera: Bool = true
    // Opt-in: microphone use also includes recording and dictation.
    var holdBreaksWhileMicrophoneInUse: Bool = false

    static let defaults = AppSettings()

    // The interval a new work cycle actually runs for.
    var effectiveWorkInterval: TimeInterval {
        workInterval * focusPace.workIntervalMultiplier
    }

    // Fatigue-aware variant: in tapering mode the interval shrinks by 1.2
    // seconds for every focus minute accumulated since the last long rest.
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
        scheduledBreak.clamp()
        let gapRange = (SettingsRange.taperingResetGapHours.lowerBound * 3600)...(SettingsRange.taperingResetGapHours.upperBound * 3600)
        taperingResetGap = clampSeconds(taperingResetGap, to: gapRange)
        dailySkipLimit = min(max(dailySkipLimit, SettingsRange.dailySkipLimit.lowerBound), SettingsRange.dailySkipLimit.upperBound)
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
             scheduledBreak, taperingResetGap, harderToSkipBreaks,
             holdBreaksWhileOnCamera, holdBreaksWhileMicrophoneInUse, dailySkipLimit
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
        scheduledBreak = try container.decodeIfPresent(WorkingHoursRange.self, forKey: .scheduledBreak) ?? defaults.scheduledBreak
        taperingResetGap = try container.decodeIfPresent(TimeInterval.self, forKey: .taperingResetGap) ?? defaults.taperingResetGap
        harderToSkipBreaks = try container.decodeIfPresent(Bool.self, forKey: .harderToSkipBreaks) ?? defaults.harderToSkipBreaks
        holdBreaksWhileOnCamera = try container.decodeIfPresent(Bool.self, forKey: .holdBreaksWhileOnCamera) ?? defaults.holdBreaksWhileOnCamera
        holdBreaksWhileMicrophoneInUse = try container.decodeIfPresent(Bool.self, forKey: .holdBreaksWhileMicrophoneInUse) ?? defaults.holdBreaksWhileMicrophoneInUse
        dailySkipLimit = try container.decodeIfPresent(Int.self, forKey: .dailySkipLimit) ?? defaults.dailySkipLimit
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
