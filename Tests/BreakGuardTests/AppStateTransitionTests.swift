import UserNotifications
import XCTest
@testable import BreakGuard

private final class TransitionClock: TimeProvider {
    var now: Date
    init(now: Date) { self.now = now }
}

private final class TransitionCallActivity: CallActivityClient {
    var activity = CallActivity()
    var reads = 0
    var microphoneRequested = false

    func read(includeMicrophone: Bool) -> CallActivity {
        reads += 1
        microphoneRequested = includeMicrophone
        return CallActivity(cameraInUse: activity.cameraInUse,
                            microphoneInUse: includeMicrophone && activity.microphoneInUse)
    }
}

private final class TransitionNotifications: UserNotificationCenterClient {
    var delegate: UNUserNotificationCenterDelegate?
    func getCapabilities(_ completion: @escaping (NotificationCapabilities) -> Void) {
        completion(NotificationCapabilities(authorizationStatus: .denied, alertSetting: .disabled,
                                            alertStyle: .none, soundSetting: .disabled, timeSensitiveSetting: .disabled))
    }
    func requestAuthorization(options: UNAuthorizationOptions, completion: @escaping (Bool, Error?) -> Void) {
        XCTFail("These tests must not request permission")
    }
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) { completion(nil) }
    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {}
    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {}
    func getDeliveredNotifications(completion: @escaping ([UNNotification]) -> Void) { completion([]) }
}

@MainActor
final class AppStateTransitionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_700_000)
    private var temporaryURLs: [URL] = []

    override func tearDown() {
        for url in temporaryURLs { try? FileManager.default.removeItem(at: url) }
        temporaryURLs.removeAll()
        super.tearDown()
    }

    private func app(clock: TransitionClock, idle: @escaping () -> TimeInterval = { 0 },
                     activity: TransitionCallActivity = TransitionCallActivity()) -> AppState {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        temporaryURLs.append(directory)
        return AppState(persistence: PersistenceStore(fileURL: directory.appendingPathComponent("state.json")),
                        notifications: NotificationManager(client: TransitionNotifications()),
                        loginItems: LoginItemManager(), clock: clock, idleSeconds: idle,
                        callActivityClient: activity)
    }

    private func advance(_ app: AppState, clock: TransitionClock, by seconds: TimeInterval) {
        let end = clock.now.addingTimeInterval(seconds)
        while clock.now < end {
            clock.now = min(clock.now.addingTimeInterval(60), end)
            app.tick()
        }
    }

    func testCameraAndMicrophoneOverlapKeepsBreakHeldUntilBothEnd() {
        let clock = TransitionClock(now: start)
        let activity = TransitionCallActivity()
        let app = app(clock: clock, activity: activity)
        var settings = app.settings
        settings.holdBreaksWhileMicrophoneInUse = true
        app.updateSettings(settings)
        activity.activity = CallActivity(cameraInUse: true, microphoneInUse: true)
        advance(app, clock: clock, by: 29 * 60)
        XCTAssertTrue(app.isCallHoldActive)
        activity.activity.cameraInUse = false
        advance(app, clock: clock, by: 10 * 60)
        XCTAssertTrue(app.isCallHoldActive)
        activity.activity.microphoneInUse = false
        app.tick()
        XCTAssertFalse(app.isCallHoldActive)
        guard case let .working(deadline, _) = app.timerState else { return XCTFail("Expected a countdown") }
        XCTAssertEqual(deadline.timeIntervalSince(clock.now), CallHold.minimumRunway)
    }

    func testLongCallDoesNotBecomeIdleAbsenceWhenTheMicrophoneStops() {
        let clock = TransitionClock(now: start)
        let activity = TransitionCallActivity()
        let app = app(clock: clock, idle: { clock.now.timeIntervalSince(self.start) }, activity: activity)
        var settings = app.settings
        settings.holdBreaksWhileMicrophoneInUse = true
        app.updateSettings(settings)
        activity.activity.microphoneInUse = true
        advance(app, clock: clock, by: 40 * 60)
        activity.activity.microphoneInUse = false
        clock.now = clock.now.addingTimeInterval(1)
        app.tick()
        guard case .working = app.timerState else { return XCTFail("Call end must keep the countdown running") }
        advance(app, clock: clock, by: 2 * 60)
        guard case .breaking = app.timerState else { return XCTFail("The post-call runway must end in a break") }
        advance(app, clock: clock, by: 2 * 60)
        app.completeBreak()
        XCTAssertEqual(app.statistics.totalFocusMinutes, 42)
    }

    func testMicrophoneSettingIsOptInAndDoesNotDismissAnExistingBreak() {
        let clock = TransitionClock(now: start)
        let activity = TransitionCallActivity()
        activity.activity.microphoneInUse = true
        let app = app(clock: clock, activity: activity)
        clock.now = start.addingTimeInterval(29 * 60)
        app.tick()
        XCTAssertFalse(app.isCallHoldActive)
        clock.now = start.addingTimeInterval(30 * 60)
        app.tick()
        guard case .breaking = app.timerState else { return XCTFail("Expected the usual break") }
        let before = app.timerState
        var settings = app.settings
        settings.holdBreaksWhileMicrophoneInUse = true
        app.updateSettings(settings)
        XCTAssertEqual(app.timerState, before)
        XCTAssertFalse(app.isCallHoldActive)
    }

    func testNextTickReleasesHoldWithoutADeviceCallback() {
        for microphone in [false, true] {
            let clock = TransitionClock(now: start)
            let activity = TransitionCallActivity()
            let app = app(clock: clock, activity: activity)
            var settings = app.settings
            settings.holdBreaksWhileMicrophoneInUse = microphone
            app.updateSettings(settings)
            activity.activity = CallActivity(cameraInUse: !microphone, microphoneInUse: microphone)
            advance(app, clock: clock, by: 40 * 60)
            XCTAssertTrue(app.isCallHoldActive)
            activity.activity = CallActivity()
            clock.now = clock.now.addingTimeInterval(1)
            app.tick()
            XCTAssertFalse(app.isCallHoldActive)
            advance(app, clock: clock, by: CallHold.minimumRunway)
            guard case .breaking = app.timerState else { return XCTFail("Hold must release without callbacks") }
        }
    }

    func testSettingsResampleDevicesAndImmediatelyReleaseDisabledSources() {
        let clock = TransitionClock(now: start)
        let activity = TransitionCallActivity()
        activity.activity = CallActivity(cameraInUse: true, microphoneInUse: true)
        let app = app(clock: clock, activity: activity)
        advance(app, clock: clock, by: 29 * 60)
        XCTAssertEqual(app.callHoldActivity, CallActivity(cameraInUse: true))
        XCTAssertFalse(activity.microphoneRequested)
        let previousReads = activity.reads
        var settings = app.settings
        settings.holdBreaksWhileOnCamera = false
        settings.holdBreaksWhileMicrophoneInUse = true
        app.updateSettings(settings)
        XCTAssertEqual(activity.reads, previousReads + 1, "Settings must not recursively tick via a subscriber")
        XCTAssertEqual(app.callHoldActivity, CallActivity(microphoneInUse: true))
        settings.holdBreaksWhileMicrophoneInUse = false
        app.updateSettings(settings)
        XCTAssertFalse(app.isCallHoldActive)
        XCTAssertFalse(activity.microphoneRequested)
    }

    func testSleepClearsTransientHoldAndWakeReadsDevicesAgain() {
        let clock = TransitionClock(now: start)
        let activity = TransitionCallActivity()
        activity.activity.cameraInUse = true
        let app = app(clock: clock, activity: activity)
        advance(app, clock: clock, by: 29 * 60)
        XCTAssertTrue(app.isCallHoldActive)
        app.handleSleepOrInactive()
        XCTAssertFalse(app.isCallHoldActive)
        let reads = activity.reads
        activity.activity = CallActivity()
        clock.now = clock.now.addingTimeInterval(10)
        app.tick()
        XCTAssertEqual(activity.reads, reads, "Inactive sessions must not read hardware")
        app.handleWakeOrActive()
        XCTAssertEqual(activity.reads, reads + 1)
        XCTAssertFalse(app.isCallHoldActive)
        guard case .breaking = app.timerState else { return XCTFail("The sleep break must remain in force") }
    }

    func testLongRealCallHasNoArtificialHoldTimeout() {
        let clock = TransitionClock(now: start)
        let activity = TransitionCallActivity()
        activity.activity.cameraInUse = true
        let app = app(clock: clock, idle: { clock.now.timeIntervalSince(self.start) }, activity: activity)
        advance(app, clock: clock, by: 3 * 3600)
        XCTAssertTrue(app.isCallHoldActive)
        guard case .working = app.timerState else { return XCTFail("An active input must keep its hold") }
        activity.activity = CallActivity()
        advance(app, clock: clock, by: CallHold.minimumRunway + 1)
        guard case .breaking = app.timerState else { return XCTFail("The break must start after the call") }
    }

    func testInactiveTicksLeaveBreakWallClockIntactAndWakeCompletesIt() {
        let clock = TransitionClock(now: start)
        let app = app(clock: clock)
        clock.now = start.addingTimeInterval(10 * 60)
        app.handleSleepOrInactive()
        let before = app.timerState
        clock.now = clock.now.addingTimeInterval(5 * 60)
        app.tick()
        XCTAssertEqual(app.timerState, before)
        app.handleWakeOrActive()
        XCTAssertEqual(app.timerState, .breakCompleted)
        app.completeBreak()
        XCTAssertEqual(app.statistics.totalFocusMinutes, 10)
        XCTAssertEqual(app.statistics.completedBreaks, 1)
    }

    func testQueuedSkipActionsCannotChangeABreakAfterTheScreenLocks() {
        let clock = TransitionClock(now: start)
        let app = app(clock: clock)
        clock.now = start.addingTimeInterval(10 * 60)
        app.handleSleepOrInactive()
        let before = app.timerState
        app.postpone(seconds: 60)
        app.useEmergencyOverride()
        app.spendPressureOverride()
        app.extendFocus(minutes: 15)
        app.takeBreakNow()
        app.resumeNow()
        XCTAssertEqual(app.timerState, before)
        XCTAssertEqual(app.dailySkipsRemaining, 3)
        XCTAssertNil(app.emergencyOverrideAvailableAt)
        XCTAssertEqual(app.statistics, .empty)
    }

    func testTimedPauseDoesNotFabricateFocusWhenItExpiresWhileLocked() {
        let clock = TransitionClock(now: start)
        let app = app(clock: clock)
        clock.now = start.addingTimeInterval(10 * 60)
        app.pauseUntilNextMorning(until: clock.now.addingTimeInterval(60))
        app.handleSleepOrInactive()
        clock.now = clock.now.addingTimeInterval(4 * 3600)
        app.tick()
        guard case .suspended = app.timerState else { return XCTFail("Inactive session must keep its pause") }
        app.handleWakeOrActive()
        guard case .working = app.timerState else { return XCTFail("Expected a fresh cycle on wake") }
        XCTAssertEqual(app.statistics.totalFocusMinutes, 10)
        XCTAssertEqual(app.statistics.completedBreaks, 0)
    }
}
