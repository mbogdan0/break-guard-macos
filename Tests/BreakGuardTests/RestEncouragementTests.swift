import XCTest
@testable import BreakGuard

final class RestEncouragementTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let sunday = Date(timeIntervalSince1970: 1_792_281_600) // October 18, 2026, UTC.

    private func status(extra: TimeInterval, required: TimeInterval = 120, day: Int = 0) -> RestEncouragement {
        RestEncouragement(elapsed: required + extra, requiredDuration: required, canFinish: true,
                          breakStartedAt: sunday.addingTimeInterval(Double(day) * 86400), calendar: calendar)
    }

    func testSevenDistinctScalesHave21UniqueEmojiAndAlignedMessages() {
        XCTAssertEqual(RestRewardCatalog.scales.count, 7)
        XCTAssertEqual(RestEncouragement.rewardOffsets.count, 21)
        XCTAssertEqual(Set(RestRewardCatalog.scales.map(\.name)).count, 7)
        for scale in RestRewardCatalog.scales {
            XCTAssertEqual(scale.messages.count, 21)
            XCTAssertEqual(Set(scale.messages.map(\.emoji)).count, 21, scale.name)
            XCTAssertEqual(Set(scale.messages.map(\.title)).count, 21, scale.name)
            XCTAssertEqual(Set(scale.messages.map(\.text)).count, 21, scale.name)
        }
    }

    func testEveryWeekdayFollowsItsAuthoredScaleAtEveryBoundary() {
        for day in 0..<7 {
            for required: TimeInterval in [30, 120, 1800] {
                for (index, offset) in RestEncouragement.rewardOffsets.enumerated() {
                    let current = status(extra: offset, required: required, day: day)
                    XCTAssertEqual(current.scaleIndex, day)
                    XCTAssertEqual(current.messageIndex, index)
                    XCTAssertEqual(current.message, RestRewardCatalog.scales[day].messages[index])
                    XCTAssertEqual(current.title, current.message.title)
                    XCTAssertEqual(current.message, status(extra: offset + 1, required: required, day: day).message)
                    if index > 0 {
                        XCTAssertEqual(status(extra: offset - 0.01, required: required, day: day).messageIndex, index - 1)
                    }
                }
            }
        }
    }

    func testStepsBecomeLessFrequentAfterFiveExtraMinutes() {
        let offsets = RestEncouragement.rewardOffsets
        XCTAssertEqual(offsets[9], 300)
        let gaps = zip(offsets.dropFirst(), offsets).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { $0 > 0 })
        XCTAssertLessThanOrEqual(offsets[1], 10)
        XCTAssertTrue(gaps.dropFirst(9).allSatisfy { $0 >= 120 })
        XCTAssertTrue(zip(gaps.dropFirst(10), gaps.dropFirst(9)).allSatisfy { $0 >= $1 })
        XCTAssertEqual(status(extra: 300, required: 600).messageIndex, 9)
    }

    func testEachStageCompletesBeforeTheNextStageStarts() {
        let starts = RestEncouragement.stageStarts
        XCTAssertEqual(starts, [0, 5, 10, 15])
        for (stage, first) in starts.enumerated() {
            let last = stage + 1 < starts.count ? starts[stage + 1] - 1 : 20
            let startTime = RestEncouragement.rewardOffsets[first]
            let endTime = RestEncouragement.rewardOffsets[last]
            XCTAssertEqual(status(extra: startTime).stageIndex, stage)
            XCTAssertEqual(status(extra: startTime).progress, 0)
            XCTAssertEqual(status(extra: (startTime + endTime) / 2).progress, 0.5, accuracy: 0.0001)
            XCTAssertEqual(status(extra: endTime).progress, 1)
            if stage + 1 < starts.count {
                let next = RestEncouragement.rewardOffsets[starts[stage + 1]]
                XCTAssertEqual(status(extra: next - 0.01).stageIndex, stage)
                XCTAssertEqual(status(extra: next - 0.01).progress, 1)
                XCTAssertEqual(status(extra: next).stageIndex, stage + 1)
                XCTAssertEqual(status(extra: next).progress, 0)
            }
        }
    }

    func testReflectionsStayStableWithinAStepAndVaryAcrossWeeks() {
        for day in 0..<7 {
            let reflections = RestEncouragement.rewardOffsets.map { offset -> String in
                let current = status(extra: offset, day: day)
                XCTAssertEqual(current.reflection, status(extra: offset + 1, day: day).reflection)
                XCTAssertEqual(current.message, status(extra: offset, day: day + 7).message)
                XCTAssertNotEqual(current.reflection, status(extra: offset, day: day + 7).reflection)
                return current.reflection!
            }
            XCTAssertEqual(Set(reflections).count, 21)
        }
    }

    func testCrossingMidnightDoesNotSwitchTheBreaksScale() {
        let start = sunday.addingTimeInterval(86400 - 60)
        let before = RestEncouragement(elapsed: 30, requiredDuration: 20, canFinish: true,
                                       breakStartedAt: start, calendar: calendar)
        let after = RestEncouragement(elapsed: 600, requiredDuration: 20, canFinish: true,
                                      breakStartedAt: start, calendar: calendar)
        XCTAssertEqual(before.scaleIndex, after.scaleIndex)
        XCTAssertGreaterThan(after.messageIndex, before.messageIndex)
    }

    func testLongRestStaysAtTheFinalStage() {
        for day in 0..<7 {
            for extra: TimeInterval in [3900, 4000, 86400] {
                let current = status(extra: extra, day: day)
                XCTAssertEqual(current.message, RestRewardCatalog.scales[day].messages.last)
                XCTAssertEqual(current.stageIndex, 3)
                XCTAssertEqual(current.progress, 1)
                XCTAssertEqual(current.secondsToNextReward, 0)
            }
        }
    }

    func testRequiredRestAndInvalidElapsedTimeStayQuiet() {
        for elapsed: TimeInterval in [-1, .nan, .infinity, -.infinity, 0, 119, 120, 180] {
            let current = RestEncouragement(elapsed: elapsed, requiredDuration: 120, canFinish: false)
            XCTAssertEqual(current.title, "Required rest")
            XCTAssertEqual(current.message.emoji, "😌")
            XCTAssertNil(current.reflection)
            XCTAssertEqual(current.progress, 0)
            XCTAssertEqual(current.secondsToNextReward, 0)
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
