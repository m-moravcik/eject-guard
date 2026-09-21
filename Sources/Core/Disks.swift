// Finding disks. Scanning spawns processes; merging is pure.

import Foundation

/// A local Time Machine destination. Network destinations are dropped at the
/// source: there is no local disk to eject on an SMB share.
struct TimeMachineDestination: Equatable {
    var id: String
    var name: String
    var mountPoint: String?
}

/// One reading of what is plugged in. Producing this spawns processes;
/// consuming it does not. Keeping the two apart is what lets the app scan off
/// the main thread and merge under a lock without ever holding the lock across
/// a process launch.
struct DiskSnapshot: Equatable {
    var destinations: [TimeMachineDestination] = []
    var attached: [AttachedVolume] = []
}

enum Disks {
    // MARK: Scanning (spawns processes - never call while holding a lock)

    static func scan() -> DiskSnapshot {
        let destinations = readDestinations()
        return DiskSnapshot(
            destinations: destinations,
            attached: attachedVolumes(destinations: destinations))
    }

    private static func readDestinations() -> [TimeMachineDestination] {
        let info = Shell.run("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: 15)
        guard info.status == 0,
              let root = Shell.plist(from: info.output),
              let destinations = root["Destinations"] as? [[String: Any]]
        else { return [] }

        return destinations.compactMap { destination in
            // Network destinations have no local disk to eject.
            guard (destination["Kind"] as? String) == "Local",
                  let id = destination["ID"] as? String else { return nil }
            return TimeMachineDestination(
                id: id,
                name: (destination["Name"] as? String) ?? "Time Machine",
                mountPoint: destination["MountPoint"] as? String)
        }
    }

    /// External, ejectable volumes that are mounted right now.
    ///
    /// Internal and non-ejectable volumes are filtered out here, which is what
    /// keeps the boot disk out of reach of every later step.
    static func attachedVolumes(destinations: [TimeMachineDestination]) -> [AttachedVolume] {
        let keys: [URLResourceKey] = [
            .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsBrowsableKey,
            .volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsRootFileSystemKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return [] }

        return urls.compactMap { url -> AttachedVolume? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            // volumeIsInternal is nil for external media rather than false, so
            // test for "not internal" instead of "external". Ejectable is the
            // load bearing check: every built-in volume reports false.
            guard values.volumeIsEjectable == true,
                  values.volumeIsInternal != true,
                  values.volumeIsRootFileSystem != true else { return nil }
            let path = url.path
            guard isMountedVolume(path) else { return nil }

            return AttachedVolume(
                path: path,
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                volumeUUID: values.volumeUUIDString,
                tmDestinationID: destinations.first { $0.mountPoint == path }?.id)
        }
    }

    // MARK: Pure logic (no processes, no I/O - this is the part under test)

    /// A path is only a candidate if it is a directory directly inside /Volumes.
    /// Last line of defence before anything reaches `diskutil eject`.
    static func isMountedVolume(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/"), path.count > "/Volumes/".count else { return false }
        guard URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Volumes" else {
            return false
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return true
    }

    /// Fold a snapshot into the remembered list. Disks are never dropped unless
    /// the user hid them: the list is what you pick from while the disk sits in
    /// a drawer.
    static func merge(_ snapshot: DiskSnapshot, into config: inout GuardConfig) {
        var known = config.knownDisks

        func upsert(_ disk: KnownDisk) {
            // Match on either identity, so a Time Machine placeholder and the
            // volume we later see plugged in collapse into one entry.
            if let index = known.firstIndex(where: { existing in
                if let a = existing.volumeUUID, a == disk.volumeUUID { return true }
                if let a = existing.tmDestinationID, a == disk.tmDestinationID { return true }
                // A Time Machine destination we have never seen mounted carries
                // no volume UUID. Fall back to the name so it does not show up
                // twice once the disk is actually plugged in.
                if existing.volumeUUID == nil, disk.volumeUUID != nil,
                   existing.name.caseInsensitiveCompare(disk.name) == .orderedSame {
                    // Matching on a name is a guess: two disks could share one.
                    // It only happens when tmutil did not report a mount point,
                    // so leave a trace rather than merging silently.
                    Log.write("merged \"\(disk.name)\" by name - tmutil reported no mount point")
                    return true
                }
                return false
            }) {
                var merged = known[index]
                let previousID = merged.id
                merged.name = disk.name
                merged.volumeUUID = disk.volumeUUID ?? merged.volumeUUID
                merged.tmDestinationID = disk.tmDestinationID ?? merged.tmDestinationID
                merged.lastSeen = disk.lastSeen ?? merged.lastSeen
                // Prefer the volume UUID as the stable key once we know it.
                merged.id = merged.volumeUUID ?? merged.tmDestinationID ?? merged.id
                known[index] = merged
                if previousID != merged.id,
                   let watchIndex = config.watchedDiskIDs.firstIndex(of: previousID) {
                    config.watchedDiskIDs[watchIndex] = merged.id
                }
            } else {
                known.append(disk)
            }
        }

        for destination in snapshot.destinations {
            upsert(KnownDisk(
                id: destination.id,
                name: destination.name,
                volumeUUID: nil,
                tmDestinationID: destination.id,
                lastSeen: nil))
        }

        for volume in snapshot.attached {
            upsert(KnownDisk(
                id: volume.volumeUUID ?? volume.tmDestinationID ?? volume.path,
                name: volume.name,
                volumeUUID: volume.volumeUUID,
                tmDestinationID: volume.tmDestinationID,
                lastSeen: Date()))
        }

        let dismissed = Set(config.dismissedDiskIDs)
        config.knownDisks = known
            .filter { !dismissed.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Scan and merge in one step. Fine for the command line tool, which is
    /// single threaded; the app scans and merges separately.
    static func refreshKnownDisks(in config: inout GuardConfig) {
        merge(scan(), into: &config)
    }

    /// The attached volume backing a remembered disk, if it is plugged in.
    static func attachedVolume(for disk: KnownDisk, among volumes: [AttachedVolume]) -> AttachedVolume? {
        volumes.first { volume in
            if let uuid = disk.volumeUUID, uuid == volume.volumeUUID { return true }
            if let tm = disk.tmDestinationID, tm == volume.tmDestinationID { return true }
            return false
        }
    }

    /// Remembered disks the user guards, that are present in this snapshot.
    static func guardedVolumes(_ config: GuardConfig, among volumes: [AttachedVolume]) -> [AttachedVolume] {
        config.knownDisks
            .filter { config.watchedDiskIDs.contains($0.id) }
            .compactMap { attachedVolume(for: $0, among: volumes) }
    }
}
