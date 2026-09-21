// What Time Machine is doing right now.

import Foundation

/// What Time Machine is doing right now. Read on demand while the popover is
/// open, never on a background schedule.
struct BackupStatus {
    var running = false
    var mountPoint: String?
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
        // tmutil reports -1 while it is still sizing the job up.
        if let raw = (root["Percent"] as? NSNumber)?.doubleValue
            ?? Double(root["Percent"] as? String ?? ""), raw >= 0 {
            percent = min(max(raw, 0), 1)
        }
    }

    init() {}

    func isBackingUp(to path: String) -> Bool {
        // A running backup with no destination reported is still a reason to
        // show activity on the one disk being guarded.
        running && (mountPoint == nil || mountPoint == path)
    }
}
