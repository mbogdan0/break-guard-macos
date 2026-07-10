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

struct AppSettings: Codable, Equatable {
    var workInterval: TimeInterval = 30 * 60
    var breakDuration: TimeInterval = 2 * 60
    var warningLeadTime: TimeInterval = 60
    var firstPostponeDuration: TimeInterval = 2 * 60
    var secondPostponeDuration: TimeInterval = 15 * 60
    var notificationSound: Bool = true
    var launchAtLogin: Bool = true
    var showSecondsInMenuBar: Bool = true

    static let defaults = AppSettings()

    mutating func clamp() {
        workInterval = min(max(workInterval, 60), 240 * 60)
        breakDuration = min(max(breakDuration, 60), 60 * 60)
        warningLeadTime = min(max(warningLeadTime, 0), 30 * 60)
        firstPostponeDuration = min(max(firstPostponeDuration, 60), 120 * 60)
        secondPostponeDuration = min(max(secondPostponeDuration, 60), 120 * 60)
        warningLeadTime = min(warningLeadTime, workInterval)
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
}

struct Statistics: Codable, Equatable {
    var currentCleanStreak: Int = 0
    var bestCleanStreak: Int = 0
    var completedBreaks: Int = 0
    var violatedCycles: Int = 0
    var totalPostponements: Int = 0
    var lastCompletedBreakDate: Date?
    var focusSessionsByTag: [String: Int] = [:]
    var skippedFocusSessions: Int = 0

    static let empty = Statistics()
}

struct RuntimeState: Codable, Equatable {
    var timerState: TimerState
    var cycleViolated: Bool
    var cyclePostponements: Int
    var cycleStartDate: Date
    var preservedAt: Date?
    var preservedRemaining: TimeInterval?
}

struct PersistedAppData: Codable, Equatable {
    static let currentSchemaVersion = 2

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

enum MenuPrimaryAction: Equatable {
    case takeBreak
    case resume
    case none
}

struct MenuPresentation: Equatable {
    let menuBarTitle: String
    let statusTitle: String
    let primaryAction: MenuPrimaryAction

    var canPause: Bool { primaryAction == .takeBreak }
}

func makeMenuPresentation(
    for state: TimerState,
    showSeconds: Bool,
    now: Date = Date()
) -> MenuPresentation {
    func countdown(_ interval: TimeInterval) -> String {
        if showSeconds {
            return formatClock(interval)
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
            statusTitle: "Next break in \(remaining)",
            primaryAction: .takeBreak
        )
    case let .warning(deadline):
        let remaining = countdown(deadline.timeIntervalSince(now))
        return MenuPresentation(
            menuBarTitle: remaining,
            statusTitle: "Break starts in \(remaining)",
            primaryAction: .takeBreak
        )
    case let .postponed(deadline):
        let remaining = countdown(deadline.timeIntervalSince(now))
        return MenuPresentation(
            menuBarTitle: "+\(remaining)",
            statusTitle: "Postponed break in \(remaining)",
            primaryAction: .takeBreak
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
            statusTitle = "Paused for \(countdown(until.timeIntervalSince(now)))"
        } else {
            statusTitle = "Paused with \(countdown(remaining)) remaining"
        }
        return MenuPresentation(menuBarTitle: "PAUSED", statusTitle: statusTitle, primaryAction: .resume)
    }
}
