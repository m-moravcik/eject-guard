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
