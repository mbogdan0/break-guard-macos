import Foundation

// Why the app is currently reminding the user to stop. A recurring card leaves
// the screen clear between reminders. The whole feature is gated on
// `harderToSkipBreaks`: without it the app stays as polite as it has been.
enum PressureReason: Equatable {
    // Past the configured working hours for the day.
    case outsideWorkingHours
}

// Fixed, not settings. A pressure valve the user can weaken from the settings
// pane is not a pressure valve — the same reasoning as EmergencyOverride.
enum BreakPressure {
    // How long closing the card buys. The card is the part with a dismiss, so
    // it is the part that has to come back.
    static let cardReturnInterval: TimeInterval = 90
    static let dismissHoldDuration: TimeInterval = 3
}

struct PressureReminderState {
    private(set) var reason: PressureReason?
    private var hiddenUntil: Date?

    mutating func update(reason: PressureReason?) {
        guard self.reason != reason else { return }
        self.reason = reason
        hiddenUntil = nil
    }

    mutating func dismiss(at now: Date) {
        guard reason != nil else { return }
        hiddenUntil = now.addingTimeInterval(BreakPressure.cardReturnInterval)
    }

    func shouldShowCard(at now: Date) -> Bool {
        reason != nil && (hiddenUntil.map { now >= $0 } ?? true)
    }
}

// What the nudge card says. Derived rather than stored so the card can be
// rebuilt from the reason alone.
//
// The main action starts a break. A separate disclosure offers the six-day
// override; pausing until morning remains in the menu behind its confirmation.
struct NudgePresentation: Equatable {
    let title: String
    let message: String
    let primaryTitle: String
}

func makeNudgePresentation(reason: PressureReason) -> NudgePresentation {
    switch reason {
    case .outsideWorkingHours:
        return NudgePresentation(
            title: "Outside working hours",
            message: "Time to step away and rest your eyes. This reminder returns \(formatDurationPhrase(BreakPressure.cardReturnInterval)) after dismissal.",
            primaryTitle: "Take a Break Now"
        )
    }
}

extension AppSettings {
    func pressureReason(at now: Date, calendar: Calendar = .current) -> PressureReason? {
        guard harderToSkipBreaks else { return nil }
        return isOutsideWorkingHours(at: now, calendar: calendar) ? .outsideWorkingHours : nil
    }
}
