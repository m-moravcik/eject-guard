// The on-disk log. One line per entry, 0600, serialised across threads.

import Foundation

enum Log {
    // Under `swift test` the log goes to a temporary file: tests drive Shell
    // timeouts and eject failures on purpose, and those lines have no place in
    // the log you read after a real failure. The app and the CLI never load
    // XCTest, so this only ever decides for the test runner.
    static let url: URL = NSClassFromString("XCTestCase") != nil
        ? FileManager.default.temporaryDirectory.appendingPathComponent("eject-guard-tests.log")
        : FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/eject-guard.log")

    // Entries come from the main actor and from the work queue, so appends are
    // serialised: two interleaved writes would corrupt the one record you go
    // looking for after a failure.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var permissionsChecked = false

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        // One entry per line, always: a newline from a meeting title would
        // otherwise let anyone forge a log record.
        let line = "\(stamp.string(from: Date()))  \(Sanitize.oneLine(message, max: 500))\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        if isatty(STDERR_FILENO) == 1 {
            FileHandle.standardError.write(data)
        }
        // Keep the log from growing without bound, but roll it over rather
        // than delete it: the entry you want is usually the one just before
        // the rollover.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 512_000 {
            let previous = url.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: previous)
            try? FileManager.default.moveItem(at: url, to: previous)
        }
        // The log names your meetings, so it is nobody else's business on a
        // shared Mac. Create it 0600 rather than inheriting the umask, and
        // repair a file left 0644 by an earlier version - once per process,
        // because this runs on every line.
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(
                atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            permissionsChecked = true
        } else if !permissionsChecked {
            permissionsChecked = true
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}
