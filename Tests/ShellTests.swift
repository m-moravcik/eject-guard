import XCTest
@testable import TMEjectGuardCore

final class ShellTests: XCTestCase {
    func testOutputAndStatusOfANormalCommand() {
        let result = Shell.run("/bin/sh", ["-c", "echo hello; exit 3"])
        XCTAssertEqual(result.status, 3)
        XCTAssertEqual(result.output, "hello")
    }

    /// A hung `tmutil destinationinfo` that outlived SIGTERM used to crash the
    /// app: reading `terminationStatus` of a running task raises an exception.
    func testAChildThatIgnoresSIGTERMIsKilledInsteadOfCrashing() {
        let started = Date()
        let result = Shell.run(
            "/bin/sh", ["-c", "trap '' TERM; exec sleep 30"],
            timeout: 0.5, killGrace: 1)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    /// The test above logs a timeout; it must land in a scratch file, not in
    /// the log a user reads after a failed eject.
    func testTestsNeverWriteToTheUserLog() throws {
        let userLog = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/eject-guard.log")
        XCTAssertNotEqual(Log.url.standardizedFileURL, userLog.standardizedFileURL)

        let before = try? Data(contentsOf: userLog)
        let marker = "test marker \(UUID().uuidString)"
        Log.write(marker)
        XCTAssertEqual(try? Data(contentsOf: userLog), before)
        XCTAssertTrue(try String(contentsOf: Log.url, encoding: .utf8).contains(marker))
    }
}
