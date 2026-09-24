// Running external tools, and the seam that decides how a notification is posted.

import Foundation

enum Shell {
    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = Data()

        var data: Data {
            get { lock.lock(); defer { lock.unlock() }; return stored }
            set { lock.lock(); defer { lock.unlock() }; stored = newValue }
        }
    }

    /// Run a command and wait for it.
    ///
    /// Deliberately does **not** use `Process.waitUntilExit()`. That method runs
    /// the run loop while it waits, so on the main thread it re-enters whatever
    /// the run loop delivers next - including our own volume notifications. That
    /// is how this app deadlocked on a non-recursive lock it already held. A
    /// semaphore blocks the calling thread and nothing else.
    ///
    /// The timeout is the second half of the same lesson: a wedged child process
    /// must never be able to hold anything forever. A child that ignores SIGTERM
    /// gets SIGKILL after `killGrace`, and the exit status is only read once the
    /// child is really gone: `Process.terminationStatus` raises an Objective-C
    /// exception on a running task, which is how a hung `tmutil` crashed the app.
    @discardableResult
    static func run(
        _ launchPath: String,
        _ arguments: [String],
        timeout: TimeInterval = 20,
        killGrace: TimeInterval = 5
    ) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe

        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }

        do { try task.run() } catch { return (-1, "\(error)") }

        // Drain the pipe on another thread: a child that fills the buffer would
        // block forever if nobody is reading while we wait.
        let box = Box()
        let drained = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            box.data = pipe.fileHandleForReading.readDataToEndOfFile()
            drained.signal()
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            Log.write("timeout after \(Int(timeout))s: \(launchPath) \(arguments.joined(separator: " "))")
            task.terminate()
            if finished.wait(timeout: .now() + killGrace) == .timedOut {
                Log.write("SIGTERM ignored, sending SIGKILL: \(launchPath)")
                kill(task.processIdentifier, SIGKILL)
                _ = finished.wait(timeout: .now() + killGrace)
            }
        }
        _ = drained.wait(timeout: .now() + killGrace)

        let out = String(data: box.data, encoding: .utf8) ?? ""
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isRunning else {
            Log.write("still running after SIGKILL, abandoning: \(launchPath)")
            return (-1, trimmed)
        }
        return (task.terminationStatus, trimmed)
    }

    static func plist(from output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return root
    }

    /// Fallback used by the command line tool, which has no bundle and so
    /// cannot post a user notification of its own.
    static func notifyViaAppleScript(title: String, body: String) {
        // AppleScript string literals: backslashes first, then quotes.
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        run("/usr/bin/osascript", ["-e",
            "display notification \"\(esc(Sanitize.oneLine(body)))\" "
            + "with title \"\(esc(Sanitize.oneLine(title)))\" sound name \"Submarine\""],
            timeout: 15)
    }
}

/// Indirection so the app can post real user notifications while the CLI falls
/// back to AppleScript. Under the hardened runtime the AppleScript route is not
/// dependable, and the app has a bundle identity that can do it properly.
enum Notify {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (String, String) -> Void = { title, body in
        Shell.notifyViaAppleScript(title: title, body: body)
    }

    /// Set once at startup, before anything can eject. Behind a lock because
    /// the writer is the app launching and the readers are the work queue.
    static func setHandler(_ newHandler: @escaping (String, String) -> Void) {
        lock.lock(); defer { lock.unlock() }
        handler = newHandler
    }

    static func post(title: String, body: String) {
        lock.lock()
        let current = handler
        lock.unlock()
        current(title, body)
    }
}
