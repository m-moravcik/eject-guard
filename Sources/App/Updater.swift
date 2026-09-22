// The Sparkle half of in-app updates. Everything that does not need the
// framework lives in UpdaterProtocol.swift.
//
// The shape follows VibeRes, the sibling utility: a protocol with a real and a
// no-op implementation chosen by a factory, so an ad-hoc development build
// cannot download and run a binary from the internet, and so the popover has
// something to render when updates are off.
//
// Sparkle's normal flow installs on quit. A menu bar app runs for weeks, so
// "on quit" can mean "never". The install-on-quit hook is therefore captured
// and turned into a row the user can click.

import AppKit
import Security
import Sparkle
import SwiftUI

// MARK: - Signature check

/// True when the bundle carries a Developer ID Application signature from our
/// team.
///
/// Sparkle's EdDSA signature on the downloaded archive is a separate and
/// equally necessary check: this one says *we* are the thing running, that one
/// says the thing we fetched came from us. Neither substitutes for the other.
func isDeveloperIDSigned(bundleURL: URL) -> Bool {
    var staticCode: SecStaticCode?
    guard SecStaticCodeCreateWithPath(bundleURL as CFURL, [], &staticCode) == errSecSuccess,
          let staticCode
    else { return false }

    var requirement: SecRequirement?
    let text = "anchor apple generic and certificate leaf[subject.OU] = \"7TM9VA58W5\"" as CFString
    guard SecRequirementCreateWithString(text, [], &requirement) == errSecSuccess,
          let requirement
    else { return false }

    return SecStaticCodeCheckValidity(staticCode, [], requirement) == errSecSuccess
}

// MARK: - Sparkle

@MainActor
final class SparkleUpdaterController: NSObject, UpdaterProviding,
                                      SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Sparkle hands us a closure to trigger the staged install. Boxed because
    /// it outlives the callback that produced it.
    private final class InstallHandler {
        private let run: () -> Void
        init(_ run: @escaping () -> Void) { self.run = run }
        func callAsFunction() { run() }
    }

    let updateStatus = UpdateStatus()
    let isAvailable = true
    let unavailableReason: UpdaterGate.Reason? = nil

    private var controller: SPUStandardUpdaterController!
    private var installHandler: InstallHandler?

    override init() {
        super.init()
        controller = SPUStandardUpdaterController(
            startingUpdater: false,
            updaterDelegate: self,
            userDriverDelegate: self
        )
        controller.startUpdater()
    }

    /// Bound straight to Sparkle, which persists it. Sparkle's own header is
    /// explicit that an app should not keep a second copy in its defaults.
    var automaticallyChecksForUpdates: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            controller.updater.automaticallyChecksForUpdates = newValue
            // Downloading ahead of time is what makes the install click
            // instant, and is also what makes willInstallUpdateOnQuit fire.
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    func checkForUpdates() {
        // No Dock icon, so Sparkle's window would otherwise open behind
        // whatever the user is working in, with no way to reach it.
        NSApp.activate(ignoringOtherApps: true)
        controller.updater.checkForUpdates()
    }

    func installUpdate() {
        guard let installHandler else { return }
        self.installHandler = nil
        updateStatus.isUpdateReady = false
        installHandler()
    }

    private func apply(_ event: UpdateReadiness.Event) {
        updateStatus.isUpdateReady = UpdateReadiness.next(
            after: event,
            currentlyReady: updateStatus.isUpdateReady
        )
        if !updateStatus.isUpdateReady { installHandler = nil }
    }

    // MARK: SPUUpdaterDelegate
    //
    // Plain main-actor methods: the protocol is NS_SWIFT_UI_ACTOR, so hopping
    // through a detached Task would only reintroduce ordering races.

    func updater(
        _ updater: SPUUpdater,
        willInstallUpdateOnQuit item: SUAppcastItem,
        immediateInstallationBlock immediateInstallHandler: @escaping () -> Void
    ) -> Bool {
        installHandler = InstallHandler(immediateInstallHandler)
        apply(.queuedForInstallOnQuit)
        // Taking over the *timing* of the install. Sparkle still installs on
        // quit regardless; this is not a way to suppress its UI.
        return true
    }

    func updater(_ updater: SPUUpdater, failedToDownloadUpdate item: SUAppcastItem, error: Error) {
        Log.write("update download failed: \(Sanitize.oneLine(error.localizedDescription))")
        apply(.downloadFailed)
    }

    func userDidCancelDownload(_ updater: SPUUpdater) {
        apply(.downloadCancelled)
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        apply(.aborted)
    }

    func updater(
        _ updater: SPUUpdater,
        userDidMake choice: SPUUserUpdateChoice,
        forUpdate updateItem: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        switch choice {
        case .install: apply(.userChoseInstall)
        case .skip: apply(.userChoseSkip)
        case .dismiss: apply(.userDismissed(downloaded: state.stage == .downloaded))
        @unknown default: apply(.aborted)
        }
    }

    func updater(
        _ updater: SPUUpdater,
        didFinishUpdateCycleFor updateCheck: SPUUpdateCheck,
        error: Error?
    ) {
        apply(.cycleFinished)
    }

    // MARK: SPUStandardUserDriverDelegate
    //
    // Unlike SPUUpdaterDelegate this protocol is not annotated for the main
    // actor, so its members are nonisolated and hop explicitly.

    /// Required for background apps: Sparkle's documentation is explicit that a
    /// dockless app must implement this, or scheduled alerts appear behind
    /// everything with no Dock icon to bring them forward.
    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }

    nonisolated func standardUserDriverShouldHandleShowingScheduledUpdate(
        _ update: SUAppcastItem,
        andInImmediateFocus immediateFocus: Bool
    ) -> Bool {
        // A scheduled find is surfaced by our own popover row instead.
        false
    }

    nonisolated func standardUserDriverWillHandleShowingUpdate(
        _ handleShowingUpdate: Bool,
        forUpdate update: SUAppcastItem,
        state: SPUUserUpdateState
    ) {
        // Anything Sparkle does show needs the app brought forward first.
        guard state.userInitiated else { return }
        Task { @MainActor in NSApp.activate(ignoringOtherApps: true) }
    }
}

/// Chooses the real updater or the no-op one. The decision itself is in
/// `UpdaterGate`, which is pure and therefore testable; this only supplies the
/// two measurements it needs.
@MainActor
func makeUpdaterController() -> any UpdaterProviding {
    let bundleURL = Bundle.main.bundleURL
    switch UpdaterGate.decide(
        bundleURL: bundleURL,
        isDeveloperIDSigned: isDeveloperIDSigned(bundleURL: bundleURL)
    ) {
    case .enabled:
        return SparkleUpdaterController()
    case .disabled(let reason):
        return DisabledUpdaterController(reason: reason)
    }
}
