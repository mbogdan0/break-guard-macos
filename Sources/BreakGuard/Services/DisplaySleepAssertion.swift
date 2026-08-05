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
@MainActor
final class DisplaySleepAssertion {
    private var id: IOPMAssertionID = IOPMAssertionID(0)
    private var isHeld = false
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "DisplaySleepAssertion")

    // Idempotent: the callers run on the per-second reconcile, so this is asked
    // far more often than the answer changes.
    func acquire(timeout: TimeInterval) {
        guard !isHeld else { return }
        // A held assertion is the only real hazard here — leak one and the
        // display never sleeps again. Release is wired to the overlay teardown
        // and IOKit drops assertions when the process exits, and the timeout is
        // the third line of defence for the cases neither covers.
        let properties: [String: Any] = [
            kIOPMAssertionTypeKey as String: kIOPMAssertionTypePreventUserIdleDisplaySleep as String,
            kIOPMAssertionNameKey as String: "BreakGuard break overlay",
            kIOPMAssertionTimeoutKey as String: max(60, timeout),
            kIOPMAssertionTimeoutActionKey as String: kIOPMAssertionTimeoutActionRelease as String
        ]
        var assertionID = IOPMAssertionID(0)
        let status = IOPMAssertionCreateWithProperties(properties as CFDictionary, &assertionID)
        guard status == kIOReturnSuccess else {
            logger.error("Display sleep assertion failed: \(status, privacy: .public)")
            return
        }
        id = assertionID
        isHeld = true
        logger.info("Holding display awake for the overlay")
    }

    func release() {
        guard isHeld else { return }
        isHeld = false
        // A timeout may have released it already; the extra release is a
        // harmless not-found, and dropping the flag first keeps a failed call
        // from wedging the assertion as permanently held.
        IOPMAssertionRelease(id)
        id = IOPMAssertionID(0)
        logger.info("Released the display sleep assertion")
    }
}
