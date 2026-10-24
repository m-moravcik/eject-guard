// Stopping and starting a Time Machine backup on request.
//
// On its own the guard only ever stops a backup to a guarded disk, on its way
// to taking that disk off. These are the user's own requests, for any
// destination, guarded or not: a backup slowing the Mac down can be stopped,
// and one can be started without waiting for the hourly run. Neither is
// remembered. A backup stopped by hand is not started again after a meeting
// the way one the guard stopped is (`PendingReconnect.stoppedBackup`), and
// Time Machine carries on at its next scheduled backup.

import Foundation

enum BackupControl {
    /// How long a stop may take to show. A share sat in `Stopping` for ~55 s
    /// (see `Ejector.stopBackup(to:)`).
    static let stopBudget = Ejector.stopBackupBudget
    /// How long a start may take to show. Time Machine reports a backup as
    /// running from the moment it takes the request, before it mounts a share.
    static let startBudget: TimeInterval = 30

    /// The destination to start a backup to for `disk`, nil when none can be
    /// started there: a destination Time Machine reports, and for a disk, one
    /// that is plugged in. A disk unmounted for a meeting is not: an
    /// encrypted one is locked again by the unmount, and a backup to it fails
    /// (see Reconnecting.swift). A share is never plugged in; Time Machine
    /// mounts it itself.
    static func destinationToStart(_ disk: KnownDisk, attached: [AttachedVolume],
                                   reportedDestinationIDs: Set<String>) -> String? {
        guard let id = disk.tmDestinationID, reportedDestinationIDs.contains(id) else { return nil }
        if !disk.isNetworkDestination, Disks.attachedVolume(for: disk, among: attached) == nil { return nil }
        return id
    }

    /// Asks Time Machine to stop the backup it is running. There is only ever
    /// one, so there is no destination to name. Only the request: whether it
    /// stopped is for `BackupRequest` to tell. Spawns `tmutil`, so never on the
    /// main thread.
    static func stop() -> Bool {
        // Measured at ~11 s on a real backup, so the default budget is too tight.
        let result = Shell.run("/usr/bin/tmutil", ["stopbackup"], timeout: 120)
        Log.write("tmutil stopbackup - by hand -> status \(result.status)"
            + (result.output.isEmpty ? "" : ": \(result.output)"))
        return result.status == 0
    }

    /// Asks Time Machine to back up to one destination now, as the system
    /// menu's "Back Up Now" does, rather than in the background mode of a
    /// scheduled backup (`--auto`). Returns once the request is taken.
    static func start(destinationID: String, name: String) -> Bool {
        let result = Shell.run("/usr/bin/tmutil", ["startbackup", "--destination", destinationID], timeout: 30)
        Log.write("tmutil startbackup to \(name) - by hand -> status \(result.status)"
            + (result.output.isEmpty ? "" : ": \(result.output)"))
        return result.status == 0
    }
}

/// A stop or a start the user asked for, from the request until Time Machine
/// shows it took. Settled against each status read rather than waited out on
/// the work queue, which an eject pass needs.
struct BackupRequest: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case stop
        case start(destinationID: String)
    }

    enum Settled: Equatable {
        case pending, done, failed
    }

    var kind: Kind
    /// The disk or share it is about, for saying it did not take.
    var name: String
    var deadline: Date

    /// The row to say "Starting backup…" on.
    var startingDestinationID: String? {
        if case .start(let id) = kind { return id }
        return nil
    }

    /// Whether `status` shows the request took. A start is done once any
    /// backup runs: Time Machine runs one at a time, and whichever it is, the
    /// popover now shows where it writes. A late answer still counts.
    func settle(_ status: BackupStatus, now: Date) -> Settled {
        if took(status) { return .done }
        return now > deadline ? .failed : .pending
    }

    /// Whether `status` shows what was asked for, deadline or not. Once it
    /// does, saying the request failed is stale: a stop that did not take is
    /// over once nothing runs, and a start once a backup runs.
    func took(_ status: BackupStatus) -> Bool {
        kind == .stop ? !status.running : status.running
    }

    /// Whether a start can no longer be made where it was asked for: the disk
    /// is unplugged, or Time Machine no longer reports the destination. Saying
    /// it failed is then stale too. A stop names no destination.
    func lostDestination(_ knownDisks: [KnownDisk], attached: [AttachedVolume],
                         reportedDestinationIDs: Set<String>) -> Bool {
        guard let id = startingDestinationID else { return false }
        return !knownDisks.contains {
            BackupControl.destinationToStart($0, attached: attached,
                                             reportedDestinationIDs: reportedDestinationIDs) == id
        }
    }
}
