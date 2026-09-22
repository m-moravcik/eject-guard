// Getting a disk safely off the machine.

import Foundation

enum Ejector {
    struct Result {
        var volume: AttachedVolume
        var succeeded: Bool
        var detail: String
    }

    static func eject(_ volume: AttachedVolume, config: GuardConfig, dryRun: Bool = false) -> Result {
        guard Disks.isMountedVolume(volume.path) else {
            return Result(volume: volume, succeeded: false, detail: "not a mounted volume")
        }
        if dryRun {
            Log.write("dry-run: would stop backup and eject \(volume.path)")
            return Result(volume: volume, succeeded: true, detail: "dry run")
        }

        stopBackupIfTargeting(volume)

        // Resolve before unmounting: once the volume is gone there is nothing
        // left to ask about. Ejecting the whole disk also unmounts every volume
        // on it, which is what Finder's eject button does.
        let target = DeviceResolver.ejectTarget(forMountPoint: volume.path)

        var lastOutput = ""
        for attempt in 1...max(1, config.ejectAttempts) {
            let result = Shell.run("/usr/sbin/diskutil", ["eject", target], timeout: 60)
            if result.status == 0 {
                Log.write("ejected \(volume.name) via \(target) on attempt \(attempt)")
                return Result(volume: volume, succeeded: true, detail: "ok")
            }
            lastOutput = result.output
            Log.write("eject \(volume.name) attempt \(attempt)/\(config.ejectAttempts) failed: \(result.output)")
            if attempt < config.ejectAttempts {
                Thread.sleep(forTimeInterval: config.ejectRetryDelay)
            }
        }

        let blockers = blockingProcesses(at: volume.path)
        Log.write("EJECT FAILED \(volume.name): \(lastOutput) | holding: \(blockers.isEmpty ? "unknown" : blockers)")
        return Result(volume: volume, succeeded: false, detail: blockers)
    }

    /// Stop a backup that is writing to this disk. A backup to another
    /// destination is left running.
    private static func stopBackupIfTargeting(_ volume: AttachedVolume) {
        let status = BackupStatus.current()
        guard status.isBackingUp(to: volume.path) else { return }
        // Measured at ~11 s on a real backup, so the default budget is too tight.
        let stop = Shell.run("/usr/bin/tmutil", ["stopbackup"], timeout: 120)
        Log.write("tmutil stopbackup -> status \(stop.status)\(stop.output.isEmpty ? "" : ": \(stop.output)")")
    }

    static func blockingProcesses(at path: String) -> String {
        // lsof walks the whole volume, which is slow on a big disk and is only
        // ever used to make an error message useful.
        let lsof = Shell.run("/usr/sbin/lsof", ["+D", path], timeout: 30)
        let names = Set(lsof.output.split(separator: "\n").dropFirst().compactMap {
            $0.split(separator: " ").first.map(String.init)
        })
        return names.sorted().prefix(4).joined(separator: ", ")
    }
}
