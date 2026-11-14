// Whether and how Settings may put the bundled `eject-guard` on the PATH.
//
// The tool ships inside the app at Contents/Helpers/eject-guard, so it is
// always the app's own version and Sparkle updates both together. Getting it on
// the PATH is a symlink to that file; a link, not a copy, keeps working after
// every update because the bundle path stays the same.
//
// A pure function, like UpdaterGate: what may be overwritten with an
// administrator prompt is a decision a test has to be able to reach, and the
// real file system of whoever runs the tests is the last thing to try it on.

import Foundation

enum CommandLineLink {
    static let toolName = "eject-guard"
    /// Where Install... puts the link: on the default PATH of every macOS.
    static let installDirectory = "/usr/local/bin"
    static var installPath: String { "\(installDirectory)/\(toolName)" }

    /// The folders a link is looked for in, Homebrew's first.
    static func searchDirectories(home: String) -> [String] {
        ["/opt/homebrew/bin", "/usr/local/bin", "\(home)/.local/bin"]
    }

    /// What sits at one path.
    enum Entry: Equatable, Sendable {
        case nothing
        /// A symlink; `resolved` is nil when it points at nothing.
        case link(resolved: String?)
        /// A regular file or anything else that is not a symlink.
        case other
    }

    enum Refusal: Equatable, Sendable {
        /// macOS runs a downloaded app from a randomised read-only copy until
        /// it is moved; a link to that copy breaks on the next launch.
        case translocated
        /// From a mounted disk image or the Downloads folder: not installed yet.
        case notInstalled
        /// Something that is not an Eject Guard link already has the name.
        case occupied(path: String)
    }

    enum Decision: Equatable, Sendable {
        /// Already on the PATH through a link to an app's helper.
        case linked(at: String)
        case create(at: String)
        /// A link to an older copy of the app, or one that leads nowhere.
        case relink(at: String)
        case refuse(Refusal)
    }

    /// Whether `path` is the helper inside some copy of the app.
    static func isHelper(_ path: String) -> Bool {
        path.hasSuffix(".app/Contents/Helpers/\(toolName)")
    }

    static func bundleProblem(bundlePath: String, home: String) -> Refusal? {
        if bundlePath.contains("/AppTranslocation/") { return .translocated }
        if bundlePath.hasPrefix("/Volumes/") || bundlePath.hasPrefix("\(home)/Downloads/") { return .notInstalled }
        return nil
    }

    /// - Parameters:
    ///   - helperPath: this app's own helper, symlinks resolved.
    ///   - entries: what sits at `<dir>/eject-guard` for each search directory.
    static func decide(helperPath: String, bundlePath: String, home: String,
                       entries: [String: Entry]) -> Decision {
        // A link to this very app anywhere on the PATH is enough, wherever it
        // came from: install.sh or an earlier Install....
        for directory in searchDirectories(home: home) {
            let path = "\(directory)/\(toolName)"
            if case .link(let resolved?) = entries[path] ?? .nothing, resolved == helperPath {
                return .linked(at: path)
            }
        }
        if let problem = bundleProblem(bundlePath: bundlePath, home: home) { return .refuse(problem) }

        let target = installPath
        switch entries[target] ?? .nothing {
        case .nothing:
            return .create(at: target)
        case .link(nil):
            return .relink(at: target)
        case .link(let resolved?):
            // A link to some other copy of the app counts as ours to replace;
            // anything else belongs to someone else.
            return isHelper(resolved) && resolved != helperPath
                ? .relink(at: target)
                : .refuse(.occupied(path: target))
        case .other:
            return .refuse(.occupied(path: target))
        }
    }

    /// Reads the real file system for `decide`.
    static func entry(at path: String) -> Entry {
        let files = FileManager.default
        guard let destination = try? files.destinationOfSymbolicLink(atPath: path) else {
            return files.fileExists(atPath: path) ? .other : .nothing
        }
        let absolute = destination.hasPrefix("/")
            ? destination
            : URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent(destination).path
        // Followed to the end, so a link to a link still counts; a dangling
        // one resolves to nothing.
        let resolved = URL(fileURLWithPath: absolute).resolvingSymlinksInPath().path
        return files.fileExists(atPath: resolved) ? .link(resolved: resolved) : .link(resolved: nil)
    }

    static func currentEntries(home: String) -> [String: Entry] {
        var entries: [String: Entry] = [:]
        for directory in searchDirectories(home: home) {
            let path = "\(directory)/\(toolName)"
            entries[path] = entry(at: path)
        }
        return entries
    }

    /// The AppleScript run by `osascript` with the helper and the link as its
    /// two arguments. Paths reach the shell only through `quoted form of`,
    /// never spliced into the script text.
    static func installScript(relink: Bool) -> [String] {
        let ln = relink ? "ln -sfn " : "ln -s "
        return [
            "-e", "on run argv",
            "-e", "do shell script \"mkdir -p \" & quoted form of \(quoted(installDirectory)) & \" && \(ln)\" & "
                + "quoted form of (item 1 of argv) & \" \" & quoted form of (item 2 of argv) "
                + "with administrator privileges",
            "-e", "end run",
        ]
    }

    private static func quoted(_ text: String) -> String { "\"\(text)\"" }
}
