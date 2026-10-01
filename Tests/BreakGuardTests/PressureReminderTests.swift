import XCTest
@testable import BreakGuard

final class PressureReminderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_700_000)

    func testDismissedCardReturnsExactlyOneMinuteLater() {
        var reminder = PressureReminderState()
        reminder.update(reason: .outsideWorkingHours)
        XCTAssertTrue(reminder.shouldShowCard(at: now))
        reminder.dismiss(at: now)
        XCTAssertFalse(reminder.shouldShowCard(at: now.addingTimeInterval(59.999)))
        XCTAssertTrue(reminder.shouldShowCard(at: now.addingTimeInterval(60)))
        XCTAssertEqual(BreakPressure.dismissHoldDuration, 2)
    }

    func testUnchangedPressureDoesNotResetDismissalOnEachTick() {
        var reminder = PressureReminderState()
        reminder.update(reason: .scheduledBreak)
        reminder.dismiss(at: now)
        for second in 1..<60 {
            reminder.update(reason: .scheduledBreak)
            XCTAssertFalse(reminder.shouldShowCard(at: now.addingTimeInterval(Double(second))))
        }
    }

    func testEndingAnEpisodeOrChangingItsReasonShowsTheNextReminderImmediately() {
        var reminder = PressureReminderState()
        reminder.update(reason: .scheduledBreak)
        reminder.dismiss(at: now)
        reminder.update(reason: .outsideWorkingHours)
        XCTAssertTrue(reminder.shouldShowCard(at: now.addingTimeInterval(10)))
        reminder.dismiss(at: now)
        reminder.update(reason: nil)
        XCTAssertFalse(reminder.shouldShowCard(at: now.addingTimeInterval(100)))
        reminder.update(reason: .outsideWorkingHours)
        XCTAssertTrue(reminder.shouldShowCard(at: now.addingTimeInterval(20)))
    }
}
