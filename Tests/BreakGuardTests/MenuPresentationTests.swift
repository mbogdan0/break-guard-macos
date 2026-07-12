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

    func testOnlyWarningStateIsUrgent() {
        let deadline = now.addingTimeInterval(60)
        let states: [(TimerState, Bool)] = [
            (.working(deadline: deadline, warningDeadline: now.addingTimeInterval(30)), false),
            (.warning(deadline: deadline), true),
            (.postponed(deadline: deadline), false),
            (.breakDue, false),
            (.breaking(deadline: deadline, startedAt: now, duration: 60), false),
            (.breakCompleted, false),
            (.suspended(previous: .working, remaining: 60, until: nil), false)
        ]

        for (state, expected) in states {
            let presentation = makeMenuPresentation(for: state, showSeconds: true, now: now)
            XCTAssertEqual(presentation.isUrgent, expected, "Unexpected urgency for \(state)")
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
        XCTAssertTrue(inside.isUrgent)
        XCTAssertEqual(inside.menuBarTitle, "+00:45")

        let outside = makeMenuPresentation(
            for: .postponed(deadline: now.addingTimeInterval(90)),
            showSeconds: true,
            warningLeadTime: 60,
            now: now
        )
        XCTAssertFalse(outside.isUrgent)

        // No warning window configured: the postponement never turns red.
        let disabled = makeMenuPresentation(
            for: .postponed(deadline: deadline),
            showSeconds: true,
            warningLeadTime: 0,
            now: now
        )
        XCTAssertFalse(disabled.isUrgent)
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
    }

    func testBreakPromptCatalogContainsTenUniqueMessages() {
        XCTAssertEqual(BreakPromptCatalog.all.count, 10)
        XCTAssertEqual(Set(BreakPromptCatalog.all).count, 10)
        XCTAssertTrue(BreakPromptCatalog.all.allSatisfy { !$0.isEmpty })
    }
}
