import XCTest
@testable import BreakGuard

final class RestEncouragementTests: XCTestCase {
    private func status(extra: TimeInterval, required: TimeInterval = 120) -> RestEncouragement {
        RestEncouragement(elapsed: required + extra, requiredDuration: required, canFinish: true)
    }

    func testRequiredRestStaysQuietUntilCompletionIsAllowed() {
        let initial = RestEncouragement(elapsed: 0, requiredDuration: 120, canFinish: false)
        for elapsed: TimeInterval in [30, 119, 120, 180] {
            let current = RestEncouragement(elapsed: elapsed, requiredDuration: 120, canFinish: false)
            XCTAssertEqual(current.message.text, initial.message.text)
            XCTAssertEqual(current.message.emoji, initial.message.emoji)
            XCTAssertEqual(current.title, "Required rest")
            XCTAssertEqual(current.progress, 0)
        }
        XCTAssertNotEqual(status(extra: 0).message.text, initial.message.text)
    }

    func testEveryRewardHasItsOwnBoundaryRelativeToRequiredDuration() {
        for required: TimeInterval in [30, 120, 300, 1800] {
            for (index, offset) in RestEncouragement.rewardOffsets.enumerated() {
                XCTAssertEqual(status(extra: offset, required: required).messageIndex, index)
                if index > 0 {
                    XCTAssertEqual(status(extra: offset - 0.01, required: required).messageIndex, index - 1)
                }
            }
        }
    }

    func testRewardsAreUnevenAndSlowDown() {
        let offsets = RestEncouragement.rewardOffsets
        let gaps = zip(offsets.dropFirst(), offsets).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { $0 > 0 })
        XCTAssertGreaterThan(Set(gaps.prefix(10)).count, 3)
        XCTAssertLessThan(gaps.prefix(10).reduce(0, +), gaps.suffix(10).reduce(0, +))
        XCTAssertLessThanOrEqual(offsets[1], 10)
        XCTAssertEqual(offsets.count, RestEncouragement.messages.count)
        XCTAssertEqual(Set(RestEncouragement.messages.map(\.text)).count, offsets.count)
        XCTAssertEqual(Set(RestEncouragement.messages.map(\.emoji)).count, offsets.count)
    }

    func testProgressGrowsSmoothlyWithDecreasingGains() {
        XCTAssertEqual(status(extra: 0).progress, 0)
        XCTAssertGreaterThan(status(extra: 30).progress, status(extra: 15).progress)
        let earlyGain = status(extra: 30).progress - status(extra: 15).progress
        let laterGain = status(extra: 315).progress - status(extra: 300).progress
        XCTAssertGreaterThan(earlyGain, laterGain)
        for offset in RestEncouragement.rewardOffsets.dropFirst() {
            XCTAssertGreaterThanOrEqual(status(extra: offset).progress, status(extra: offset - 0.01).progress)
        }
        XCTAssertEqual(status(extra: 1080).progress, 1)
        XCTAssertEqual(status(extra: 600, required: 600).progress, 1)
        XCTAssertEqual(status(extra: 0, required: 1800).progress, 0)
        XCTAssertEqual(status(extra: 60, required: 1800).progress, 1)
    }

    func testLongRestContinuesWithCalmMessagesAndPositiveCountdown() {
        let last = RestEncouragement.rewardOffsets.last!
        XCTAssertEqual(status(extra: last + 119).messageIndex, 47)
        XCTAssertEqual(status(extra: last + 120).messageIndex, 40)
        XCTAssertEqual(status(extra: last + 240).messageIndex, 41)
        XCTAssertEqual(status(extra: last + 120).secondsToNextReward, 120)
        XCTAssertEqual(status(extra: last + 121).secondsToNextReward, 119)
    }

    func testInvalidElapsedTimeStartsAtZero() {
        for elapsed: TimeInterval in [-1, .nan, .infinity, -.infinity] {
            let current = RestEncouragement(elapsed: elapsed, requiredDuration: 120, canFinish: false)
            XCTAssertEqual(current.progress, 0)
            XCTAssertEqual(current.extraRest, 0)
        }
    }

    func testSettingIsOptInAndPersists() throws {
        XCTAssertFalse(AppSettings.defaults.encourageLongBreaks)
        XCTAssertFalse(try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)).encourageLongBreaks)
        var settings = AppSettings.defaults
        settings.encourageLongBreaks = true
        let decoded = try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(decoded, settings)
    }
}
