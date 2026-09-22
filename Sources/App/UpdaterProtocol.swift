// The updater as the rest of the app sees it.
//
// Deliberately free of `import Sparkle`: the popover, Settings and the preview
// harness all talk to this protocol, so only one file in the project needs the
// framework, and the harness that renders the popover to PNG can be built
// without it.

import SwiftUI

@MainActor
protocol UpdaterProviding: AnyObject, Sendable {
    var automaticallyChecksForUpdates: Bool { get set }
    var isAvailable: Bool { get }
    /// Why updates are off. Nil when they are on.
    var unavailableReason: UpdaterGate.Reason? { get }
    var updateStatus: UpdateStatus { get }
    func checkForUpdates()
    func installUpdate()
}

/// Drives the popover's "update ready" row.
@MainActor
@Observable
final class UpdateStatus {
    var isUpdateReady: Bool

    init(isUpdateReady: Bool = false) {
        self.isUpdateReady = isUpdateReady
    }
}

/// Used when this build must not update itself, and by the preview harness.
/// Carries the reason so Settings can say what is going on rather than showing
/// a dead control.
@MainActor
final class DisabledUpdaterController: UpdaterProviding {
    var automaticallyChecksForUpdates = false
    let isAvailable = false
    let unavailableReason: UpdaterGate.Reason?
    let updateStatus = UpdateStatus()

    init(reason: UpdaterGate.Reason?) {
        self.unavailableReason = reason
    }

    func checkForUpdates() {}
    func installUpdate() {}
}

// MARK: - Environment plumbing

/// The updater is a protocol existential, which SwiftUI's `@Observable`
/// environment injection cannot carry. `UpdateStatus` goes through that path
/// because it drives a view; the controller itself goes through a plain key
/// because views only ever call methods on it.
///
/// Optional because `EnvironmentKey.defaultValue` has to be nonisolated while
/// every conformer is main-actor bound. A nil default is honest anyway: a view
/// rendered without the app around it has no updater rather than a fake one.
private struct UpdaterKey: EnvironmentKey {
    static let defaultValue: (any UpdaterProviding)? = nil
}

extension EnvironmentValues {
    var updater: (any UpdaterProviding)? {
        get { self[UpdaterKey.self] }
        set { self[UpdaterKey.self] = newValue }
    }
}
