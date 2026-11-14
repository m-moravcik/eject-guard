import XCTest
@testable import TMEjectGuardCore

/// The control channel against a real socket in a temporary folder: the CLI's
/// side and the app's side, as they talk to each other.
final class ControlTests: XCTestCase {
    private var folder: URL!
    private var path: String { folder.appendingPathComponent("c.sock").path }

    override func setUpWithError() throws {
        // Short on purpose: a socket path must fit in 104 bytes.
        folder = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(String(UUID().uuidString.prefix(8)))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    func testNobodyListeningMeansTheAppIsNotRunning() {
        XCTAssertEqual(Control.send(Control.Request(command: .ping), to: path).failure, .notRunning)
    }

    func testASocketLeftByACrashedAppMeansNotRunningAndIsReplaced() throws {
        // A crashed app leaves the file without a listener.
        let stale = try UnixSocket.listen(at: path)
        close(stale)
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(Control.send(Control.Request(command: .ping), to: path).failure, .notRunning)

        let server = ControlServer(path: path) { _, reply in reply(.ok("pong")) }
        try server.start()
        defer { server.stop() }
        XCTAssertEqual(Control.send(Control.Request(command: .ping), to: path).success?.lines, ["pong"])
    }

    func testTheHandlersAnswerReachesTheClientWithItsExitCode() throws {
        let server = ControlServer(path: path) { request, reply in
            // Answered later, from another queue, as the app does after a pass.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) {
                reply(Control.Response(exitCode: 1, lines: ["minutes \(request.minutes ?? 0)"],
                                       errors: ["FAILED: WD - held by Finder"]))
            }
        }
        try server.start()
        defer { server.stop() }

        let response = Control.send(Control.Request(command: .pause, minutes: 30), to: path).success
        XCTAssertEqual(response, Control.Response(exitCode: 1, lines: ["minutes 30"],
                                                  errors: ["FAILED: WD - held by Finder"]))
    }

    func testASecondAppDoesNotTakeOverALiveSocket() throws {
        let server = ControlServer(path: path) { _, reply in reply(.ok()) }
        try server.start()
        defer { server.stop() }
        XCTAssertThrowsError(try UnixSocket.listen(at: path)) { error in
            XCTAssertEqual(error as? UnixSocket.Failure, .alreadyServing)
        }
    }

    func testStoppingRemovesTheSocketSoTheCLIActsOnItsOwn() throws {
        let server = ControlServer(path: path) { _, reply in reply(.ok()) }
        try server.start()
        server.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path))
        XCTAssertEqual(Control.send(Control.Request(command: .ping), to: path).failure, .notRunning)
    }

    func testTheSocketIsReadableByItsOwnerOnly() throws {
        let server = ControlServer(path: path) { _, reply in reply(.ok()) }
        try server.start()
        defer { server.stop() }
        let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testARequestFromAnotherVersionIsRefusedBeforeAnyWork() throws {
        var request = Control.Request(command: .ejectNow)
        request.version = Control.version + 1
        guard case .refuse(let response) = Control.precheck(try Control.encode(request)) else {
            return XCTFail("a request from another version was accepted")
        }
        XCTAssertEqual(response.exitCode, 1)
    }

    func testGarbageIsRefused() {
        guard case .refuse = Control.precheck(Data("eject everything".utf8)) else {
            return XCTFail("an unreadable request was accepted")
        }
    }

    func testAnOversizedRequestNeverReachesTheHandler() throws {
        final class Flag: @unchecked Sendable { var called = false }
        let flag = Flag()
        let server = ControlServer(path: path) { _, reply in
            flag.called = true
            reply(.ok())
        }
        try server.start()
        defer { server.stop() }

        guard case .success(let fd) = UnixSocket.connect(to: path) else { return XCTFail("could not connect") }
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, seconds: 5)
        try? UnixSocket.writeAll(fd, Data(repeating: UInt8(ascii: "x"), count: Control.maxMessageBytes + 10))
        shutdown(fd, SHUT_WR)
        let answer = try UnixSocket.readAll(fd, limit: Control.maxMessageBytes)
        XCTAssertEqual(try Control.decode(Control.Response.self, from: answer).exitCode, 1)
        XCTAssertFalse(flag.called)
    }
}

private extension Result {
    var success: Success? { if case .success(let value) = self { return value }; return nil }
    var failure: Failure? { if case .failure(let error) = self { return error }; return nil }
}
