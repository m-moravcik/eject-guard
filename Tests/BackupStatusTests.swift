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
        XCTAssertEqual(status.percent ?? 0, 0.1 + 0.9 * 0.2464, accuracy: 0.0001)
    }

    /// Read off a real backup to a share, next to the Time Machine menu bar
    /// item, which said 13.5% while the copy alone was at 3.9%.
    func testThePercentMatchesTheTimeMachineMenu() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true),
            "BackupPhase": "Copying",
            "FractionOfProgressBar": "0.9",
            "Progress": ["Percent": "0.03888370181742058", "bytes": NSNumber(value: 9_788_899_328),
                         "totalBytes": NSNumber(value: 657_068_568_576)],
        ])
        XCTAssertEqual(status.percent ?? 0, 0.135, accuracy: 0.0005)
    }

    func testWithoutABarShareTheCopyFigureIsTakenAsItComes() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true), "BackupPhase": "Copying",
            "Progress": ["Percent": NSNumber(value: 0.25)],
        ])
        XCTAssertEqual(status.percent ?? 0, 0.25, accuracy: 0.0001)
    }

    func testNoNumberOutsideTheCopy() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true), "BackupPhase": "Finishing",
            "FractionOfProgressBar": NSNumber(value: 0.9), "Progress": ["Percent": NSNumber(value: 1)],
        ])
        XCTAssertTrue(status.running)
        XCTAssertNil(status.percent, "the system menu shows no number outside the copy")
    }

    func testAPercentPastTheEndStopsAtTheEnd() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true), "BackupPhase": "Copying",
            "FractionOfProgressBar": NSNumber(value: 0.9), "Progress": ["Percent": NSNumber(value: 1.2)],
        ])
        XCTAssertEqual(status.percent ?? 0, 1, accuracy: 0.0001)
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

    /// The case that started this: a backup to a share nobody ticked. Progress
    /// is shown for it all the same, under the share's own name.
    func testAnUnguardedShareIsNamedWhileItBacksUp() {
        let status = BackupStatus(plist: [
            "Running": NSNumber(value: true),
            "DestinationID": "NET-1",
            "DestinationMountPoint": "/Volumes/Backups of MekBuk-Pro",
            "Progress": ["Percent": NSNumber(value: 0.036)],
        ])
        let share = KnownDisk(id: "NET-1", name: "time_mbp_m5", tmDestinationID: "NET-1", network: true)
        let names = status.destinationNames(attached: [volume("/Volumes/WD", tm: "TM-1")], known: [share])
        XCTAssertEqual(names, ["time_mbp_m5"])
    }

    func testAPluggedInDiskIsNamedWhileItBacksUp() {
        let status = BackupStatus(plist: ["Running": NSNumber(value: true), "DestinationID": "TM-1"])
        let names = status.destinationNames(
            attached: [volume("/Volumes/WD", tm: "TM-1"), volume("/Volumes/Sync")], known: [])
        XCTAssertEqual(names, ["WD"])
    }

    func testABackupWithNoDestinationNamesNoDisk() {
        let status = BackupStatus(plist: ["Running": NSNumber(value: true)])
        XCTAssertEqual(status.destinationNames(attached: [volume("/Volumes/Sync")], known: []), [],
                       "naming every disk plugged in would be a guess")
    }

    func testAnIdleStatusNamesNothing() {
        let status = BackupStatus(plist: ["Running": NSNumber(value: false), "DestinationID": "TM-1"])
        XCTAssertEqual(status.destinationNames(attached: [volume("/Volumes/WD", tm: "TM-1")], known: []), [])
    }

    func testAnyReachableDestinationIsWorthWatchingGuardedOrNot() {
        var config = GuardConfig()
        XCTAssertFalse(Disks.hasTimeMachineTarget(config, among: []))
        XCTAssertFalse(Disks.hasTimeMachineTarget(config, among: [volume("/Volumes/Sync")]),
                       "a plain disk can never be backed up to")
        XCTAssertTrue(Disks.hasTimeMachineTarget(config, among: [volume("/Volumes/WD", tm: "TM-1")]))

        config.knownDisks = [KnownDisk(id: "NET-1", name: "NAS", tmDestinationID: "NET-1", network: true)]
        XCTAssertTrue(Disks.hasTimeMachineTarget(config, among: []), "a share is always reachable")

        config.knownDisks = [KnownDisk(id: "UUID-1", name: "WD", volumeUUID: "UUID-1", tmDestinationID: "TM-1")]
        XCTAssertFalse(Disks.hasTimeMachineTarget(config, among: []))
        let plugged = AttachedVolume(path: "/Volumes/WD", name: "WD", volumeUUID: "UUID-1", tmDestinationID: nil)
        XCTAssertTrue(Disks.hasTimeMachineTarget(config, among: [plugged]),
                      "a known destination counts even when this scan missed its Time Machine link")
    }

    private func volume(_ path: String, tm: String? = nil) -> AttachedVolume {
        AttachedVolume(path: path, name: "WD", volumeUUID: nil, tmDestinationID: tm)
    }

    func testGarbageIsNotRunning() {
        XCTAssertFalse(BackupStatus(plist: [:]).running)
    }
}
