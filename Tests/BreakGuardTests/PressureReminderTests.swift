import XCTest
@testable import BreakGuard

final class PressureReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_700_000)

    func testDismissedCardReturnsExactlyNinetySecondsLater() {
        var reminder = PressureReminderState()
        reminder.update(reason: .outsideWorkingHours)
        XCTAssertTrue(reminder.shouldShowCard(at: now))
        reminder.dismiss(at: now)
        XCTAssertFalse(reminder.shouldShowCard(at: now.addingTimeInterval(60)))
        XCTAssertFalse(reminder.shouldShowCard(at: now.addingTimeInterval(89.999)))
        XCTAssertTrue(reminder.shouldShowCard(at: now.addingTimeInterval(90)))
        XCTAssertEqual(BreakPressure.dismissHoldDuration, 3)
    }

    func testUnchangedPressureDoesNotResetDismissalOnEachTick() {
        var reminder = PressureReminderState()
        reminder.update(reason: .outsideWorkingHours)
        reminder.dismiss(at: now)
        for second in 1..<90 {
            reminder.update(reason: .outsideWorkingHours)
            XCTAssertFalse(reminder.shouldShowCard(at: now.addingTimeInterval(Double(second))))
        }
    }

    func testEndingAnEpisodeShowsTheNextReminderImmediately() {
        var reminder = PressureReminderState()
        reminder.update(reason: .outsideWorkingHours)
        reminder.dismiss(at: now)
        reminder.update(reason: nil)
        XCTAssertFalse(reminder.shouldShowCard(at: now.addingTimeInterval(100)))
        reminder.update(reason: .outsideWorkingHours)
        XCTAssertTrue(reminder.shouldShowCard(at: now.addingTimeInterval(20)))
    }
}
