import XCTest
@testable import BreakGuard

final class NotificationManagerTests: XCTestCase {
    func testWarningTitleReflectsLeadTime() {
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 60), "Break in 1 minute")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 5 * 60), "Break in 5 minutes")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 30 * 60), "Break in 30 minutes")
    }

    func testWarningTitleHandlesSubMinuteEdges() {
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 30), "Break in 30 seconds")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 0), "Break starting now")
    }
}
