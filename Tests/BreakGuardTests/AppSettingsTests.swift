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

    func testTaperingPenaltyIsOneSecondPerFocusMinute() {
        XCTAssertEqual(FocusPace.taperingPenalty(forFocus: 0), 0)
        XCTAssertEqual(FocusPace.taperingPenalty(forFocus: 30 * 60), 30, accuracy: 0.001)
        XCTAssertEqual(FocusPace.taperingPenalty(forFocus: 8 * 3600), 480, accuracy: 0.001)
        // Linear, so twice the focus is exactly twice the penalty.
        XCTAssertEqual(
            FocusPace.taperingPenalty(forFocus: 2 * 3600),
            2 * FocusPace.taperingPenalty(forFocus: 3600),
            accuracy: 0.001
        )
        // Garbage in is not a negative penalty (which would lengthen a window).
        XCTAssertEqual(FocusPace.taperingPenalty(forFocus: -600), 0)
        XCTAssertEqual(FocusPace.taperingPenalty(forFocus: .nan), 0)
    }

    func testFocusAwareIntervalAppliesOnlyToTapering() {
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60

        settings.focusPace = .normal
        XCTAssertEqual(settings.effectiveWorkInterval(taperedFocus: 8 * 3600), 30 * 60)
        settings.focusPace = .deepFocus
        XCTAssertEqual(settings.effectiveWorkInterval(taperedFocus: 8 * 3600), 36 * 60)

        settings.focusPace = .tapering
        XCTAssertEqual(settings.effectiveWorkInterval(taperedFocus: 0), 30 * 60)
        // One 30-minute window banked costs the next one 30 seconds.
        XCTAssertEqual(
            settings.effectiveWorkInterval(taperedFocus: 30 * 60),
            30 * 60 - 30,
            accuracy: 0.001
        )
        // An 8-hour day lands a 30-minute window at about 22 minutes.
        XCTAssertEqual(
            settings.effectiveWorkInterval(taperedFocus: 8 * 3600),
            22 * 60,
            accuracy: 0.001
        )
    }

    func testTaperingNeverFallsBelowTheSafetyBottom() {
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.focusPace = .tapering

        // 100 hours of focus would drive the raw formula far below zero.
        XCTAssertEqual(
            settings.effectiveWorkInterval(taperedFocus: 100 * 3600),
            FocusPace.taperingMinimumInterval
        )

        // An interval already shorter than the bottom is never lengthened by it.
        settings.workInterval = 5 * 60
        XCTAssertEqual(settings.effectiveWorkInterval(taperedFocus: 0), 5 * 60)
        XCTAssertEqual(settings.effectiveWorkInterval(taperedFocus: 100 * 3600), 5 * 60)
    }

    func testWarningLeadNeverSwallowsTheWholeWindow() {
        var settings = AppSettings.defaults
        settings.workInterval = 15 * 60
        settings.warningLeadTime = 60
        // Comfortably inside the window: used as configured.
        XCTAssertEqual(settings.effectiveWarningLeadTime(for: 15 * 60), 60)

        // A lead longer than the window would start every cycle already
        // warning; it is capped at the back half instead.
        settings.warningLeadTime = 10 * 60
        XCTAssertEqual(settings.effectiveWarningLeadTime(for: FocusPace.taperingMinimumInterval), 3.5 * 60)
        XCTAssertEqual(settings.effectiveWarningLeadTime(for: 30 * 60), 10 * 60)

        settings.warningLeadTime = 0
        XCTAssertEqual(settings.effectiveWarningLeadTime(for: 15 * 60), 0)
    }

    func testClampBoundsTaperingResetGap() {
        var settings = AppSettings.defaults
        settings.taperingResetGap = 30 * 60
        settings.clamp()
        XCTAssertEqual(settings.taperingResetGap, 3600)

        settings.taperingResetGap = 100 * 3600
        settings.clamp()
        XCTAssertEqual(settings.taperingResetGap, 24 * 3600)
    }
}
