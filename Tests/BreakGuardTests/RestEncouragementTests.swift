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
                let current = status(extra: offset, required: required)
                XCTAssertEqual(current.messageIndex, index)
                XCTAssertEqual(current.title, current.message.title)
                if index > 0 {
                    let previous = status(extra: offset - 0.01, required: required)
                    XCTAssertEqual(previous.messageIndex, index - 1)
                    XCTAssertEqual(previous.title, previous.message.title)
                    XCTAssertNotEqual(current.title, previous.title)
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
        XCTAssertEqual(Set(RestEncouragement.messages.map(\.title)).count, offsets.count)
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
        XCTAssertEqual(status(extra: last + 119).messageIndex, RestEncouragement.messages.count - 1)
        XCTAssertEqual(status(extra: last + 120).messageIndex, RestEncouragement.messages.count - 8)
        XCTAssertEqual(status(extra: last + 240).messageIndex, RestEncouragement.messages.count - 7)
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

    func testEachBreakHasAStableVariedSequenceWithoutRepeats() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_790_700_000)
        var sequences: Set<[String]> = []
        for day in 0..<7 {
            for pause in 0..<2 {
                let date = start.addingTimeInterval(Double(day * 86400 + pause * 3600))
                let sequence = RestEncouragement.rewardOffsets.map { offset in
                    let current = RestEncouragement(elapsed: 120 + offset, requiredDuration: 120,
                                                    canFinish: true, breakStartedAt: date, calendar: calendar)
                    let nextTick = RestEncouragement(elapsed: 121 + offset, requiredDuration: 120,
                                                     canFinish: true, breakStartedAt: date, calendar: calendar)
                    XCTAssertEqual(current.title, nextTick.title)
                    XCTAssertEqual(current.message.emoji, nextTick.message.emoji)
                    XCTAssertEqual(current.message.text, nextTick.message.text)
                    XCTAssertEqual(current.title, current.message.title)
                    return current.title
                }
                XCTAssertEqual(Set(sequence).count, RestEncouragement.messages.count)
                sequences.insert(sequence)
            }
        }
        XCTAssertEqual(sequences.count, 14)
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
