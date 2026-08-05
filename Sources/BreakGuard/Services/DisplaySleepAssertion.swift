import Foundation
import IOKit.pwr_mgt
import os

// Keeps the display lit while the break overlay is up. The overlay window sits
// at the screen saver level, which only wins the stacking order — it does not
// stop the saver from starting, and when it does start the app treats it as
// downtime and pins the break's remaining time, so a break entered behind a
// saver never finishes.
//
// Deliberately only kIOPMAssertionTypePreventUserIdleDisplaySleep: it blocks
// idle-triggered display sleep and the saver, and nothing else. Closing the
// lid, locking manually, and system sleep all still work, so the user's energy
// settings are otherwise untouched.
//
// Held as a short assertion renewed on a timer rather than one open-ended
// assertion. The timeout is what bounds a leak if the overlay never tears down,
// but the overlay has no upper bound of its own — the completion screen stays
// until it is dismissed — so a fixed timeout expires under a live overlay and
// the display sleeps anyway. Renewing keeps both properties: never lapses while
// the overlay is on screen, never outlives it by more than the timeout.
@MainActor
final class DisplaySleepAssertion {
    private var id: IOPMAssertionID = IOPMAssertionID(0)
    // Also the held flag: non-nil exactly while an assertion is outstanding.
    private var renewAt: Date?
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "DisplaySleepAssertion")

    // Called from the per-second reconcile for as long as the overlay is up, so
    // the common path has to be a date comparison and nothing else.
    func hold(timeout: TimeInterval, now: Date = Date()) {
        let ceiling = Self.ceiling(for: timeout)
        if let renewAt, now < renewAt { return }
        let renewing = renewAt != nil
        // Renewal is create-then-drop in effect: the old one is dropped first
        // because IOKit keys assertions by id, and holding two would double the
        // leak window for no benefit.
        if renewing { drop() }

        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
            kIOPMAssertionNameKey as String: "BreakGuard break overlay",
            kIOPMAssertionTimeoutKey as String: ceiling,
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String
        ]
        var assertionID = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &assertionID)
        guard status == kIOReturnSuccess else {
            // Leave renewAt nil so the next tick retries rather than believing
            // it holds an assertion it does not.
            renewAt = nil
            logger.error("Display sleep assertion failed: \(status, privacy: .public)")
            return
        }
        id = assertionID
        renewAt = now.addingTimeInterval(Self.renewalInterval(for: ceiling))
        logger.info("\(renewing ? "Renewed" : "Holding", privacy: .public) the display sleep assertion")
    }

    func release() {
        guard renewAt != nil else { return }
        renewAt = nil
        drop()
        logger.info("Released the display sleep assertion")
    }

    // A timeout may have fired already; the extra release is a harmless
    // not-found.
    private func drop() {
        IOPMAssertionRelease(id)
        id = IOPMAssertionID(0)
    }

    // Floored so a pathologically short break cannot turn this into a
    // per-second create/release churn against IOKit.
    nonisolated static func ceiling(for timeout: TimeInterval) -> TimeInterval {
        max(60, timeout)
    }

    // Half the ceiling, so a renewal that fails still leaves a full half of the
    // assertion's life for the next tick to retry in.
    nonisolated static func renewalInterval(for ceiling: TimeInterval) -> TimeInterval {
        ceiling / 2
    }
}
