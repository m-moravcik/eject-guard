// What the command line tool prints, decided in one place.
//
// The same action can run in the app (asked over the control socket) or in
// the CLI itself (when the app is not running). Either way the user reads the
// same lines and a script sees the same exit code.

import Foundation

enum Reports {
    static func eject(_ outcome: GuardRunner.Outcome) -> Control.Response {
        var lines: [String] = []
        var errors: [String] = []
        if outcome.didNothing {
            lines.append("no guarded disk is attached, and no backup to a guarded share is running")
        }
        for name in outcome.ejected { lines.append("ejected: \(name)") }
        for failure in outcome.failed {
            errors.append("FAILED: \(failure.name) - held by \(GuardRunner.holder(failure.detail))")
        }
        appendBackupStops(outcome, lines: &lines, errors: &errors)
        return Control.Response(exitCode: errors.isEmpty ? 0 : 1, lines: lines, errors: errors)
    }

    static func appendBackupStops(_ outcome: GuardRunner.Outcome, lines: inout [String], errors: inout [String]) {
        for name in outcome.stoppedBackups { lines.append("stopped backup: \(name)") }
        for name in outcome.unstoppedBackups { errors.append("FAILED: the backup to \(name) is still running") }
    }

    static func paused(until date: Date) -> Control.Response {
        .ok("guard paused until \(clock(date))")
    }

    static let resumed = Control.Response.ok("guard resumed")

    static func skipped(title: String?, start: Date) -> Control.Response {
        .ok("skipping \"\(title ?? "?")\" at \(clock(start)) - undo with --unskip")
    }

    static let nothingToSkip = Control.Response(
        exitCode: 1, lines: [], errors: ["no qualifying meeting today to skip"])

    static let noBackupRunning = Control.Response.ok("Time Machine is not backing up - nothing to stop")

    static func stopRequested(_ names: String) -> Control.Response {
        .ok("asked Time Machine to stop the backup to \(names); a backup to a share can take two minutes to end")
    }

    static let stopNotTaken = Control.Response.failure("Time Machine did not take the request to stop - see the log")

    static let busy = Control.Response.failure("a pass is already running - try again in a moment")

    static func badMinutes(_ value: Int?) -> Control.Response {
        .failure("--pause needs a positive number of minutes, not \(value.map(String.init) ?? "nothing")")
    }

    static func clock(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}

/// The state `eject-guard --json` prints. Field names are a contract for
/// scripts, so they only ever grow.
struct StatusReport: Codable, Equatable {
    struct Disk: Codable, Equatable {
        var id: String
        var name: String
        var guarded: Bool
        var attached: Bool
        var timeMachine: Bool
        var network: Bool
    }

    struct Meeting: Codable, Equatable {
        var title: String
        var start: Date
        var calendar: String
    }

    struct Reconnect: Codable, Equatable {
        var name: String
        var notBefore: Date
    }

    var version: String
    var enabled: Bool
    var pausedUntil: Date?
    var leadMinutes: Double
    var appRunning: Bool
    var disks: [Disk]
    var pendingReconnects: [Reconnect]
    /// Nil when there is none in the next 24 hours, or no calendar access.
    var nextMeeting: Meeting?
    var calendarAccess: Bool

    static func json(_ report: StatusReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        let data = (try? encoder.encode(report)) ?? Data()
        return String(data: data, encoding: .utf8) ?? "{}"
    }
}
