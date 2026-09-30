import Foundation
import UserNotifications
import os

struct NotificationCapabilities: Equatable {
    let authorizationStatus: UNAuthorizationStatus
    let alertSetting: UNNotificationSetting
    let alertStyle: UNAlertStyle
    let soundSetting: UNNotificationSetting
    let timeSensitiveSetting: UNNotificationSetting

    var isAuthorized: Bool {
        switch authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        default: return false
        }
    }

    var canPresentAlerts: Bool {
        isAuthorized && alertSetting == .enabled && alertStyle != .none
    }

    var supportsTimeSensitive: Bool {
        timeSensitiveSetting == .enabled
    }
}

protocol UserNotificationCenterClient: AnyObject {
    var delegate: UNUserNotificationCenterDelegate? { get set }

    func getCapabilities(_ completion: @escaping (NotificationCapabilities) -> Void)
    func requestAuthorization(
        options: UNAuthorizationOptions,
        completion: @escaping (Bool, Error?) -> Void
    )
    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void)
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
    func getDeliveredNotifications(completion: @escaping ([UNNotification]) -> Void)
}

final class SystemUserNotificationCenterClient: UserNotificationCenterClient {
    private let center = UNUserNotificationCenter.current()

    var delegate: UNUserNotificationCenterDelegate? {
        get { center.delegate }
        set { center.delegate = newValue }
    }

    func getCapabilities(_ completion: @escaping (NotificationCapabilities) -> Void) {
        center.getNotificationSettings { settings in
            completion(NotificationCapabilities(
                authorizationStatus: settings.authorizationStatus,
                alertSetting: settings.alertSetting,
                alertStyle: settings.alertStyle,
                soundSetting: settings.soundSetting,
                timeSensitiveSetting: settings.timeSensitiveSetting
            ))
        }
    }

    func requestAuthorization(
        options: UNAuthorizationOptions,
        completion: @escaping (Bool, Error?) -> Void
    ) {
        center.requestAuthorization(options: options, completionHandler: completion)
    }

    func add(_ request: UNNotificationRequest, completion: @escaping (Error?) -> Void) {
        center.add(request, withCompletionHandler: completion)
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    func getDeliveredNotifications(completion: @escaping ([UNNotification]) -> Void) {
        center.getDeliveredNotifications(completionHandler: completion)
    }
}

enum NotificationTestState: Equatable {
    case queued
    case delivered
    case notDelivered
}

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    typealias DelayScheduler = (TimeInterval, @escaping () -> Void) -> Void
    typealias TestEventHandler = (Result<NotificationTestState, Error>) -> Void

    private struct ActiveTest {
        let token: Int
        let handler: TestEventHandler
    }

    private struct WarningSchedule: Equatable {
        let date: Date
        let deadline: Date
        let sound: Bool
    }

    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "Notifications")
    private let warningIdentifier = "breakguard.warning"
    private let testIdentifier = "breakguard.test"
    private let client: UserNotificationCenterClient
    private let scheduleAfter: DelayScheduler
    // Client callbacks may be synchronous. Keep submitting and cancelling a
    // warning in one ordered operation without deadlocking those callbacks.
    private let lock = NSRecursiveLock()
    private var scheduledWarning: WarningSchedule?
    private var warningGeneration = 0
    private var activeTest: ActiveTest?
    private var testGeneration = 0

    init(
        client: UserNotificationCenterClient = SystemUserNotificationCenterClient(),
        scheduleAfter: @escaping DelayScheduler = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.client = client
        self.scheduleAfter = scheduleAfter
        super.init()
    }

    func configure() {
        client.delegate = self
    }

    func requestAuthorizationIfNeeded() {
        client.getCapabilities { [weak self, logger] capabilities in
            guard capabilities.authorizationStatus == .notDetermined else { return }
            self?.client.requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    logger.error("Notification authorization failed: \(error.localizedDescription)")
                } else {
                    logger.info("Notification authorization result: \(granted, privacy: .public)")
                }
            }
        }
    }

    func capabilities(_ completion: @escaping (NotificationCapabilities) -> Void) {
        client.getCapabilities(completion)
    }

    // `deadline` is when the break actually lands, so the title is always the
    // gap between this notification and that moment. Taking it as a date
    // rather than a duration is deliberate: the lead a cycle runs is not
    // settings.warningLeadTime — effectiveWarningLeadTime caps it at half the
    // window, and a call hold arms the warning against its own runway — and
    // a caller cannot pass a lead that disagrees with the schedule it just
    // asked for.
    func scheduleWarning(at date: Date, breakAt deadline: Date, settings: AppSettings) {
        guard settings.warningLeadTime > 0 else { cancelWarning(); return }
        guard date > Date() else { return }
        let schedule = WarningSchedule(date: date, deadline: deadline, sound: settings.notificationSound)
        guard let generation = beginWarningSchedule(schedule) else { return }

        client.getCapabilities { [weak self] capabilities in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            guard self.isCurrentWarning(generation: generation, schedule: schedule) else { return }
            let content = Self.warningContent(
                leadTime: deadline.timeIntervalSince(date),
                settings: settings,
                interruptionLevel: capabilities.supportsTimeSensitive ? .timeSensitive : .active
            )
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second],
                from: date
            )
            let request = UNNotificationRequest(
                identifier: self.warningIdentifier,
                content: content,
                trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            )
            self.client.add(request) { [weak self, logger = self.logger] error in
                guard let self else { return }
                if let error {
                    self.clearWarningIfCurrent(generation: generation, schedule: schedule)
                    logger.error("Warning scheduling failed: \(error.localizedDescription)")
                } else if self.isCurrentWarning(generation: generation, schedule: schedule) {
                    logger.info("Warning notification scheduled")
                }
                // A stale completion must not remove a newer request using
                // the same identifier. Cancellation already ordered its
                // removal after submission under the lock above.
            }
        }
    }

    func sendTestNotification(settings: AppSettings, eventHandler: @escaping TestEventHandler) {
        client.getCapabilities { [weak self] capabilities in
            guard let self else { return }
            switch capabilities.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                guard capabilities.canPresentAlerts else {
                    eventHandler(.failure(NotificationTestError.alertsDisabled))
                    return
                }
                self.scheduleTestNotification(settings: settings, eventHandler: eventHandler)
            case .notDetermined:
                self.client.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        eventHandler(.failure(error))
                    } else if granted {
                        self.scheduleTestNotification(settings: settings, eventHandler: eventHandler)
                    } else {
                        eventHandler(.failure(NotificationTestError.permissionDenied))
                    }
                }
            case .denied:
                eventHandler(.failure(NotificationTestError.permissionDenied))
            @unknown default:
                eventHandler(.failure(NotificationTestError.unavailable))
            }
        }
    }

    func cancelWarning() {
        lock.lock()
        defer { lock.unlock() }
        scheduledWarning = nil
        warningGeneration += 1
        client.removePendingNotificationRequests(withIdentifiers: [warningIdentifier])
    }

    // Shares formatDurationPhrase with the settings footers rather than
    // rounding to whole minutes on its own. The old rule reported a 90-second
    // lead as "2 minutes" — and rounding up is the dangerous direction, since
    // the title then promises time the countdown does not have.
    static func warningTitle(leadTime: TimeInterval) -> String {
        let seconds = max(0, Int(leadTime.rounded()))
        guard seconds > 0 else { return "Break starting now" }
        return "Break in \(formatDurationPhrase(TimeInterval(seconds)))"
    }

    static func warningContent(
        leadTime: TimeInterval,
        settings: AppSettings,
        interruptionLevel: UNNotificationInterruptionLevel
    ) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = warningTitle(leadTime: leadTime)
        content.body = "Save your work and finish the current task."
        if settings.notificationSound {
            content.sound = .default
        }
        content.interruptionLevel = interruptionLevel
        return content
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        recordDelivery(identifier: notification.request.identifier)
        return [.banner, .sound]
    }

    func recordDelivery(identifier: String) {
        guard identifier == testIdentifier else { return }
        finishActiveTest(with: .success(.delivered))
    }

    private func beginWarningSchedule(_ schedule: WarningSchedule) -> Int? {
        lock.lock()
        defer { lock.unlock() }
        if scheduledWarning == schedule { return nil }
        scheduledWarning = schedule
        warningGeneration += 1
        client.removePendingNotificationRequests(withIdentifiers: [warningIdentifier])
        return warningGeneration
    }

    private func isCurrentWarning(generation: Int, schedule: WarningSchedule) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return warningGeneration == generation && scheduledWarning == schedule
    }

    private func clearWarningIfCurrent(generation: Int, schedule: WarningSchedule) {
        lock.lock()
        defer { lock.unlock() }
        guard warningGeneration == generation, scheduledWarning == schedule else { return }
        scheduledWarning = nil
    }

    private func scheduleTestNotification(settings: AppSettings, eventHandler: @escaping TestEventHandler) {
        client.removePendingNotificationRequests(withIdentifiers: [testIdentifier])
        client.removeDeliveredNotifications(withIdentifiers: [testIdentifier])

        lock.lock()
        testGeneration += 1
        let token = testGeneration
        activeTest = ActiveTest(token: token, handler: eventHandler)
        lock.unlock()

        let request = UNNotificationRequest(
            identifier: testIdentifier,
            // The preview shows the configured lead: there is no cycle behind
            // it to cap or pin, so the setting is the honest answer here.
            content: Self.warningContent(
                leadTime: settings.warningLeadTime,
                settings: settings,
                interruptionLevel: .active
            ),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        client.add(request) { [weak self] error in
            guard let self else { return }
            if let error {
                self.finishTest(token: token, with: .failure(error))
                return
            }
            self.reportTest(token: token, result: .success(.queued))
            self.scheduleAfter(3) { [weak self] in
                self?.confirmTestDelivery(token: token)
            }
        }
    }

    private func confirmTestDelivery(token: Int) {
        client.getDeliveredNotifications { [weak self] notifications in
            guard let self else { return }
            let delivered = notifications.contains { $0.request.identifier == self.testIdentifier }
            self.finishTest(token: token, with: .success(delivered ? .delivered : .notDelivered))
        }
    }

    private func reportTest(token: Int, result: Result<NotificationTestState, Error>) {
        lock.lock()
        let handler = activeTest?.token == token ? activeTest?.handler : nil
        lock.unlock()
        handler?(result)
    }

    private func finishTest(token: Int, with result: Result<NotificationTestState, Error>) {
        lock.lock()
        guard activeTest?.token == token else {
            lock.unlock()
            return
        }
        let handler = activeTest?.handler
        activeTest = nil
        lock.unlock()
        handler?(result)
    }

    private func finishActiveTest(with result: Result<NotificationTestState, Error>) {
        lock.lock()
        guard let activeTest else {
            lock.unlock()
            return
        }
        self.activeTest = nil
        lock.unlock()
        activeTest.handler(result)
    }
}

private enum NotificationTestError: LocalizedError {
    case permissionDenied
    case alertsDisabled
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Notifications are disabled in System Settings."
        case .alertsDisabled: return "Notification alerts or banners are disabled in System Settings."
        case .unavailable: return "Notifications are currently unavailable."
        }
    }
}
