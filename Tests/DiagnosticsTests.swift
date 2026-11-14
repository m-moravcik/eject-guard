import XCTest
@testable import TMEjectGuardCore

/// Copy diagnostics must be enough to triage a report and must not carry the
/// two things the log deliberately keeps: meeting titles and disk names. The
/// log lines below have the exact shape GuardRunner and Ejector write.
final class DiagnosticsTests: XCTestCase {
    private let home = "/Users/someone"
    private let labels = ["Time Machine WD": "disk 1", "Sync": "disk 2"]
    private let names = ["Time Machine WD", "Sync"]

    private func redact(_ line: String) -> String {
        Diagnostics.redact(line, diskNames: names, labels: labels, home: home)
    }

    func testAMeetingTitleIsReplacedAndTheActionKept() {
        XCTAssertEqual(
            redact("2026-11-13 14:25:07  Servio 2.6: Sprint 12 - Review in 5 min -> unmounting Sync (/Volumes/Sync)"),
            "2026-11-13 14:25:07  [meeting] in 5 min -> unmounting disk 2 (/Volumes/disk 2)")
    }

    func testATitleThatItselfSaysInFiveMinIsReplacedWhole() {
        XCTAssertEqual(
            redact("2026-11-13 09:55:02  Standup in 5 min sharp in 5 min -> unmounting Sync (/Volumes/Sync)"),
            "2026-11-13 09:55:02  [meeting] in 5 min -> unmounting disk 2 (/Volumes/disk 2)")
    }

    func testDiskNamesAreReplacedWholeAndLongestFirst() {
        XCTAssertEqual(
            redact("2026-11-12 17:08:31  ejected Sync, Time Machine WD via disk10 on attempt 1"),
            "2026-11-12 17:08:31  ejected disk 2, disk 1 via disk10 on attempt 1")
        // Part of another word is not the disk.
        XCTAssertEqual(redact("2026-11-12 17:08:31  Syncthing holds it"),
                       "2026-11-12 17:08:31  Syncthing holds it")
    }

    func testAQuotedNameOfADiskNoLongerRememberedIsReplaced() {
        XCTAssertEqual(redact("2026-11-12 10:00:00  forgot \"Old Backup\" - not guarded and unplugged for 30 days"),
                       "2026-11-12 10:00:00  forgot \"[disk]\" - not guarded and unplugged for 30 days")
    }

    func testALineCutShortIsLeftOutWholeSoACutTitleCannotSlipThrough() {
        let title = String(repeating: "Quarterly planning with the board ", count: 20)
        let line = "2026-11-12 10:00:00  " + Sanitize.oneLine("\(title) in 5 min -> unmounting Sync", max: 500)
        XCTAssertEqual(redact(line), "2026-11-12 10:00:00  [long line left out]")
    }

    func testTheHomeFolderIsShortened() {
        XCTAssertEqual(redact("2026-11-12 10:00:00  config unreadable at /Users/someone/Library/x"),
                       "2026-11-12 10:00:00  config unreadable at ~/Library/x")
    }

    func testTheReportNamesNoDiskAndNoMeeting() {
        var config = GuardConfig()
        config.knownDisks = [
            KnownDisk(id: "A", name: "Time Machine WD", volumeUUID: "A", tmDestinationID: "T"),
            KnownDisk(id: "B", name: "Sync", volumeUUID: "B"),
        ]
        config.watchedDiskIDs = ["A"]
        let facts = Diagnostics.Facts(
            appVersion: "1.7", build: "200", developerIDSigned: true,
            bundlePath: "/Applications/Eject Guard.app", macOS: "Version 27.0", model: "Mac16,1",
            calendarAccess: "granted", notifications: "on", controlSocket: true,
            commandLine: "\(home)/.local/bin/eject-guard", config: config,
            attached: [AttachedVolume(path: "/Volumes/Sync", name: "Sync", volumeUUID: "B", connection: .usb)],
            logLines: ["2026-11-13 14:25:07  1on1 Anna in 5 min -> unmounting Sync (/Volumes/Sync)"],
            home: home)
        let report = Diagnostics.report(facts)
        for secret in ["Time Machine WD", "Sync", "1on1 Anna", home] {
            XCTAssertFalse(report.contains(secret), "the report contains \(secret)")
        }
        XCTAssertTrue(report.contains("disk 1: guarded, not attached, Time Machine"))
        XCTAssertTrue(report.contains("disk 2: not guarded, attached, USB"))
        XCTAssertTrue(report.contains("command line:  ~/.local/bin/eject-guard"))
    }
}
