import Foundation

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
