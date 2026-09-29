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

    // A disk remembered as a plain volume, then made a Time Machine
    // destination: the destination arrives with no volume UUID and the entry
    // with no destination ID, so neither identity matched and the disk was
    // listed twice.

    func testADiskThatBecomesATimeMachineDestinationIsStillListedOnce() {
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1")]
        config.watchedDiskIDs = ["VOL-1"]

        Disks.merge(DiskSnapshot(
            destinations: [TimeMachineDestination(id: "TM-1", name: "WD", mountPoint: "/Volumes/WD")],
            attached: [volume("WD", uuid: "VOL-1", tm: "TM-1")]), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"], "the same disk must not be listed twice")
        XCTAssertEqual(config.knownDisks[0].tmDestinationID, "TM-1")
        XCTAssertEqual(config.watchedDiskIDs, ["VOL-1"])
    }

    func testTimeMachinesOwnRecordLinksTheDestinationWhileTheDiskIsUnplugged() {
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1")]

        Disks.merge(DiskSnapshot(
            destinations: [TimeMachineDestination(
                id: "TM-1", name: "WD", mountPoint: nil, volumeUUIDs: ["VOL-1"])],
            attached: []), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"])
        XCTAssertEqual(config.knownDisks[0].tmDestinationID, "TM-1")
    }

    func testADuplicateAnEarlierReleaseLeftBehindCollapsesOnceTheDiskIsPluggedIn() {
        var config = GuardConfig()
        config.knownDisks = [
            KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1", tmDestinationID: "TM-1"),
            KnownDisk(id: "TM-1", name: "WD", tmDestinationID: "TM-1"),
        ]
        // Ticked on the duplicate: the tick has to survive the collapse.
        config.watchedDiskIDs = ["TM-1"]

        Disks.merge(DiskSnapshot(
            destinations: [TimeMachineDestination(id: "TM-1", name: "WD", mountPoint: "/Volumes/WD")],
            attached: [volume("WD", uuid: "VOL-1", tm: "TM-1")]), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"])
        XCTAssertEqual(config.watchedDiskIDs, ["VOL-1"], "collapsing a duplicate must not unguard the disk")
    }

    func testTimeMachinesOwnRecordAlsoCollapsesADuplicateWhileTheDiskIsUnplugged() {
        var config = GuardConfig()
        // The placeholder first, so it is the entry the destination lands on.
        config.knownDisks = [
            KnownDisk(id: "TM-1", name: "WD", tmDestinationID: "TM-1"),
            KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1"),
        ]
        config.watchedDiskIDs = ["VOL-1"]

        Disks.merge(DiskSnapshot(
            destinations: [TimeMachineDestination(
                id: "TM-1", name: "WD", mountPoint: nil, volumeUUIDs: ["VOL-1"])],
            attached: []), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"])
        XCTAssertEqual(config.knownDisks[0].tmDestinationID, "TM-1")
        XCTAssertEqual(config.watchedDiskIDs, ["VOL-1"])
    }

    func testTimeMachinePreferencesMapEachDestinationToItsVolumes() {
        let preferences: [String: Any] = [
            "Destinations": [
                ["DestinationID": "TM-1", "DestinationUUIDs": ["VOL-1"]],
                ["DestinationID": "TM-2"],
                ["DestinationUUIDs": ["VOL-3"]],
            ],
        ]

        XCTAssertEqual(Disks.destinationVolumeUUIDs(fromPreferences: preferences), ["TM-1": ["VOL-1"]])
        XCTAssertEqual(Disks.destinationVolumeUUIDs(fromPreferences: [:]), [:])
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

    // A disk nobody guards is forgotten a week after it was unplugged: a
    // volume made while formatting a disk otherwise stayed listed for good,
    // and hiding it by hand was the only way out.

    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let unplugged = DiskSnapshot(destinations: [], attached: [])

    func testAnUnguardedDiskUnpluggedForAWeekIsForgotten() {
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(destinations: [], attached: [volume("TmpInit", uuid: "VOL-1")]),
                    into: &config, now: start)
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(60))

        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(60 + week - 1))
        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"], "not a week yet")

        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(60 + week))
        XCTAssertTrue(config.knownDisks.isEmpty)
    }

    func testAGuardedDiskIsNeverForgotten() {
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1")]
        config.watchedDiskIDs = ["VOL-1"]

        Disks.merge(unplugged, into: &config, now: start)
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(52 * week))

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"],
                       "you pick from this list while the disk is in a drawer")
        XCTAssertEqual(config.watchedDiskIDs, ["VOL-1"])
    }

    func testATimeMachineDiskIsNeverForgotten() {
        // Time Machine reports it again on every pass, so forgetting it would
        // only make the row flicker. One it no longer backs up to is hidden.
        var config = GuardConfig()
        config.knownDisks = [
            KnownDisk(id: "VOL-2", name: "TM MBP", volumeUUID: "VOL-2", tmDestinationID: "TM-2"),
        ]

        Disks.merge(unplugged, into: &config, now: start)
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(52 * week))

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-2"])
    }

    func testTheWeekCountsFromWhenTheDiskWasFoundMissing() {
        // The app rescans only when something mounts, unmounts or wakes, so a
        // disk left plugged into a Mac that never sleeps, or one an earlier
        // release remembered, can carry a `lastSeen` weeks old the moment it
        // is found missing.
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "Archive", volumeUUID: "VOL-1",
                                       lastSeen: start.addingTimeInterval(-4 * week))]

        Disks.merge(unplugged, into: &config, now: start)
        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"], "found missing just now")

        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(week))
        XCTAssertTrue(config.knownDisks.isEmpty)
    }

    func testPluggingTheDiskBackInStartsTheWeekAgain() {
        let day: TimeInterval = 24 * 60 * 60
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "Archive", volumeUUID: "VOL-1")]
        let pluggedIn = DiskSnapshot(destinations: [], attached: [volume("Archive", uuid: "VOL-1")])

        Disks.merge(unplugged, into: &config, now: start)
        Disks.merge(pluggedIn, into: &config, now: start.addingTimeInterval(6 * day))
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(6 * day + 60))
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(week + 1))

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"])
    }

    func testADiskImageAnEarlierReleaseRememberedIsForgotten() {
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "IMG-1", name: "cmux", volumeUUID: "IMG-1")]

        Disks.merge(DiskSnapshot(destinations: [], attached: [], diskImageIDs: ["IMG-1"]),
                    into: &config)

        XCTAssertTrue(config.knownDisks.isEmpty)
    }

    func testAGuardedDiskIsNeverForgottenForSharingAnImagesUUID() {
        // A block-level image of a real disk carries the same volume UUID.
        var config = GuardConfig()
        config.knownDisks = [
            KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1"),
            KnownDisk(id: "VOL-2", name: "TM", volumeUUID: "VOL-2", tmDestinationID: "TM-2"),
        ]
        config.watchedDiskIDs = ["VOL-1"]

        Disks.merge(DiskSnapshot(destinations: [], attached: [], diskImageIDs: ["VOL-1", "VOL-2"]),
                    into: &config)

        XCTAssertEqual(Set(config.knownDisks.map(\.id)), ["VOL-1", "VOL-2"])
        XCTAssertEqual(config.watchedDiskIDs, ["VOL-1"], "an image must never unguard a disk")
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
