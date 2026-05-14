import Foundation
import UserNotifications

enum NotificationService {
    private static var isAvailable: Bool = {
        guard Bundle.main.bundleIdentifier != nil else { return false }
        return true
    }()

    private static var hasPermission = false

    static func requestPermission() {
        guard isAvailable else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            hasPermission = granted
        }
    }

    static func send(title: String, body: String, identifier: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
