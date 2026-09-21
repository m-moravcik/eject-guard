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
        XCTAssertTrue(status.isBackingUp(to: "/Volumes/WD"))
        XCTAssertFalse(status.isBackingUp(to: "/Volumes/Other"))
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
        XCTAssertTrue(status.isBackingUp(to: "/Volumes/WD"),
                      "better to stop a backup that was not ours than eject under one that was")
    }

    func testGarbageIsNotRunning() {
        XCTAssertFalse(BackupStatus(plist: [:]).running)
    }
}
