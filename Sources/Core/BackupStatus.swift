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
    /// 0...1, or nil when Time Machine has not worked out a figure yet.
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
        // Current macOS nests the figure in `Progress`; older releases put it
        // at the top level. Not `FractionOfProgressBar`: that one spans every
        // phase of the job and sat at 0.9 while the copy was a quarter done.
        // tmutil reports -1 while it is still sizing the job up.
        let progress = root["Progress"] as? [String: Any]
        if let raw = Self.number(progress?["Percent"]) ?? Self.number(root["Percent"]), raw >= 0 {
            percent = min(max(raw, 0), 1)
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
