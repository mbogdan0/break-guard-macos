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
        XCTAssertEqual(offsets[9], 330)
        let gaps = zip(offsets.dropFirst(), offsets).map { $0 - $1 }
        XCTAssertTrue(gaps.allSatisfy { $0 > 0 })
        XCTAssertLessThanOrEqual(offsets[1], 10)
        XCTAssertTrue(gaps.dropFirst(9).allSatisfy { $0 >= 55 })
        XCTAssertTrue(zip(gaps.dropFirst(10), gaps.dropFirst(9)).allSatisfy { $0 >= $1 })
        XCTAssertEqual(status(extra: 330, required: 600).messageIndex, 9)
    }

    func testEarlyStepsSlowDownAndFinalStatusArrivesAt21ExtraMinutes() {
        let previous: [Double] = [0, 7, 23, 45, 72, 110, 155, 210, 255, 300]
        for (actual, old) in zip(RestEncouragement.rewardOffsets, previous) {
            XCTAssertEqual(actual, (old * 1.1).rounded(), accuracy: 0.01)
        }
        for required: TimeInterval in [30, 120, 1800] {
            XCTAssertEqual(status(extra: 1259, required: required).messageIndex, 19)
            XCTAssertEqual(status(extra: 1260, required: required).messageIndex, 20)
            XCTAssertEqual(status(extra: 1260, required: required).progress, 1)
        }
    }

    func testSingleQuoteKeepsBothStoriesAndReflectionsStable() {
        for day in 0..<7 {
            for (index, offset) in RestEncouragement.rewardOffsets.enumerated() {
                let current = status(extra: offset, day: day)
                XCTAssertEqual(current.quote, index % 2 == 1 ? current.reflection! : current.message.text)
                XCTAssertEqual(current.quote, status(extra: offset + 1, day: day).quote)
            }
        }
        let initial = RestEncouragement(elapsed: 0, requiredDuration: 120, canFinish: false)
        XCTAssertEqual(initial.quote, initial.message.text)
    }

    func testProgressUsesTheSameBoundaryAsTheStageTransition() {
        let starts = RestEncouragement.stageStarts
        XCTAssertEqual(starts, [0, 5, 10, 15])
        for (stage, first) in starts.enumerated() {
            let end = stage + 1 < starts.count ? starts[stage + 1] : 20
            let startTime = RestEncouragement.rewardOffsets[first]
            let endTime = RestEncouragement.rewardOffsets[end]
            XCTAssertEqual(status(extra: startTime).stageIndex, stage)
            XCTAssertEqual(status(extra: startTime).progress, 0)
            XCTAssertEqual(status(extra: (startTime + endTime) / 2).progress, 0.5, accuracy: 0.0001)
            // Check the entire stage, including the gap after its last emoji.
            for second in Int(startTime)..<Int(endTime) {
                let current = status(extra: Double(second))
                XCTAssertEqual(current.stageIndex, stage)
                XCTAssertLessThan(current.progress, 1)
                XCTAssertEqual(current.progress, (Double(second) - startTime) / (endTime - startTime), accuracy: 0.0001)
            }
            XCTAssertLessThan(status(extra: endTime - 0.01).progress, 1)
            if stage + 1 < starts.count {
                XCTAssertEqual(status(extra: endTime).stageIndex, stage + 1)
                XCTAssertEqual(status(extra: endTime).progress, 0)
            } else {
                XCTAssertEqual(status(extra: endTime).progress, 1)
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
            for extra: TimeInterval in [1260, 1261, 86400] {
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
