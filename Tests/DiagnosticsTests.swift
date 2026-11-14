import XCTest
@testable import TMEjectGuardCore

/// Copy diagnostics must be enough to triage a report and must not carry the
/// two things the log deliberately keeps: meeting titles and disk names. The
/// log lines below have the exact shapes the app, GuardRunner and Ejector
/// write.
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

    func testTheCommandLineTriggerFormIsReplacedWholeEvenWithAQuoteInTheTitle() {
        XCTAssertEqual(
            redact("2026-11-13 14:25:07  trigger: \"Q4 \"final\" review\" in 5 min -> unmounting Sync (/Volumes/Sync)"),
            "2026-11-13 14:25:07  [meeting] in 5 min -> unmounting disk 2 (/Volumes/disk 2)")
    }

    func testATitleWithALineSeparatorAnOlderVersionLoggedIsStillReplaced() {
        XCTAssertEqual(
            redact("2026-11-13 14:25:07  Board\u{2028}Q4 cuts in 5 min -> unmounting Sync (/Volumes/Sync)"),
            "2026-11-13 14:25:07  [meeting] in 5 min -> unmounting disk 2 (/Volumes/disk 2)")
    }

    func testAStampA12HourSettingRewroteStillHidesTheTitle() {
        XCTAssertEqual(
            redact("2026-11-13 2:25:07 PM  1on1 Anna in 5 min -> unmounting Sync"),
            "2026-11-13 2:25:07 PM  [meeting] in 5 min -> unmounting disk 2")
    }

    func testLineAndParagraphSeparatorsNeverReachTheLog() {
        XCTAssertEqual(Sanitize.oneLine("Board\u{2028}Q4\u{2029}cuts\u{85}now"), "Board Q4 cuts now")
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

    /// macOS allows a double quote in a volume name; such a name must still go
    /// whole, not be split at its quotes.
    func testAKnownDiskNameWithAQuoteInItIsReplacedWhole() {
        let name = "Bob's \"Work\" SSD"
        XCTAssertEqual(
            Diagnostics.redact("2026-11-13 15:02:00  reconnected Bob's \"Work\" SSD",
                               diskNames: [name], labels: [name: "disk 3"], home: home),
            "2026-11-13 15:02:00  reconnected disk 3")
    }

    func testAForgottenDiskNameWithAQuoteInItIsReplacedWhole() {
        let facts = Diagnostics.Facts(
            appVersion: "1.7", build: "200", developerIDSigned: true,
            bundlePath: "/Applications/Eject Guard.app", macOS: "Version 27.0", model: "Mac16,1",
            calendarAccess: "granted", notifications: "on", controlSocket: true,
            commandLine: "not installed", config: GuardConfig(), attached: [],
            logLines: [
                "2026-11-13 14:25:09  ejected Bob's \"Work\" SSD via disk4 on attempt 1",
                "2026-11-13 16:40:12  forgot \"Bob's \"Work\" SSD\" - by hand",
            ],
            home: home)
        let report = Diagnostics.report(facts)
        for part in ["Bob", "Work", "SSD"] {
            XCTAssertFalse(report.contains(part), "the report contains \(part)")
        }
        XCTAssertTrue(report.contains("  2026-11-13 14:25:09  ejected [disk] via disk4 on attempt 1\n"))
        XCTAssertTrue(report.contains("  2026-11-13 16:40:12  forgot \"[disk]\" - by hand\n"))
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

    /// Unmounted for a meeting, unplugged, then forgotten by hand: the app no
    /// longer remembers "Old Backup", but older lines still name it unquoted.
    func testADiskForgottenAfterItWasLoggedIsReplacedInTheOlderLines() {
        let facts = Diagnostics.Facts(
            appVersion: "1.7", build: "200", developerIDSigned: true,
            bundlePath: "/Applications/Eject Guard.app", macOS: "Version 27.0", model: "Mac16,1",
            calendarAccess: "granted", notifications: "on", controlSocket: true,
            commandLine: "not installed", config: GuardConfig(), attached: [],
            logLines: [
                "2026-11-13 14:25:07  Weekly in 5 min -> unmounting Old Backup (/Volumes/Old Backup)",
                "2026-11-13 14:25:09  ejected Old Backup via disk4 on attempt 1",
                "2026-11-13 15:02:00  reconnected Old Backup",
                "2026-11-13 16:40:12  forgot \"Old Backup\" - by hand",
            ],
            home: home)
        let report = Diagnostics.report(facts)
        XCTAssertFalse(report.contains("Old Backup"))
        XCTAssertTrue(report.contains("  2026-11-13 14:25:07  [meeting] in 5 min -> unmounting [disk] (/Volumes/[disk])\n"))
        XCTAssertTrue(report.contains("  2026-11-13 14:25:09  ejected [disk] via disk4 on attempt 1\n"))
        XCTAssertTrue(report.contains("  2026-11-13 16:40:12  forgot \"[disk]\" - by hand\n"))
    }
}
