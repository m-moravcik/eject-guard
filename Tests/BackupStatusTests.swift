import XCTest
@testable import TMEjectGuardCore

/// Parsing is separated from running `tmutil` so the awkward values it reports
/// can be pinned down without a backup actually running.
final class BackupStatusTests: XCTestCase {
    func testIdle() {
        let status = BackupStatus(plist: ["Running": NSNumber(value: false)])
        XCTAssertFalse(status.running)
        XCTAssertNil(status.percent)
    }

    func testRunningWithProgress() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true),
            "Percent": NSNumber(value: 0.42),
            "DestinationMountPoint": "/Volumes/WD",
        ])
        XCTAssertTrue(status.running)
        XCTAssertEqual(status.percent ?? 0, 0.42, accuracy: 0.0001)
        XCTAssertTrue(status.isBackingUp(to: volume("/Volumes/WD")))
        XCTAssertFalse(status.isBackingUp(to: volume("/Volumes/Other")))
    }

    /// The shape `tmutil status -X` really returns on macOS 26: the figure sits
    /// inside `Progress`, and nothing called Percent exists at the top level.
    func testPercentNestedUnderProgress() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true),
            "BackupPhase": "Copying",
            "DestinationMountPoint": "/Volumes/WD",
            "FractionOfProgressBar": NSNumber(value: 0.9),
            "Progress": ["Percent": NSNumber(value: 0.2464), "TimeRemaining": NSNumber(value: 341.7)],
        ])
        XCTAssertEqual(status.percent ?? 0, 0.2464, accuracy: 0.0001)
    }

    func testMinusOneNestedUnderProgressIsStillUnknown() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true), "Progress": ["Percent": NSNumber(value: -1)],
        ])
        XCTAssertNil(status.percent)
    }

    func testMinusOnePercentMeansUnknownNotZero() {
        // tmutil reports -1 while it is still sizing the job up.
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true), "Percent": NSNumber(value: -1),
        ])
        XCTAssertTrue(status.running)
        XCTAssertNil(status.percent)
    }

    func testPercentAsAString() {
        let status = BackupStatus(plist: ["Running": NSNumber(value: true), "Percent": "0.5"])
        XCTAssertEqual(status.percent ?? 0, 0.5, accuracy: 0.0001)
    }

    func testARunningBackupWithNoDestinationCountsAgainstTheDiskWeAreEjecting() {
        let status = BackupStatus(plist: ["Running": NSNumber(value: true)])
        XCTAssertTrue(status.isBackingUp(to: volume("/Volumes/WD")),
                      "better to stop a backup that was not ours than eject under one that was")
    }

    /// What `tmutil status -X` reported during a real backup to an SMB share:
    /// the mount point is the disk image inside it, and only the destination
    /// ID says where the backup is going.
    func testANetworkBackupIsMatchedByDestinationNotMountPoint() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true),
            "BackupPhase": "PreparingSourceVolumes",
            "DestinationID": "NET-1",
            "DestinationMountPoint": "/Volumes/Backups of MekBuk-Pro",
            "Percent": NSNumber(value: -1),
        ])
        XCTAssertEqual(status.destinationID, "NET-1")
        XCTAssertTrue(status.isBackingUp(toDestination: "NET-1"))
        XCTAssertFalse(status.isBackingUp(toDestination: "TM-1"))
        XCTAssertFalse(status.isBackingUp(toDestination: nil))
        XCTAssertFalse(status.isBackingUp(to: volume("/Volumes/WD", tm: "TM-1")),
                       "a network backup must not show as one to a plugged-in disk")
        XCTAssertFalse(status.isBackingUp(to: volume("/Volumes/WD")))
    }

    func testTheDestinationIDWinsOverTheMountPointForAPluggedInDisk() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true), "DestinationID": "TM-1",
        ])
        XCTAssertTrue(status.isBackingUp(to: volume("/Volumes/WD", tm: "TM-1")))
        XCTAssertFalse(status.isBackingUp(to: volume("/Volumes/Other", tm: "TM-2")))
    }

    func testAnIdleStatusIsNotBackingUpToAnyDestination() {
        let status = BackupStatus(plist: ["Running": NSNumber(value: false), "DestinationID": "NET-1"])
        XCTAssertFalse(status.isBackingUp(toDestination: "NET-1"))
    }

    private func volume(_ path: String, tm: String? = nil) -> AttachedVolume {
        AttachedVolume(path: path, name: "WD", volumeUUID: nil, tmDestinationID: tm)
    }

    func testGarbageIsNotRunning() {
        XCTAssertFalse(BackupStatus(plist: [:]).running)
    }
}
