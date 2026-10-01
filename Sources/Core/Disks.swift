// Finding disks. Scanning spawns processes; merging is pure.

import DiskArbitration
import Foundation

/// A Time Machine destination: a local disk, or a share on the network.
struct TimeMachineDestination: Equatable {
    var id: String
    var name: String
    var mountPoint: String?
    /// The volumes Time Machine itself records for this destination. The only
    /// link between the two while the disk is unplugged, when there is no
    /// mount point to go by.
    var volumeUUIDs: [String] = []
    /// A share on the network. Never tied to a mounted volume: what backs it
    /// is a disk image, and there is nothing to eject.
    var isNetwork = false
}

/// One reading of what is plugged in. Producing this spawns processes;
/// consuming it does not. Keeping the two apart is what lets the app scan off
/// the main thread and merge under a lock without ever holding the lock across
/// a process launch.
struct DiskSnapshot: Equatable {
    var destinations: [TimeMachineDestination] = []
    var attached: [AttachedVolume] = []
    /// Mounted disk images, keyed the way `merge` keys a disk. They are never
    /// offered, and are listed only so that `merge` can forget one an earlier
    /// release remembered.
    var diskImageIDs: [String] = []
}

enum Disks {
    // MARK: Scanning (spawns processes - never call while holding a lock)

    static func scan() -> DiskSnapshot {
        let destinations = readDestinations()
        let volumes = mountedVolumes(destinations: destinations)
        return DiskSnapshot(
            destinations: destinations,
            attached: volumes.attached,
            diskImageIDs: volumes.diskImageIDs)
    }

    private static func readDestinations() -> [TimeMachineDestination] {
        let info = Shell.run("/usr/bin/tmutil", ["destinationinfo", "-X"], timeout: 15)
        guard info.status == 0,
              let root = Shell.plist(from: info.output),
              let destinations = root["Destinations"] as? [[String: Any]]
        else { return [] }

        let volumes = destinationVolumeUUIDs(fromPreferences: timeMachinePreferences())
        return destinations.compactMap { destination in
            guard let kind = destination["Kind"] as? String, kind == "Local" || kind == "Network",
                  let id = destination["ID"] as? String else { return nil }
            let isNetwork = kind == "Network"
            // A network destination's volumes live inside a disk image, which
            // must never be linked to anything we would eject.
            return TimeMachineDestination(
                id: id,
                name: (destination["Name"] as? String) ?? "Time Machine",
                mountPoint: isNetwork ? nil : destination["MountPoint"] as? String,
                volumeUUIDs: isNetwork ? [] : volumes[id] ?? [],
                isNetwork: isNetwork)
        }
    }

    /// Time Machine's own preferences, which `tmutil destinationinfo` does not
    /// expose all of. Readable by every user. Not a documented interface, so
    /// it may only ever add a link: missing or reshaped, and merging falls back
    /// to mount points as before.
    private static func timeMachinePreferences() -> [String: Any] {
        let url = URL(fileURLWithPath: "/Library/Preferences/com.apple.TimeMachine.plist")
        guard let data = try? Data(contentsOf: url),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return [:] }
        return root
    }

    /// External volumes that are mounted right now, split into the disks we
    /// may offer and the disk images we never do.
    ///
    /// Internal and non-ejectable volumes are filtered out here, which is what
    /// keeps the boot disk out of reach of every later step.
    static func mountedVolumes(destinations: [TimeMachineDestination])
        -> (attached: [AttachedVolume], diskImageIDs: [String]) {
        // Every key the predicate reads must be requested here, or it comes
        // back nil and the volume is silently rejected.
        let keys: [URLResourceKey] = [
            .volumeIsInternalKey, .volumeIsLocalKey, .volumeIsRootFileSystemKey,
            .volumeUUIDStringKey, .volumeLocalizedNameKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return ([], []) }

        let session = DASessionCreate(kCFAllocatorDefault)
        var attached: [AttachedVolume] = []
        var diskImageIDs: [String] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { continue }
            let path = url.path
            guard isMountedVolume(path),
                  isGuardable(isInternal: values.volumeIsInternal,
                              isLocal: values.volumeIsLocal,
                              isRootFileSystem: values.volumeIsRootFileSystem)
            else { continue }

            let device = deviceDescription(of: url, session: session)
            if isDiskImage(deviceModel: device.model) {
                diskImageIDs.append(values.volumeUUIDString ?? path)
                continue
            }
            attached.append(AttachedVolume(
                path: path,
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                volumeUUID: values.volumeUUIDString,
                tmDestinationID: destinations.first { !$0.isNetwork && $0.mountPoint == path }?.id,
                connection: connection(fromProtocol: device.protocol)))
        }
        return (attached, diskImageIDs)
    }

    /// The device model and interface DiskArbitration reports for the disk
    /// behind a volume. This asks `diskarbitrationd` over IPC; no process is
    /// launched.
    private static func deviceDescription(of url: URL, session: DASession?)
        -> (model: String?, protocol: String?) {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
              let description = DADiskCopyDescription(disk) as? [String: Any]
        else { return (nil, nil) }
        return (description[kDADiskDescriptionDeviceModelKey as String] as? String,
                description[kDADiskDescriptionDeviceProtocolKey as String] as? String)
    }

    // MARK: Pure logic (no processes, no I/O - this is the part under test)

    /// Destination ID to the volume UUIDs behind it, from Time Machine's
    /// preferences. Entries missing either half are skipped.
    static func destinationVolumeUUIDs(fromPreferences preferences: [String: Any]) -> [String: [String]] {
        guard let destinations = preferences["Destinations"] as? [[String: Any]] else { return [:] }
        var result: [String: [String]] = [:]
        for destination in destinations {
            guard let id = destination["DestinationID"] as? String,
                  let uuids = destination["DestinationUUIDs"] as? [String], !uuids.isEmpty
            else { continue }
            result[id] = uuids
        }
        return result
    }

    /// Whether a mounted volume is one we may offer to guard.
    ///
    /// Pure, and tested against values read off real hardware, because getting
    /// this wrong is silent in both directions.
    ///
    /// `volumeIsEjectable` is **not** part of it, despite the name. A fixed
    /// external USB hard disk reports `ejectable == false`: in this API
    /// "ejectable" means removable media - a card reader, an optical drive, a
    /// disk image - not "can be unmounted and unplugged". Requiring it meant a
    /// real Time Machine drive never appeared, and a disk image test fixture
    /// hid that for a whole day because images do report true.
    ///
    /// Observed values:
    ///
    /// | volume                    | internal | local | ejectable |
    /// |---------------------------|----------|-------|-----------|
    /// | external USB hard disk    | false    | true  | false     |
    /// | boot and system volumes   | true     | true  | false     |
    /// | disk image                | nil      | true  | true      |
    /// | Time Machine snapshots    | nil      | true  | false     |
    /// | autofs network mount      | nil      | false | false     |
    ///
    /// So: never internal, always local. An unknown `internal` is not read as
    /// internal, and the user still has to tick a disk before anything happens
    /// to it. A disk image passes this check; it is turned away by
    /// `isDiskImage`, since none of these values tell it apart.
    static func isGuardable(isInternal: Bool?, isLocal: Bool?, isRootFileSystem: Bool?) -> Bool {
        guard isInternal != true else { return false }
        guard isLocal == true else { return false }
        guard isRootFileSystem != true else { return false }
        return true
    }

    /// Whether DiskArbitration's device model is that of a mounted disk image:
    /// a `.dmg` installer, a sparse bundle. There is nothing to unplug, so it
    /// is never offered.
    ///
    /// Observed on an installer image: model `Disk Image`, protocol `Virtual
    /// Interface`, while an external disk reports its vendor's model.
    ///
    /// An unknown model counts as a real disk. Listing an image by mistake is
    /// one extra row; hiding a real disk by mistake means it is never guarded.
    static func isDiskImage(deviceModel: String?) -> Bool {
        deviceModel?.trimmingCharacters(in: .whitespaces) == "Disk Image"
    }

    /// The interface DiskArbitration reports, as the popover names it.
    ///
    /// Observed: `Apple Fabric` for the internal SSD and `Virtual Interface`
    /// for a disk image, neither of which is ever offered. An external NVMe in
    /// a Thunderbolt enclosure reports `PCI-Express`: on a Mac an external PCIe
    /// device is a Thunderbolt one. Anything else is nil, and the popover falls
    /// back to plain "Connected" rather than naming it wrong.
    static func connection(fromProtocol value: String?) -> Connection? {
        guard let value = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return nil }
        if value.hasPrefix("usb") { return .usb }
        if value.hasPrefix("thunderbolt") || value.hasPrefix("pci") { return .thunderbolt }
        if value == "secure digital" || value == "sd" { return .sdCard }
        return nil
    }

    /// A path is only a candidate if it is a directory directly inside /Volumes.
    /// Last line of defence before anything reaches `diskutil eject`.
    static func isMountedVolume(_ path: String) -> Bool {
        guard isDirectlyInVolumes(path) else { return false }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return false }
        return true
    }

    /// Whether a volume that mounted or unmounted at `path` can change the
    /// disk list, and so is worth a rescan.
    ///
    /// Time Machine mounts snapshots and backups deeper inside /Volumes, under
    /// `com.apple.TimeMachine.localsnapshots` and `.timemachine`, all through
    /// a backup. Each one used to set off a rescan, and a `tmutil
    /// destinationinfo` started while such a mount settles can block in the
    /// kernel past every timeout `Shell.run` has, SIGKILL included.
    ///
    /// Judged by shape alone: after an unmount there is nothing left on disk
    /// to look at. No path at all rescans - a missed disk is worse than one
    /// extra scan.
    static func mayChangeDiskList(volumePath path: String?) -> Bool {
        guard let path else { return true }
        return isDirectlyInVolumes(path)
    }

    private static func isDirectlyInVolumes(_ path: String) -> Bool {
        guard path.hasPrefix("/Volumes/"), path.count > "/Volumes/".count else { return false }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Volumes"
    }

    static let forgetUnguardedAfter: TimeInterval = 7 * 24 * 60 * 60

    /// Fold a snapshot into the remembered list. A guarded disk is never
    /// dropped unless the user hid it: the list is what you pick from while the
    /// disk sits in a drawer. One nobody guards is forgotten a week after it
    /// was unplugged.
    static func merge(_ snapshot: DiskSnapshot, into config: inout GuardConfig, now: Date = Date()) {
        var known = config.knownDisks

        /// Move the user's tick to the identity that replaces an old one,
        /// without ever ticking the same disk twice.
        func rekeyWatch(from old: String, to new: String) {
            guard old != new, let watchIndex = config.watchedDiskIDs.firstIndex(of: old) else { return }
            if config.watchedDiskIDs.contains(new) {
                config.watchedDiskIDs.remove(at: watchIndex)
            } else {
                config.watchedDiskIDs[watchIndex] = new
            }
        }

        func upsert(_ disk: KnownDisk, timeMachineVolumes: [String] = []) {
            // Match on either identity, so a Time Machine placeholder and the
            // volume we later see plugged in collapse into one entry.
            if let index = known.firstIndex(where: { existing in
                if let a = existing.volumeUUID, a == disk.volumeUUID { return true }
                if let a = existing.tmDestinationID, a == disk.tmDestinationID { return true }
                // Past the exact identities, only guesses are left, and a
                // network destination and a disk are never guessed to be the
                // same thing: folding a plugged-in disk into a share would take
                // it off the eject path without a word. The exact matches above
                // are not held to this, because an older release running at the
                // same time drops the `network` flag it does not know.
                guard existing.isNetworkDestination == disk.isNetworkDestination else { return false }
                // A disk remembered as a plain volume and made a destination
                // later: while it is unplugged, Time Machine's own record is the
                // only link. Only for an entry not yet tied to a destination, so
                // a volume listed under two of them does not flip between them.
                if existing.tmDestinationID == nil, let a = existing.volumeUUID,
                   timeMachineVolumes.contains(a) { return true }
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
                merged.network = disk.network ?? merged.network

                // Another entry sharing an identity is this same disk, written
                // down before the link between its volume and its destination
                // was known - an earlier release listed such a disk twice. Fold
                // it in, Time Machine's own record counting as a shared
                // identity. One naming a different volume or destination is a
                // different disk and stays.
                func differ(_ a: String?, _ b: String?) -> Bool {
                    guard let a, let b else { return false }
                    return a != b
                }
                let duplicates = known.indices.filter { other in
                    guard other != index else { return false }
                    let candidate = known[other]
                    let shared = (candidate.volumeUUID != nil && candidate.volumeUUID == merged.volumeUUID)
                        || (candidate.tmDestinationID != nil && candidate.tmDestinationID == merged.tmDestinationID)
                        || (candidate.tmDestinationID == nil
                            && candidate.volumeUUID.map(timeMachineVolumes.contains) == true)
                    return shared
                        && !differ(candidate.volumeUUID, merged.volumeUUID)
                        && !differ(candidate.tmDestinationID, merged.tmDestinationID)
                }
                for other in duplicates {
                    let duplicate = known[other]
                    merged.volumeUUID = merged.volumeUUID ?? duplicate.volumeUUID
                    merged.tmDestinationID = merged.tmDestinationID ?? duplicate.tmDestinationID
                    if let seen = duplicate.lastSeen, seen > merged.lastSeen ?? .distantPast {
                        merged.lastSeen = seen
                    }
                }

                // Prefer the volume UUID as the stable key once we know it.
                merged.id = merged.volumeUUID ?? merged.tmDestinationID ?? merged.id
                rekeyWatch(from: previousID, to: merged.id)
                for other in duplicates { rekeyWatch(from: known[other].id, to: merged.id) }
                known[index] = merged
                let dropped = Set(duplicates)
                known = known.indices.filter { !dropped.contains($0) }.map { known[$0] }
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
                lastSeen: nil,
                network: destination.isNetwork ? true : nil),
                timeMachineVolumes: destination.volumeUUIDs)
        }

        for volume in snapshot.attached {
            upsert(KnownDisk(
                id: volume.volumeUUID ?? volume.tmDestinationID ?? volume.path,
                name: volume.name,
                volumeUUID: volume.volumeUUID,
                tmDestinationID: volume.tmDestinationID,
                lastSeen: now))
        }

        // Earlier releases offered disk images, and remembered every one that
        // was ever mounted. Forget one the next time it shows up - unless it is
        // guarded or a Time Machine destination: a block-level copy of a real
        // disk carries that disk's volume UUID, and quietly unguarding the
        // real one is the failure this app exists to prevent.
        let watched = Set(config.watchedDiskIDs)
        let images = Set(snapshot.diskImageIDs)
        known.removeAll { disk in
            images.contains(disk.id) && !watched.contains(disk.id) && !disk.isTimeMachineDestination
        }

        // Counted from the first pass that finds the disk gone, not from
        // `lastSeen`: the app rescans only when something mounts, unmounts or
        // wakes, so a disk left plugged into a Mac that never sleeps can carry
        // a `lastSeen` weeks old the moment it is pulled out.
        for index in known.indices {
            // A network destination is never plugged in, nor ever unplugged.
            if known[index].isNetworkDestination || attachedVolume(for: known[index], among: snapshot.attached) != nil {
                known[index].absentSince = nil
            } else if known[index].absentSince == nil {
                known[index].absentSince = now
            }
        }

        // A disk nobody guards, unplugged for a week, is most likely gone for
        // good: a volume made while formatting, a stick handed on. Forgetting
        // it costs nothing, it is listed again the moment it is plugged in.
        // Never a guarded disk, and never a Time Machine destination, which
        // Time Machine reports again on every pass.
        known.removeAll { disk in
            guard let since = disk.absentSince,
                  now.timeIntervalSince(since) >= forgetUnguardedAfter,
                  !watched.contains(disk.id), !disk.isTimeMachineDestination
            else { return false }
            Log.write("forgot \"\(disk.name)\" - not guarded and unplugged for a week")
            return true
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
    /// Never one for a network destination: that is what keeps a share out of
    /// every eject.
    static func attachedVolume(for disk: KnownDisk, among volumes: [AttachedVolume]) -> AttachedVolume? {
        guard !disk.isNetworkDestination else { return nil }
        return volumes.first { volume in
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

    /// Network Time Machine destinations the user guards. Reported by Time
    /// Machine on every pass, so there is no "present" to check.
    /// Somewhere Time Machine could be writing to right now, guarded or not: a
    /// destination plugged in, or a share, which is always reachable as far as
    /// the app can tell. Nothing else can have a backup worth showing.
    static func hasTimeMachineTarget(_ config: GuardConfig, among attached: [AttachedVolume]) -> Bool {
        attached.contains { $0.tmDestinationID != nil }
            || config.knownDisks.contains { disk in
                disk.isNetworkDestination
                    || (disk.isTimeMachineDestination && attachedVolume(for: disk, among: attached) != nil)
            }
    }

    static func guardedNetworkDestinations(_ config: GuardConfig) -> [KnownDisk] {
        config.knownDisks.filter { $0.isNetworkDestination && config.watchedDiskIDs.contains($0.id) }
    }
}
