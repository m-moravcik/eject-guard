import XCTest
@testable import TMEjectGuardCore

/// The guarantees this tool rests on. If any of these break, it can damage
/// something rather than merely fail to help.
final class SafetyTests: XCTestCase {
    func testTheBootVolumeIsNeverAnEjectCandidate() {
        XCTAssertFalse(Disks.isMountedVolume("/"))
        XCTAssertFalse(Disks.isMountedVolume("/System/Volumes/Data"))
        XCTAssertFalse(Disks.isMountedVolume("/Users"))
    }

    func testOnlyDirectChildrenOfVolumesQualify() {
        XCTAssertFalse(Disks.isMountedVolume("/Volumes"))
        XCTAssertFalse(Disks.isMountedVolume("/Volumes/"))
        XCTAssertFalse(Disks.isMountedVolume("/Volumes/Some Disk/subfolder"))
        XCTAssertFalse(Disks.isMountedVolume("/Volumes/definitely not mounted \(UUID().uuidString)"))
        XCTAssertFalse(Disks.isMountedVolume("../Volumes/escape"))
        XCTAssertFalse(Disks.isMountedVolume(""))
    }

    func testUntrustedTextCannotForgeALogLineOrBreakAppleScript() {
        let hostile = "Standup\nnot a real log line\r\u{0000}"
        let cleaned = Sanitize.oneLine(hostile)

        XCTAssertFalse(cleaned.contains("\n"))
        XCTAssertFalse(cleaned.contains("\r"))
        XCTAssertFalse(cleaned.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertTrue(cleaned.hasPrefix("Standup"))
    }

    func testSanitiseCapsLength() {
        let long = String(repeating: "a", count: 5_000)
        XCTAssertLessThanOrEqual(Sanitize.oneLine(long, max: 200).count, 201)
    }

    func testSanitiseLeavesOrdinaryTitlesAlone() {
        let title = "Weekly sync/review - príprava (Room 8.20)"
        XCTAssertEqual(Sanitize.oneLine(title), title)
    }
}

/// Values read off real hardware on 2026-09-22, when a 3 TB external USB Time
/// Machine disk turned out to report `ejectable == false` and therefore never
/// appeared in the app. A disk image fixture reported `true` and hid it.
final class VolumeEligibilityTests: XCTestCase {
    func testExternalUsbHardDiskIsGuardable() {
        // /Volumes/Time Machine WD, WD 3 TB over USB, APFS.
        XCTAssertTrue(Disks.isGuardable(isInternal: false, isLocal: true, isRootFileSystem: false))
    }

    func testDiskImageIsTurnedAwayByItsDeviceModel() {
        // /Volumes/cmux, an app installer .dmg, read on 2026-09-28. It passes
        // the volume checks - internal nil, local true - so only the device
        // model tells it apart from an external disk.
        XCTAssertTrue(Disks.isGuardable(isInternal: nil, isLocal: true, isRootFileSystem: false))
        XCTAssertTrue(Disks.isDiskImage(deviceModel: "Disk Image"))
    }

    func testARealDiskIsNotADiskImage() {
        XCTAssertFalse(Disks.isDiskImage(deviceModel: "APPLE SSD AP1024Z"))
        // USB bridges pad their model strings.
        XCTAssertFalse(Disks.isDiskImage(deviceModel: "Elements 25A3    "))
    }

    func testAnUnknownDeviceModelCountsAsARealDisk() {
        // Hiding a real disk is the silent failure; listing an image is not.
        XCTAssertFalse(Disks.isDiskImage(deviceModel: nil))
    }

    func testBootVolumeIsNot() {
        XCTAssertFalse(Disks.isGuardable(isInternal: true, isLocal: true, isRootFileSystem: true))
    }

    func testInternalSystemVolumeIsNot() {
        // /System/Volumes/VM, Preboot, and friends.
        XCTAssertFalse(Disks.isGuardable(isInternal: true, isLocal: true, isRootFileSystem: false))
    }

    func testNetworkMountIsNot() {
        // Nothing to eject on an autofs or SMB mount.
        XCTAssertFalse(Disks.isGuardable(isInternal: nil, isLocal: false, isRootFileSystem: false))
    }

    func testUnknownLocalityIsNot() {
        XCTAssertFalse(Disks.isGuardable(isInternal: false, isLocal: nil, isRootFileSystem: false))
    }

    func testEjectableIsDeliberatelyNotConsulted() {
        // The real disk reports ejectable false. If this predicate ever starts
        // depending on it again, the tool silently stops working.
        let real = Disks.isGuardable(isInternal: false, isLocal: true, isRootFileSystem: false)
        XCTAssertTrue(real, "a fixed external disk reports ejectable == false")
    }
}

/// Which volume notifications are worth a rescan. Paths are the mounts seen in
/// the system log on 2026-09-26..28, each one second before a `tmutil
/// destinationinfo` that hung past SIGKILL.
final class RescanTriggerTests: XCTestCase {
    func testAPluggedInDiskIsNeverMissed() {
        XCTAssertTrue(Disks.mayChangeDiskList(volumePath: "/Volumes/Time Machine WD"))
        XCTAssertTrue(Disks.mayChangeDiskList(volumePath: "/Volumes/cmux"))
    }

    func testAnUnknownPathRescans() {
        // A missed disk is worse than one extra scan.
        XCTAssertTrue(Disks.mayChangeDiskList(volumePath: nil))
    }

    func testTimeMachineSnapshotMountsDoNot() {
        XCTAssertFalse(Disks.mayChangeDiskList(volumePath:
            "/Volumes/com.apple.TimeMachine.localsnapshots/Backups.backupdb/MekBuk-Pro/2026-09-20-223706/Data"))
        XCTAssertFalse(Disks.mayChangeDiskList(volumePath:
            "/Volumes/.timemachine/4F85D473-0835-475D-951B-EAB250EC9492/2026-09-12-170727.backup/2026-09-12-170727.backup"))
    }

    func testANetworkBackupShareDoesNot() {
        XCTAssertFalse(Disks.mayChangeDiskList(volumePath:
            "/Volumes/.timemachine/10.2.0.180/DB1BA805-F5F5-47F4-A054-D0DA4C4AA85B/time_mbp_m5"))
    }

    func testMountsOutsideVolumesDoNot() {
        XCTAssertFalse(Disks.mayChangeDiskList(volumePath: "/"))
        XCTAssertFalse(Disks.mayChangeDiskList(volumePath: "/System/Volumes/Update/mnt1"))
        XCTAssertFalse(Disks.mayChangeDiskList(volumePath: "/private/tmp/mnt"))
        XCTAssertFalse(Disks.mayChangeDiskList(volumePath: "/Volumes"))
    }
}
