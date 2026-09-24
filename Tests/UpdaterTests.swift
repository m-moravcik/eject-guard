import XCTest
@testable import TMEjectGuardCore

/// The gate is the security boundary of the updater: if it says yes, the app is
/// allowed to download and execute a binary from the internet. These are the
/// tests that a development build can never reach that state.
final class UpdaterGateTests: XCTestCase {
    private let installed = URL(fileURLWithPath: "/Applications/Eject Guard.app")

    func testSignedInstalledBundleMayUpdate() {
        XCTAssertEqual(
            UpdaterGate.decide(bundleURL: installed, isDeveloperIDSigned: true),
            .enabled)
    }

    func testUnsignedBundleMayNotUpdate() {
        XCTAssertEqual(
            UpdaterGate.decide(bundleURL: installed, isDeveloperIDSigned: false),
            .disabled(reason: .notSigned))
    }

    /// build.sh ad-hoc signs, so this is the case that covers every local build.
    func testAdHocBuildInTheBuildDirectoryMayNotUpdate() {
        let local = URL(fileURLWithPath: "/Users/someone/src/build/Eject Guard.app")
        XCTAssertEqual(
            UpdaterGate.decide(bundleURL: local, isDeveloperIDSigned: false),
            .disabled(reason: .notSigned))
    }

    /// A loose binary has nowhere to install an update to.
    func testLooseBinaryMayNotUpdate() {
        let binary = URL(fileURLWithPath: "/usr/local/bin/eject-guard")
        XCTAssertEqual(
            UpdaterGate.decide(bundleURL: binary, isDeveloperIDSigned: true),
            .disabled(reason: .notABundle))
    }

    /// The signature is checked before the path, so an unsigned copy is never
    /// told the problem is where it lives.
    func testSignatureIsReportedBeforeLocation() {
        let binary = URL(fileURLWithPath: "/usr/local/bin/eject-guard")
        XCTAssertEqual(
            UpdaterGate.decide(bundleURL: binary, isDeveloperIDSigned: false),
            .disabled(reason: .notSigned))
    }
}

/// Every callback that can end an update has to clear the "update ready" row.
/// Miss one and the row advertises an update that is no longer there, which the
/// user clicks and nothing happens.
final class UpdateReadinessTests: XCTestCase {
    func testOnlyQueuedForInstallTurnsTheRowOn() {
        XCTAssertTrue(UpdateReadiness.next(after: .queuedForInstallOnQuit, currentlyReady: false))
    }

    func testEveryFailureClearsTheRow() {
        for event: UpdateReadiness.Event in [.downloadFailed, .downloadCancelled, .aborted] {
            XCTAssertFalse(
                UpdateReadiness.next(after: event, currentlyReady: true),
                "\(event) left the row on")
        }
    }

    func testActingThroughSparklesOwnWindowClearsTheRow() {
        for event: UpdateReadiness.Event in [.userChoseInstall, .userChoseSkip] {
            XCTAssertFalse(
                UpdateReadiness.next(after: event, currentlyReady: true),
                "\(event) left the row on")
        }
    }

    /// Dismissing an alert does not discard a finished download.
    func testDismissKeepsADownloadedUpdate() {
        XCTAssertTrue(
            UpdateReadiness.next(after: .userDismissed(downloaded: true), currentlyReady: false))
        XCTAssertFalse(
            UpdateReadiness.next(after: .userDismissed(downloaded: false), currentlyReady: true))
    }

    /// A scheduled check finishing says nothing about an update already offered.
    func testCycleFinishedIsNeutral() {
        XCTAssertTrue(UpdateReadiness.next(after: .cycleFinished, currentlyReady: true))
        XCTAssertFalse(UpdateReadiness.next(after: .cycleFinished, currentlyReady: false))
    }
}
