import XCTest
@testable import BreakGuard

final class SessionActivityTests: XCTestCase {
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
