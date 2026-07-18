import Foundation
import XCTest
@testable import BreakGuard

private struct FakeClock: TimeProvider {
    var now: Date
}

final class StatisticsRetentionTests: XCTestCase {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    // Noon avoids day-boundary surprises when offsetting by whole days.
    private let now = Date(timeIntervalSince1970: 1_752_840_000)

    private func key(daysAgo: Int) -> String {
        let date = calendar.date(byAdding: .day, value: -daysAgo, to: now)!
        return FocusDay.key(for: date, calendar: calendar)
    }

    func testPruneKeepsExactlyTheRetentionWindow() {
        var statistics = Statistics()
        statistics.focusMinutesByDay = [
            key(daysAgo: 0): 10,
            key(daysAgo: 27): 20,
            key(daysAgo: 28): 30,
            key(daysAgo: 90): 40,
        ]

        statistics.pruneFocusHistory(now: now, calendar: calendar)

        XCTAssertEqual(statistics.focusMinutesByDay, [
            key(daysAgo: 0): 10,
            key(daysAgo: 27): 20,
        ])
    }

    func testPruneDoesNotTouchTheLifetimeTotal() {
        var statistics = Statistics()
        statistics.focusMinutesByDay = [key(daysAgo: 0): 10, key(daysAgo: 90): 40]
        statistics.totalFocusMinutes = 500

        statistics.pruneFocusHistory(now: now, calendar: calendar)

        XCTAssertEqual(statistics.totalFocusMinutes, 500)
    }

    // Files written before the retention window lack the totalFocusMinutes
    // key; the decoder must seed it from the complete daily history.
    func testDecodingLegacyFileSeedsTotalFromFullHistory() throws {
        var machine = StateMachine()
        machine.statistics.focusMinutesByDay = [
            key(daysAgo: 0): 10,
            key(daysAgo: 40): 60,
            key(daysAgo: 200): 30,
        ]

        let encoded = try JSONEncoder.breakGuard.encode(machine.data)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        var statistics = try XCTUnwrap(object["statistics"] as? [String: Any])
        statistics.removeValue(forKey: "totalFocusMinutes")
        object["statistics"] = statistics
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder.breakGuard.decode(PersistedAppData.self, from: legacyData)
        XCTAssertEqual(decoded.statistics.totalFocusMinutes, 100)
    }

    // Once the total is stored, re-encoding and re-decoding must not
    // re-derive it from the (possibly pruned) history.
    func testStoredTotalSurvivesRepeatedRoundTripsAfterPruning() throws {
        var statistics = Statistics()
        statistics.focusMinutesByDay = [key(daysAgo: 0): 10]
        statistics.totalFocusMinutes = 500
        var machine = StateMachine()
        machine.statistics = statistics

        var data = machine.data
        for _ in 0..<2 {
            let encoded = try JSONEncoder.breakGuard.encode(data)
            data = try JSONDecoder.breakGuard.decode(PersistedAppData.self, from: encoded)
        }

        XCTAssertEqual(data.statistics.totalFocusMinutes, 500)
        XCTAssertEqual(data.statistics.focusMinutesByDay, [key(daysAgo: 0): 10])
    }

    func testStateMachineInitPrunesStaleDaysAndKeepsTotal() {
        var machine = StateMachine(clock: FakeClock(now: now))
        machine.statistics.focusMinutesByDay = [
            FocusDay.key(for: now): 10,
            FocusDay.key(for: Calendar.current.date(byAdding: .day, value: -90, to: now)!): 40,
        ]
        machine.statistics.totalFocusMinutes = 50

        let restored = StateMachine(data: machine.data, clock: FakeClock(now: now))

        XCTAssertEqual(restored.statistics.focusMinutesByDay, [FocusDay.key(for: now): 10])
        XCTAssertEqual(restored.statistics.totalFocusMinutes, 50)
    }

    func testCompleteBreakCreditsDayAndTotalEqually() {
        let start = now
        var machine = StateMachine(clock: FakeClock(now: start))
        machine.clock = FakeClock(now: start.addingTimeInterval(30 * 60))
        machine.startBreak()
        machine.clock = FakeClock(now: start.addingTimeInterval(30 * 60 + machine.settings.breakDuration + 1))
        _ = machine.tick()

        machine.completeBreak()

        let day = FocusDay.key(for: machine.clock.now)
        XCTAssertEqual(machine.statistics.focusMinutesByDay[day], 30)
        XCTAssertEqual(machine.statistics.totalFocusMinutes, 30)
    }
}
