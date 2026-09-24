import XCTest
@testable import TMEjectGuardCore

/// The rename from TM Eject Guard must not cost anyone their settings.
final class ConfigMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("config-migration-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func write(_ text: String, to folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try text.write(to: folder.appendingPathComponent("config.json"), atomically: true, encoding: .utf8)
    }

    private func read(_ folder: URL) -> String? {
        try? String(contentsOf: folder.appendingPathComponent("config.json"), encoding: .utf8)
    }

    func testTheOldFolderMovesToTheNewName() throws {
        let legacy = root.appendingPathComponent("TMEjectGuard")
        let current = root.appendingPathComponent("EjectGuard")
        try write("old", to: legacy)

        XCTAssertTrue(ConfigStore.migrate(from: legacy, to: current))
        XCTAssertEqual(read(current), "old")
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path),
                       "a copy would leave two configs to drift apart")
    }

    func testAnExistingNewFolderWins() throws {
        let legacy = root.appendingPathComponent("TMEjectGuard")
        let current = root.appendingPathComponent("EjectGuard")
        try write("old", to: legacy)
        try write("new", to: current)

        XCTAssertFalse(ConfigStore.migrate(from: legacy, to: current))
        XCTAssertEqual(read(current), "new")
        XCTAssertEqual(read(legacy), "old", "nothing is thrown away")
    }

    func testNothingToMigrate() {
        XCTAssertFalse(ConfigStore.migrate(from: root.appendingPathComponent("missing"),
                                           to: root.appendingPathComponent("EjectGuard")))
    }
}
