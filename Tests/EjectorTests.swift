import XCTest
@testable import TMEjectGuardCore

final class EjectorTests: XCTestCase {
    /// Field output from `lsof -F c +D` on a Mac with a Time Machine share
    /// mounted, with the warning lsof prints to stderr, which Shell.run merges
    /// in. Read as a table, a failed eject was "Held by Output, assuming."
    func testLsofWarningsAreNotTakenForProcessNames() {
        let output = """
            lsof: WARNING: can't stat() smbfs file system /Volumes/.timemachine/10.2.0.180/8E59/time_mbp_m5
                  Output information may be incomplete.
                  assuming "dev=360000bf" from mount table
            p30204
            czsh
            f3
            p56907
            cbash
            f3
            f4
            """
        XCTAssertEqual(Ejector.holderNames(fromLsof: output), "bash, zsh")
    }

    /// A timed-out lsof is killed before it flushes its listing, leaving only
    /// the warnings: that is an unknown holder, not one called "Output".
    func testOnlyWarningsMeansNoKnownHolder() {
        let output = """
            lsof: WARNING: can't stat() smbfs file system /Volumes/.timemachine/x
                  Output information may be incomplete.
                  assuming "dev=360000bf" from mount table
            """
        XCTAssertEqual(Ejector.holderNames(fromLsof: output), "")
    }
}
