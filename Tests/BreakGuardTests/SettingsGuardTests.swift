import XCTest
@testable import BreakGuard

// The predicate behind the settings-visit gate. Every case is stated in both
// directions on purpose: charging for a tightening would teach the user to
// stay out of the settings pane, which is the opposite of the point.
final class SettingsGuardTests: XCTestCase {
    private let baseline = AppSettings.defaults

    private func changed(_ mutate: (inout AppSettings) -> Void) -> AppSettings {
        var settings = baseline
        mutate(&settings)
        return settings
    }

    private func assertWeakens(
        _ mutate: (inout AppSettings) -> Void,
        _ message: String,
        line: UInt = #line
    ) {
        XCTAssertTrue(changed(mutate).weakensGuard(comparedTo: baseline), message, line: line)
    }

    private func assertTightens(
        _ mutate: (inout AppSettings) -> Void,
        _ message: String,
        line: UInt = #line
    ) {
        XCTAssertFalse(changed(mutate).weakensGuard(comparedTo: baseline), message, line: line)
    }

    func testAnUnchangedVisitIsNotCharged() {
        XCTAssertFalse(baseline.weakensGuard(comparedTo: baseline))
    }

    func testTimingChangesAreJudgedInBothDirections() {
        assertWeakens({ $0.workInterval += 60 }, "a longer stretch before the break")
        assertTightens({ $0.workInterval -= 60 }, "a shorter stretch is a tightening")
        assertWeakens({ $0.breakDuration -= 30 }, "a shorter break")
        assertTightens({ $0.breakDuration += 30 }, "a longer break is a tightening")
    }

    func testPostponementsAreWeakerWhenLonger() {
        assertWeakens({ $0.firstPostponeDuration += 60 }, "a bigger first skip")
        assertWeakens({ $0.secondPostponeDuration += 60 }, "a bigger second skip")
        assertTightens({ $0.firstPostponeDuration -= 30 }, "a smaller skip is a tightening")
    }

    // The multiplier alone cannot see this: tapering and normal share 1.0, but
    // tapering shortens every window as the day accumulates.
    func testFocusPaceIsRankedByPressureNotByMultiplier() {
        XCTAssertEqual(FocusPace.tapering.workIntervalMultiplier, FocusPace.normal.workIntervalMultiplier)
        var tapering = baseline
        tapering.focusPace = .tapering
        var normal = baseline
        normal.focusPace = .normal
        XCTAssertTrue(normal.weakensGuard(comparedTo: tapering), "leaving tapering is a loosening")
        XCTAssertFalse(tapering.weakensGuard(comparedTo: normal))

        assertWeakens({ $0.focusPace = .deepFocus }, "deep focus is the loosest pace")
        assertTightens({ $0.focusPace = .moreBreaks }, "more breaks is the strictest")
    }

    func testTaperingResettingSoonerIsWeaker() {
        assertWeakens({ $0.taperingResetGap -= 3600 }, "tapering starting over sooner")
        assertTightens({ $0.taperingResetGap += 3600 }, "carrying tapering longer is a tightening")
    }

    func testCameraHoldAndLaunchAtLogin() {
        var withoutHold = baseline
        withoutHold.holdBreaksWhileOnCamera = false
        XCTAssertTrue(
            baseline.weakensGuard(comparedTo: withoutHold),
            "a call that can hold a break off indefinitely"
        )
        XCTAssertFalse(withoutHold.weakensGuard(comparedTo: baseline))

        assertWeakens({ $0.launchAtLogin = false }, "an app that does not come back")
    }

    func testWorkingHoursLooseWhenWidenedOrSwitchedOff() {
        var enabled = baseline
        enabled.workingHoursEnabled = true
        enabled.weekdayWorkingHours = WorkingHoursRange(
            enabled: true, startMinutes: 10 * 60, endMinutes: 18 * 60
        )

        var off = enabled
        off.workingHoursEnabled = false
        XCTAssertTrue(off.weakensGuard(comparedTo: enabled), "the whole feature switched off")

        var earlierStart = enabled
        earlierStart.weekdayWorkingHours.startMinutes = 8 * 60
        XCTAssertTrue(earlierStart.weakensGuard(comparedTo: enabled), "more hours count as working")

        var laterEnd = enabled
        laterEnd.weekdayWorkingHours.endMinutes = 22 * 60
        XCTAssertTrue(laterEnd.weakensGuard(comparedTo: enabled))

        var narrower = enabled
        narrower.weekdayWorkingHours.endMinutes = 16 * 60
        XCTAssertFalse(narrower.weakensGuard(comparedTo: enabled), "fewer hours is a tightening")

        var categoryOff = enabled
        categoryOff.weekdayWorkingHours.enabled = false
        XCTAssertTrue(categoryOff.weakensGuard(comparedTo: enabled), "a day category switched off")
    }

    // The opposite direction from working hours: pressure applies *inside* the
    // scheduled window, so a shorter one is less rest.
    func testScheduledBreakLoosensWhenShortenedOrSwitchedOff() {
        var enabled = baseline
        enabled.scheduledBreak = WorkingHoursRange(
            enabled: true, startMinutes: 15 * 60 + 30, endMinutes: 16 * 60
        )

        var off = enabled
        off.scheduledBreak.enabled = false
        XCTAssertTrue(off.weakensGuard(comparedTo: enabled))

        var laterStart = enabled
        laterStart.scheduledBreak.startMinutes = 15 * 60 + 45
        XCTAssertTrue(laterStart.weakensGuard(comparedTo: enabled), "a shorter rest window")

        var longer = enabled
        longer.scheduledBreak.endMinutes = 16 * 60 + 30
        XCTAssertFalse(longer.weakensGuard(comparedTo: enabled), "a longer window is a tightening")

        // Turning it on for the first time is never a loosening.
        XCTAssertFalse(enabled.weakensGuard(comparedTo: baseline))
    }

    // Excluded on purpose: none of these change how hard a break is to avoid.
    func testCosmeticAndNeutralSettingsAreNeverCharged() {
        assertTightens({ $0.warningLeadTime = 0 }, "the break still lands at the same moment")
        assertTightens({ $0.notificationSound = false }, "sound is a preference")
        assertTightens({ $0.showSecondsInMenuBar = false }, "menu bar rendering")
        assertTightens({ $0.coarseSecondsInMenuBar = true }, "menu bar rendering")
    }

    // Harder mode has its own gate at its own toggle; charging for the same
    // decision twice in one visit would be noise, not friction.
    func testHarderModeItselfIsNotPartOfTheComparison() {
        var on = baseline
        on.harderToSkipBreaks = true
        var off = on
        off.harderToSkipBreaks = false
        XCTAssertFalse(off.weakensGuard(comparedTo: on))

        // But anything else loosened in the same visit still counts.
        off.workInterval += 60
        XCTAssertTrue(off.weakensGuard(comparedTo: on))
    }
}
