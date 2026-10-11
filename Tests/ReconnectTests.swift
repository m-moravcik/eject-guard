import XCTest
@testable import TMEjectGuardCore

/// Reconnecting after a meeting: whether the disk is still there, when it is
/// due, and which meetings hold it back. The `diskutil info -plist` shapes are
/// the ones read from APFS volumes on 2026-10-11, before and after
/// `diskutil unmountDisk`.
final class ReconnectTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let uuid = "66150C45-7922-435C-BA78-6199E3CDEBDE"

    private func entry(dueIn seconds: TimeInterval, name: String = "Time Machine WD") -> PendingReconnect {
        PendingReconnect(volumeUUID: uuid, name: name, notBefore: now.addingTimeInterval(seconds),
                         tmDestinationID: "3C010DF9-BF9E-413F-8ACF-C06A4E3B5B78", stoppedBackup: true)
    }

    // MARK: - Volume state

    func testAMountedVolumeIsMounted() {
        let info: [String: Any] = ["MountPoint": "/Volumes/Time Machine WD", "Locked": NSNumber(value: false)]
        XCTAssertEqual(Reconnector.state(fromInfo: info), .mounted)
    }

    func testAnUnmountedEncryptedVolumeIsLockedAndKnowsItsDisk() {
        // What an encrypted APFS volume reads as after unmountDisk: the mount
        // point key is there but empty, and the volume is locked again.
        let info: [String: Any] = [
            "MountPoint": "",
            "Locked": NSNumber(value: true),
            "APFSPhysicalStores": [["APFSPhysicalStore": "disk6s2"]],
        ]
        XCTAssertEqual(Reconnector.state(fromInfo: info), .unmounted(wholeDisk: "disk6", locked: true))
    }

    func testAnUnmountedPlainVolumeIsNotLocked() {
        let info: [String: Any] = ["MountPoint": "", "ParentWholeDisk": "disk6"]
        XCTAssertEqual(Reconnector.state(fromInfo: info), .unmounted(wholeDisk: "disk6", locked: false))
    }

    func testAVolumeDiskutilDoesNotKnowHasBeenUnplugged() {
        XCTAssertEqual(Reconnector.state(fromInfo: nil), .gone)
    }

    // MARK: - Due, waiting, stale

    func testOnlyEntriesWhoseMeetingIsOverAreDue() {
        let over = entry(dueIn: -60, name: "over")
        let later = entry(dueIn: 600, name: "later")
        let plan = Reconnector.plan([over, later], now: now, busyUntil: nil)
        XCTAssertEqual(plan.due, [over])
        XCTAssertEqual(plan.waiting, [later])
    }

    func testAnEntryFromYesterdayIsDroppedNotMounted() {
        // The Mac slept through the evening: mounting the disk the next
        // morning out of nowhere would be a surprise.
        let stale = entry(dueIn: -(PendingReconnect.staleAfter + 60))
        let plan = Reconnector.plan([stale], now: now, busyUntil: nil)
        XCTAssertTrue(plan.due.isEmpty)
        XCTAssertTrue(plan.waiting.isEmpty)
    }

    func testAMeetingStillRunningPushesTheReconnectToItsEnd() {
        let over = entry(dueIn: -60)
        let end = now.addingTimeInterval(1800)
        let plan = Reconnector.plan([over], now: now, busyUntil: end)
        XCTAssertTrue(plan.due.isEmpty, "never mounted while the user may be walking off")
        XCTAssertEqual(plan.waiting.map(\.notBefore), [end])
    }

    func testABusyPeriodAlreadyOverDoesNotHoldAnythingBack() {
        let over = entry(dueIn: -60)
        let plan = Reconnector.plan([over], now: now, busyUntil: now.addingTimeInterval(-1))
        XCTAssertEqual(plan.due, [over])
    }

    // MARK: - Meetings in the way

    private func meeting(_ startMinutes: Double, _ endMinutes: Double) -> (start: Date, end: Date) {
        (now.addingTimeInterval(startMinutes * 60), now.addingTimeInterval(endMinutes * 60))
    }

    func testNoMeetingsMeansNotBusy() {
        XCTAssertNil(Meetings.busyUntil([], at: now, leadMinutes: 5))
    }

    func testAMeetingRunningNowIsBusyUntilItEnds() {
        XCTAssertEqual(Meetings.busyUntil([meeting(-30, 15)], at: now, leadMinutes: 5),
                       now.addingTimeInterval(15 * 60))
    }

    func testBackToBackMeetingsChain() {
        // 10:00-11:00 then 11:00-11:30: at 11:00 the disk waits for 11:30.
        let first = meeting(-60, 0.5)
        let second = meeting(0, 30)
        XCTAssertEqual(Meetings.busyUntil([second, first], at: now, leadMinutes: 5),
                       now.addingTimeInterval(30 * 60))
    }

    func testAMeetingStartingWithinTheLeadTimeCounts() {
        XCTAssertEqual(Meetings.busyUntil([meeting(4, 34)], at: now, leadMinutes: 5),
                       now.addingTimeInterval(34 * 60))
    }

    func testAMeetingLaterInTheDayDoesNotHoldTheDiskBack() {
        XCTAssertNil(Meetings.busyUntil([meeting(60, 90)], at: now, leadMinutes: 5))
    }

    func testAMeetingThatHasEndedIsIgnored() {
        XCTAssertNil(Meetings.busyUntil([meeting(-90, -30)], at: now, leadMinutes: 5))
    }

    // MARK: - Safety

    func testOnlyAUUIDIsEverHandedToDiskutil() {
        XCTAssertTrue(Reconnector.isVolumeUUID(uuid))
        // A name would be accepted by diskutil too, and could match another disk.
        XCTAssertFalse(Reconnector.isVolumeUUID("Time Machine WD"))
        XCTAssertFalse(Reconnector.isVolumeUUID("disk6"))
        XCTAssertFalse(Reconnector.isVolumeUUID("/Volumes/Time Machine WD"))
    }

    func testTheNotificationPromisesAReconnectOnlyWhenEveryDiskGetsOne() {
        var outcome = GuardRunner.Outcome()
        outcome.unmounted = ["Time Machine WD"]
        XCTAssertTrue(outcome.allReconnect)

        // A volume without a UUID was ejected for good and will not come back.
        outcome.ejected = ["Old FAT stick"]
        XCTAssertFalse(outcome.allReconnect)
        XCTAssertEqual(outcome.takenOff, ["Time Machine WD", "Old FAT stick"])

        XCTAssertFalse(GuardRunner.Outcome().allReconnect)
    }

    // MARK: - Persistence

    func testAPendingReconnectSurvivesARestart() throws {
        var config = GuardConfig()
        config.pendingReconnects = [entry(dueIn: 600)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(GuardConfig.self, from: encoder.encode(config))
        XCTAssertEqual(decoded.pendingReconnects, config.pendingReconnects)
    }

    func testAnOlderFileHasNothingPending() throws {
        let config = try JSONDecoder().decode(GuardConfig.self, from: Data(#"{ "leadMinutes": 7 }"#.utf8))
        XCTAssertTrue(config.pendingReconnects.isEmpty)
        XCTAssertEqual(config.leadMinutes, 7)
    }
}
