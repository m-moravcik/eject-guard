import XCTest
@testable import TMEjectGuardCore

/// Built from `diskutil info -plist` output captured on 2026-09-22 from the
/// actual Time Machine drive, after the live run showed that ejecting the
/// volume path left the disk spinning.
final class DeviceResolverTests: XCTestCase {
    /// /Volumes/Time Machine WD - an APFS volume in a synthesised container.
    private let apfsVolume: [String: Any] = [
        "DeviceIdentifier": "disk7s2",
        "ParentWholeDisk": "disk7",
        "APFSContainerReference": "disk7",
        "APFSPhysicalStores": [["APFSPhysicalStore": "disk6s2"]],
        "Internal": NSNumber(value: false),
        "Ejectable": NSNumber(value: true),
    ]

    /// The physical 3 TB USB disk behind it.
    private let externalDisk: [String: Any] = [
        "DeviceIdentifier": "disk6",
        "ParentWholeDisk": "disk6",
        "WholeDisk": NSNumber(value: true),
        "Internal": NSNumber(value: false),
        "OSInternalMedia": NSNumber(value: false),
        "Ejectable": NSNumber(value: true),
        "RemovableMedia": NSNumber(value: false),
        "RemovableMediaOrExternalDevice": NSNumber(value: true),
        "BusProtocol": "USB",
    ]

    func testApfsVolumeResolvesToThePhysicalDiskNotTheContainer() {
        // ParentWholeDisk is disk7, the synthesised container. Powering that
        // down is not a thing; disk6 is the device with the heads.
        XCTAssertEqual(DeviceResolver.wholeDisk(fromInfo: apfsVolume), "disk6")
    }

    func testPlainVolumeFallsBackToItsParentWholeDisk() {
        let hfs: [String: Any] = ["ParentWholeDisk": "disk6", "DeviceIdentifier": "disk6s2"]
        XCTAssertEqual(DeviceResolver.wholeDisk(fromInfo: hfs), "disk6")
    }

    func testListStyleKeyIsAlsoAccepted() {
        let info: [String: Any] = ["APFSPhysicalStores": [["DeviceIdentifier": "disk6s2"]]]
        XCTAssertEqual(DeviceResolver.wholeDisk(fromInfo: info), "disk6")
    }

    func testNothingToResolve() {
        XCTAssertNil(DeviceResolver.wholeDisk(fromInfo: [:]))
    }

    func testIdentifierParsing() {
        XCTAssertEqual(DeviceResolver.wholeDiskIdentifier(from: "disk6s2"), "disk6")
        XCTAssertEqual(DeviceResolver.wholeDiskIdentifier(from: "disk10"), "disk10")
        XCTAssertEqual(DeviceResolver.wholeDiskIdentifier(from: "disk10s1s2"), "disk10")
        XCTAssertNil(DeviceResolver.wholeDiskIdentifier(from: "/Volumes/Thing"))
        XCTAssertNil(DeviceResolver.wholeDiskIdentifier(from: "disk"))
        XCTAssertNil(DeviceResolver.wholeDiskIdentifier(from: "rdisk6"))
    }

    func testTheExternalBackupDiskMayBePoweredDown() {
        XCTAssertTrue(DeviceResolver.isExternalWholeDisk(externalDisk))
    }

    func testAnInternalDiskMayNotBe() {
        var internalDisk = externalDisk
        internalDisk["Internal"] = NSNumber(value: true)
        XCTAssertFalse(DeviceResolver.isExternalWholeDisk(internalDisk))
    }

    func testSystemMediaMayNotBe() {
        var system = externalDisk
        system["OSInternalMedia"] = NSNumber(value: true)
        XCTAssertFalse(DeviceResolver.isExternalWholeDisk(system))
    }

    func testAPartitionIsNotAWholeDisk() {
        var partition = externalDisk
        partition["WholeDisk"] = NSNumber(value: false)
        XCTAssertFalse(DeviceResolver.isExternalWholeDisk(partition))
    }

    func testSilenceIsNotConsent() {
        // Missing keys must not read as "external, go ahead".
        XCTAssertFalse(DeviceResolver.isExternalWholeDisk([:]))
    }
}
