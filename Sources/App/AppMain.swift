import AppKit
import SwiftUI

@main
struct TMEjectGuardApp: App {
    @State private var controller: GuardController

    init() {
        // Must happen before anything can eject: the notification path is set up
        // here, not in the controller, because the preview harness has no bundle
        // and UNUserNotificationCenter traps without one.
        AppNotifier.install()
        let controller = GuardController()
        controller.start()
        _controller = State(initialValue: controller)
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent()
                .environment(controller)
        } label: {
            Image(systemName: statusSymbol)
                .accessibilityLabel("TM Eject Guard")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }

    /// The icon carries the only state worth reading at a glance: whether a
    /// disk is actually being guarded right now.
    private var statusSymbol: String {
        if controller.isBusy { return "externaldrive.badge.minus" }
        if !controller.config.isActive { return "externaldrive.badge.xmark" }
        if controller.guardedVolumes.isEmpty { return "externaldrive" }
        return "externaldrive.badge.checkmark"
    }
}
