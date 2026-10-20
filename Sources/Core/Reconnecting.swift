// Putting a disk back after a meeting it stayed plugged in through.
//
// Before a meeting the guard unmounts rather than ejects: the device stays
// attached, so if the laptop never left the desk the disk can be mounted again
// in software once the meeting is over. Whether the cable is still in is the
// one signal that cannot be wrong about whether the user moved.
//
// Measured on APFS volumes in a disk image, 2026-10-11:
// - `diskutil unmountDisk` leaves the device; `diskutil info <volume UUID>`
//   still answers, with an empty `MountPoint`. After `diskutil eject` it does
//   not answer at all.
// - An encrypted APFS volume is locked again by any unmount. `diskutil
//   mountDisk` then exits 0 and prints "mounted successfully" while the volume
//   stays locked and unmounted. The exit status proves nothing; only reading
//   the mount point back does.
// - Unlocking needs the passphrase. Measured on a real encrypted Time Machine
//   disk, 2026-10-12: Time Machine does not unlock it. `tmutil startbackup`
//   to the locked destination fails with BACKUP_FAILED_TARGETVOL_NOT_FOUND.
//   What unlocks it on plug-in is the login keychain item macOS saved when
//   the user ticked "Remember this password": a generic password, service and
//   account both the volume UUID, stored with a trailing NUL. Read through
//   the Security framework, that unlocks it with one keychain approval.

import Foundation
import Security

/// A disk the guard unmounted before a meeting and will try to mount again.
/// Persisted, so a restart or a sleep through the meeting does not lose it.
struct PendingReconnect: Codable, Equatable {
    var volumeUUID: String
    var name: String
    /// The meeting's end. Pushed later while another meeting runs or is
    /// about to start.
    var notBefore: Date
    /// Set for a Time Machine disk: the destination to start a backup to,
    /// also the last resort for a locked encrypted volume.
    var tmDestinationID: String?
    /// The guard stopped a backup to this disk, so starting one again is
    /// putting things back rather than doing something new.
    var stoppedBackup: Bool

    /// Past this, the entry describes a day that is over. Whatever happened to
    /// the disk since, mounting it out of the blue would be a surprise.
    static let staleAfter: TimeInterval = 12 * 3600
}

enum Reconnector {
    enum VolumeState: Equatable {
        case mounted
        /// Attached but not mounted. `wholeDisk` is nil when diskutil did not
        /// say which device it sits on.
        case unmounted(wholeDisk: String?, locked: Bool)
        /// diskutil does not know the volume: the cable is out.
        case gone
    }

    enum Result: Equatable {
        case remounted(backupStarted: Bool)
        case alreadyMounted(backupStarted: Bool)
        case unplugged
        case failed(locked: Bool)
    }

    /// Read a `diskutil info -plist <volume UUID>` answer. Nil means diskutil
    /// did not know the volume.
    static func state(fromInfo info: [String: Any]?) -> VolumeState {
        guard let info else { return .gone }
        if let mountPoint = info["MountPoint"] as? String, !mountPoint.isEmpty {
            return .mounted
        }
        let locked = (info["Locked"] as? NSNumber)?.boolValue == true
        return .unmounted(wholeDisk: DeviceResolver.wholeDisk(fromInfo: info), locked: locked)
    }

    /// Entries whose time has come, and those to keep waiting. Stale ones are
    /// in neither: they are dropped.
    static func partition(_ pending: [PendingReconnect], now: Date)
        -> (due: [PendingReconnect], waiting: [PendingReconnect]) {
        let live = pending.filter { now.timeIntervalSince($0.notBefore) < PendingReconnect.staleAfter }
        return (live.filter { $0.notBefore <= now }, live.filter { $0.notBefore > now })
    }

    /// `partition`, with meetings in the way: while one runs or is about to
    /// start, whatever is due waits for it to end instead.
    static func plan(_ pending: [PendingReconnect], now: Date, busyUntil: Date?)
        -> (due: [PendingReconnect], waiting: [PendingReconnect]) {
        let (due, waiting) = partition(pending, now: now)
        guard let busyUntil, busyUntil > now else { return (due, waiting) }
        return ([], waiting + due.map { var entry = $0; entry.notBefore = busyUntil; return entry })
    }

    /// Only a real UUID is ever handed to diskutil. A volume name would be
    /// accepted too and could match some other disk.
    static func isVolumeUUID(_ value: String) -> Bool {
        UUID(uuidString: value) != nil
    }

    /// How long Time Machine gets to unlock and mount its own disk.
    static let timeMachineMountBudget: TimeInterval = 90

    /// Mount the disk again if it is still attached, and get Time Machine
    /// going. Spawns processes, so never call it on the main thread.
    static func reconnect(_ pending: PendingReconnect) -> Result {
        guard isVolumeUUID(pending.volumeUUID) else {
            Log.write("reconnect \(pending.name): not a volume UUID, skipped")
            return .unplugged
        }
        let before = currentState(of: pending.volumeUUID)

        switch before {
        case .gone:
            Log.write("reconnect \(pending.name): no longer attached, nothing to do")
            return .unplugged
        case .mounted:
            // Plugged back in by hand, or mounted by someone else.
            let started = pending.stoppedBackup && startBackup(pending)
            return .alreadyMounted(backupStarted: started)
        case .unmounted(let wholeDisk, _):
            mount(pending, wholeDisk: wholeDisk)
        }

        // A locked encrypted volume stays down after a mount. The user's
        // keychain holds its passphrase if macOS was told to remember it.
        if case .unmounted(_, locked: true) = currentState(of: pending.volumeUUID) {
            unlockFromKeychain(pending)
        }

        if currentState(of: pending.volumeUUID) == .mounted {
            Log.write("reconnected \(pending.name)")
            let started = pending.stoppedBackup && startBackup(pending)
            return .remounted(backupStarted: started)
        }

        // Last resort, for a passphrase only Time Machine has (the System
        // keychain). Not seen to work for a disk unlocked from the login
        // keychain, but costs nothing beyond the wait.
        if pending.tmDestinationID != nil, startBackup(pending) {
            let deadline = Date().addingTimeInterval(timeMachineMountBudget)
            while Date() < deadline {
                Thread.sleep(forTimeInterval: 3)
                if currentState(of: pending.volumeUUID) == .mounted {
                    Log.write("reconnected \(pending.name) through Time Machine")
                    return .remounted(backupStarted: true)
                }
            }
        }

        let after = currentState(of: pending.volumeUUID)
        if after == .gone { return .unplugged }
        let locked: Bool
        if case .unmounted(_, let isLocked) = after { locked = isLocked } else { locked = false }
        Log.write("RECONNECT FAILED \(pending.name): still not mounted\(locked ? ", volume locked" : "")")
        return .failed(locked: locked)
    }

    private static func currentState(of volumeUUID: String) -> VolumeState {
        state(fromInfo: DeviceResolver.info(about: volumeUUID))
    }

    /// The whole disk when diskutil confirms it is external, which mounts
    /// every volume `unmountDisk` took down; otherwise just this volume.
    private static func mount(_ pending: PendingReconnect, wholeDisk: String?) {
        let result: (status: Int32, output: String)
        if let wholeDisk, let info = DeviceResolver.info(about: wholeDisk),
           DeviceResolver.isExternalWholeDisk(info) {
            result = Shell.run("/usr/sbin/diskutil", ["mountDisk", wholeDisk], timeout: 60)
        } else {
            result = Shell.run("/usr/sbin/diskutil", ["mount", pending.volumeUUID], timeout: 60)
        }
        Log.write("mount \(pending.name) -> status \(result.status)\(result.output.isEmpty ? "" : ": \(result.output)")")
    }

    /// Unlock and mount an encrypted APFS volume with the passphrase macOS
    /// saved in the login keychain. The passphrase goes to diskutil on stdin
    /// and is never logged. The first read asks the user to allow it.
    private static func unlockFromKeychain(_ pending: PendingReconnect) {
        guard var passphrase = keychainPassphrase(volumeUUID: pending.volumeUUID) else {
            Log.write("unlock \(pending.name): no passphrase in the keychain")
            return
        }
        defer { passphrase.resetBytes(in: 0..<passphrase.count) }
        let result = Shell.run("/usr/sbin/diskutil",
                               ["apfs", "unlockVolume", pending.volumeUUID, "-stdinpassphrase"],
                               timeout: 60, input: passphrase)
        Log.write("unlock \(pending.name) -> status \(result.status)\(result.output.isEmpty ? "" : ": \(result.output)")")
    }

    /// The "Encrypted Volume Password" item macOS keeps for a volume, without
    /// the trailing NUL it is stored with.
    static func keychainPassphrase(volumeUUID: String) -> Data? {
        guard isVolumeUUID(volumeUUID) else { return nil }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: volumeUUID,
            kSecAttrAccount as String: volumeUUID,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecItemNotFound { Log.write("keychain read for \(volumeUUID) -> status \(status)") }
            return nil
        }
        return stripTrailingNULs(data)
    }

    static func stripTrailingNULs(_ data: Data) -> Data? {
        var end = data.endIndex
        while end > data.startIndex, data[data.index(before: end)] == 0 { end = data.index(before: end) }
        return end > data.startIndex ? Data(data[data.startIndex..<end]) : nil
    }

    private static func startBackup(_ pending: PendingReconnect) -> Bool {
        guard let destination = pending.tmDestinationID else { return false }
        let result = Shell.run("/usr/bin/tmutil", ["startbackup", "--destination", destination], timeout: 30)
        Log.write("tmutil startbackup to \(pending.name) -> status \(result.status)"
            + (result.output.isEmpty ? "" : ": \(result.output)"))
        return result.status == 0
    }
}
