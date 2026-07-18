import XCTest
@testable import BreakGuard

final class FormattingTests: XCTestCase {
    func testDurationFieldFormatsMinutesAndSeconds() {
        let style = DurationFieldStyle()
        XCTAssertEqual(style.format(0), "0:00")
        XCTAssertEqual(style.format(45), "0:45")
        XCTAssertEqual(style.format(150), "2:30")
        XCTAssertEqual(style.format(1800), "30:00")
        XCTAssertEqual(style.format(240 * 60), "240:00")
    }

    func testDurationFieldFormatsNegativeAsZero() {
        XCTAssertEqual(DurationFieldStyle().format(-30), "0:00")
    }

    func testParseAcceptsMinuteSecondPairs() {
        XCTAssertEqual(parseDurationField("2:30"), 150)
        XCTAssertEqual(parseDurationField("0:45"), 45)
        XCTAssertEqual(parseDurationField("2:05"), 125)
        XCTAssertEqual(parseDurationField("2:5"), 125)
        XCTAssertEqual(parseDurationField("0:00"), 0)
        XCTAssertEqual(parseDurationField("240:00"), 240 * 60)
    }

    // The field replaces a minutes-only one, so a bare number keeps meaning
    // minutes rather than silently becoming a sub-minute value.
    func testParseTreatsBareNumberAsMinutes() {
        XCTAssertEqual(parseDurationField("30"), 1800)
        XCTAssertEqual(parseDurationField("0"), 0)
    }

    func testParseIgnoresSurroundingWhitespace() {
        XCTAssertEqual(parseDurationField("  2:30 "), 150)
    }

    func testParseRejectsMalformedInput() {
        XCTAssertNil(parseDurationField(""))
        XCTAssertNil(parseDurationField("   "))
        XCTAssertNil(parseDurationField("abc"))
        XCTAssertNil(parseDurationField("1:60"))
        XCTAssertNil(parseDurationField("1:005"))
        XCTAssertNil(parseDurationField("1:-5"))
        XCTAssertNil(parseDurationField("-1"))
        XCTAssertNil(parseDurationField("1:2:3"))
        XCTAssertNil(parseDurationField("1:"))
        XCTAssertNil(parseDurationField(":30"))
    }

    func testParseStrategyThrowsOnMalformedInput() throws {
        let strategy = DurationFieldStrategy()
        XCTAssertEqual(try strategy.parse("2:30"), 150)
        XCTAssertThrowsError(try strategy.parse("nope"))
    }

    func testDurationPhraseCoversEveryUnit() {
        XCTAssertEqual(formatDurationPhrase(0), "0 seconds")
        XCTAssertEqual(formatDurationPhrase(1), "1 second")
        XCTAssertEqual(formatDurationPhrase(45), "45 seconds")
        XCTAssertEqual(formatDurationPhrase(60), "1 minute")
        XCTAssertEqual(formatDurationPhrase(150), "2 minutes 30 seconds")
        XCTAssertEqual(formatDurationPhrase(1800), "30 minutes")
        XCTAssertEqual(formatDurationPhrase(3600), "1 hour")
        XCTAssertEqual(formatDurationPhrase(288 * 60), "4 hours 48 minutes")
        XCTAssertEqual(formatDurationPhrase(3661), "1 hour 1 minute 1 second")
    }

    func testDurationPhraseClampsNegativeToZero() {
        XCTAssertEqual(formatDurationPhrase(-10), "0 seconds")
    }

    func testDurationCompactCoversEveryUnit() {
        XCTAssertEqual(formatDurationCompact(0), "0s")
        XCTAssertEqual(formatDurationCompact(45), "45s")
        XCTAssertEqual(formatDurationCompact(60), "1m")
        XCTAssertEqual(formatDurationCompact(140), "2m 20s")
        XCTAssertEqual(formatDurationCompact(15 * 60), "15m")
        XCTAssertEqual(formatDurationCompact(90 * 60), "1h 30m")
        XCTAssertEqual(formatDurationCompact(3661), "1h 1m 1s")
        XCTAssertEqual(formatDurationCompact(-10), "0s")
    }
}
