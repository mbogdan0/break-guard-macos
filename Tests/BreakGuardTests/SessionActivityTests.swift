import XCTest
@testable import BreakGuard

final class SessionActivityTests: XCTestCase {
    func testEverySignalOrderKeepsSleepDurationAndWaitsForAllReasons() {
        let reasons: [InactiveReason] = [.sleep, .session, .screenLock, .screenSaver]
        let orders = permutations(reasons)
        let start = Date(timeIntervalSince1970: 1_790_700_000)
        for entering in orders {
            for leaving in orders {
                var activity = SessionActivity()
                for (index, reason) in entering.enumerated() {
                    XCTAssertEqual(activity.set(reason, inactive: true, at: start), index == 0)
                }
                for (index, reason) in leaving.enumerated() {
                    XCTAssertEqual(activity.set(reason, inactive: false, at: start.addingTimeInterval(3600)), index == 3)
                    XCTAssertEqual(activity.isInactive, index != 3)
                }
                XCTAssertEqual(activity.longestSleepDuration, 3600)
                // A later lock-only episode must not reuse the previous sleep.
                XCTAssertTrue(activity.set(.screenLock, inactive: true, at: start.addingTimeInterval(7200)))
                XCTAssertEqual(activity.longestSleepDuration, 0)
                XCTAssertTrue(activity.set(.screenLock, inactive: false, at: start.addingTimeInterval(10800)))
                XCTAssertEqual(activity.longestSleepDuration, 0)
            }
        }
    }

    private func permutations(_ reasons: [InactiveReason]) -> [[InactiveReason]] {
        guard !reasons.isEmpty else { return [[]] }
        return reasons.flatMap { first in
            permutations(reasons.filter { $0 != first }).map { [first] + $0 }
        }
    }

    func testOverlappingSignalsResumeOnlyWhenTheLastReasonEnds() {
        let reasons: [InactiveReason] = [.sleep, .session, .screenLock, .screenSaver]
        for first in reasons {
            for second in reasons where first != second {
                var activity = SessionActivity()
                XCTAssertTrue(activity.set(first, inactive: true))
                XCTAssertFalse(activity.set(second, inactive: true))
                XCTAssertFalse(activity.set(first, inactive: false))
                XCTAssertTrue(activity.isInactive)
                XCTAssertTrue(activity.set(second, inactive: false))
                XCTAssertFalse(activity.isInactive)
            }
        }
    }

    func testDuplicateAndUnmatchedSignalsDoNotRestartTheStateMachine() {
        var activity = SessionActivity()
        XCTAssertFalse(activity.set(.sleep, inactive: false))
        XCTAssertTrue(activity.set(.screenLock, inactive: true))
        XCTAssertFalse(activity.set(.screenLock, inactive: true))
        XCTAssertFalse(activity.set(.sleep, inactive: false))
        XCTAssertTrue(activity.isInactive)
        XCTAssertTrue(activity.set(.screenLock, inactive: false))
        XCTAssertFalse(activity.set(.screenLock, inactive: false))
    }
}
