// Working out which device to power down.
//
// `diskutil eject /Volumes/Thing` on an APFS disk unmounts that one volume and
// stops there. Handing it the whole disk instead is what Finder's eject button
// does: it unmounts every volume on the device and issues the eject to the
// device itself.
//
// Honest about the evidence: on a fixed external disk the /dev node survives
// either way, so watching `diskutil list` cannot tell you which happened, and
// whether the spindle parked is not observable from here. The reason to prefer
// the whole disk is not a measurement - it is that unmounting one volume of
// several is plainly not "the disk is ready to unplug", and the device level
// eject is the documented way to ask for that.
//
// The cost: a disk with other volumes on it gets those unmounted too. That is
// the right answer for a drive about to be unplugged, and if one of them is
// busy the eject fails and says which process is holding it.
//
// Parsing is kept apart from running diskutil so it can be tested against
// output captured from real hardware.

import Foundation

enum DeviceResolver {
    /// The whole physical disk behind a `diskutil info -plist` reading, e.g.
    /// "disk6".
    ///
    /// An APFS volume's `ParentWholeDisk` is its *synthesised* container
    /// ("disk7"), which is not a device that can be powered down. The physical
    /// store behind the container is, so it wins when present.
    static func wholeDisk(fromInfo info: [String: Any]) -> String? {
        if let stores = info["APFSPhysicalStores"] as? [[String: Any]],
           let first = stores.first,
           let store = (first["APFSPhysicalStore"] ?? first["DeviceIdentifier"]) as? String,
           let disk = wholeDiskIdentifier(from: store) {
            return disk
        }
        if let parent = info["ParentWholeDisk"] as? String,
           let disk = wholeDiskIdentifier(from: parent) {
            return disk
        }
        return nil
    }

    /// "disk6s2" -> "disk6", "disk6" -> "disk6", anything else -> nil.
    static func wholeDiskIdentifier(from identifier: String) -> String? {
        guard identifier.hasPrefix("disk") else { return nil }
        let rest = identifier.dropFirst("disk".count)
        let digits = rest.prefix { $0.isNumber }
        guard !digits.isEmpty else { return nil }
        // Whatever follows must be a partition or slice suffix, never a path.
        let tail = rest.dropFirst(digits.count)
        guard tail.isEmpty || tail.first == "s" else { return nil }
        return "disk\(digits)"
    }

    /// Whether a whole disk may be powered down. Being wrong here means
    /// ejecting something that is not the user's backup drive, so the answer is
    /// no unless diskutil says plainly that it is external.
    static func isExternalWholeDisk(_ info: [String: Any]) -> Bool {
        guard (info["Internal"] as? NSNumber)?.boolValue == false else { return false }
        guard (info["OSInternalMedia"] as? NSNumber)?.boolValue != true else { return false }
        guard (info["WholeDisk"] as? NSNumber)?.boolValue != false else { return false }
        return (info["Ejectable"] as? NSNumber)?.boolValue == true
            || (info["RemovableMediaOrExternalDevice"] as? NSNumber)?.boolValue == true
    }

    /// Ask diskutil about something, by mount point or device identifier.
    static func info(about target: String) -> [String: Any]? {
        let result = Shell.run("/usr/sbin/diskutil", ["info", "-plist", target], timeout: 20)
        guard result.status == 0 else { return nil }
        return Shell.plist(from: result.output)
    }

    /// What to hand `diskutil eject` for this mount point: the whole physical
    /// disk when we can prove it is external, otherwise the mount point itself,
    /// which at least unmounts the filesystem.
    static func ejectTarget(forMountPoint path: String) -> String {
        guard let volumeInfo = info(about: path),
              let disk = wholeDisk(fromInfo: volumeInfo),
              let diskInfo = info(about: disk),
              isExternalWholeDisk(diskInfo)
        else {
            Log.write("could not resolve a physical disk for \(path) - unmounting the volume only")
            return path
        }
        return disk
    }
}
