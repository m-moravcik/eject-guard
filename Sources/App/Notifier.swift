import Foundation
import UserNotifications

/// Posts real user notifications through the app bundle.
///
/// Only the bundled app may use this: `UNUserNotificationCenter.current()`
/// traps when the running executable has no bundle identifier, which is why the
/// command line tool keeps the AppleScript fallback.
enum AppNotifier {
    private static let delegate = ForegroundDelegate()

    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.write("notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                Log.write("notifications not allowed - ejects will be silent")
            }
        }

        Notify.setHandler { title, body in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            // No trigger means deliver immediately.
            let request = UNNotificationRequest(
                identifier: UUID().uuidString, content: content, trigger: nil)
            center.add(request) { error in
                if let error {
                    Log.write("notification failed: \(error.localizedDescription)")
                }
            }
        }
    }
}

/// A menu bar accessory is never the frontmost app in the usual sense, but ask
/// for the banner explicitly so a notification is never swallowed.
private final class ForegroundDelegate: NSObject, UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
}
