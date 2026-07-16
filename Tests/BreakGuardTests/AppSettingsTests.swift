import XCTest
@testable import BreakGuard

final class AppSettingsTests: XCTestCase {
    // The whole point of second-granular entry: a value that is not a whole
    // number of minutes must survive a settings round-trip untouched.
    func testClampKeepsSecondGranularValues() {
        var settings = AppSettings()
        settings.workInterval = 150
        settings.breakDuration = 90
        settings.warningLeadTime = 45
        settings.firstPostponeDuration = 30
        settings.secondPostponeDuration = 195
        settings.clamp()

        XCTAssertEqual(settings.workInterval, 150)
        XCTAssertEqual(settings.breakDuration, 90)
        XCTAssertEqual(settings.warningLeadTime, 45)
        XCTAssertEqual(settings.firstPostponeDuration, 30)
        XCTAssertEqual(settings.secondPostponeDuration, 195)
    }

    func testClampRaisesValuesBelowTheFloor() {
        var settings = AppSettings()
        settings.workInterval = 5
        settings.breakDuration = 0
        settings.warningLeadTime = -5
        settings.firstPostponeDuration = 1
        settings.secondPostponeDuration = -60
        settings.clamp()

        XCTAssertEqual(settings.workInterval, 30)
        XCTAssertEqual(settings.breakDuration, 30)
        XCTAssertEqual(settings.warningLeadTime, 0)
        XCTAssertEqual(settings.firstPostponeDuration, 30)
        XCTAssertEqual(settings.secondPostponeDuration, 30)
    }

    func testClampLowersValuesAboveTheCeiling() {
        var settings = AppSettings()
        settings.workInterval = 999 * 60
        settings.breakDuration = 999 * 60
        settings.warningLeadTime = 999 * 60
        settings.firstPostponeDuration = 999 * 60
        settings.secondPostponeDuration = 999 * 60
        settings.clamp()

        XCTAssertEqual(settings.workInterval, 240 * 60)
        XCTAssertEqual(settings.breakDuration, 60 * 60)
        XCTAssertEqual(settings.warningLeadTime, 30 * 60)
        XCTAssertEqual(settings.firstPostponeDuration, 120 * 60)
        XCTAssertEqual(settings.secondPostponeDuration, 120 * 60)
    }

    func testClampKeepsWarningInsideTheWorkInterval() {
        var settings = AppSettings()
        settings.workInterval = 45
        settings.warningLeadTime = 30 * 60
        settings.clamp()

        XCTAssertEqual(settings.workInterval, 45)
        XCTAssertEqual(settings.warningLeadTime, 45)
    }

    func testClampRoundsToWholeSeconds() {
        var settings = AppSettings()
        settings.workInterval = 90.4
        settings.breakDuration = 90.6
        settings.clamp()

        XCTAssertEqual(settings.workInterval, 90)
        XCTAssertEqual(settings.breakDuration, 91)
    }

    // A hand-edited or corrupt state.json must not crash the launch: both the
    // Int conversion and the bounds comparison are hostile to these values.
    func testClampHandlesNonFiniteAndOversizedValues() {
        var settings = AppSettings()
        settings.workInterval = .nan
        settings.breakDuration = .infinity
        settings.warningLeadTime = -.infinity
        settings.firstPostponeDuration = 1e300
        settings.clamp()

        XCTAssertEqual(settings.workInterval, 30)
        XCTAssertEqual(settings.breakDuration, 60 * 60)
        XCTAssertEqual(settings.warningLeadTime, 0)
        XCTAssertEqual(settings.firstPostponeDuration, 120 * 60)
    }

    func testDefaultsSurviveClampUnchanged() {
        var settings = AppSettings.defaults
        settings.clamp()
        XCTAssertEqual(settings, AppSettings.defaults)
    }
}
