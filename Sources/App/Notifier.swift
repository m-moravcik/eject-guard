import AppKit
import Foundation
import UserNotifications

/// Posts real user notifications through the app bundle.
///
/// Only the bundled app may use this: `UNUserNotificationCenter.current()`
/// traps when the running executable has no bundle identifier, which is why the
/// command line tool keeps the AppleScript fallback.
@MainActor
enum AppNotifier {
    private static let delegate = ForegroundDelegate()
    private static let openSettingsButton = "openSettings"

    static func install() {
        let center = UNUserNotificationCenter.current()
        center.delegate = delegate
        // One category per action, named after it, so a click finds its way
        // back from the notification alone.
        center.setNotificationCategories([
            UNNotificationCategory(
                identifier: Notify.Action.openFullDiskAccess.rawValue,
                actions: [UNNotificationAction(identifier: openSettingsButton,
                                               title: Loc.t("notify.openSettings", "Open Settings"))],
                intentIdentifiers: []),
        ])
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                Log.write("notification authorization failed: \(error.localizedDescription)")
            } else if !granted {
                Log.write("notifications not allowed - ejects will be silent")
            }
        }

        Notify.setHandler { title, body, action in
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            if let action { content.categoryIdentifier = action.rawValue }
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

    /// NSWorkspace may be called from any thread, and the delegate is not
    /// promised the main one.
    nonisolated static func perform(_ action: Notify.Action) {
        switch action {
        case .openFullDiskAccess:
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") else { return }
            NSWorkspace.shared.open(url)
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

    /// A click on the banner does what its button does: there is only ever
    /// one thing to open.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier != UNNotificationDismissActionIdentifier,
           let action = Notify.Action(rawValue: response.notification.request.content.categoryIdentifier) {
            AppNotifier.perform(action)
        }
        completionHandler()
    }
}
