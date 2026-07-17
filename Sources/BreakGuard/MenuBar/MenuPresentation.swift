import Foundation

enum MenuPrimaryAction: Equatable {
    case takeBreak
    case resume
    case none
}

// How loudly the menu bar item should call attention to itself.
enum MenuBarEmphasis: Equatable {
    // Template eye + plain adaptive text.
    case none
    // Yellow pill: on borrowed time (postponed break, extended focus) or
    // outside configured working hours.
    case caution
    // Red pill: inside the warning window (the lead time before a break,
    // during warning or near the end of a postponement). Always wins.
    case urgent
}

struct MenuPresentation: Equatable {
    let menuBarTitle: String
    let statusTitle: String
    let primaryAction: MenuPrimaryAction
    let emphasis: MenuBarEmphasis

    init(
        menuBarTitle: String,
        statusTitle: String,
        primaryAction: MenuPrimaryAction,
        emphasis: MenuBarEmphasis = .none
    ) {
        self.menuBarTitle = menuBarTitle
        self.statusTitle = statusTitle
        self.primaryAction = primaryAction
        self.emphasis = emphasis
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
    focusExtended: Bool = false,
    outsideWorkingHours: Bool = false,
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

    let base: MenuPresentation
    switch state {
    case let .working(deadline, _):
        let remaining = countdown(deadline.timeIntervalSince(now))
        base = MenuPresentation(
            menuBarTitle: remaining,
            statusTitle: "Next break at \(timeFormatter.string(from: deadline))",
            primaryAction: .takeBreak,
            // An extended focus window runs on borrowed time.
            emphasis: focusExtended ? .caution : .none
        )
    case let .warning(deadline):
        let remaining = countdown(deadline.timeIntervalSince(now))
        base = MenuPresentation(
            menuBarTitle: remaining,
            statusTitle: "Break starts in \(remaining)",
            primaryAction: .takeBreak,
            emphasis: .urgent
        )
    case let .postponed(deadline):
        let interval = deadline.timeIntervalSince(now)
        // A postponement runs on borrowed time, so it is at least yellow. It
        // never re-notifies, but the menu bar still turns red for the same
        // lead window so the upcoming break is not a surprise.
        base = MenuPresentation(
            menuBarTitle: "+\(countdown(interval))",
            statusTitle: "Postponed break at \(timeFormatter.string(from: deadline))",
            primaryAction: .takeBreak,
            emphasis: warningLeadTime > 0 && interval <= warningLeadTime ? .urgent : .caution
        )
    case let .breaking(deadline, _, _):
        let remaining = countdown(deadline.timeIntervalSince(now))
        base = MenuPresentation(
            menuBarTitle: "BREAK \(remaining)",
            statusTitle: "Break remaining \(remaining)",
            primaryAction: .none
        )
    case .breakDue:
        base = MenuPresentation(menuBarTitle: "BREAK", statusTitle: "Break due now", primaryAction: .none)
    case .breakCompleted:
        base = MenuPresentation(menuBarTitle: "DONE", statusTitle: "Break completed", primaryAction: .none)
    case let .suspended(_, remaining, until):
        let statusTitle: String
        if let until {
            statusTitle = "Paused until \(timeFormatter.string(from: until))"
        } else {
            statusTitle = "Paused with \(countdown(remaining)) remaining"
        }
        base = MenuPresentation(menuBarTitle: "PAUSED", statusTitle: statusTitle, primaryAction: .resume)
    }

    // Outside working hours everything shows in the caution pill, but a state
    // that is already yellow or red keeps its own emphasis — the red warning
    // must never be diluted down to yellow.
    guard outsideWorkingHours, base.emphasis == .none else { return base }
    return MenuPresentation(
        menuBarTitle: base.menuBarTitle,
        statusTitle: base.statusTitle,
        primaryAction: base.primaryAction,
        emphasis: .caution
    )
}
