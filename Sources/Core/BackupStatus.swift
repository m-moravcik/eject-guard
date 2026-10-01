// What Time Machine is doing right now.

import Foundation

/// What Time Machine is doing right now. Read on demand while the popover is
/// open, never on a background schedule.
struct BackupStatus {
    var running = false
    var mountPoint: String?
    /// The Time Machine destination being written to. The only reliable link
    /// for a network destination, whose mount point is a disk image.
    var destinationID: String?
    /// 0...1 on the scale the Time Machine menu bar item shows, or nil when
    /// there is no figure to show: Time Machine is still sizing the job up, or
    /// is in a phase other than copying, where it shows no number either.
    var percent: Double?

    /// Spawns `tmutil`, so never call this on the main thread.
    static func current() -> BackupStatus {
        let output = Shell.run("/usr/bin/tmutil", ["status", "-X"], timeout: 15)
        guard output.status == 0, let root = Shell.plist(from: output.output) else {
            return BackupStatus()
        }
        return BackupStatus(plist: root)
    }

    /// Pure: parsing is separated from running the tool so it can be tested.
    init(plist root: [String: Any]) {
        running = (root["Running"] as? NSNumber)?.boolValue ?? false
        mountPoint = root["DestinationMountPoint"] as? String
        destinationID = root["DestinationID"] as? String
        // A number only while copying, as in the system menu. Older releases
        // report no phase at all, and then the figure is taken as it comes.
        if let phase = root["BackupPhase"] as? String, phase != "Copying" { return }
        // Current macOS nests the figure in `Progress`; older releases put it
        // at the top level. tmutil reports -1 while it is still sizing the job up.
        let progress = root["Progress"] as? [String: Any]
        guard let raw = Self.number(progress?["Percent"]) ?? Self.number(root["Percent"]), raw >= 0 else {
            return
        }
        let copy = min(raw, 1)
        // `Percent` covers the copy alone. `FractionOfProgressBar` is not
        // progress but the share of the whole bar the copy is given; the
        // phases before it fill the rest. The system bar is the sum, and
        // matches it to the tenth: 0.1 + 0.9 x 0.0389 = 13.5% shown, against
        // a bare 3.9%. One number everywhere beats a "correct" one that
        // reads as a bug next to Apple's.
        if let share = Self.number(root["FractionOfProgressBar"]), share > 0, share <= 1 {
            percent = (1 - share) + share * copy
        } else {
            percent = copy
        }
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue ?? (value as? String).flatMap(Double.init)
    }

    init() {}

    func isBackingUp(to volume: AttachedVolume) -> Bool {
        guard running else { return false }
        if let destinationID, let target = volume.tmDestinationID { return destinationID == target }
        if let mountPoint { return mountPoint == volume.path }
        // A running backup with no destination reported is still a reason to
        // show activity on the one disk being guarded.
        return destinationID == nil
    }

    func isBackingUp(toDestination id: String?) -> Bool {
        guard running, let id else { return false }
        return destinationID == id
    }

    /// The disks and shares this backup writes to, named as the popover names
    /// them, whether or not they are guarded. Progress is worth showing for
    /// any backup; guarding only decides what gets stopped or ejected.
    ///
    /// Empty when the backup reports no destination at all. `isBackingUp(to:)`
    /// counts that against every disk, which is right before an eject and
    /// wrong here: it would name every disk plugged in.
    func destinationNames(attached: [AttachedVolume], known: [KnownDisk]) -> [String] {
        guard running, destinationID != nil || mountPoint != nil else { return [] }
        let volumes = attached.filter { isBackingUp(to: $0) }.map(\.name)
        let shares = known
            .filter { $0.isNetworkDestination && isBackingUp(toDestination: $0.tmDestinationID) }
            .map(\.name)
        return volumes + shares
    }
}
