import XCTest
@testable import TMEjectGuardCore

/// `Disks.merge` is the pure half of disk discovery: no processes, no I/O.
/// Everything about which disk is which, and which one the user guards, is
/// decided here.
final class DiskMergeTests: XCTestCase {
    private func volume(_ name: String, uuid: String?, tm: String? = nil) -> AttachedVolume {
        AttachedVolume(path: "/Volumes/\(name)", name: name, volumeUUID: uuid, tmDestinationID: tm)
    }

    func testTimeMachineDestinationAppearsBeforeItIsEverPluggedIn() {
        var config = GuardConfig()
        let snapshot = DiskSnapshot(
            destinations: [TimeMachineDestination(id: "TM-1", name: "Time Machine WD", mountPoint: nil)],
            attached: [])

        Disks.merge(snapshot, into: &config)

        XCTAssertEqual(config.knownDisks.count, 1)
        XCTAssertEqual(config.knownDisks[0].id, "TM-1")
        XCTAssertTrue(config.knownDisks[0].isTimeMachineDestination)
        XCTAssertNil(config.knownDisks[0].lastSeen, "a destination we have never seen is not 'seen'")
    }

    func testPlaceholderAndRealVolumeCollapseIntoOneEntry() {
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(
            destinations: [TimeMachineDestination(id: "TM-1", name: "Time Machine WD", mountPoint: nil)],
            attached: []), into: &config)

        // Now the disk is plugged in and Time Machine reports its mount point.
        Disks.merge(DiskSnapshot(
            destinations: [TimeMachineDestination(
                id: "TM-1", name: "Time Machine WD", mountPoint: "/Volumes/Time Machine WD")],
            attached: [volume("Time Machine WD", uuid: "VOL-1", tm: "TM-1")]), into: &config)

        XCTAssertEqual(config.knownDisks.count, 1, "the same disk must not be listed twice")
        XCTAssertEqual(config.knownDisks[0].id, "VOL-1", "volume UUID is the stronger identity")
        XCTAssertEqual(config.knownDisks[0].volumeUUID, "VOL-1")
        XCTAssertEqual(config.knownDisks[0].tmDestinationID, "TM-1")
        XCTAssertNotNil(config.knownDisks[0].lastSeen)
    }

    func testTheUsersSelectionFollowsTheIdentityChange() {
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(
            destinations: [TimeMachineDestination(id: "TM-1", name: "WD", mountPoint: nil)],
            attached: []), into: &config)
        config.watchedDiskIDs = ["TM-1"]

        Disks.merge(DiskSnapshot(
            destinations: [TimeMachineDestination(id: "TM-1", name: "WD", mountPoint: "/Volumes/WD")],
            attached: [volume("WD", uuid: "VOL-1", tm: "TM-1")]), into: &config)

        XCTAssertEqual(config.watchedDiskIDs, ["VOL-1"],
                       "re-keying a disk must not silently unguard it")
    }

    func testHiddenDisksStayHiddenEvenThoughTimeMachineKeepsReportingThem() {
        var config = GuardConfig()
        config.dismissedDiskIDs = ["TM-2"]

        Disks.merge(DiskSnapshot(
            destinations: [
                TimeMachineDestination(id: "TM-1", name: "WD", mountPoint: nil),
                TimeMachineDestination(id: "TM-2", name: "Someone else's Mac", mountPoint: nil),
            ],
            attached: []), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["TM-1"])
    }

    func testDisksAreSortedByName() {
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(
            destinations: [],
            attached: [volume("Zulu", uuid: "V-Z"), volume("alpha", uuid: "V-A")]), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.name), ["alpha", "Zulu"])
    }

    func testARememberedDiskIsNotDroppedWhenItIsUnplugged() {
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(destinations: [], attached: [volume("WD", uuid: "VOL-1")]), into: &config)
        Disks.merge(DiskSnapshot(destinations: [], attached: []), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"],
                       "you pick from this list while the disk is in a drawer")
    }

    func testOnlyTickedDisksThatArePresentAreGuarded() {
        var config = GuardConfig()
        let present = volume("WD", uuid: "VOL-1")
        let absent = volume("Other", uuid: "VOL-2")
        Disks.merge(DiskSnapshot(destinations: [], attached: [present, absent]), into: &config)
        config.watchedDiskIDs = ["VOL-1"]

        let guarded = Disks.guardedVolumes(config, among: [present, absent])

        XCTAssertEqual(guarded.map(\.volumeUUID), ["VOL-1"],
                       "an unticked disk must never be a target")
    }

    func testNothingIsGuardedWhenNothingIsTicked() {
        var config = GuardConfig()
        let present = volume("WD", uuid: "VOL-1")
        Disks.merge(DiskSnapshot(destinations: [], attached: [present]), into: &config)

        XCTAssertTrue(Disks.guardedVolumes(config, among: [present]).isEmpty)
    }
}
