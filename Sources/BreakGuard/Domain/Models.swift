import Foundation

protocol TimeProvider {
    var now: Date { get }
}

struct SystemClock: TimeProvider {
    var now: Date { Date() }
}

enum TimerState: Codable, Equatable {
    case working(deadline: Date, warningDeadline: Date)
    case warning(deadline: Date)
    case breakDue
    case breaking(deadline: Date, startedAt: Date, duration: TimeInterval)
    case breakCompleted
    case postponed(deadline: Date)
    case suspended(previous: SuspendedState, remaining: TimeInterval, until: Date?)
}

enum SuspendedState: Codable, Equatable {
    case working
    case warning
    case postponed
}

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
    var focusTagsEnabled: Bool = true

    static let defaults = AppSettings()

    // The interval a new work cycle actually runs for.
    var effectiveWorkInterval: TimeInterval {
        workInterval * focusPace.workIntervalMultiplier
    }

    mutating func clamp() {
        workInterval = min(max(workInterval, 60), 240 * 60)
        breakDuration = min(max(breakDuration, 60), 60 * 60)
        warningLeadTime = min(max(warningLeadTime, 0), 30 * 60)
        firstPostponeDuration = min(max(firstPostponeDuration, 60), 120 * 60)
        secondPostponeDuration = min(max(secondPostponeDuration, 60), 120 * 60)
        warningLeadTime = min(warningLeadTime, workInterval)
    }
}

extension AppSettings {
    private enum CodingKeys: String, CodingKey {
        case workInterval
        case focusPace
        case breakDuration
        case warningLeadTime
        case firstPostponeDuration
        case secondPostponeDuration
        case notificationSound
        case launchAtLogin
        case showSecondsInMenuBar
        case coarseSecondsInMenuBar
        case focusTagsEnabled
    }

    // Lenient decoding: fields absent from older schema versions fall back to
    // their defaults instead of failing the whole load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings()
        workInterval = try container.decodeIfPresent(TimeInterval.self, forKey: .workInterval) ?? defaults.workInterval
        // Decoded through the raw string so an unknown pace from a newer
        // build degrades to the default instead of failing the whole load.
        focusPace = FocusPace(rawValue: try container.decodeIfPresent(String.self, forKey: .focusPace) ?? "") ?? defaults.focusPace
        breakDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .breakDuration) ?? defaults.breakDuration
        warningLeadTime = try container.decodeIfPresent(TimeInterval.self, forKey: .warningLeadTime) ?? defaults.warningLeadTime
        firstPostponeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .firstPostponeDuration) ?? defaults.firstPostponeDuration
        secondPostponeDuration = try container.decodeIfPresent(TimeInterval.self, forKey: .secondPostponeDuration) ?? defaults.secondPostponeDuration
        notificationSound = try container.decodeIfPresent(Bool.self, forKey: .notificationSound) ?? defaults.notificationSound
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? defaults.launchAtLogin
        showSecondsInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .showSecondsInMenuBar) ?? defaults.showSecondsInMenuBar
        coarseSecondsInMenuBar = try container.decodeIfPresent(Bool.self, forKey: .coarseSecondsInMenuBar) ?? defaults.coarseSecondsInMenuBar
        focusTagsEnabled = try container.decodeIfPresent(Bool.self, forKey: .focusTagsEnabled) ?? defaults.focusTagsEnabled
    }
}

struct FocusTag: Codable, Equatable, Identifiable {
    static let maximumNameLength = 24

    let id: String
    var name: String

    static let defaults = [
        FocusTag(id: "work", name: "Work"),
        FocusTag(id: "study", name: "Study")
    ]

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum FocusTagNameError: Error, Equatable {
    case empty
    case tooLong
    case duplicate

    var message: String {
        switch self {
        case .empty: return "Enter a tag name."
        case .tooLong: return "Tag names must be 24 characters or fewer."
        case .duplicate: return "Tag names must be unique."
        }
    }
}

enum FocusClassification: Equatable {
    case tag(id: String)
    case skipped
    // Chosen via "Continue Working" when focus tags are disabled:
    // the break counts, but no focus minutes are recorded anywhere.
    case untracked
}

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

extension Statistics {
    private enum CodingKeys: String, CodingKey {
        case currentCleanStreak
        case bestCleanStreak
        case completedBreaks
        case violatedCycles
        case totalPostponements
        case lastCompletedBreakDate
        case focusMinutesByTag
        case skippedFocusMinutes
        case focusMinutesByDay
    }

    // Lenient decoding: fields absent from older schema versions fall back to
    // their defaults instead of failing the whole load.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        currentCleanStreak = try container.decodeIfPresent(Int.self, forKey: .currentCleanStreak) ?? 0
        bestCleanStreak = try container.decodeIfPresent(Int.self, forKey: .bestCleanStreak) ?? 0
        completedBreaks = try container.decodeIfPresent(Int.self, forKey: .completedBreaks) ?? 0
        violatedCycles = try container.decodeIfPresent(Int.self, forKey: .violatedCycles) ?? 0
        totalPostponements = try container.decodeIfPresent(Int.self, forKey: .totalPostponements) ?? 0
        lastCompletedBreakDate = try container.decodeIfPresent(Date.self, forKey: .lastCompletedBreakDate)
        focusMinutesByTag = try container.decodeIfPresent([String: Int].self, forKey: .focusMinutesByTag) ?? [:]
        skippedFocusMinutes = try container.decodeIfPresent(Int.self, forKey: .skippedFocusMinutes) ?? 0
        focusMinutesByDay = try container.decodeIfPresent([String: Int].self, forKey: .focusMinutesByDay) ?? [:]
    }
}

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

extension TimeInterval {
    var wholeSeconds: Int { max(0, Int(ceil(self))) }
}

func formatClock(_ interval: TimeInterval, includeHours: Bool = false) -> String {
    let seconds = interval.wholeSeconds
    let hours = seconds / 3600
    let minutes = (seconds % 3600) / 60
    let secs = seconds % 60
    if includeHours || hours > 0 {
        return String(format: "%02d:%02d:%02d", hours, minutes, secs)
    }
    return String(format: "%02d:%02d", minutes, secs)
}

func formatMinutes(_ minutes: Int) -> String {
    let clamped = max(0, minutes)
    let hours = clamped / 60
    let mins = clamped % 60
    if hours > 0 {
        return mins == 0 ? "\(hours)h" : "\(hours)h \(mins)m"
    }
    return "\(clamped) min"
}

enum MenuPrimaryAction: Equatable {
    case takeBreak
    case resume
    case none
}

struct MenuPresentation: Equatable {
    let menuBarTitle: String
    let statusTitle: String
    let primaryAction: MenuPrimaryAction
    // True inside the warning window (the lead time before a break, during
    // warning or near the end of a postponement), so the menu bar can render
    // the countdown in red.
    let isUrgent: Bool

    init(
        menuBarTitle: String,
        statusTitle: String,
        primaryAction: MenuPrimaryAction,
        isUrgent: Bool = false
    ) {
        self.menuBarTitle = menuBarTitle
        self.statusTitle = statusTitle
        self.primaryAction = primaryAction
        self.isUrgent = isUrgent
    }

    var canExtend: Bool { primaryAction == .takeBreak }
}

extension DateFormatter {
    // Cached: makeMenuPresentation runs every second and DateFormatter is
    // expensive to construct.
    static let breakGuardTime: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter
    }()
}

func makeMenuPresentation(
    for state: TimerState,
    showSeconds: Bool,
    coarseSeconds: Bool = false,
    warningLeadTime: TimeInterval = 0,
    now: Date = Date(),
    timeFormatter: DateFormatter = .breakGuardTime
) -> MenuPresentation {
    func countdown(_ interval: TimeInterval) -> String {
        if showSeconds {
            // Coarse mode rounds up to the next 10 seconds, so the rendered
            // string only changes once per 10 seconds and never understates
            // the remaining time.
            let displayed = coarseSeconds ? ceil(interval / 10) * 10 : interval
            return formatClock(displayed)
        }

        let totalMinutes = max(0, Int(ceil(interval / 60)))
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 {
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }
        return "\(totalMinutes)m"
    }

    switch state {
    case let .working(deadline, _):
        let remaining = countdown(deadline.timeIntervalSince(now))
        return MenuPresentation(
            menuBarTitle: remaining,
            statusTitle: "Next break at \(timeFormatter.string(from: deadline))",
            primaryAction: .takeBreak
        )
    case let .warning(deadline):
        let remaining = countdown(deadline.timeIntervalSince(now))
        return MenuPresentation(
            menuBarTitle: remaining,
            statusTitle: "Break starts in \(remaining)",
            primaryAction: .takeBreak,
            isUrgent: true
        )
    case let .postponed(deadline):
        let interval = deadline.timeIntervalSince(now)
        // A postponement never re-notifies, but the menu bar still turns red
        // for the same lead window so the upcoming break is not a surprise.
        return MenuPresentation(
            menuBarTitle: "+\(countdown(interval))",
            statusTitle: "Postponed break at \(timeFormatter.string(from: deadline))",
            primaryAction: .takeBreak,
            isUrgent: warningLeadTime > 0 && interval <= warningLeadTime
        )
    case let .breaking(deadline, _, _):
        let remaining = countdown(deadline.timeIntervalSince(now))
        return MenuPresentation(
            menuBarTitle: "BREAK \(remaining)",
            statusTitle: "Break remaining \(remaining)",
            primaryAction: .none
        )
    case .breakDue:
        return MenuPresentation(menuBarTitle: "BREAK", statusTitle: "Break due now", primaryAction: .none)
    case .breakCompleted:
        return MenuPresentation(menuBarTitle: "DONE", statusTitle: "Break completed", primaryAction: .none)
    case let .suspended(_, remaining, until):
        let statusTitle: String
        if let until {
            statusTitle = "Paused until \(timeFormatter.string(from: until))"
        } else {
            statusTitle = "Paused with \(countdown(remaining)) remaining"
        }
        return MenuPresentation(menuBarTitle: "PAUSED", statusTitle: statusTitle, primaryAction: .resume)
    }
}
