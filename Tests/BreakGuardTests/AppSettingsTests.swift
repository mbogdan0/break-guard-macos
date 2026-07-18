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

    func testTaperingMultiplierCurveShape() {
        // First session at full length; ~27% down after 16 sessions (a 30-min
        // interval lands near 22 minutes); ~32% down after 20; floored at 65%.
        XCTAssertEqual(FocusPace.taperingMultiplier(sessionsCompleted: 0), 1.0)
        XCTAssertEqual(FocusPace.taperingMultiplier(sessionsCompleted: 16), 0.727, accuracy: 0.01)
        XCTAssertEqual(FocusPace.taperingMultiplier(sessionsCompleted: 20), 0.683, accuracy: 0.01)

        var previous = FocusPace.taperingMultiplier(sessionsCompleted: 0)
        for n in 1...60 {
            let current = FocusPace.taperingMultiplier(sessionsCompleted: n)
            XCTAssertLessThanOrEqual(current, previous, "not monotonic at n=\(n)")
            XCTAssertGreaterThanOrEqual(current, FocusPace.taperingFloor)
            previous = current
        }

        // The early decline is gentle: the second session loses only seconds.
        let secondSessionLoss = 30 * 60 * (1 - FocusPace.taperingMultiplier(sessionsCompleted: 1))
        XCTAssertLessThan(secondSessionLoss, 15)
    }

    func testSessionAwareIntervalAppliesOnlyToTapering() {
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60

        settings.focusPace = .normal
        XCTAssertEqual(settings.effectiveWorkInterval(sessionsCompleted: 16), 30 * 60)
        settings.focusPace = .deepFocus
        XCTAssertEqual(settings.effectiveWorkInterval(sessionsCompleted: 16), 36 * 60)

        settings.focusPace = .tapering
        XCTAssertEqual(settings.effectiveWorkInterval(sessionsCompleted: 0), 30 * 60)
        XCTAssertEqual(
            settings.effectiveWorkInterval(sessionsCompleted: 16),
            30 * 60 * FocusPace.taperingMultiplier(sessionsCompleted: 16),
            accuracy: 0.001
        )
    }

    func testConfigurableTaperingFloorRaisesTheLevelingPoint() {
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.focusPace = .tapering
        settings.taperingFloorPercent = 90

        // Deep into the day the interval approaches the configured floor and
        // never drops below it.
        let late = settings.effectiveWorkInterval(sessionsCompleted: 60)
        XCTAssertGreaterThanOrEqual(late, 30 * 60 * 0.9)
        XCTAssertLessThan(late, 30 * 60 * 0.91)
    }

    func testClampBoundsTaperingSettings() {
        var settings = AppSettings.defaults
        settings.taperingFloorPercent = 5
        settings.taperingResetGap = 30 * 60
        settings.clamp()
        XCTAssertEqual(settings.taperingFloorPercent, SettingsRange.taperingFloorPercent.lowerBound)
        XCTAssertEqual(settings.taperingResetGap, 3600)

        settings.taperingFloorPercent = 200
        settings.taperingResetGap = 100 * 3600
        settings.clamp()
        XCTAssertEqual(settings.taperingFloorPercent, SettingsRange.taperingFloorPercent.upperBound)
        XCTAssertEqual(settings.taperingResetGap, 24 * 3600)
    }
}
