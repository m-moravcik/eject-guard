import XCTest
@testable import TMEjectGuardCore

/// What Install... may do at /usr/local/bin/eject-guard. The rule, from the
/// house standard for a bundled CLI: create when free, relink a link to an
/// older copy of the app or one that leads nowhere, and never overwrite
/// anything else.
final class CommandLineLinkTests: XCTestCase {
    private let home = "/Users/someone"
    private let bundle = "/Applications/Eject Guard.app"
    private let helper = "/Applications/Eject Guard.app/Contents/Helpers/eject-guard"
    private let target = "/usr/local/bin/eject-guard"

    private func decide(_ entries: [String: CommandLineLink.Entry], bundle: String? = nil) -> CommandLineLink.Decision {
        CommandLineLink.decide(helperPath: helper, bundlePath: bundle ?? self.bundle, home: home, entries: entries)
    }

    func testNothingThereIsCreated() {
        XCTAssertEqual(decide([:]), .create(at: target))
    }

    func testALinkToThisAppAnywhereOnThePathCountsAsInstalled() {
        XCTAssertEqual(decide(["\(home)/.local/bin/eject-guard": .link(resolved: helper)]),
                       .linked(at: "\(home)/.local/bin/eject-guard"))
        XCTAssertEqual(decide([target: .link(resolved: helper)]), .linked(at: target))
    }

    func testADanglingLinkIsRelinked() {
        XCTAssertEqual(decide([target: .link(resolved: nil)]), .relink(at: target))
    }

    func testALinkToAnotherCopyOfTheAppIsRelinked() {
        let old = "/Users/someone/Desktop/Old/Eject Guard.app/Contents/Helpers/eject-guard"
        XCTAssertEqual(decide([target: .link(resolved: old)]), .relink(at: target))
    }

    func testALinkToSomethingElseIsLeftAlone() {
        XCTAssertEqual(decide([target: .link(resolved: "/opt/tools/eject-guard")]),
                       .refuse(.occupied(path: target)))
    }

    func testARegularFileIsLeftAlone() {
        XCTAssertEqual(decide([target: .other]), .refuse(.occupied(path: target)))
    }

    func testATranslocatedOrUninstalledCopyIsAskedToMoveFirst() {
        XCTAssertEqual(decide([:], bundle: "/private/var/folders/x/AppTranslocation/ABC/d/Eject Guard.app"),
                       .refuse(.translocated))
        XCTAssertEqual(decide([:], bundle: "/Volumes/Eject Guard/Eject Guard.app"), .refuse(.notInstalled))
        XCTAssertEqual(decide([:], bundle: "\(home)/Downloads/Eject Guard.app"), .refuse(.notInstalled))
    }

    func testTheRealFileSystemIsReadAsLinksFilesAndNothing() throws {
        let folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real").path
        FileManager.default.createFile(atPath: real, contents: Data())
        let good = folder.appendingPathComponent("good").path
        let dangling = folder.appendingPathComponent("dangling").path
        try FileManager.default.createSymbolicLink(atPath: good, withDestinationPath: "real")
        try FileManager.default.createSymbolicLink(atPath: dangling, withDestinationPath: "gone")

        XCTAssertEqual(CommandLineLink.entry(at: good),
                       .link(resolved: URL(fileURLWithPath: real).resolvingSymlinksInPath().path))
        XCTAssertEqual(CommandLineLink.entry(at: dangling), .link(resolved: nil))
        XCTAssertEqual(CommandLineLink.entry(at: real), .other)
        XCTAssertEqual(CommandLineLink.entry(at: folder.appendingPathComponent("none").path), .nothing)
    }
}
