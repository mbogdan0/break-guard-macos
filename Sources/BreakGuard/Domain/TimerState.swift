import Foundation

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
