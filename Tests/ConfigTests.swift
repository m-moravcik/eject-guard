import XCTest
@testable import TMEjectGuardCore

/// The config decoder is hand written because the synthesised one throws on a
/// missing key even when the property has a default - which once silently reset
/// every setting the user had. These tests exist so that cannot happen again.
final class ConfigTests: XCTestCase {
    private func decode(_ json: String) throws -> GuardConfig {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(GuardConfig.self, from: Data(json.utf8))
    }

    func testMissingKeysKeepDefaultsAndPreserveWhatIsThere() throws {
        // A file written by an older build: none of the newer keys exist.
        let config = try decode("""
        {
          "watchedDiskIDs": ["DISK-A"],
          "knownDisks": [],
          "leadMinutes": 7
        }
        """)

        XCTAssertEqual(config.watchedDiskIDs, ["DISK-A"], "the user's selection must survive")
        XCTAssertEqual(config.leadMinutes, 7)
        XCTAssertTrue(config.watchAllCalendars, "a key added later must fall back to its default")
        XCTAssertFalse(config.ejectOnSleep)
        XCTAssertEqual(config.minAttendees, 2)
        XCTAssertNil(config.launchAtLoginIntent, "never asked is not the same as off")
    }

    /// The welcome tour is for new installs. Someone updating from a version
    /// without it must not be walked through the app they already use.
    func testAnOlderFileSkipsTheWelcomeTour() throws {
        let config = try decode(#"{ "watchedDiskIDs": ["DISK-A"] }"#)
        XCTAssertTrue(config.onboardingShown)
    }

    func testAFreshInstallStartsWithTheWelcomeTour() throws {
        XCTAssertFalse(GuardConfig().onboardingShown)
        // Written and read back before the tour was finished: still due.
        let config = try decode(#"{ "onboardingShown": false }"#)
        XCTAssertFalse(config.onboardingShown)
    }

    func testUnknownKeysAreIgnored() throws {
        let config = try decode("""
        { "watchedDiskIDs": ["DISK-A"], "somethingFromTheFuture": 42 }
        """)
        XCTAssertEqual(config.watchedDiskIDs, ["DISK-A"])
    }

    func testWrongTypeFallsBackToTheDefaultInsteadOfLosingEverything() throws {
        let config = try decode("""
        { "watchedDiskIDs": ["DISK-A"], "leadMinutes": "not a number" }
        """)
        XCTAssertEqual(config.watchedDiskIDs, ["DISK-A"])
        XCTAssertEqual(config.leadMinutes, GuardConfig().leadMinutes)
    }

    func testRoundTrip() throws {
        var original = GuardConfig()
        original.watchedDiskIDs = ["A", "B"]
        original.watchAllCalendars = false
        original.watchedCalendarIDs = ["cal-1"]
        original.leadMinutes = 10
        original.ejectOnSleep = true

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(try decoder.decode(GuardConfig.self, from: data), original)
    }

    /// A 1.4.2 file: disks without the size this release stores. Every
    /// disk, tick and absence must come through, with no size until the disk
    /// is seen again.
    func testDisksFromAnOlderFileDecodeWithoutASize() throws {
        let config = try decode("""
        {
          "watchedDiskIDs": ["VOL-1"],
          "dismissedDiskIDs": ["TM-9"],
          "knownDisks": [
            { "id": "VOL-1", "name": "Time Machine WD", "volumeUUID": "VOL-1",
              "tmDestinationID": "TM-1", "lastSeen": "2026-10-07T08:00:00Z" },
            { "id": "VOL-2", "name": "Macintosh HD", "volumeUUID": "VOL-2",
              "lastSeen": "2026-10-20T09:00:00Z", "absentSince": "2026-10-20T09:05:00Z" },
            { "id": "NET-1", "name": "NAS", "tmDestinationID": "NET-1", "network": true }
          ]
        }
        """)

        XCTAssertEqual(config.knownDisks.map(\.id), ["VOL-1", "VOL-2", "NET-1"])
        XCTAssertEqual(config.watchedDiskIDs, ["VOL-1"])
        XCTAssertEqual(config.dismissedDiskIDs, ["TM-9"])
        XCTAssertTrue(config.knownDisks.allSatisfy { $0.capacity == nil })
        XCTAssertNotNil(config.knownDisks[1].absentSince)
        XCTAssertTrue(config.knownDisks[2].isNetworkDestination)
    }

    func testADisksSizeSurvivesARoundTrip() throws {
        var original = GuardConfig()
        original.knownDisks = [KnownDisk(id: "VOL-1", name: "WD", volumeUUID: "VOL-1",
                                         capacity: 999_995_129_856)]
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(#""capacity":999995129856"#))

        XCTAssertEqual(try decode(String(decoding: data, as: UTF8.self)), original)
    }

    func testIsActive() {
        var config = GuardConfig()
        XCTAssertTrue(config.isActive)

        config.enabled = false
        XCTAssertFalse(config.isActive)

        config.enabled = true
        config.pausedUntil = Date().addingTimeInterval(600)
        XCTAssertFalse(config.isActive, "a live pause suspends the guard")

        config.pausedUntil = Date().addingTimeInterval(-600)
        XCTAssertTrue(config.isActive, "an expired pause does not")
    }

    func testSkipListIsBoundedAndDeduplicated() {
        var config = GuardConfig()
        config.skip("event-1")
        config.skip("event-1")
        XCTAssertEqual(config.skippedEventIDs, ["event-1"])

        for i in 0..<(GuardConfig.maxSkippedEvents + 20) {
            config.skip("event-\(i)")
        }
        XCTAssertEqual(config.skippedEventIDs.count, GuardConfig.maxSkippedEvents)
        XCTAssertEqual(config.skippedEventIDs.last, "event-\(GuardConfig.maxSkippedEvents + 19)",
                       "the newest skip must survive the trim")
    }
}
