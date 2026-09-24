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
}
