import XCTest
@testable import TMEjectGuardCore

/// "Forget this disk" in a disk row's context menu. Unlike hiding, nothing is
/// kept: the disk is listed again, unguarded, the next time it is plugged in.
final class ForgetDiskTests: XCTestCase {
    private let wd = KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1", tmDestinationID: "TM-1")
    private let stick = KnownDisk(id: "VOL-2", name: "Speaker's SSD", volumeUUID: "VOL-2")

    private func volume(_ disk: KnownDisk) -> AttachedVolume {
        AttachedVolume(path: "/Volumes/\(disk.name)", name: disk.name,
                       volumeUUID: disk.volumeUUID, tmDestinationID: disk.tmDestinationID)
    }

    private func pending(_ uuid: String) -> PendingReconnect {
        PendingReconnect(volumeUUID: uuid, name: "WD", notBefore: Date(), stoppedBackup: false)
    }

    func testForgettingTakesTheTickTheHiddenMarkAndTheReconnectWithIt() {
        var config = GuardConfig()
        config.knownDisks = [wd, stick]
        config.watchedDiskIDs = ["VOL-1", "VOL-2"]
        // Left over from a hide the user undid by hand in an older release.
        config.dismissedDiskIDs = ["VOL-1", "TM-9"]
        config.pendingReconnects = [pending("VOL-1"), pending("VOL-3")]

        config.forget(wd)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-2"])
        XCTAssertEqual(config.watchedDiskIDs, ["VOL-2"], "another disk's tick is not touched")
        XCTAssertEqual(config.dismissedDiskIDs, ["TM-9"])
        XCTAssertEqual(config.pendingReconnects.map(\.volumeUUID), ["VOL-3"])
    }

    func testAForgottenDiskComesBackUnguardedWhenPluggedIn() {
        var config = GuardConfig()
        config.knownDisks = [stick]
        config.watchedDiskIDs = ["VOL-2"]

        config.forget(stick)
        Disks.merge(DiskSnapshot(destinations: [], attached: [volume(stick)]), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-2"], "unlike a hidden disk, it is listed again")
        XCTAssertTrue(config.watchedDiskIDs.isEmpty, "and it is not guarded")
    }

    func testAForgottenDiskStaysGoneWhileItIsAway() {
        var config = GuardConfig()
        config.knownDisks = [stick]
        config.forget(stick)

        Disks.merge(DiskSnapshot(destinations: [], attached: []), into: &config)

        XCTAssertTrue(config.knownDisks.isEmpty)
    }

    func testOnlyADiskThatIsNotPluggedInCanBeForgotten() {
        XCTAssertTrue(Disks.canForget(stick, attached: [], reportedDestinationIDs: []))
        XCTAssertFalse(Disks.canForget(stick, attached: [volume(stick)], reportedDestinationIDs: []),
                       "the next scan would list it again")
    }

    func testATimeMachineDestinationTimeMachineStillReportsIsHiddenNotForgotten() {
        // Forgetting it would only make it come back with the next scan.
        XCTAssertFalse(Disks.canForget(wd, attached: [], reportedDestinationIDs: ["TM-1"]))
        let share = KnownDisk(id: "NET-1", name: "NAS", tmDestinationID: "NET-1", network: true)
        XCTAssertFalse(Disks.canForget(share, attached: [], reportedDestinationIDs: ["NET-1"]))

        // One Time Machine no longer backs up to, unseen for weeks.
        XCTAssertTrue(Disks.canForget(wd, attached: [], reportedDestinationIDs: ["TM-2"]))
        XCTAssertTrue(Disks.canForget(share, attached: [], reportedDestinationIDs: []))
    }

    func testAForgottenTimeMachineDestinationIsNotRelistedOnceTimeMachineDropsIt() {
        var config = GuardConfig()
        config.knownDisks = [wd]
        config.watchedDiskIDs = ["VOL-1"]

        config.forget(wd)
        Disks.merge(DiskSnapshot(destinations: [], attached: []), into: &config)

        XCTAssertTrue(config.knownDisks.isEmpty)
        XCTAssertTrue(config.watchedDiskIDs.isEmpty)
    }
}
