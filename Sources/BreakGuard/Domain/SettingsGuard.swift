import Foundation

// Which settings edits give the user more room, and which take it away.
//
// Harder mode charges for a visit to the settings pane, but only for the net
// loosening: gating each write would open a dialog per stepper click, and
// charging the same for tightening as for loosening would teach the user to
// stay out of the pane entirely — the opposite of what the mode is for.
//
// Deliberately excluded, because they change nothing about how hard a break is
// to avoid: the warning lead time (the break still lands at the same moment),
// the notification sound, and both menu bar rendering options.
extension AppSettings {
    func weakensGuard(comparedTo baseline: AppSettings) -> Bool {
        // Longer to the next break, or shorter once it arrives.
        if workInterval > baseline.workInterval { return true }
        if breakDuration < baseline.breakDuration { return true }
        if focusPace.guardRank > baseline.focusPace.guardRank { return true }

        // A bigger skip when one is taken.
        if firstPostponeDuration > baseline.firstPostponeDuration { return true }
        if secondPostponeDuration > baseline.secondPostponeDuration { return true }

        // Tapering starting over sooner means full-length windows sooner — but
        // only while the pace is tapering; the gap is inert otherwise. Leaving
        // tapering altogether is already caught by guardRank above.
        if focusPace == .tapering, taperingResetGap < baseline.taperingResetGap { return true }

        // A break that a call can postpone indefinitely.
        if holdBreaksWhileOnCamera && !baseline.holdBreaksWhileOnCamera { return true }

        // An app that does not come back after a restart guards nothing.
        if !launchAtLogin && baseline.launchAtLogin { return true }

        // After-hours pressure: switched off, or given fewer hours to fall
        // outside of. The master switch is folded into the ranges rather than
        // tested beside them, which also covers switching it off: with the
        // current side inert, widens(from:) reports whether the baseline had
        // any pressure to lose — and says no when both day ranges were off
        // anyway, where the old standalone test charged for a no-op.
        if afterHoursRange(weekdayWorkingHours)
            .widens(from: baseline.afterHoursRange(baseline.weekdayWorkingHours)) { return true }
        if afterHoursRange(weekendWorkingHours)
            .widens(from: baseline.afterHoursRange(baseline.weekendWorkingHours)) { return true }

        // The scheduled rest window: switched off, or made shorter.
        if scheduledBreak.narrows(from: baseline.scheduledBreak) { return true }

        // `harderToSkipBreaks` itself is absent on purpose. It is gated at its
        // own toggle, and charging for one decision twice is not friction, it
        // is noise.
        return false
    }

    // A day range means nothing while the master switch is off, so it compares
    // as disabled. Comparing the raw ranges got the direction wrong: the
    // defaults leave an unused 9–18 weekday range behind the switch, so
    // turning after-hours pressure *on* with wider hours than that read as a
    // loosening, when it is the opposite.
    private func afterHoursRange(_ range: WorkingHoursRange) -> WorkingHoursRange {
        workingHoursEnabled ? range : WorkingHoursRange(enabled: false)
    }
}

extension FocusPace {
    // How hard the pace pushes, strictest first. Deliberately not
    // workIntervalMultiplier: tapering shares normal's multiplier but shortens
    // every window as the day accumulates, so leaving tapering is a loosening
    // the multiplier alone cannot see.
    var guardRank: Int {
        switch self {
        case .moreBreaks: return 0
        case .tapering: return 1
        case .normal: return 2
        case .deepFocus: return 3
        }
    }
}

extension WorkingHoursRange {
    // For working hours, where the pressure applies *outside* the range: more
    // hours inside it is less pressure. Turning the day category off removes
    // the pressure for that day entirely.
    func widens(from baseline: WorkingHoursRange) -> Bool {
        guard enabled else { return baseline.enabled }
        guard baseline.enabled else { return false }
        return startMinutes < baseline.startMinutes || endMinutes > baseline.endMinutes
    }

    // For the scheduled break, where the pressure applies *inside* the range:
    // fewer minutes is less rest.
    func narrows(from baseline: WorkingHoursRange) -> Bool {
        guard enabled else { return baseline.enabled }
        guard baseline.enabled else { return false }
        return startMinutes > baseline.startMinutes || endMinutes < baseline.endMinutes
    }
}
