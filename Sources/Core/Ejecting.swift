// Getting a disk safely off the machine.

import Foundation

enum Ejector {
    /// How far to take the disk.
    enum Mode {
        /// Unmount and power the device down, as Finder does. The user is
        /// about to unplug it; getting it back means replugging.
        case eject
        /// Unmount every volume but leave the device attached, so a disk that
        /// is still plugged in after the meeting can be mounted again. Just as
        /// safe to unplug: nothing is mounted and every write is flushed.
        case unmount
    }

    struct Result {
        var volume: AttachedVolume
        var succeeded: Bool
        var detail: String
        /// A Time Machine backup to this disk was stopped on the way.
        var stoppedBackup = false
    }

    /// Guarded volumes that one `diskutil` call takes off together. Every
    /// volume on a physical disk goes down with it, so two guarded volumes on
    /// one drive are one job: taken one at a time, the first call pulls the
    /// second volume from under a backup and leaves nothing for the second.
    struct Group: Equatable {
        /// The whole disk, or a mount point when no external disk could be
        /// proven behind it.
        var target: String
        var volumes: [AttachedVolume]
    }

    /// Group volumes by what `diskutil` is handed for them, in first-seen order.
    static func group(_ volumes: [AttachedVolume], target: (AttachedVolume) -> String) -> [Group] {
        var groups: [Group] = []
        for volume in volumes {
            let key = target(volume)
            if let index = groups.firstIndex(where: { $0.target == key }) {
                groups[index].volumes.append(volume)
            } else {
                groups.append(Group(target: key, volumes: [volume]))
            }
        }
        return groups
    }

    /// Resolves every volume's disk before anything is unmounted: once a
    /// volume is gone there is nothing left to ask about.
    static func groups(_ volumes: [AttachedVolume]) -> [Group] {
        group(volumes) { DeviceResolver.ejectTarget(forMountPoint: $0.path) }
    }

    /// Take a group off with one `diskutil` call. One result per volume that
    /// was mounted: a disk that will not go down as a whole can still have
    /// taken some of its volumes with it, and those are off.
    static func eject(_ group: Group, config: GuardConfig,
                      mode: Mode = .eject, dryRun: Bool = false) -> [Result] {
        let verb = mode == .eject ? "eject" : "unmount"
        let mounted = group.volumes.filter { volume in
            guard Disks.isMountedVolume(volume.path) else {
                Log.write("\(volume.name) is no longer mounted, nothing to \(verb)")
                return false
            }
            return true
        }
        guard !mounted.isEmpty else { return [] }
        let names = mounted.map(\.name).joined(separator: ", ")
        if dryRun {
            Log.write("dry-run: would stop backup and \(verb) \(names) via \(group.target)")
            return mounted.map { Result(volume: $0, succeeded: true, detail: "dry run") }
        }

        let stopped = stopBackupIfOnDisk(group, volumes: mounted)
        func result(_ volume: AttachedVolume, succeeded: Bool, detail: String) -> Result {
            Result(volume: volume, succeeded: succeeded, detail: detail,
                   stoppedBackup: stopped?.isBackingUp(to: volume) ?? false)
        }

        // Ejecting the whole disk also unmounts every volume on it, which is
        // what Finder's eject button does.
        let arguments: [String]
        switch mode {
        case .eject: arguments = ["eject", group.target]
        // `unmountDisk` wants a device; the mount point fallback gets the
        // volume-level verb.
        case .unmount: arguments = [group.target.hasPrefix("/") ? "unmount" : "unmountDisk", group.target]
        }

        var lastOutput = ""
        for attempt in 1...max(1, config.ejectAttempts) {
            let run = Shell.run("/usr/sbin/diskutil", arguments, timeout: 60)
            if run.status == 0 {
                Log.write("\(verb)ed \(names) via \(group.target) on attempt \(attempt)")
                return mounted.map { result($0, succeeded: true, detail: "ok") }
            }
            lastOutput = run.output
            Log.write("\(verb) \(names) attempt \(attempt)/\(config.ejectAttempts) failed: \(run.output)")
            if attempt < config.ejectAttempts {
                Thread.sleep(forTimeInterval: config.ejectRetryDelay)
            }
        }

        // The disk as a whole refused, but a volume nothing held went down on
        // the first attempt. It is off, and has to be reported as off: its
        // reconnect is the only way it comes back.
        return mounted.map { volume in
            guard Disks.isMountedVolume(volume.path) else {
                Log.write("\(verb)ed \(volume.name) with \(group.target), which as a whole would not go")
                return result(volume, succeeded: true, detail: "ok")
            }
            // diskutil names the process that refused; lsof is the slow
            // fallback and on a big volume runs out of time first.
            let blockers = dissenter(in: lastOutput) ?? blockingProcesses(at: volume.path)
            Log.write("\(verb.uppercased()) FAILED \(volume.name): \(lastOutput) | holding: \(blockers.isEmpty ? "unknown" : blockers)")
            return result(volume, succeeded: false, detail: blockers)
        }
    }

    /// Stop a backup writing to a volume on this disk, guarded or not: the
    /// one `diskutil` call takes them all down. A backup to another
    /// destination is left running. Returns what was stopped.
    private static func stopBackupIfOnDisk(_ group: Group, volumes: [AttachedVolume]) -> BackupStatus? {
        let status = BackupStatus.current()
        guard status.running,
              volumes.contains(where: { status.isBackingUp(to: $0) })
                || isOnDisk(status.mountPoint, group.target)
        else { return nil }
        // Measured at ~11 s on a real backup, so the default budget is too tight.
        let stop = Shell.run("/usr/bin/tmutil", ["stopbackup"], timeout: 120)
        Log.write("tmutil stopbackup -> status \(stop.status)\(stop.output.isEmpty ? "" : ": \(stop.output)")")
        return status
    }

    private static func isOnDisk(_ mountPoint: String?, _ target: String) -> Bool {
        guard let mountPoint, !target.hasPrefix("/"),
              let info = DeviceResolver.info(about: mountPoint) else { return false }
        return DeviceResolver.wholeDisk(fromInfo: info) == target
    }

    /// How long to wait for a stopped network backup to actually end. About
    /// twice what was measured, and well inside the default lead time.
    static let stopBackupBudget: TimeInterval = 120

    struct BackupStop {
        var name: String
        var succeeded: Bool
    }

    /// Stop a backup that is writing to a network destination, so the laptop
    /// can leave the network without cutting a write to the disk image short.
    /// Nil when no backup is writing to it: then there is nothing to do and
    /// nothing to say.
    static func stopBackup(to destination: KnownDisk, dryRun: Bool = false) -> BackupStop? {
        guard destination.isNetworkDestination,
              BackupStatus.current().isBackingUp(toDestination: destination.tmDestinationID)
        else { return nil }
        if dryRun {
            Log.write("dry-run: would stop the backup to \(destination.name)")
            return BackupStop(name: destination.name, succeeded: true)
        }
        let stop = Shell.run("/usr/bin/tmutil", ["stopbackup"], timeout: 120)
        // To a network destination the request is asynchronous: tmutil
        // returned 0 within half a second, the backup sat in `Stopping`, and
        // it took ~55 s to actually end. The exit status says the request was
        // taken, not that the write ended, so wait for Time Machine to say so.
        var stillRunning = true
        let deadline = Date().addingTimeInterval(stopBackupBudget)
        while true {
            stillRunning = BackupStatus.current().isBackingUp(toDestination: destination.tmDestinationID)
            guard stillRunning, Date() < deadline else { break }
            Thread.sleep(forTimeInterval: 3)
        }
        Log.write("tmutil stopbackup for \(destination.name) -> status \(stop.status)"
            + (stillRunning ? ", STILL BACKING UP" : ", stopped")
            + (stop.output.isEmpty ? "" : ": \(stop.output)"))
        return BackupStop(name: destination.name, succeeded: !stillRunning)
    }

    /// "Unmount was dissented by PID 85940 (/usr/bin/tee)" -> "tee".
    static func dissenter(in output: String) -> String? {
        guard let range = output.range(of: #"dissented by PID \d+ \(([^)]+)\)"#, options: .regularExpression)
        else { return nil }
        let match = output[range]
        guard let open = match.firstIndex(of: "("), let close = match.lastIndex(of: ")") else { return nil }
        let path = match[match.index(after: open)..<close]
        return path.split(separator: "/").last.map(String.init)
    }

    static func blockingProcesses(at path: String) -> String {
        // lsof walks the whole volume, which is slow on a big disk and is only
        // ever used to make an error message useful.
        // -w drops warnings, which Shell.run would merge into the output;
        // -F c asks for one `c<command>` line per process instead of a table.
        let lsof = Shell.run("/usr/sbin/lsof", ["-w", "-F", "c", "+D", path], timeout: 30)
        return holderNames(fromLsof: lsof.output)
    }

    /// Process names from `lsof -F c` output. Only `c` lines name a process,
    /// so a stray warning, or one left behind by a timed-out lsof that never
    /// flushed its listing, is not mistaken for one.
    static func holderNames(fromLsof output: String) -> String {
        let names = Set(output.split(separator: "\n").compactMap { line in
            line.first == "c" ? String(line.dropFirst()) : nil
        })
        return names.sorted().prefix(4).joined(separator: ", ")
    }
}
