// The control channel between the command line tool and the running app.
//
// Without it the CLI and the app are two writers of one config file and two
// schedulers of one disk: `--eject-now` would run its own pass next to the
// app's, and a `--pause` would not show in the popover until something else
// made the app reread its settings. So whenever the app runs, the CLI asks it
// to act instead, and the app answers with what it did. When the app is not
// running there is nobody to race, and the CLI acts on its own as before.
//
// The channel is a Unix domain socket in the app's support folder:
// - the folder is 0700 and the socket 0600, and the server also checks the
//   peer's user id, so only the same user can connect;
// - nothing about it is reachable from a web page or another machine;
// - one request per connection, JSON, capped in size, with timeouts on both
//   ends, so a stuck or hostile peer cannot hold the app.

import Foundation

enum Control {
    /// Bumped when a request or response changes shape. A CLI and an app of
    /// different versions refuse each other rather than guess.
    static let version = 1
    /// Far more than any request or response needs.
    static let maxMessageBytes = 64 * 1024

    static var socketURL: URL { ConfigStore.directory.appendingPathComponent("control.sock") }

    enum Command: String, Codable, Sendable, CaseIterable {
        /// Is the app there? Changes nothing.
        case ping
        /// The CLI changed the config file; reread it and reschedule.
        case reload
        case ejectNow = "eject-now"
        case pause
        case resume
        case skipNext = "skip-next"
        case stopBackup = "stop-backup"

        /// How long the CLI waits for the answer. An eject may first wait for
        /// Time Machine to stop a backup to a share, which alone can take two
        /// minutes, and then retry a busy disk.
        var timeout: TimeInterval {
            switch self {
            case .ejectNow: return 600
            default: return 15
            }
        }
    }

    struct Request: Codable, Equatable, Sendable {
        var version = Control.version
        var command: Command
        /// For `pause`.
        var minutes: Int?
    }

    /// What the CLI prints and how it exits, decided by whoever did the work.
    struct Response: Codable, Equatable, Sendable {
        var version = Control.version
        var exitCode: Int32
        /// Printed to standard output.
        var lines: [String]
        /// Printed to standard error.
        var errors: [String]

        static func ok(_ lines: String...) -> Response { Response(exitCode: 0, lines: lines, errors: []) }
        static func failure(_ errors: String...) -> Response { Response(exitCode: 1, lines: [], errors: errors) }
    }

    enum ClientError: Error, Equatable {
        /// No socket, or nobody listening on it: the app is not running.
        case notRunning
        case timedOut
        case refused(String)
        case io(String)
    }

    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return try encoder.encode(value)
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try JSONDecoder().decode(type, from: data)
    }

    // MARK: - Client

    /// Sends one request and waits for the answer.
    static func send(_ request: Request, to path: String = socketURL.path,
                     timeout: TimeInterval? = nil) -> Result<Response, ClientError> {
        let fd: Int32
        switch UnixSocket.connect(to: path) {
        case .success(let value): fd = value
        case .failure(let error): return .failure(error)
        }
        defer { close(fd) }
        UnixSocket.setTimeouts(fd, seconds: timeout ?? request.command.timeout)

        do {
            try UnixSocket.writeAll(fd, encode(request))
            // Half close: the server reads to the end of the request.
            shutdown(fd, SHUT_WR)
            let data = try UnixSocket.readAll(fd, limit: maxMessageBytes)
            let response = try decode(Response.self, from: data)
            guard response.version == version else {
                return .failure(.refused("the app speaks control version \(response.version), this tool \(version)"))
            }
            return .success(response)
        } catch UnixSocket.Failure.timedOut {
            return .failure(.timedOut)
        } catch {
            return .failure(.io("\(error)"))
        }
    }

    /// The answer the server gives a request it cannot take, before any work.
    enum Precheck: Equatable {
        case accept(Request)
        case refuse(Response)
    }

    static func precheck(_ data: Data) -> Precheck {
        guard let request = try? decode(Request.self, from: data) else {
            return .refuse(.failure("unreadable request"))
        }
        guard request.version == version else {
            return .refuse(.failure("this app speaks control version \(version), the tool \(request.version); "
                                    + "use the eject-guard inside the installed app"))
        }
        return .accept(request)
    }
}

// MARK: - Server

/// Accepts connections on a background thread and hands each request to
/// `handler`, which answers through its completion when the work is done.
final class ControlServer: @unchecked Sendable {
    typealias Handler = @Sendable (Control.Request, @escaping @Sendable (Control.Response) -> Void) -> Void

    private let path: String
    private let handler: Handler
    private let lock = NSLock()
    private var listener: Int32 = -1
    private let connections = DispatchQueue(label: "sk.moravcik.tmejectguard.control", attributes: .concurrent)

    init(path: String = Control.socketURL.path, handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    func start() throws {
        let fd = try UnixSocket.listen(at: path)
        lock.lock(); listener = fd; lock.unlock()
        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "control accept"
        thread.start()
    }

    /// Closing the listener ends the accept loop; the socket file goes too,
    /// so the next CLI call knows at once that nobody is listening.
    func stop() {
        lock.lock()
        let fd = listener
        listener = -1
        lock.unlock()
        guard fd >= 0 else { return }
        close(fd)
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            connections.async { [self] in serve(client) }
        }
    }

    private func serve(_ fd: Int32) {
        defer { close(fd) }
        // Reading the request is quick; a peer that stalls is dropped.
        UnixSocket.setTimeouts(fd, seconds: 5)
        guard UnixSocket.peerUID(fd) == getuid() else {
            Log.write("control: refused a connection from another user")
            return
        }
        let response: Control.Response
        do {
            let data = try UnixSocket.readAll(fd, limit: Control.maxMessageBytes)
            switch Control.precheck(data) {
            case .refuse(let refusal):
                response = refusal
            case .accept(let request):
                response = wait(for: request)
            }
        } catch {
            response = .failure("could not read the request: \(error)")
        }
        UnixSocket.setTimeouts(fd, seconds: 5)
        try? UnixSocket.writeAll(fd, (try? Control.encode(response)) ?? Data())
    }

    /// Blocks this connection's worker, never the main thread, until the
    /// handler answers. A handler that never answers costs one worker, capped
    /// at the longest client timeout.
    private func wait(for request: Control.Request) -> Control.Response {
        final class Slot: @unchecked Sendable {
            var value: Control.Response?
        }
        let slot = Slot()
        let done = DispatchSemaphore(value: 0)
        handler(request) { response in
            slot.value = response
            done.signal()
        }
        // A little under the client's own wait, so the client hears why
        // rather than timing out on its own.
        let budget = max(request.command.timeout - 3, 1)
        guard done.wait(timeout: .now() + budget) == .success, let value = slot.value else {
            return .failure("the app did not finish in time; see the log")
        }
        return value
    }
}

// MARK: - Sockets

/// The few POSIX socket calls the channel needs, with errors as values.
enum UnixSocket {
    enum Failure: Error, Equatable {
        case pathTooLong
        case alreadyServing
        case timedOut
        case tooLarge
        case system(String, Int32)
    }

    private static func address(_ path: String) -> sockaddr_un? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    private static func withAddress<T>(_ address: sockaddr_un, _ body: (UnsafePointer<sockaddr>, socklen_t) -> T) -> T {
        var copy = address
        return withUnsafePointer(to: &copy) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    private static func newSocket() throws(Failure) -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw .system("socket", errno) }
        // A peer that goes away mid-write must cost an error, not a SIGPIPE
        // that takes the whole app down.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        return fd
    }

    static func connect(to path: String) -> Result<Int32, Control.ClientError> {
        guard let address = address(path) else { return .failure(.io("socket path too long: \(path)")) }
        let fd: Int32
        do { fd = try newSocket() } catch { return .failure(.io("\(error)")) }
        let result = withAddress(address) { Darwin.connect(fd, $0, $1) }
        guard result == 0 else {
            let code = errno
            close(fd)
            // No file, or a file nobody listens on: a crashed app leaves the
            // second behind.
            if code == ENOENT || code == ECONNREFUSED { return .failure(.notRunning) }
            return .failure(.io(String(cString: strerror(code))))
        }
        return .success(fd)
    }

    /// Binds and listens, replacing a socket file a previous run left behind,
    /// but never one another live process still answers on.
    static func listen(at path: String) throws(Failure) -> Int32 {
        guard let address = address(path) else { throw .pathTooLong }
        if FileManager.default.fileExists(atPath: path) {
            if case .success(let fd) = connect(to: path) {
                close(fd)
                throw .alreadyServing
            }
            unlink(path)
        }
        let fd = try newSocket()
        let bound = withAddress(address) { bind(fd, $0, $1) }
        guard bound == 0 else {
            let code = errno
            close(fd)
            throw .system("bind", code)
        }
        // The folder is already 0700; the socket itself is narrowed as well
        // so it does not depend on that alone.
        chmod(path, 0o600)
        guard Darwin.listen(fd, 8) == 0 else {
            let code = errno
            close(fd)
            unlink(path)
            throw .system("listen", code)
        }
        return fd
    }

    static func setTimeouts(_ fd: Int32, seconds: TimeInterval) {
        var value = timeval(tv_sec: Int(seconds), tv_usec: Int32((seconds - floor(seconds)) * 1_000_000))
        let size = socklen_t(MemoryLayout<timeval>.size)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &value, size)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &value, size)
    }

    static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
    }

    static func writeAll(_ fd: Int32, _ data: Data) throws(Failure) {
        var offset = 0
        let bytes = [UInt8](data)
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw .timedOut }
                throw .system("write", errno)
            }
            offset += written
        }
    }

    /// Reads until the peer closes its end.
    static func readAll(_ fd: Int32, limit: Int) throws(Failure) -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count == 0 { return data }
            if count < 0 {
                if errno == EINTR { continue }
                if errno == EAGAIN { throw .timedOut }
                throw .system("read", errno)
            }
            data.append(contentsOf: buffer[0..<count])
            if data.count > limit { throw .tooLarge }
        }
    }
}
