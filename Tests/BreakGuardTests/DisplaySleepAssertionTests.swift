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

@MainActor
private final class FakeSleepAssertionClient: SleepAssertionClient {
    var created: [(type: String, id: UInt32)] = []
    var released: [UInt32] = []
    var failType: String?
    var nextID: UInt32 = 1

    func create(type: String, timeout: TimeInterval) -> UInt32? {
        guard type != failType else { return nil }
        let id = nextID
        nextID += 1
        created.append((type, id))
        return id
    }

    func release(_ id: UInt32) { released.append(id) }
}

extension DisplaySleepAssertionTests {
    @MainActor
    func testHoldsDisplayAndSystemSleepWithoutPerTickChurn() {
        let client = FakeSleepAssertionClient()
        let assertion = DisplaySleepAssertion(client: client)
        assertion.hold(timeout: 60, now: 0)
        XCTAssertEqual(Set(client.created.map(\.type)), ["PreventUserIdleDisplaySleep", "PreventUserIdleSystemSleep"])
        for second in 1..<30 { assertion.hold(timeout: 60, now: Double(second)) }
        XCTAssertEqual(client.created.count, 2)
        assertion.hold(timeout: 60, now: 30)
        XCTAssertEqual(client.created.count, 4)
        XCTAssertEqual(Set(client.released), [1, 2])
        assertion.release()
        XCTAssertEqual(Set(client.released), [1, 2, 3, 4])
        assertion.release()
        XCTAssertEqual(client.released.count, 4)
    }

    @MainActor
    func testFailedRenewalKeepsOldCoverageAndRetriesNextTick() {
        let client = FakeSleepAssertionClient()
        let assertion = DisplaySleepAssertion(client: client)
        assertion.hold(timeout: 60, now: 0)
        client.failType = "PreventUserIdleDisplaySleep"
        assertion.hold(timeout: 60, now: 30)
        XCTAssertFalse(client.released.contains(1))
        client.failType = nil
        assertion.hold(timeout: 60, now: 31)
        XCTAssertTrue(client.released.contains(1))
        XCTAssertEqual(client.created.count, 5)
        assertion.release()
        XCTAssertEqual(Set(client.released), Set(client.created.map(\.id)))
    }

    @MainActor
    func testReleaseAllowsANewOverlayToAcquireImmediately() {
        let client = FakeSleepAssertionClient()
        let assertion = DisplaySleepAssertion(client: client)
        assertion.hold(timeout: 600, now: 0)
        assertion.release()
        assertion.hold(timeout: 600, now: 1)
        XCTAssertEqual(client.created.count, 4)
        assertion.release()
    }
}
