import AppKit
import SwiftUI

@main
struct EjectGuardApp: App {
    @State private var controller: GuardController
    /// Not @State: the updater is created once and never replaced, and the
    /// thing views observe is its `updateStatus`, not the controller itself.
    private let updater: any UpdaterProviding

    init() {
        // Must happen before anything can eject: the notification path is set up
        // here, not in the controller, because the preview harness has no bundle
        // and UNUserNotificationCenter traps without one.
        AppNotifier.install()
        let controller = GuardController()
        controller.start()
        // Repair a login item registration that dropped without the user
        // touching the toggle, as a replaced or moved bundle makes it do.
        let storedIntent = ConfigStore.load().launchAtLoginIntent
        let intent = LoginItem.reconcile(storedIntent: storedIntent)
        if intent != storedIntent { controller.update { $0.launchAtLoginIntent = intent } }
        _controller = State(initialValue: controller)
        // Returns the no-op updater unless this is an installed, Developer ID
        // signed bundle. See UpdaterGate.
        updater = makeUpdaterController()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(controller)
                .environment(updater.updateStatus)
                .environment(\.updater, updater)
        } label: {
            StatusIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
                .environment(updater.updateStatus)
                .environment(\.updater, updater)
        }
    }
}
