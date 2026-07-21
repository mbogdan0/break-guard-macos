import XCTest
@testable import BreakGuard

private struct FakeClock: TimeProvider {
    var now: Date
}

// Edge cases for the focus-minute tapering accumulator and the weekly
// emergency override: the paths that are easy to get wrong and hard to notice
// going wrong, because they fail silently rather than crashing.
final class TaperingAndOverrideEdgeCaseTests: XCTestCase {

    private func taperingMachine(
        start: Date,
        clock: FakeClock,
        workInterval: TimeInterval = 30 * 60
    ) -> StateMachine {
        var settings = AppSettings.defaults
        settings.workInterval = workInterval
        settings.breakDuration = 2 * 60
        settings.focusPace = .tapering
        return StateMachine(settings: settings, clock: clock)
    }

    // MARK: - Accumulator hygiene

    // Overlay time on a break the user started and then cancelled is not focus:
    // cancelManualBreak shifts the cycle start forward, and the accumulator has
    // to honour that shift rather than measuring from the original start.
    func testCancelledManualBreakDoesNotInflateTheAccumulator() {
        let start = Date(timeIntervalSince1970: 100_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        machine.takeBreakNow()
        machine.startBreak()

        // Three minutes staring at the overlay, then cancel.
        clock.now = clock.now.addingTimeInterval(3 * 60)
        machine.clock = clock
        machine.cancelManualBreak()

        // Ten more minutes of real work, then close the cycle.
        clock.now = clock.now.addingTimeInterval(10 * 60)
        machine.clock = clock
        machine.markBreakTaken()

        // 20 minutes worked, not the 23 minutes of wall clock.
        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 20 * 60, accuracy: 0.001)
    }

    // Sleeping through a cycle is not focus either, however long the nap.
    func testSleepTimeIsNotChargedToTheAccumulator() {
        let start = Date(timeIntervalSince1970: 110_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        clock.now = start.addingTimeInterval(10 * 60)
        machine.clock = clock
        machine.preserveForSleep()

        clock.now = clock.now.addingTimeInterval(3 * 3600)
        machine.clock = clock
        machine.restoreAfterSleep()

        // Ten minutes of focus preceded the nap; the nap itself adds nothing.
        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 10 * 60, accuracy: 0.001)
    }

    // Postponed time counts as focus, matching how statistics credit it. Pinned
    // because it is a deliberate choice, not an accident of the measurement.
    func testPostponedTimeCountsAsFocus() {
        let start = Date(timeIntervalSince1970: 120_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        machine.postpone(by: 2 * 60)
        clock.now = clock.now.addingTimeInterval(2 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        machine.postpone(by: 2 * 60)
        clock.now = clock.now.addingTimeInterval(2 * 60)
        machine.clock = clock
        machine.markBreakTaken()

        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 34 * 60, accuracy: 0.001)
    }

    // A day's accumulation still runs while another pace is selected, so
    // switching to Tapering mid-afternoon does not hand out a fresh full window.
    func testSwitchingToTaperingMidDayInheritsTheDaysTotal() {
        let start = Date(timeIntervalSince1970: 130_000)
        var clock = FakeClock(now: start)
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.focusPace = .normal
        var machine = StateMachine(settings: settings, clock: clock)

        clock.now = start.addingTimeInterval(4 * 3600)
        machine.clock = clock
        machine.markBreakTaken()
        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 4 * 3600, accuracy: 0.001)

        machine.settings.focusPace = .tapering
        clock.now = clock.now.addingTimeInterval(10 * 60)
        machine.clock = clock
        machine.markBreakTaken()

        // 4h10m banked costs 250 seconds off the next window.
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 30 * 60 - 250, accuracy: 0.001)
    }

    // Postponing ends the break it interrupted, so the capture startBreak()
    // took must not outlive it. Sleeping during the brief .breakDue moment
    // after a postponed window expires reads that capture, and a stale one
    // silently drops the work done between the postponement and the sleep.
    func testSleepingWhileABreakIsDueAfterAPostponementCreditsAllFocus() {
        let start = Date(timeIntervalSince1970: 155_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        machine.postpone(by: 15 * 60)

        // The postponed window runs out; the break is due again but the
        // overlay has not started yet.
        clock.now = clock.now.addingTimeInterval(15 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)

        machine.preserveForSleep()
        clock.now = clock.now.addingTimeInterval(3600)
        machine.clock = clock
        machine.restoreAfterSleep()

        // 30 minutes before the break plus 15 on the postponed window.
        XCTAssertEqual(machine.statistics.totalFocusMinutes, 45)
        XCTAssertEqual(machine.runtime.taperedFocusSeconds, 45 * 60, accuracy: 0.001)
    }

    // MARK: - Hostile inputs

    // A clock that jumps backwards (NTP correction, timezone edit) must not
    // produce a negative charge, which would lengthen the next window.
    func testBackwardClockJumpCannotProduceNegativeFocus() {
        let start = Date(timeIntervalSince1970: 140_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)
        machine.runtime.taperedFocusSeconds = 20 * 60

        clock.now = start.addingTimeInterval(-3600)
        machine.clock = clock
        machine.markBreakTaken()

        XCTAssertGreaterThanOrEqual(machine.runtime.taperedFocusSeconds, 20 * 60)
        guard case let .working(deadline, _) = machine.runtime.timerState else {
            return XCTFail("Expected working state")
        }
        XCTAssertLessThanOrEqual(deadline.timeIntervalSince(clock.now), 30 * 60)
    }

    // The accumulator is persisted as a Double. JSONEncoder throws on infinity
    // and NaN, and PersistenceStore.save() swallows that error, so a poisoned
    // value would silently stop every future write and freeze the user's
    // statistics forever. The value must be kept finite at the source.
    func testAccumulatorStaysEncodableAfterAbsurdInput() throws {
        let start = Date(timeIntervalSince1970: 150_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        for poison in [Double.infinity, -Double.infinity, Double.nan, 1e300] {
            machine.runtime.taperedFocusSeconds = poison
            clock.now = clock.now.addingTimeInterval(60)
            machine.clock = clock
            machine.markBreakTaken()

            XCTAssertTrue(
                machine.runtime.taperedFocusSeconds.isFinite,
                "accumulator went non-finite after \(poison)"
            )
            XCTAssertNoThrow(
                try JSONEncoder.breakGuard.encode(machine.data),
                "state stopped being encodable after \(poison)"
            )
            guard case let .working(deadline, _) = machine.runtime.timerState else {
                return XCTFail("Expected working state after \(poison)")
            }
            let length = deadline.timeIntervalSince(clock.now)
            XCTAssertGreaterThanOrEqual(length, FocusPace.taperingMinimumInterval)
            XCTAssertLessThanOrEqual(length, 30 * 60)
        }
    }

    // MARK: - Emergency override

    func testOverrideSurvivesSleepAcrossItsGrant() {
        let start = Date(timeIntervalSince1970: 160_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        machine.useEmergencyOverride()
        let usedAt = clock.now

        machine.preserveForSleep()
        clock.now = clock.now.addingTimeInterval(2 * 3600)
        machine.clock = clock
        machine.restoreAfterSleep()

        XCTAssertEqual(machine.runtime.emergencyOverrideUsedAt, usedAt)
        XCTAssertFalse(machine.canUseEmergencyOverride)
    }

    // A relaunch must not hand the quota back.
    func testOverrideQuotaSurvivesAPersistenceRoundTrip() throws {
        let start = Date(timeIntervalSince1970: 170_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        machine.useEmergencyOverride()
        let usedAt = clock.now

        let encoded = try JSONEncoder.breakGuard.encode(machine.data)
        let decoded = try JSONDecoder.breakGuard.decode(PersistedAppData.self, from: encoded)
        clock.now = clock.now.addingTimeInterval(24 * 3600)
        let relaunched = StateMachine(data: decoded, clock: clock)

        XCTAssertEqual(relaunched.runtime.emergencyOverrideUsedAt, usedAt)
        XCTAssertEqual(
            relaunched.emergencyOverrideAvailableAt,
            usedAt.addingTimeInterval(EmergencyOverride.cooldown)
        )
    }

    // Overriding and then postponing inside one cycle is one violation, not two.
    func testOverrideThenPostponeCountsOneViolatedCycle() {
        let start = Date(timeIntervalSince1970: 180_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        machine.useEmergencyOverride()

        clock.now = clock.now.addingTimeInterval(EmergencyOverride.focusGrant)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        machine.postpone(by: 2 * 60)

        XCTAssertEqual(machine.statistics.violatedCycles, 1)
        XCTAssertEqual(machine.statistics.currentCleanStreak, 0)
    }

    // The grant lands in .postponed, from which takeBreakNow is still legal;
    // doing so must not resurrect the spent quota.
    func testTakingABreakDuringTheGrantDoesNotRefundTheQuota() {
        let start = Date(timeIntervalSince1970: 190_000)
        var clock = FakeClock(now: start)
        var machine = taperingMachine(start: start, clock: clock)

        clock.now = start.addingTimeInterval(30 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .breakDue)
        machine.startBreak()
        machine.useEmergencyOverride()
        let usedAt = clock.now

        clock.now = clock.now.addingTimeInterval(10 * 60)
        machine.clock = clock
        machine.takeBreakNow()
        machine.startBreak()

        // A manual break never offers the override, and the stamp is unchanged.
        XCTAssertFalse(machine.canUseEmergencyOverride)
        XCTAssertEqual(machine.runtime.emergencyOverrideUsedAt, usedAt)
    }

    // MARK: - Warning lead

    func testWarningLeadCapHandlesExtremes() {
        var settings = AppSettings.defaults
        settings.warningLeadTime = 30 * 60
        XCTAssertEqual(settings.effectiveWarningLeadTime(for: 0), 0)
        XCTAssertEqual(settings.effectiveWarningLeadTime(for: 60), 30)
        XCTAssertEqual(settings.effectiveWarningLeadTime(for: 120 * 60), 30 * 60)
    }

    // A lead longer than half the window is capped when the cycle is built.
    // The paths that re-anchor a deadline mid-cycle have to honour the same
    // cap, or they re-arm a warning the cycle's own rule forbids. All three
    // use a 30-minute window with a 30-minute lead, capped to 15 minutes.
    private func wideLeadMachine(clock: FakeClock) -> StateMachine {
        var settings = AppSettings.defaults
        settings.workInterval = 30 * 60
        settings.warningLeadTime = 30 * 60
        settings.breakDuration = 2 * 60
        return StateMachine(settings: settings, clock: clock)
    }

    func testResumingAShortPauseDoesNotArmTheWarningEarly() {
        let start = Date(timeIntervalSince1970: 500_000)
        var clock = FakeClock(now: start)
        var machine = wideLeadMachine(clock: clock)

        // Pause five minutes in, resume a minute later: 25 minutes remain,
        // well outside the capped 15-minute lead.
        clock.now = start.addingTimeInterval(5 * 60)
        machine.clock = clock
        machine.suspend(until: nil)

        clock.now = clock.now.addingTimeInterval(60)
        machine.clock = clock
        machine.resume()

        guard case let .working(deadline, warningDeadline) = machine.runtime.timerState else {
            return XCTFail("Expected working, got \(machine.runtime.timerState)")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 25 * 60, accuracy: 0.001)
        // Capped to half the window, not the raw 30-minute setting.
        XCTAssertEqual(deadline.timeIntervalSince(warningDeadline), 15 * 60, accuracy: 0.001)
        XCTAssertEqual(machine.tick(), machine.runtime.timerState)
    }

    func testCancellingAManualBreakDoesNotArmTheWarningEarly() {
        let start = Date(timeIntervalSince1970: 510_000)
        var clock = FakeClock(now: start)
        var machine = wideLeadMachine(clock: clock)

        clock.now = start.addingTimeInterval(5 * 60)
        machine.clock = clock
        machine.takeBreakNow()
        machine.startBreak()

        clock.now = clock.now.addingTimeInterval(60)
        machine.clock = clock
        machine.cancelManualBreak()

        guard case let .working(deadline, warningDeadline) = machine.runtime.timerState else {
            return XCTFail("Expected working, got \(machine.runtime.timerState)")
        }
        XCTAssertEqual(deadline.timeIntervalSince(warningDeadline), 15 * 60, accuracy: 0.001)
        XCTAssertEqual(machine.tick(), machine.runtime.timerState)
    }

    // Extending during the warning must actually leave it. With the raw lead
    // the new warning deadline landed at or before the current moment, so the
    // next tick dropped straight back into .warning and the extension read as
    // a no-op. The extension has to be no longer than the excess lead for the
    // old behaviour to show, which the 15-minute menu option satisfies here.
    func testExtendingDuringTheWarningLeavesTheWarningState() {
        let start = Date(timeIntervalSince1970: 520_000)
        var clock = FakeClock(now: start)
        var machine = wideLeadMachine(clock: clock)

        // Fifteen minutes in, the capped lead opens the warning.
        clock.now = start.addingTimeInterval(15 * 60)
        machine.clock = clock
        XCTAssertEqual(machine.tick(), .warning(deadline: start.addingTimeInterval(30 * 60)))

        machine.extendFocus(by: 15 * 60)

        guard case let .working(deadline, warningDeadline) = machine.runtime.timerState else {
            return XCTFail("Expected working, got \(machine.runtime.timerState)")
        }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), 30 * 60, accuracy: 0.001)
        XCTAssertEqual(deadline.timeIntervalSince(warningDeadline), 15 * 60, accuracy: 0.001)
        // The extension survives the next tick instead of snapping back.
        XCTAssertEqual(machine.tick(), machine.runtime.timerState)
    }
}
