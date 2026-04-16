import Foundation
import UserNotifications
import Observation

@Observable
class NotificationManager: @unchecked Sendable {
    static let shared = NotificationManager()

    private(set) var isAuthorized = false

    func requestPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                self.isAuthorized = granted
            }
        }
    }

    func notifyCycleComplete(appliance: String, id: String) {
        guard isAuthorized else { return }

        let content = UNMutableNotificationContent()
        content.title = "\(appliance) Done"
        content.body = "Your \(appliance.lowercased()) has finished its cycle."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "cycle_\(id)",
            content: content,
            trigger: nil // deliver immediately
        )

        UNUserNotificationCenter.current().add(request)
    }
}
