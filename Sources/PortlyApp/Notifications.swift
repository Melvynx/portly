import Foundation
import UserNotifications

/// Only fires for terminal failures. Every automatic restart notifying would be
/// noise, and noise gets muted, which defeats the point.
enum Notifications {
    private static var authorized = false

    static func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            authorized = granted
        }
    }

    static func serverFailed(name: String, project: String, reason: String?) {
        guard authorized else { return }
        let content = UNMutableNotificationContent()
        content.title = "\(name) stopped"
        content.body = reason ?? "\(project): the server failed and Portly stopped restarting it."
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "portly.failed.\(name).\(Int(Date().timeIntervalSince1970))",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request)
    }
}
