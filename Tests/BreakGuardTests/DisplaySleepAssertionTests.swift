import XCTest
@testable import BreakGuard

// The assertion's timing arithmetic. The IOKit calls themselves are not
// exercised here — what broke in practice was the schedule, not the syscall: a
// fixed timeout expired under a live overlay, because the completion screen has
// no upper bound of its own.
final class DisplaySleepAssertionTests: XCTestCase {

    func testCeilingFloorsPathologicallyShortBreaks() {
        // A 30-second break plus slack is already well clear of the floor.
        XCTAssertEqual(DisplaySleepAssertion.ceiling(for: 30 + 5 * 60), 330)
        // But the floor is what stops a per-second create/release churn.
        XCTAssertEqual(DisplaySleepAssertion.ceiling(for: 1), 60)
        XCTAssertEqual(DisplaySleepAssertion.ceiling(for: 0), 60)
        XCTAssertEqual(DisplaySleepAssertion.ceiling(for: -100), 60)
    }

    // The renewal has to land with room to spare, or a single failed renewal
    // drops the assertion for the rest of the overlay.
    func testRenewalLeavesHalfTheAssertionLifeToRetryIn() {
        let ceiling = DisplaySleepAssertion.ceiling(for: 2 * 60 + 5 * 60)
        let renewal = DisplaySleepAssertion.renewalInterval(for: ceiling)

        XCTAssertLessThan(renewal, ceiling)
        XCTAssertEqual(ceiling - renewal, renewal, accuracy: 0.001)
    }

    // The regression, stated as arithmetic: with the default 2-minute break the
    // ceiling is 7 minutes, and an overlay left up longer than that used to lose
    // the assertion outright. Renewing on the reconcile keeps it covered for as
    // long as the overlay lives.
    func testOverlayOutlivingTheCeilingStaysCovered() {
        let ceiling = DisplaySleepAssertion.ceiling(for: 2 * 60 + 5 * 60)
        let renewal = DisplaySleepAssertion.renewalInterval(for: ceiling)
        XCTAssertEqual(ceiling, 7 * 60, accuracy: 0.001)

        // Half an hour on the completion screen, renewed on the per-second
        // reconcile: every moment is inside some assertion's lifetime.
        var renewedAt: TimeInterval = 0
        var covered: TimeInterval = ceiling
        while renewedAt < 30 * 60 {
            XCTAssertGreaterThan(covered, renewedAt, "assertion lapsed at \(renewedAt)s")
            renewedAt += renewal
            covered = renewedAt + ceiling
        }
        XCTAssertGreaterThan(covered, 30 * 60)
    }
}
