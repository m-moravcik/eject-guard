import XCTest
@testable import TMEjectGuardCore

/// The guarantees this tool rests on. If any of these break, it can damage
/// something rather than merely fail to help.
final class SafetyTests: XCTestCase {
    func testTheBootVolumeIsNeverAnEjectCandidate() {
        XCTAssertFalse(Disks.isMountedVolume("/"))
        XCTAssertFalse(Disks.isMountedVolume("/System/Volumes/Data"))
        XCTAssertFalse(Disks.isMountedVolume("/Users"))
    }

    func testOnlyDirectChildrenOfVolumesQualify() {
        XCTAssertFalse(Disks.isMountedVolume("/Volumes"))
        XCTAssertFalse(Disks.isMountedVolume("/Volumes/"))
        XCTAssertFalse(Disks.isMountedVolume("/Volumes/Some Disk/subfolder"))
        XCTAssertFalse(Disks.isMountedVolume("/Volumes/definitely not mounted \(UUID().uuidString)"))
        XCTAssertFalse(Disks.isMountedVolume("../Volumes/escape"))
        XCTAssertFalse(Disks.isMountedVolume(""))
    }

    func testUntrustedTextCannotForgeALogLineOrBreakAppleScript() {
        let hostile = "Standup\nnot a real log line\r\u{0000}"
        let cleaned = Sanitize.oneLine(hostile)

        XCTAssertFalse(cleaned.contains("\n"))
        XCTAssertFalse(cleaned.contains("\r"))
        XCTAssertFalse(cleaned.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertTrue(cleaned.hasPrefix("Standup"))
    }

    func testSanitiseCapsLength() {
        let long = String(repeating: "a", count: 5_000)
        XCTAssertLessThanOrEqual(Sanitize.oneLine(long, max: 200).count, 201)
    }

    func testSanitiseLeavesOrdinaryTitlesAlone() {
        let title = "Weekly sync/review - príprava (Room 8.20)"
        XCTAssertEqual(Sanitize.oneLine(title), title)
    }
}
