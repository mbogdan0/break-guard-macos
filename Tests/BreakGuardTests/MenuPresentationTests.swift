import XCTest
@testable import BreakGuard

final class MenuPresentationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testCountdownIncludesSecondsWhenEnabled() {
        let presentation = makeMenuPresentation(
            for: .working(
                deadline: now.addingTimeInterval(5 * 60 + 7),
                warningDeadline: now.addingTimeInterval(4 * 60)
            ),
            showSeconds: true,
            now: now
        )

        XCTAssertEqual(presentation.menuBarTitle, "05:07")
        XCTAssertEqual(presentation.statusTitle, "Next break in 05:07")
    }

    func testCountdownRoundsUpToMinutesWhenSecondsAreHidden() {
        let presentation = makeMenuPresentation(
            for: .working(
                deadline: now.addingTimeInterval(5 * 60 + 7),
                warningDeadline: now.addingTimeInterval(4 * 60)
            ),
            showSeconds: false,
            now: now
        )

        XCTAssertEqual(presentation.menuBarTitle, "6m")
        XCTAssertEqual(presentation.statusTitle, "Next break in 6m")
    }

    func testEveryTimerStateHasAConciseStatusLabel() {
        let deadline = now.addingTimeInterval(125)
        let cases: [(TimerState, String, String)] = [
            (.working(deadline: deadline, warningDeadline: now), "02:05", "Next break in 02:05"),
            (.warning(deadline: deadline), "02:05", "Break starts in 02:05"),
            (.postponed(deadline: deadline), "+02:05", "Postponed break in 02:05"),
            (.breakDue, "BREAK", "Break due now"),
            (.breaking(deadline: deadline, startedAt: now, duration: 180), "BREAK 02:05", "Break remaining 02:05"),
            (.breakCompleted, "DONE", "Break completed"),
            (
                .suspended(previous: .working, remaining: 125, until: now.addingTimeInterval(125)),
                "PAUSED",
                "Paused for 02:05"
            )
        ]

        for (state, menuBarTitle, statusTitle) in cases {
            let presentation = makeMenuPresentation(for: state, showSeconds: true, now: now)
            XCTAssertEqual(presentation.menuBarTitle, menuBarTitle)
            XCTAssertEqual(presentation.statusTitle, statusTitle)
        }
    }

    func testMenuActionsFollowTimerState() {
        let active = makeMenuPresentation(
            for: .working(deadline: now.addingTimeInterval(60), warningDeadline: now),
            showSeconds: true,
            now: now
        )
        XCTAssertEqual(active.primaryAction, .takeBreak)
        XCTAssertTrue(active.canPause)

        let suspended = makeMenuPresentation(
            for: .suspended(previous: .working, remaining: 60, until: nil),
            showSeconds: true,
            now: now
        )
        XCTAssertEqual(suspended.primaryAction, .resume)
        XCTAssertFalse(suspended.canPause)

        let breaking = makeMenuPresentation(
            for: .breaking(deadline: now.addingTimeInterval(60), startedAt: now, duration: 60),
            showSeconds: true,
            now: now
        )
        XCTAssertEqual(breaking.primaryAction, .none)
        XCTAssertFalse(breaking.canPause)
    }
}
