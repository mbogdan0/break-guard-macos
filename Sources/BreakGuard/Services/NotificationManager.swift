import Foundation
import UserNotifications
import os

final class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    private let logger = Logger(subsystem: "local.bohdan.BreakGuard", category: "Notifications")
    private let warningIdentifier = "breakguard.warning"
    private let testIdentifier = "breakguard.test"
    private var scheduledWarningDate: Date?

    func configure() {
        UNUserNotificationCenter.current().delegate = self
    }

    func requestAuthorizationIfNeeded() {
        UNUserNotificationCenter.current().getNotificationSettings { [logger] settings in
            guard settings.authorizationStatus == .notDetermined else { return }
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
                if let error {
                    logger.error("Notification authorization failed: \(error.localizedDescription)")
                } else {
                    logger.info("Notification authorization result: \(granted, privacy: .public)")
                }
            }
        }
    }

    func authorizationStatus(_ completion: @escaping (UNAuthorizationStatus) -> Void) {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            completion(settings.authorizationStatus)
        }
    }

    func scheduleWarning(at date: Date, settings: AppSettings) {
        guard settings.warningLeadTime > 0, date > Date() else { return }
        if let scheduledWarningDate, abs(scheduledWarningDate.timeIntervalSince(date)) < 1 {
            return
        }
        cancelWarning()
        scheduledWarningDate = date
        let content = warningContent(settings: settings)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        let request = UNNotificationRequest(identifier: warningIdentifier, content: content, trigger: trigger)
        UNUserNotificationCenter.current().add(request) { [logger] error in
            if let error {
                logger.error("Warning scheduling failed: \(error.localizedDescription)")
            } else {
                logger.info("Warning notification scheduled")
            }
        }
    }

    func sendTestNotification(settings: AppSettings, completion: @escaping (Result<Void, Error>) -> Void) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { [weak self] notificationSettings in
            guard let self else { return }
            switch notificationSettings.authorizationStatus {
            case .authorized, .provisional, .ephemeral:
                self.scheduleTestNotification(settings: settings, completion: completion)
            case .notDetermined:
                center.requestAuthorization(options: [.alert, .sound]) { granted, error in
                    if let error {
                        completion(.failure(error))
                    } else if granted {
                        self.scheduleTestNotification(settings: settings, completion: completion)
                    } else {
                        completion(.failure(NotificationTestError.permissionDenied))
                    }
                }
            case .denied:
                completion(.failure(NotificationTestError.permissionDenied))
            @unknown default:
                completion(.failure(NotificationTestError.unavailable))
            }
        }
    }

    func cancelWarning() {
        scheduledWarningDate = nil
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [warningIdentifier])
    }

    private func scheduleTestNotification(
        settings: AppSettings,
        completion: @escaping (Result<Void, Error>) -> Void
    ) {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [testIdentifier])
        center.removeDeliveredNotifications(withIdentifiers: [testIdentifier])
        let request = UNNotificationRequest(
            identifier: testIdentifier,
            content: warningContent(settings: settings),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        )
        center.add(request) { error in
            if let error {
                completion(.failure(error))
            } else {
                completion(.success(()))
            }
        }
    }

    private func warningContent(settings: AppSettings) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Break in 1 minute"
        content.body = "Save your work and finish the current task."
        if settings.notificationSound {
            content.sound = .default
        }
        return content
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}

private enum NotificationTestError: LocalizedError {
    case permissionDenied
    case unavailable

    var errorDescription: String? {
        switch self {
        case .permissionDenied: return "Notifications are disabled in System Settings."
        case .unavailable: return "Notifications are currently unavailable."
        }
    }
}
