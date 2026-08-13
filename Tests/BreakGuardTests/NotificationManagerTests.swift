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

    func getCapabilities(_ completion: @escaping (NotificationCapabilities) -> Void) {
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
    // window, and a camera hold arms the warning against its own runway.
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
