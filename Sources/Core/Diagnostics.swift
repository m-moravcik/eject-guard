// "Copy diagnostics": what a bug report needs, with the user's names left out.
//
// Eject Guard sends nothing anywhere on its own (VISION.md: the only network
// traffic is the update check). When something goes wrong, the user copies
// this text and decides whether to paste it into an issue. So it has to be
// enough to triage a report without a second round of questions, and it must
// not carry what the log deliberately keeps: meeting titles and disk names.
//
// A pure function over facts gathered by the app, so the redaction can be
// tested against real log lines without reading anybody's real log.

import Foundation

enum Diagnostics {
    struct Facts {
        var appVersion: String
        var build: String
        var developerIDSigned: Bool
        var bundlePath: String
        var macOS: String
        var model: String
        var calendarAccess: String
        var notifications: String
        var controlSocket: Bool
        var commandLine: String
        var config: GuardConfig
        var attached: [AttachedVolume]
        var logLines: [String]
        var home: String
    }

    /// How many log lines go in: enough for the last few meetings.
    static let logLineCount = 80

    static func report(_ facts: Facts, now: Date = Date()) -> String {
        let config = facts.config
        let labels = diskLabels(config.knownDisks)
        var lines: [String] = []
        lines.append("Eject Guard diagnostics, \(ISO8601DateFormatter().string(from: now))")
        lines.append("")
        lines.append("app:           \(facts.appVersion) (\(facts.build)), "
                     + (facts.developerIDSigned ? "Developer ID signed" : "not Developer ID signed")
                     + ", at \(home(facts.bundlePath, facts.home))")
        lines.append("macOS:         \(facts.macOS) on \(facts.model)")
        lines.append("calendar:      \(facts.calendarAccess)")
        lines.append("notifications: \(facts.notifications)")
        lines.append("control:       \(facts.controlSocket ? "listening" : "not listening")")
        lines.append("command line:  \(home(facts.commandLine, facts.home))")
        lines.append("")
        let paused = config.pausedUntil.map { $0 > now ? "paused until \(ISO8601DateFormatter().string(from: $0))" : "not paused" }
            ?? "not paused"
        lines.append("guard:         \(config.enabled ? "enabled" : "disabled"), \(paused)")
        lines.append("lead:          \(Int(config.leadMinutes)) min, at least \(config.minAttendees) attendees"
                     + (config.ignoreFreeEvents ? ", Free events ignored" : ""))
        lines.append("calendars:     " + (config.watchAllCalendars ? "all" : "\(config.watchedCalendarIDs.count) selected"))
        lines.append("eject on sleep: \(config.ejectOnSleep ? "on" : "off")")
        lines.append("skipped:       \(config.skippedEventIDs.count), hidden disks: \(config.dismissedDiskIDs.count)")
        lines.append("")
        lines.append("disks:")
        if config.knownDisks.isEmpty { lines.append("  none remembered") }
        for disk in config.knownDisks {
            var traits: [String] = []
            traits.append(config.watchedDiskIDs.contains(disk.id) ? "guarded" : "not guarded")
            if disk.isNetworkDestination {
                traits.append("network")
            } else if let volume = Disks.attachedVolume(for: disk, among: facts.attached) {
                traits.append("attached")
                traits.append(connection(volume.connection))
            } else {
                traits.append("not attached")
            }
            if disk.isTimeMachineDestination { traits.append("Time Machine") }
            if disk.volumeUUID == nil { traits.append("no volume UUID") }
            lines.append("  \(labels[disk.name] ?? "disk"): \(traits.joined(separator: ", "))")
        }
        lines.append("pending reconnects: \(config.pendingReconnects.count)")
        lines.append("")
        lines.append("log, last \(facts.logLines.count) lines, meeting titles and disk names replaced:")
        let names = config.knownDisks.map(\.name) + facts.attached.map(\.name)
            + config.pendingReconnects.map(\.name)
        for line in facts.logLines {
            lines.append("  " + redact(line, diskNames: names, labels: labels, home: facts.home))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// "disk 1", "disk 2", ... in the order the app lists them. Two disks
    /// with one name share a label, as they share it in the log.
    static func diskLabels(_ disks: [KnownDisk]) -> [String: String] {
        var labels: [String: String] = [:]
        for disk in disks where labels[disk.name] == nil {
            labels[disk.name] = "disk \(labels.count + 1)"
        }
        return labels
    }

    /// The pattern of the one log line that names a meeting:
    /// `<stamp>  <title> in <n> min -> <action>`. Greedy, so a title that
    /// itself contains " in 5 min" is still replaced whole.
    private static let meetingLine = try! NSRegularExpression(
        pattern: #"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  )(.+)( in -?\d+ min -> )"#)

    private static let quoted = try! NSRegularExpression(pattern: #""[^"]*""#)

    /// A log line Sanitize cut short ends in "…". A meeting line cut before
    /// " in N min ->" no longer matches `meetingLine`, so its title would pass
    /// through; such a line is left out whole rather than guessed at.
    private static let truncated = try! NSRegularExpression(pattern: #"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d  ).*…$"#)

    static func redact(_ line: String, diskNames: [String], labels: [String: String], home: String) -> String {
        var text = line
        let whole = NSRange(text.startIndex..., in: text)
        if truncated.firstMatch(in: text, range: whole) != nil {
            return truncated.stringByReplacingMatches(in: text, range: whole, withTemplate: "$1[long line left out]")
        }
        let range = NSRange(text.startIndex..., in: text)
        text = meetingLine.stringByReplacingMatches(in: text, range: range, withTemplate: "$1[meeting]$3")
        // A quoted name is a disk the app may no longer remember, such as one
        // it forgot or the user hid: "forgot \"Old Backup\" - by hand".
        text = quoted.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                               withTemplate: "\"[disk]\"")
        // Longest first, so "Time Machine WD" is not half replaced by "Time".
        // Whole names only: a disk called "Sync" must not eat "Syncthing".
        for name in Set(diskNames).sorted(by: { $0.count > $1.count }) where !name.isEmpty {
            let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\p{L}\p{N}])"#
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let template = NSRegularExpression.escapedTemplate(for: labels[name] ?? "[disk]")
            text = expression.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text),
                                                       withTemplate: template)
        }
        return self.home(text, home)
    }

    private static func home(_ text: String, _ home: String) -> String {
        home.isEmpty ? text : text.replacingOccurrences(of: home, with: "~")
    }

    private static func connection(_ connection: Connection?) -> String {
        switch connection {
        case .usb?: return "USB"
        case .thunderbolt?: return "Thunderbolt"
        case .sdCard?: return "SD card"
        case nil: return "interface unknown"
        }
    }

    /// The newest `count` lines of the log, oldest first.
    static func logTail(_ url: URL = Log.url, count: Int = logLineCount) -> [String] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        return Array(lines.suffix(count))
    }

    /// `Mac16,1` and the like, from the kernel.
    static func hardwareModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "unknown" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
