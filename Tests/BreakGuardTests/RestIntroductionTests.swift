import XCTest
@testable import BreakGuard

final class RestIntroductionTests: XCTestCase {
    func testThirteenDistinctIntroductions() {
        XCTAssertEqual(RestIntroduction.messages.count, 13)
        XCTAssertEqual(Set(RestIntroduction.messages.map(\.text)).count, 13)
        XCTAssertEqual(Set(RestIntroduction.messages.map(\.title)).count, 13)
        XCTAssertEqual(Set(RestIntroduction.messages.map(\.emoji)).count, 13)
    }

    func testEachRoundUsesEveryIntroductionWithoutAdjacentRepeats() {
        var selection = RestIntroduction()
        var previous: RestEncouragement.Message?
        for round in 0..<10 {
            var texts: Set<String> = []
            for index in 0..<13 {
                let start = Date(timeIntervalSince1970: Double(round * 13 + index))
                let message = selection.message(for: start)
                XCTAssertNotEqual(message, previous)
                XCTAssertEqual(selection.message(for: start), message)
                XCTAssertEqual(selection.message(for: nil), message)
                texts.insert(message.text)
                previous = message
            }
            XCTAssertEqual(texts.count, 13)
        }
    }

    func testIntroductionStaysUntilRequiredRestEnds() {
        let introduction = RestIntroduction.messages[6]
        for elapsed: TimeInterval in [0, 30, 119, 120, 180] {
            let status = RestEncouragement(elapsed: elapsed, requiredDuration: 120,
                                           canFinish: false, introduction: introduction)
            XCTAssertEqual(status.message, introduction)
            XCTAssertNil(status.reflection)
            XCTAssertEqual(status.progress, 0)
        }
        let completed = RestEncouragement(elapsed: 120, requiredDuration: 120,
                                          canFinish: true, introduction: introduction)
        XCTAssertEqual(completed.message, completed.scale.messages[0])
    }
}
