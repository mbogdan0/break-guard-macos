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
