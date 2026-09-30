import UserNotifications
import XCTest
@testable import BreakGuard

private final class FakeNotificationCenterClient: UserNotificationCenterClient {
    var delegate: UNUserNotificationCenterDelegate?
    var capabilities = NotificationCapabilities(
        authorizationStatus: .authorized,
        alertSetting: .enabled,
        alertStyle: .banner,
        soundSetting: .enabled,
        timeSensitiveSetting: .notSupported
    )
    var authorizationResult = (true, Optional<Error>.none)
    var addResults: [Error?] = []
    var requests: [UNNotificationRequest] = []
    var removedPendingIdentifiers: [[String]] = []
    var removedDeliveredIdentifiers: [[String]] = []
    var deliveredNotifications: [UNNotification] = []
    var deferCapabilities = false
    var deferAdds = false
    var capabilityCallbacks: [(NotificationCapabilities) -> Void] = []
    var addCallbacks: [(Error?) -> Void] = []

    func getCapabilities(_ completion: @escaping (NotificationCapabilities) -> Void) {
        if deferCapabilities { capabilityCallbacks.append(completion); return }
        completion(capabilities)
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        completion(authorizationResult.0, authorizationResult.1)
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        requests.append(request)
        if deferAdds { addCallbacks.append(completion); return }
        completion(addResults.isEmpty ? nil : addResults.removeFirst())
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        removedPendingIdentifiers.append(identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        removedDeliveredIdentifiers.append(identifiers)
    }

    func getDeliveredNotifications(completion: @escaping ([UNNotification]) -> Void) {
        completion(deliveredNotifications)
    }
}

final class NotificationManagerTests: XCTestCase {
    func testLateAddCompletionCannotRemoveANewerWarning() {
        let client = FakeNotificationCenterClient()
        client.deferAdds = true
        let manager = NotificationManager(client: client)
        let first = Date().addingTimeInterval(120)
        manager.scheduleWarning(at: first, breakAt: first.addingTimeInterval(60), settings: .defaults)
        manager.cancelWarning()
        let second = first.addingTimeInterval(60)
        manager.scheduleWarning(at: second, breakAt: second.addingTimeInterval(60), settings: .defaults)
        let removals = client.removedPendingIdentifiers.count
        client.addCallbacks[1](nil)
        client.addCallbacks[0](nil)
        XCTAssertEqual(client.removedPendingIdentifiers.count, removals)
        XCTAssertEqual(client.requests.count, 2)
    }

    func testCancelledCapabilityCallbackCannotSubmitAWarningDuringACall() {
        let client = FakeNotificationCenterClient()
        client.deferCapabilities = true
        let manager = NotificationManager(client: client)
        let date = Date().addingTimeInterval(120)
        manager.scheduleWarning(at: date, breakAt: date.addingTimeInterval(60), settings: .defaults)
        manager.cancelWarning()
        client.capabilityCallbacks[0](client.capabilities)
        XCTAssertTrue(client.requests.isEmpty)
    }

    func testSoundChangesRescheduleAndDisablingWarningCancelsThePendingRequest() {
        let client = FakeNotificationCenterClient()
        let manager = NotificationManager(client: client)
        let date = Date().addingTimeInterval(120)
        var settings = AppSettings.defaults
        manager.scheduleWarning(at: date, breakAt: date.addingTimeInterval(60), settings: settings)
        settings.notificationSound = false
        manager.scheduleWarning(at: date, breakAt: date.addingTimeInterval(60), settings: settings)
        XCTAssertEqual(client.requests.count, 2)
        XCTAssertNil(client.requests.last?.content.sound)
        let removals = client.removedPendingIdentifiers.count
        settings.warningLeadTime = 0
        manager.scheduleWarning(at: date, breakAt: date.addingTimeInterval(60), settings: settings)
        XCTAssertEqual(client.removedPendingIdentifiers.count, removals + 1)
    }

    func testWarningTitleReflectsLeadTime() {
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 60), "Break in 1 minute")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 5 * 60), "Break in 5 minutes")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 30 * 60), "Break in 30 minutes")
    }

    // A lead entered to the second must be reported to the second. Rounding to
    // whole minutes reported 90 s as "2 minutes" — and rounding *up* promises
    // time the countdown does not have.
    func testWarningTitleKeepsSecondsOnPartialMinutes() {
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 90), "Break in 1 minute 30 seconds")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 100), "Break in 1 minute 40 seconds")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 150), "Break in 2 minutes 30 seconds")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 61), "Break in 1 minute 1 second")
    }

    func testWarningTitleHandlesSubMinuteEdges() {
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 30), "Break in 30 seconds")
        XCTAssertEqual(NotificationManager.warningTitle(leadTime: 0), "Break starting now")
    }

    // The title is the gap between the notification and the break, not the
    // configured lead: effectiveWarningLeadTime caps the setting at half the
    // window, and a call hold arms the warning against its own runway.
    func testWarningTitleFollowsTheScheduleNotTheSetting() {
        let client = FakeNotificationCenterClient()
        let manager = NotificationManager(client: client)
        var settings = AppSettings.defaults
        settings.warningLeadTime = 30 * 60

        let fireAt = Date().addingTimeInterval(120)
        manager.scheduleWarning(at: fireAt, breakAt: fireAt.addingTimeInterval(90), settings: settings)

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].content.title, "Break in 1 minute 30 seconds")
    }

    func testWarningUsesActiveInterruptionWithoutTimeSensitiveSupport() {
        let client = FakeNotificationCenterClient()
        let manager = NotificationManager(client: client)

        let fireAt = Date().addingTimeInterval(120)
        manager.scheduleWarning(at: fireAt, breakAt: fireAt.addingTimeInterval(60), settings: .defaults)

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].content.interruptionLevel, .active)
    }

    func testWarningUsesTimeSensitiveInterruptionWhenEnabled() {
        let client = FakeNotificationCenterClient()
        client.capabilities = NotificationCapabilities(
            authorizationStatus: .authorized,
            alertSetting: .enabled,
            alertStyle: .banner,
            soundSetting: .enabled,
            timeSensitiveSetting: .enabled
        )
        let manager = NotificationManager(client: client)

        let fireAt = Date().addingTimeInterval(120)
        manager.scheduleWarning(at: fireAt, breakAt: fireAt.addingTimeInterval(60), settings: .defaults)

        XCTAssertEqual(client.requests.count, 1)
        XCTAssertEqual(client.requests[0].content.interruptionLevel, .timeSensitive)
    }

    func testFailedWarningScheduleCanRetrySameDate() {
        let client = FakeNotificationCenterClient()
        client.addResults = [NSError(domain: "test", code: 1), nil]
        let manager = NotificationManager(client: client)
        let date = Date().addingTimeInterval(120)

        manager.scheduleWarning(at: date, breakAt: date.addingTimeInterval(60), settings: .defaults)
        manager.scheduleWarning(at: date, breakAt: date.addingTimeInterval(60), settings: .defaults)

        XCTAssertEqual(client.requests.count, 2)
    }

    func testPreviewUsesActiveDeliveryAndReportsTimeout() {
        let client = FakeNotificationCenterClient()
        var timeout: (() -> Void)?
        let manager = NotificationManager(client: client) { _, action in timeout = action }
        var states: [NotificationTestState] = []

        manager.sendTestNotification(settings: .defaults) { result in
            if case let .success(state) = result { states.append(state) }
        }

        XCTAssertEqual(client.requests.last?.content.interruptionLevel, .active)
        XCTAssertEqual(states, [.queued])
        timeout?()
        XCTAssertEqual(states, [.queued, .notDelivered])
    }

    func testPreviewReportsForegroundDelivery() {
        let client = FakeNotificationCenterClient()
        let manager = NotificationManager(client: client) { _, _ in }
        var states: [NotificationTestState] = []

        manager.sendTestNotification(settings: .defaults) { result in
            if case let .success(state) = result { states.append(state) }
        }
        manager.recordDelivery(identifier: "breakguard.test")

        XCTAssertEqual(states, [.queued, .delivered])
    }

    func testAccessStatusDistinguishesRegularAndDisabledAlerts() {
        let regular = NotificationCapabilities(
            authorizationStatus: .authorized,
            alertSetting: .enabled,
            alertStyle: .banner,
            soundSetting: .disabled,
            timeSensitiveSetting: .notSupported
        )
        let alertsDisabled = NotificationCapabilities(
            authorizationStatus: .authorized,
            alertSetting: .disabled,
            alertStyle: .none,
            soundSetting: .disabled,
            timeSensitiveSetting: .notSupported
        )

        XCTAssertEqual(
            NotificationAccessStatus(capabilities: regular),
            .enabled(timeSensitive: false, sound: false)
        )
        XCTAssertEqual(NotificationAccessStatus(capabilities: alertsDisabled), .alertsDisabled)
    }
}
