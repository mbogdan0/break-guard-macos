import Foundation

// Why the app is currently leaning on the user to stop. Both reasons dim the
// screen and float a card; neither ever blocks it — everything underneath
// stays visible and clickable. The whole feature is gated on
// `harderToSkipBreaks`: without it the app stays as polite as it has been.
enum PressureReason: Equatable {
    // Inside the weekday rest window.
    case scheduledBreak
    // Past the configured working hours for the day.
    case outsideWorkingHours
}

// Fixed, not settings. A pressure valve the user can weaken from the settings
// pane is not a pressure valve — the same reasoning as EmergencyOverride.
enum BreakPressure {
    // Enough that a bright editor stops looking normal and staying at it feels
    // like a choice, still far short of hiding content or making text
    // unreadable — the veil is pressure, never a block.
    static let veilOpacity = 0.28
    // How long closing the card buys. The card is the part with a dismiss, so
    // it is the part that has to come back.
    static let cardReturnInterval: TimeInterval = 2 * 60
}

// What the nudge card says. Derived rather than stored so the card can be
// rebuilt from the reason alone.
//
// The card offers exactly one action, deliberately: it is the action that
// answers the pressure. Stopping for the day is a bigger decision than a card
// in the corner should take, and it already lives in the menu behind its own
// confirmation.
struct NudgePresentation: Equatable {
    let title: String
    let message: String
    let primaryTitle: String
}

func makeNudgePresentation(
    reason: PressureReason,
    windowEnd: Date?,
    timeFormatter: DateFormatter = .breakGuardTime
) -> NudgePresentation {
    switch reason {
    case .scheduledBreak:
        let until = windowEnd.map { " until \(timeFormatter.string(from: $0))" } ?? ""
        return NudgePresentation(
            title: "Break time",
            message: "Your scheduled break runs\(until). Step away from the screen — the display stays dimmed while you keep working.",
            primaryTitle: "Take a Break Now"
        )
    case .outsideWorkingHours:
        // Deliberately silent about which side of the day this is. The same
        // window covers an early start and a late finish, and a message that
        // guesses wrong ("still up?" at 6 a.m.) is one the reader stops
        // believing.
        return NudgePresentation(
            title: "Outside working hours",
            message: """
            This is time you set aside for not working, and your eyes have no way of knowing \
            it is a good reason. Strain does not announce itself — it accumulates quietly and \
            is paid for later, in focus that will not come back and evenings that end with a \
            headache.

            Rest is not the reward for finishing. It is the thing that makes finishing \
            possible tomorrow. Step away from the screen, look at something far away for a \
            while, and let your eyes reset.

            The display stays dimmed while you keep working.
            """,
            primaryTitle: "Take a Break Now"
        )
    }
}

extension AppSettings {
    // Nil means no pressure. The scheduled break wins when a window overlaps
    // the end of working hours: it is the more specific instruction, and it
    // has an action ("take the break") that the other one does not.
    func pressureReason(at now: Date, calendar: Calendar = .current) -> PressureReason? {
        guard harderToSkipBreaks else { return nil }
        if isInScheduledBreak(at: now, calendar: calendar) { return .scheduledBreak }
        return isOutsideWorkingHours(at: now, calendar: calendar) ? .outsideWorkingHours : nil
    }

    func isInScheduledBreak(at now: Date, calendar: Calendar = .current) -> Bool {
        scheduledBreakWindow(containing: now, calendar: calendar) != nil
    }

    // The concrete start and end of the window `now` falls in, so callers can
    // say "until 16:00" and ask whether a break already landed inside it.
    // Nil on weekends, when the window is off, and outside its hours.
    func scheduledBreakWindow(
        containing now: Date,
        calendar: Calendar = .current
    ) -> (start: Date, end: Date)? {
        guard scheduledBreak.enabled,
              DayCategory(date: now, calendar: calendar) == .weekday else { return nil }
        let components = calendar.dateComponents([.hour, .minute], from: now)
        let minutes = (components.hour ?? 0) * 60 + (components.minute ?? 0)
        guard scheduledBreak.contains(minutesFromMidnight: minutes) else { return nil }
        // Set on the wall clock rather than added to midnight. Membership above
        // is decided by the hour and minute components, so the bounds have to
        // be read the same way — on a DST day, midnight plus 930 minutes is
        // 16:30, not the 15:30 the membership test just matched, which would
        // report an hour-wrong end time and misjudge whether a break landed
        // inside the window.
        guard let start = calendar.date(bySettingHour: scheduledBreak.startMinutes / 60,
                                        minute: scheduledBreak.startMinutes % 60,
                                        second: 0,
                                        of: now),
              let end = calendar.date(bySettingHour: scheduledBreak.endMinutes / 60,
                                      minute: scheduledBreak.endMinutes % 60,
                                      second: 0,
                                      of: now)
        else { return nil }
        return (start, end)
    }
}
