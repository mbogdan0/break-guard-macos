import AppKit
import XCTest
@testable import BreakGuard

final class MenuPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    // Deterministic formatter: the production default follows the user's
    // locale and time zone, which would make these assertions flaky.
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    func testCountdownIncludesSecondsWhenEnabled() {
        let presentation = makeMenuPresentation(
            for: .working(
                deadline: now.addingTimeInterval(5 * 60 + 7),
                warningDeadline: now.addingTimeInterval(4 * 60)
            ),
            showSeconds: true,
            now: now,
            timeFormatter: timeFormatter
        )

        XCTAssertEqual(presentation.menuBarTitle, "05:07")
        XCTAssertEqual(presentation.statusTitle, "Next break at 02:51")
    }

    func testCoarseSecondsRoundUpToTenSecondSteps() {
        let cases: [(TimeInterval, String)] = [
            (12 * 60 + 34, "12:40"),
            (12 * 60 + 31, "12:40"),
            (12 * 60 + 30, "12:30"),
            (5 * 60 + 7, "05:10")
        ]

        for (remaining, expected) in cases {
            let presentation = makeMenuPresentation(
                for: .working(
                    deadline: now.addingTimeInterval(remaining),
                    warningDeadline: now.addingTimeInterval(remaining - 60)
                ),
                showSeconds: true,
                coarseSeconds: true,
                now: now,
                timeFormatter: timeFormatter
            )
            XCTAssertEqual(presentation.menuBarTitle, expected)
        }
    }

    func testCoarseSecondsHaveNoEffectWhenSecondsAreHidden() {
        let presentation = makeMenuPresentation(
            for: .working(
                deadline: now.addingTimeInterval(5 * 60 + 7),
                warningDeadline: now.addingTimeInterval(4 * 60)
            ),
            showSeconds: false,
            coarseSeconds: true,
            now: now,
            timeFormatter: timeFormatter
        )

        XCTAssertEqual(presentation.menuBarTitle, "6m")
    }

    func testCountdownRoundsUpToMinutesWhenSecondsAreHidden() {
        let presentation = makeMenuPresentation(
            for: .working(
                deadline: now.addingTimeInterval(5 * 60 + 7),
                warningDeadline: now.addingTimeInterval(4 * 60)
            ),
            showSeconds: false,
            now: now,
            timeFormatter: timeFormatter
        )

        XCTAssertEqual(presentation.menuBarTitle, "6m")
        XCTAssertEqual(presentation.statusTitle, "Next break at 02:51")
    }

    func testEveryTimerStateHasAConciseStatusLabel() {
        let deadline = now.addingTimeInterval(125)
        let cases: [(TimerState, String, String)] = [
            (.working(deadline: deadline, warningDeadline: now), "02:05", "Next break at 02:48"),
            (.warning(deadline: deadline), "02:05", "Break starts in 02:05"),
            (.postponed(deadline: deadline), "+02:05", "Postponed break at 02:48"),
            (.breakDue, "BREAK", "Break due now"),
            (.breaking(deadline: deadline, startedAt: now, duration: 180), "BREAK 02:05", "Break remaining 02:05"),
            (.breakCompleted, "DONE", "Break completed"),
            (
                .suspended(previous: .working, remaining: 125, until: now.addingTimeInterval(125)),
                "PAUSED",
                "Paused until 02:48"
            ),
            (
                .suspended(previous: .working, remaining: 125, until: nil),
                "PAUSED",
                "Paused with 02:05 remaining"
            )
        ]

        for (state, menuBarTitle, statusTitle) in cases {
            let presentation = makeMenuPresentation(for: state, showSeconds: true, now: now, timeFormatter: timeFormatter)
            XCTAssertEqual(presentation.menuBarTitle, menuBarTitle)
            XCTAssertEqual(presentation.statusTitle, statusTitle)
        }
    }

    func testEmphasisFollowsTimerState() {
        let deadline = now.addingTimeInterval(60)
        let states: [(TimerState, MenuBarEmphasis)] = [
            (.working(deadline: deadline, warningDeadline: now.addingTimeInterval(30)), .none),
            (.warning(deadline: deadline), .urgent),
            // Postponed is borrowed time: at least yellow, even far from the deadline.
            (.postponed(deadline: now.addingTimeInterval(90 * 60)), .caution),
            (.breakDue, .none),
            (.breaking(deadline: deadline, startedAt: now, duration: 60), .none),
            (.breakCompleted, .none),
            (.suspended(previous: .working, remaining: 60, until: nil), .none)
        ]

        for (state, expected) in states {
            let presentation = makeMenuPresentation(for: state, showSeconds: true, now: now)
            XCTAssertEqual(presentation.emphasis, expected, "Unexpected emphasis for \(state)")
        }
    }

    func testPostponedTurnsUrgentInsideWarningLeadTime() {
        let deadline = now.addingTimeInterval(45)

        let inside = makeMenuPresentation(
            for: .postponed(deadline: deadline),
            showSeconds: true,
            warningLeadTime: 60,
            now: now
        )
        XCTAssertEqual(inside.emphasis, .urgent)
        XCTAssertEqual(inside.menuBarTitle, "+00:45")

        let outside = makeMenuPresentation(
            for: .postponed(deadline: now.addingTimeInterval(90)),
            showSeconds: true,
            warningLeadTime: 60,
            now: now
        )
        XCTAssertEqual(outside.emphasis, .caution)

        // No warning window configured: the postponement never turns red,
        // but it still shows the caution color.
        let disabled = makeMenuPresentation(
            for: .postponed(deadline: deadline),
            showSeconds: true,
            warningLeadTime: 0,
            now: now
        )
        XCTAssertEqual(disabled.emphasis, .caution)
    }

    func testExtendedFocusShowsCautionUntilWarning() {
        let deadline = now.addingTimeInterval(20 * 60)

        let extended = makeMenuPresentation(
            for: .working(deadline: deadline, warningDeadline: deadline.addingTimeInterval(-60)),
            showSeconds: true,
            focusExtended: true,
            now: now
        )
        XCTAssertEqual(extended.emphasis, .caution)

        // The warning window keeps its red urgency in an extended cycle.
        let warning = makeMenuPresentation(
            for: .warning(deadline: now.addingTimeInterval(30)),
            showSeconds: true,
            focusExtended: true,
            now: now
        )
        XCTAssertEqual(warning.emphasis, .urgent)
    }

    func testOutsideWorkingHoursUpgradesButNeverDowngrades() {
        let deadline = now.addingTimeInterval(10 * 60)
        let upgraded: [TimerState] = [
            .working(deadline: deadline, warningDeadline: deadline.addingTimeInterval(-60)),
            .breakDue,
            .breaking(deadline: deadline, startedAt: now, duration: 60),
            .breakCompleted,
            .suspended(previous: .working, remaining: 60, until: nil)
        ]
        for state in upgraded {
            let presentation = makeMenuPresentation(
                for: state,
                showSeconds: true,
                outsideWorkingHours: true,
                now: now
            )
            XCTAssertEqual(presentation.emphasis, .caution, "Expected caution for \(state)")
        }

        let warning = makeMenuPresentation(
            for: .warning(deadline: now.addingTimeInterval(30)),
            showSeconds: true,
            outsideWorkingHours: true,
            now: now
        )
        XCTAssertEqual(warning.emphasis, .urgent)
    }

    func testMenuActionsFollowTimerState() {
        let active = makeMenuPresentation(
            for: .working(deadline: now.addingTimeInterval(60), warningDeadline: now),
            showSeconds: true,
            now: now
        )
        XCTAssertEqual(active.primaryAction, .takeBreak)
        XCTAssertTrue(active.canExtend)

        let suspended = makeMenuPresentation(
            for: .suspended(previous: .working, remaining: 60, until: nil),
            showSeconds: true,
            now: now
        )
        XCTAssertEqual(suspended.primaryAction, .resume)
        XCTAssertFalse(suspended.canExtend)

        let breaking = makeMenuPresentation(
            for: .breaking(deadline: now.addingTimeInterval(60), startedAt: now, duration: 60),
            showSeconds: true,
            now: now
        )
        XCTAssertEqual(breaking.primaryAction, .none)
        XCTAssertFalse(breaking.canExtend)
    }

    func testExtendFocusTitlesAreIdempotentForEveryDuration() throws {
        let deadline = Date(timeIntervalSince1970: 10_000)
        let cases: [(String, Double, String)] = [
            ("By 15 Minutes", 15, "By 15 Minutes  —  until 03:01"),
            ("By 35 Minutes", 35, "By 35 Minutes  —  until 03:21"),
            ("By 1 Hour 5 Minutes", 65, "By 1 Hour 5 Minutes  —  until 03:51")
        ]

        for (baseTitle, minutes, expected) in cases {
            let item = NSMenuItem(title: baseTitle, action: nil, keyEquivalent: "")
            for _ in 0..<5 {
                item.attributedTitle = makeExtendFocusTitle(
                    baseTitle: baseTitle,
                    deadline: deadline,
                    minutes: minutes,
                    timeFormatter: timeFormatter
                )
                let attributedTitle = try XCTUnwrap(item.attributedTitle)
                XCTAssertEqual(attributedTitle.string, expected)
                XCTAssertEqual(attributedTitle.string.components(separatedBy: "until").count - 1, 1)
            }

            let suffixIndex = (baseTitle as NSString).length
            let attributedTitle = try XCTUnwrap(item.attributedTitle)
            let color = attributedTitle.attribute(.foregroundColor, at: suffixIndex, effectiveRange: nil) as? NSColor
            XCTAssertEqual(color, NSColor.secondaryLabelColor)
        }
    }

    func testExtendFocusDeadlineFollowsExtendableStates() {
        let deadline = now.addingTimeInterval(600)
        XCTAssertEqual(focusDeadline(for: .working(deadline: deadline, warningDeadline: now)), deadline)
        XCTAssertEqual(focusDeadline(for: .warning(deadline: deadline)), deadline)
        XCTAssertEqual(focusDeadline(for: .postponed(deadline: deadline)), deadline)
        XCTAssertNil(focusDeadline(for: .breakDue))
        XCTAssertNil(focusDeadline(for: .breaking(deadline: deadline, startedAt: now, duration: 60)))
        XCTAssertNil(focusDeadline(for: .breakCompleted))
        XCTAssertNil(focusDeadline(for: .suspended(previous: .working, remaining: 60, until: nil)))
    }

    func testBreakOverlayActionsDependOnBreakOrigin() {
        XCTAssertEqual(breakOverlayActionSet(isManualBreak: true), .cancel)
        XCTAssertEqual(breakOverlayActionSet(isManualBreak: false), .postpone)
        XCTAssertEqual(
            breakOverlayActionSet(isManualBreak: false, canPostpone: false),
            .unavailable
        )
        // A user-started break always keeps its penalty-free Cancel action.
        XCTAssertEqual(
            breakOverlayActionSet(isManualBreak: true, canPostpone: false),
            .cancel
        )
    }

    func testPostponeHoldDurationScalesWithTheLongerPostponement() {
        // The shorter postponement holds for 2 s, the longer for 6 s —
        // regardless of which of the two settings slots it occupies.
        XCTAssertEqual(postponeHoldDuration(for: 2 * 60, comparedTo: 15 * 60), 2)
        XCTAssertEqual(postponeHoldDuration(for: 15 * 60, comparedTo: 2 * 60), 6)
        XCTAssertEqual(postponeHoldDuration(for: 15 * 60, comparedTo: 15 * 60), 2)
    }

    func testPostponeHoldDurationUsesHarderTier() {
        XCTAssertEqual(postponeHoldDuration(for: 2 * 60, comparedTo: 15 * 60, tier: .harder), 4)
        XCTAssertEqual(postponeHoldDuration(for: 15 * 60, comparedTo: 2 * 60, tier: .harder), 12)
        XCTAssertEqual(postponeHoldDuration(for: 15 * 60, comparedTo: 15 * 60, tier: .harder), 4)
    }

    func testPostponeHoldDurationUsesRepeatedTier() {
        XCTAssertEqual(postponeHoldDuration(for: 2 * 60, comparedTo: 15 * 60, tier: .repeated), 4)
        XCTAssertEqual(postponeHoldDuration(for: 15 * 60, comparedTo: 2 * 60, tier: .repeated), 12)
        XCTAssertEqual(postponeHoldDuration(for: 15 * 60, comparedTo: 15 * 60, tier: .repeated), 4)
    }

    // The holds follow the same rule as the dialog gates: harder mode is the
    // reference and the standard tier pays exactly half.
    func testPostponeHoldStandardTierIsHalfOfHarder() {
        for (duration, other) in [(2.0 * 60, 15.0 * 60), (15.0 * 60, 2.0 * 60)] {
            XCTAssertEqual(
                postponeHoldDuration(for: duration, comparedTo: other, tier: .standard) * 2,
                postponeHoldDuration(for: duration, comparedTo: other, tier: .harder)
            )
        }
    }

    // Off the ladder on purpose: the once-a-week quota is the real price, so
    // the hold does not double in harder mode the way everything else does.
    func testEmergencyOverrideHoldIsFlat() {
        XCTAssertEqual(EmergencyOverride.holdDuration, 3)
    }

    func testPostponeHoldHintReadsAsSeconds() {
        XCTAssertEqual(postponeHoldHint(2), "Hold 2s")
        XCTAssertEqual(postponeHoldHint(4), "Hold 4s")
        XCTAssertEqual(postponeHoldHint(12), "Hold 12s")
    }

    // The menu offers exactly these four durations.
    private static let extendOptions: [Double] = [15, 35, 45, 65]

    // No action is free in either mode. Normal mode is the same ladder at half
    // the count — one rule, so a new gate cannot quietly acquire an exception.
    func testNormalModePaysHalfOfEveryHarderModeGate() {
        for minutes in Self.extendOptions {
            XCTAssertEqual(
                SkipConfirmGate.extendSeconds(forMinutes: minutes, harderToSkipBreaks: false) * 2,
                SkipConfirmGate.extendSeconds(forMinutes: minutes, harderToSkipBreaks: true),
                "\(minutes) min should cost half outside harder mode"
            )
        }
        XCTAssertEqual(
            SkipConfirmGate.pauseSeconds(harderToSkipBreaks: false) * 2,
            SkipConfirmGate.pauseSeconds(harderToSkipBreaks: true)
        )
        XCTAssertEqual(
            SkipConfirmGate.quitSeconds(harderToSkipBreaks: false) * 2,
            SkipConfirmGate.quitSeconds(harderToSkipBreaks: true)
        )
        // Halved, never waived.
        for minutes in Self.extendOptions {
            XCTAssertGreaterThan(
                SkipConfirmGate.extendSeconds(forMinutes: minutes, harderToSkipBreaks: false),
                0
            )
        }
    }

    func testExtendGateChargesTheLongerCountPastTheShortThreshold() {
        XCTAssertEqual(SkipConfirmGate.extendSeconds(forMinutes: 15, harderToSkipBreaks: true), 12)
        XCTAssertEqual(SkipConfirmGate.extendSeconds(forMinutes: 35, harderToSkipBreaks: true), 30)
        XCTAssertEqual(SkipConfirmGate.extendSeconds(forMinutes: 45, harderToSkipBreaks: true), 30)
        XCTAssertEqual(SkipConfirmGate.extendSeconds(forMinutes: 65, harderToSkipBreaks: true), 30)
        // The threshold is inclusive on the short side.
        XCTAssertEqual(
            SkipConfirmGate.extendSeconds(
                forMinutes: SkipConfirmGate.extendShortThresholdMinutes + 1,
                harderToSkipBreaks: true
            ),
            SkipConfirmGate.extendLongSeconds
        )
    }

    // Silencing every reminder until the morning and quitting outright stop the
    // same reminders, so they are priced together at the top of the ladder.
    func testPauseAndQuitShareTheLongestGate() {
        XCTAssertEqual(SkipConfirmGate.pauseSeconds(harderToSkipBreaks: true), 180)
        XCTAssertEqual(SkipConfirmGate.quitSeconds(harderToSkipBreaks: true), 180)
        XCTAssertEqual(
            SkipConfirmGate.pauseUntilMorningSeconds,
            SkipConfirmGate.quitAppSeconds
        )
    }

    // Leaving harder mode removes every other gate at once, so it is priced
    // above any single extension — and only below the pause, which silences
    // the app outright rather than lowering its guard.
    func testLeavingHarderModeIsGatedAboveAnyExtension() {
        XCTAssertEqual(SkipConfirmGate.disableHarderModeSeconds, 90)
        XCTAssertGreaterThan(
            SkipConfirmGate.disableHarderModeSeconds,
            SkipConfirmGate.extendLongSeconds
        )
        XCTAssertLessThan(
            SkipConfirmGate.disableHarderModeSeconds,
            SkipConfirmGate.pauseUntilMorningSeconds
        )
    }

    // One ladder, priced by how much rest the action removes. A change that
    // reorders any two rungs has to come here and say so.
    func testTheLadderRisesWithWhatTheActionCosts() {
        let ladder: [TimeInterval] = [
            postponeHoldDuration(for: 2 * 60, comparedTo: 15 * 60, tier: .harder),
            postponeHoldDuration(for: 15 * 60, comparedTo: 2 * 60, tier: .harder),
            SkipConfirmGate.extendLongSeconds,
            SkipConfirmGate.loosenSettingsSeconds,
            SkipConfirmGate.disableHarderModeSeconds,
            SkipConfirmGate.pauseUntilMorningSeconds
        ]
        XCTAssertEqual(ladder, ladder.sorted(), "the ladder must rise")
        XCTAssertEqual(Set(ladder).count, ladder.count, "no two rungs should tie")
        // The long postponement and the short extension buy the same 15 minutes
        // of screen time, so they are the one deliberate tie.
        XCTAssertEqual(
            postponeHoldDuration(for: 15 * 60, comparedTo: 2 * 60, tier: .harder),
            SkipConfirmGate.extendShortSeconds
        )
    }

    func testGateButtonTitleDropsTheCountAtZero() {
        XCTAssertEqual(gateButtonTitle("Extend Anyway", remaining: 30), "Extend Anyway (30)")
        XCTAssertEqual(gateButtonTitle("Extend Anyway", remaining: 1), "Extend Anyway (1)")
        XCTAssertEqual(gateButtonTitle("Extend Anyway", remaining: 0), "Extend Anyway")
        // A negative count cannot leak into the title if a tick overshoots.
        XCTAssertEqual(gateButtonTitle("Extend Anyway", remaining: -1), "Extend Anyway")
        // Shared with every other gated confirmation, not just the extension.
        XCTAssertEqual(gateButtonTitle("Turn It Off", remaining: 45), "Turn It Off (45)")
    }

    // A three-minute gate counting down in bare seconds is a number to decode,
    // so from a minute up the title reads as a clock.
    func testGateButtonTitleReadsAsAClockPastAMinute() {
        XCTAssertEqual(gateButtonTitle("Quit Anyway", remaining: 180), "Quit Anyway (3:00)")
        XCTAssertEqual(gateButtonTitle("Quit Anyway", remaining: 90), "Quit Anyway (1:30)")
        XCTAssertEqual(gateButtonTitle("Turn It Off", remaining: 60), "Turn It Off (1:00)")
        XCTAssertEqual(gateButtonTitle("Turn It Off", remaining: 61), "Turn It Off (1:01)")
        // Just below the switch it stays a bare count.
        XCTAssertEqual(gateButtonTitle("Keep Them", remaining: 59), "Keep Them (59)")
    }

    func testBreakPromptCatalogContainsTenUniqueMessages() {
        XCTAssertEqual(BreakPromptCatalog.all.count, 10)
        XCTAssertEqual(Set(BreakPromptCatalog.all).count, 10)
        XCTAssertTrue(BreakPromptCatalog.all.allSatisfy { !$0.isEmpty })
    }
}
