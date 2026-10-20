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

    // A disk nobody guards is forgotten 30 days after it was unplugged: a
    // volume made while formatting a disk otherwise stayed listed for good,
    // and hiding it by hand was the only way out.

    private let day: TimeInterval = 24 * 60 * 60
    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let month: TimeInterval = 30 * 24 * 60 * 60
    private let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private let unplugged = DiskSnapshot(destinations: [], attached: [])

    func testAnUnguardedDiskUnpluggedFor30DaysIsForgotten() {
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(destinations: [], attached: [volume("TmpInit", uuid: "VOL-1")]),
                    into: &config, now: start)
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(60))
        XCTAssertEqual(config.knownDisks.first?.absentSince, start.addingTimeInterval(60))

        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(60 + week))
        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"], "a week is no longer enough")

        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(60 + month - 1))
        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"], "not 30 days yet")

        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(60 + month))
        XCTAssertTrue(config.knownDisks.isEmpty)
    }

    func testAnEntryFromAnEarlierReleaseCountsFromItsStoredAbsence() {
        // Written by 1.4.2 with the absence it found 20 days ago.
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "Speaker's SSD", volumeUUID: "VOL-1",
                                       absentSince: start.addingTimeInterval(-20 * day))]

        Disks.merge(unplugged, into: &config, now: start)
        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"])

        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(10 * day))
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
        XCTAssertNotNil(config.knownDisks.first?.absentSince, "absent all the same")
    }

    func testATimeMachineDiskIsNeverForgotten() {
        // Time Machine reports it again on every pass, so forgetting it would
        // only make the row flicker. One it no longer backs up to is hidden
        // or forgotten by hand.
        var config = GuardConfig()
        config.knownDisks = [
            KnownDisk(id: "VOL-2", name: "TM MBP", volumeUUID: "VOL-2", tmDestinationID: "TM-2"),
            // Never seen mounted: only a destination ID.
            KnownDisk(id: "TM-3", name: "TM Old", tmDestinationID: "TM-3"),
        ]

        Disks.merge(unplugged, into: &config, now: start)
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(52 * week))

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-2", "TM-3"])
    }

    func testTheMonthCountsFromWhenTheDiskWasFoundMissing() {
        // The app rescans only when something mounts, unmounts or wakes, so a
        // disk left plugged into a Mac that never sleeps, or one an earlier
        // release remembered, can carry a `lastSeen` weeks old the moment it
        // is found missing.
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "Archive", volumeUUID: "VOL-1",
                                       lastSeen: start.addingTimeInterval(-8 * week))]

        Disks.merge(unplugged, into: &config, now: start)
        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"], "found missing just now")

        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(month))
        XCTAssertTrue(config.knownDisks.isEmpty)
    }

    func testPluggingTheDiskBackInStartsTheMonthAgain() {
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "Archive", volumeUUID: "VOL-1")]
        let pluggedIn = DiskSnapshot(destinations: [], attached: [volume("Archive", uuid: "VOL-1")])

        Disks.merge(unplugged, into: &config, now: start)
        Disks.merge(pluggedIn, into: &config, now: start.addingTimeInterval(29 * day))
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(29 * day + 60))
        Disks.merge(unplugged, into: &config, now: start.addingTimeInterval(month + 1))

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"])
    }

    func testADiskImageAnEarlierReleaseRememberedIsForgotten() {
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "IMG-1", name: "cmux", volumeUUID: "IMG-1")]

        Disks.merge(DiskSnapshot(destinations: [], attached: [], diskImageIDs: ["IMG-1"]),
                    into: &config)

        XCTAssertTrue(config.knownDisks.isEmpty)
    }

    func testAGuardedDiskImageIsForgottenButItsTickStays() {
        // Images are never listed, guarded or not. A block-level image of a
        // real disk carries the same volume UUID, so the tick is left alone:
        // the real disk comes back guarded the next time it is plugged in.
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1")]
        config.watchedDiskIDs = ["VOL-1"]

        Disks.merge(DiskSnapshot(destinations: [], attached: [], diskImageIDs: ["VOL-1"]),
                    into: &config)
        XCTAssertTrue(config.knownDisks.isEmpty)
        XCTAssertEqual(config.watchedDiskIDs, ["VOL-1"], "an image must never unguard a disk")

        Disks.merge(DiskSnapshot(destinations: [], attached: [volume("WD", uuid: "VOL-1")]),
                    into: &config)
        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"])
        XCTAssertEqual(Disks.guardedVolumes(config, among: [volume("WD", uuid: "VOL-1")]).map(\.volumeUUID),
                       ["VOL-1"])
    }

    func testARealDiskPluggedInBesideItsImageStaysListedAndGuarded() {
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1")]
        config.watchedDiskIDs = ["VOL-1"]
        let real = volume("WD", uuid: "VOL-1")

        Disks.merge(DiskSnapshot(destinations: [], attached: [real], diskImageIDs: ["VOL-1"]),
                    into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1"])
        XCTAssertEqual(Disks.guardedVolumes(config, among: [real]).map(\.volumeUUID), ["VOL-1"])
    }

    func testATimeMachineDestinationIsNeverForgottenForBeingAnImage() {
        var config = GuardConfig()
        config.knownDisks = [
            KnownDisk(id: "VOL-2", name: "TM", volumeUUID: "VOL-2", tmDestinationID: "TM-2"),
        ]

        Disks.merge(DiskSnapshot(destinations: [], attached: [], diskImageIDs: ["VOL-2"]),
                    into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-2"])
    }

    func testADiskImageIsNeverRemembered() {
        // What a test tool's scratch image looks like to a scan: listed as an
        // image, never attached. Two of them, sharing a name.
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(destinations: [], attached: [], diskImageIDs: ["IMG-1", "IMG-2"]),
                    into: &config)
        XCTAssertTrue(config.knownDisks.isEmpty)
    }

    // MARK: What a mounted volume is

    func testDiskImagesAreToldApartByModelOrDriver() {
        // Observed on macOS 27: HFS+ and APFS images through `hdiutil attach`
        // and `diskutil image attach`, and a Time Machine share's bundle.
        XCTAssertTrue(Disks.isDiskImage(deviceModel: "Disk Image"))
        XCTAssertTrue(Disks.isDiskImage(
            deviceModel: nil,
            devicePath: "IOService:/IOResources/IOHDIXController/IOHDIXHDDriveOutKernel@f0/IODiskImageBlockStorageDeviceOutKernel"))
        XCTAssertTrue(Disks.isDiskImage(
            deviceModel: nil,
            devicePath: "IOService:/IOResources/AppleDiskImagesController/AppleDiskImageDevice@2d"))
        // A USB disk, by the shape a USB storage path takes, and the internal SSD.
        XCTAssertFalse(Disks.isDiskImage(
            deviceModel: "Elements 25A3",
            devicePath: "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/usb-drd0@2280000/AppleUSBHostPort@01100000/Elements 25A3@01100000/IOUSBHostInterface@0/IOUSBMassStorageInterfaceNub/IOUSBMassStorageDriverNub/IOUSBMassStorageDriver/IOSCSILogicalUnitNub@0/IOSCSIPeripheralDeviceType00"))
        XCTAssertFalse(Disks.isDiskImage(deviceModel: "APPLE SSD AP1024Z"))
        XCTAssertFalse(Disks.isDiskImage(deviceModel: nil, devicePath: nil))
    }

    func testAVolumeThatVanishedMidScanIsNotAttached() {
        XCTAssertEqual(Disks.kind(ofDevice: nil, isTimeMachineDestination: false, stillMounted: { false }), .gone)
        // Still there but unknown to DiskArbitration: offered, as an unknown
        // model always was, rather than hiding a real disk.
        XCTAssertEqual(Disks.kind(ofDevice: nil, isTimeMachineDestination: false, stillMounted: { true }), .disk)
    }

    func testAnImageIsOfferedOnlyAsATimeMachineDestination() {
        let image = (model: Optional("Disk Image"), path: Optional<String>.none)
        XCTAssertEqual(Disks.kind(ofDevice: image, isTimeMachineDestination: false, stillMounted: { true }),
                       .diskImage)
        XCTAssertEqual(Disks.kind(ofDevice: image, isTimeMachineDestination: true, stillMounted: { true }),
                       .disk)
        let disk = (model: Optional("Elements 25A3"), path: Optional<String>.none)
        XCTAssertEqual(Disks.kind(ofDevice: disk, isTimeMachineDestination: false, stillMounted: { true }),
                       .disk)
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

    // MARK: Network Time Machine destinations

    private func network(_ id: String, name: String) -> TimeMachineDestination {
        TimeMachineDestination(id: id, name: name, mountPoint: nil, isNetwork: true)
    }

    func testANetworkDestinationIsListedAndMarked() {
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(destinations: [network("NET-1", name: "NAS")], attached: []), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["NET-1"])
        XCTAssertTrue(config.knownDisks[0].isNetworkDestination)
        XCTAssertTrue(config.knownDisks[0].isTimeMachineDestination)
        XCTAssertNil(config.knownDisks[0].absentSince, "a share is never 'unplugged'")
    }

    func testANetworkDestinationIsNeverAnEjectTarget() {
        var config = GuardConfig()
        // A volume that shares everything it could with the destination: its
        // name, and a destination ID a buggy scan could have attached to it.
        let lookalike = volume("NAS", uuid: "VOL-1", tm: "NET-1")
        Disks.merge(DiskSnapshot(destinations: [network("NET-1", name: "NAS")], attached: []), into: &config)
        config.watchedDiskIDs = ["NET-1"]

        XCTAssertTrue(Disks.guardedVolumes(config, among: [lookalike]).isEmpty,
                      "a share must never resolve to a volume that could be ejected")
        XCTAssertEqual(Disks.guardedNetworkDestinations(config).map(\.id), ["NET-1"])
    }

    func testAPluggedInDiskIsNeverFoldedIntoANetworkDestinationOfTheSameName() {
        var config = GuardConfig()
        Disks.merge(DiskSnapshot(
            destinations: [network("NET-1", name: "Backup")],
            attached: [volume("Backup", uuid: "VOL-1")]), into: &config)

        XCTAssertEqual(Set(config.knownDisks.map(\.id)), ["NET-1", "VOL-1"],
                       "matching by name must not cross from a disk to a share")
        let disk = config.knownDisks.first { $0.id == "VOL-1" }
        XCTAssertEqual(disk?.isNetworkDestination, false)
        XCTAssertNil(disk?.tmDestinationID)
    }

    func testAGuardedNetworkDestinationKeepsItsTickAcrossPasses() {
        var config = GuardConfig()
        let snapshot = DiskSnapshot(destinations: [network("NET-1", name: "NAS")], attached: [])
        Disks.merge(snapshot, into: &config)
        config.watchedDiskIDs = ["NET-1"]

        Disks.merge(snapshot, into: &config, now: Date().addingTimeInterval(30 * 24 * 3600))

        XCTAssertEqual(config.knownDisks.map(\.id), ["NET-1"])
        XCTAssertEqual(config.watchedDiskIDs, ["NET-1"])
    }

    /// What an older release running at the same time leaves behind: it
    /// drops the `network` key it does not know and writes the entry back.
    /// The destination ID is still an exact identity, so the entry is this
    /// share and gets its flag back, rather than a second one with the same ID.
    func testAnEntryThatLostItsNetworkFlagIsTheSameDestination() {
        var config = GuardConfig()
        config.knownDisks = [KnownDisk(id: "NET-1", name: "NAS", tmDestinationID: "NET-1",
                                       absentSince: Date())]
        config.watchedDiskIDs = ["NET-1"]

        Disks.merge(DiskSnapshot(destinations: [network("NET-1", name: "NAS")], attached: []), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["NET-1"], "one share, listed once")
        XCTAssertTrue(config.knownDisks[0].isNetworkDestination)
        XCTAssertNil(config.knownDisks[0].absentSince)
        XCTAssertEqual(config.watchedDiskIDs, ["NET-1"])
    }

    func testTwoEntriesWithTheSameDestinationIDCollapse() {
        // The state the bug above wrote into a real config file.
        var config = GuardConfig()
        config.knownDisks = [
            KnownDisk(id: "NET-1", name: "NAS", tmDestinationID: "NET-1"),
            KnownDisk(id: "NET-1", name: "NAS", tmDestinationID: "NET-1", network: true),
        ]

        Disks.merge(DiskSnapshot(destinations: [network("NET-1", name: "NAS")], attached: []), into: &config)

        XCTAssertEqual(config.knownDisks.map(\.id), ["NET-1"])
        XCTAssertTrue(config.knownDisks[0].isNetworkDestination)
    }

    func testANetworkFlagWrittenByThisReleaseSurvivesAnOlderFile() throws {
        // A file from before this release has no `network` key at all.
        let old = #"{"id":"TM-1","name":"WD","tmDestinationID":"TM-1"}"#
        let disk = try JSONDecoder().decode(KnownDisk.self, from: Data(old.utf8))
        XCTAssertFalse(disk.isNetworkDestination)
    }

    // MARK: How a disk is connected

    func testTheInterfaceIsNamedOnlyWhenWeRecogniseIt() {
        XCTAssertEqual(Disks.connection(fromProtocol: "USB"), .usb)
        XCTAssertEqual(Disks.connection(fromProtocol: "Thunderbolt"), .thunderbolt)
        XCTAssertEqual(Disks.connection(fromProtocol: "PCI-Express"), .thunderbolt)
        XCTAssertEqual(Disks.connection(fromProtocol: "Secure Digital"), .sdCard)
        // Observed on this project's hardware: never offered, never named.
        XCTAssertNil(Disks.connection(fromProtocol: "Apple Fabric"))
        XCTAssertNil(Disks.connection(fromProtocol: "Virtual Interface"))
        XCTAssertNil(Disks.connection(fromProtocol: "SATA"))
        XCTAssertNil(Disks.connection(fromProtocol: nil))
    }
}
