import XCTest
@testable import TMEjectGuardCore

/// "Back up now" on a disk row and "Stop backup" in the footer: the user's own
/// requests, for any destination, guarded or not.
final class BackupControlTests: XCTestCase {
    private let wd = KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1", tmDestinationID: "TM-1")
    private let stick = KnownDisk(id: "VOL-2", name: "Stick", volumeUUID: "VOL-2")
    private let nas = KnownDisk(id: "TM-2", name: "NAS", tmDestinationID: "TM-2", network: true)

    private func volume(_ disk: KnownDisk) -> AttachedVolume {
        AttachedVolume(path: "/Volumes/\(disk.name)", name: disk.name,
                       volumeUUID: disk.volumeUUID, tmDestinationID: disk.tmDestinationID)
    }

    private func destination(_ disk: KnownDisk, attached: [AttachedVolume] = [],
                             reported: Set<String> = ["TM-1", "TM-2"]) -> String? {
        BackupControl.destinationToStart(disk, attached: attached, reportedDestinationIDs: reported)
    }

    private func running(_ running: Bool) -> BackupStatus {
        var status = BackupStatus()
        status.running = running
        return status
    }

    // MARK: - Where a backup can be started

    func testAPluggedInTimeMachineDiskCanBeBackedUpGuardedOrNot() {
        XCTAssertEqual(destination(wd, attached: [volume(wd)]), "TM-1")
    }

    func testAnUnpluggedDiskCannot() {
        // Unmounted for a meeting counts as unplugged: a locked encrypted
        // volume stays locked, and Time Machine fails to find it.
        XCTAssertNil(destination(wd))
    }

    func testADiskThatIsNotADestinationCannot() {
        XCTAssertNil(destination(stick, attached: [volume(stick)]))
    }

    /// Remembered as a destination, but Time Machine no longer has it: it was
    /// removed in System Settings, or the scan timed out. Asking would fail.
    func testADestinationTimeMachineNoLongerReportsCannot() {
        XCTAssertNil(destination(wd, attached: [volume(wd)], reported: ["TM-2"]))
        XCTAssertNil(destination(nas, reported: ["TM-1"]))
    }

    /// A share is never plugged in. Time Machine mounts it itself.
    func testAShareTimeMachineReportsCan() {
        XCTAssertEqual(destination(nas), "TM-2")
    }

    // MARK: - When a request has taken

    func testAStopIsDoneOnceNothingIsRunning() {
        let now = Date()
        let stop = BackupRequest(kind: .stop, name: "WD", deadline: now.addingTimeInterval(120))
        XCTAssertEqual(stop.settle(running(true), now: now), .pending,
                       "a share sits in Stopping for most of a minute")
        XCTAssertEqual(stop.settle(running(false), now: now), .done)
    }

    func testAStopStillRunningPastItsDeadlineFailed() {
        let now = Date()
        let stop = BackupRequest(kind: .stop, name: "WD", deadline: now)
        XCTAssertEqual(stop.settle(running(true), now: now.addingTimeInterval(1)), .failed)
        XCTAssertEqual(stop.settle(running(false), now: now.addingTimeInterval(1)), .done,
                       "a late answer that it stopped is still a stop")
    }

    func testAStartIsDoneOnceABackupRuns() {
        let now = Date()
        let start = BackupRequest(kind: .start(destinationID: "TM-1"), name: "WD",
                                  deadline: now.addingTimeInterval(30))
        XCTAssertEqual(start.settle(running(false), now: now), .pending)
        XCTAssertEqual(start.settle(running(true), now: now), .done)
    }

    func testAStartThatNeverRanFailed() {
        let now = Date()
        let start = BackupRequest(kind: .start(destinationID: "TM-1"), name: "WD", deadline: now)
        XCTAssertEqual(start.settle(running(false), now: now.addingTimeInterval(1)), .failed)
    }

    // MARK: - When saying it failed is stale

    func testAStopThatDidNotTakeIsStaleOnceNothingRuns() {
        let stop = BackupRequest(kind: .stop, name: "WD", deadline: Date())
        XCTAssertFalse(stop.took(running(true)), "the backup it could not stop still runs")
        XCTAssertTrue(stop.took(running(false)))
    }

    func testAStartThatDidNotTakeIsStaleOnceABackupRuns() {
        let start = BackupRequest(kind: .start(destinationID: "TM-1"), name: "WD", deadline: Date())
        XCTAssertFalse(start.took(running(false)))
        XCTAssertTrue(start.took(running(true)), "whichever destination it writes to")
    }

    func testOnlyAStartNamesADestination() {
        let start = BackupRequest(kind: .start(destinationID: "TM-1"), name: "WD", deadline: Date())
        XCTAssertEqual(start.startingDestinationID, "TM-1")
        XCTAssertNil(BackupRequest(kind: .stop, name: "WD", deadline: Date()).startingDestinationID)
    }
}
