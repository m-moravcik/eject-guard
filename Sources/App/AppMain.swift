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
            StatusIcon(controller: controller)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(controller)
        }
    }
}

/// The menu bar icon, and the only state most people will ever read.
///
/// A View rather than a computed symbol name in the Scene body: observation is
/// registered when a view body is evaluated, so this is what reliably redraws
/// when a disk is plugged in or an eject starts.
private struct StatusIcon: View {
    let controller: GuardController

    private enum State {
        case ejecting, off, armed, idle
    }

    private var state: State {
        if controller.isBusy { return .ejecting }
        if !controller.config.isActive { return .off }
        return controller.guardedVolumes.isEmpty ? .idle : .armed
    }

    /// Each state gets its own shape, not just a different badge. A badge swap
    /// is too quiet to notice during the few seconds an eject takes.
    private var symbol: String {
        switch state {
        case .ejecting: return "eject.fill"
        case .off: return "externaldrive.badge.xmark"
        case .armed: return "externaldrive.fill.badge.checkmark"
        case .idle: return "externaldrive"
        }
    }

    private var label: String {
        switch state {
        case .ejecting: return "Ejecting"
        case .off: return "Guarding is off"
        case .armed:
            let names = controller.guardedVolumes.map(\.name).joined(separator: ", ")
            return "Guarding \(names)"
        case .idle: return "No guarded disk connected"
        }
    }

    var body: some View {
        Image(systemName: symbol)
            .accessibilityLabel("TM Eject Guard: \(label)")
    }
}
