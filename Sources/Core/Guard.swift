// Shared engine for the CLI and the menu bar app.
//
// Responsibilities:
//   - remember which external disks exist and which ones the user wants guarded
//   - find the next real meeting in the calendar
//   - stop Time Machine and eject the guarded disks before that meeting starts

import EventKit
import Foundation

// MARK: - Logging

enum Log {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/tm-eject-guard.log")

    private static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    static func write(_ message: String) {
        let line = "\(stamp.string(from: Date()))  \(message)\n"
        guard let data = line.data(using: .utf8) else { return }
        if isatty(STDERR_FILENO) == 1 {
            FileHandle.standardError.write(data)
        }
        // Keep the log from growing without bound.
        if let size = try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int,
           size > 512_000 {
            try? FileManager.default.removeItem(at: url)
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
}

// MARK: - Shell

enum Shell {
    @discardableResult
    static func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = arguments
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        do { try task.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        let out = String(data: data, encoding: .utf8) ?? ""
        return (task.terminationStatus, out.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func plist(from output: String) -> [String: Any]? {
        guard let data = output.data(using: .utf8),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil) as? [String: Any]
        else { return nil }
        return root
    }

    /// Fallback used by the command line tool, which has no bundle and so
    /// cannot post a user notification of its own.
    static func notifyViaAppleScript(title: String, body: String) {
        // AppleScript string literals: backslashes first, then quotes.
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }
        run("/usr/bin/osascript", ["-e",
            "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Submarine\""])
    }
}

/// Indirection so the app can post real user notifications while the CLI falls
/// back to AppleScript. Under the hardened runtime the AppleScript route is not
/// dependable, and the app has a bundle identity that can do it properly.
enum Notify {
    nonisolated(unsafe) static var handler: (String, String) -> Void = { title, body in
        Shell.notifyViaAppleScript(title: title, body: body)
    }

    static func post(title: String, body: String) {
        handler(title, body)
    }
}

// MARK: - Known disks

/// A disk the user has plugged in at least once, or that Time Machine knows about.
/// `id` is what the config file stores, so it has to survive remounts: a volume
/// UUID when we have seen the disk, otherwise the Time Machine destination UUID.
/// Every added property here must be optional or have its own tolerant
/// decoding, for the same reason GuardConfig writes its decoder by hand.
struct KnownDisk: Codable, Equatable {
    var id: String
    var name: String
    var volumeUUID: String?
    var tmDestinationID: String?
    var lastSeen: Date?

    var isTimeMachineDestination: Bool { tmDestinationID != nil }
}

/// A disk that is plugged in right now.
struct AttachedVolume {
    var path: String
    var name: String
    var volumeUUID: String?
    var tmDestinationID: String?
}

// MARK: - Configuration

struct GuardConfig: Codable, Equatable {
    var watchedDiskIDs: [String] = []
    var knownDisks: [KnownDisk] = []
    /// Disks the user hid. Time Machine destinations are rediscovered on every
    /// pass, so without this there would be no way to get rid of one that is
    /// never going to be plugged into this Mac.
    var dismissedDiskIDs: [String] = []
    /// When true every calendar counts and `watchedCalendarIDs` is ignored.
    /// A separate flag rather than "empty means all", because that would turn
    /// unticking the last calendar into watching all of them.
    var watchAllCalendars: Bool = true
    var watchedCalendarIDs: [String] = []
    var leadMinutes: Double = 5
    var minAttendees: Int = 2
    var enabled: Bool = true
    /// Skip events the user marked as Free - those are blocks, not meetings.
    var ignoreFreeEvents: Bool = false
    /// Also eject when the Mac goes to sleep, not just before a meeting.
    var ejectOnSleep: Bool = false
    /// Guard is off until this moment ("pause for an hour").
    var pausedUntil: Date?
    /// Events the user chose to ignore once.
    var skippedEventIDs: [String] = []

    // Retry while Spotlight or backupd still holds the volume.
    var ejectAttempts: Int = 6
    var ejectRetryDelay: Double = 15

    var isActive: Bool {
        guard enabled else { return false }
        if let until = pausedUntil, until > Date() { return false }
        return true
    }

    init() {}

    // Swift's synthesised Codable throws on a missing key even when the
    // property has a default, and the caller then has nothing to fall back on
    // but a blank config. Adding one field would silently wipe every setting
    // the user had. Decoding each key on its own keeps old files readable.
    enum CodingKeys: String, CodingKey {
        case watchedDiskIDs, knownDisks, dismissedDiskIDs
        case watchAllCalendars, watchedCalendarIDs
        case leadMinutes, minAttendees, enabled, ignoreFreeEvents, ejectOnSleep
        case pausedUntil, skippedEventIDs, ejectAttempts, ejectRetryDelay
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = GuardConfig()

        func value<T: Decodable>(_ key: CodingKeys, _ default: T) -> T {
            (try? container.decodeIfPresent(T.self, forKey: key)) .flatMap { $0 } ?? `default`
        }

        watchedDiskIDs = value(.watchedDiskIDs, fallback.watchedDiskIDs)
        knownDisks = value(.knownDisks, fallback.knownDisks)
        dismissedDiskIDs = value(.dismissedDiskIDs, fallback.dismissedDiskIDs)
        watchAllCalendars = value(.watchAllCalendars, fallback.watchAllCalendars)
        watchedCalendarIDs = value(.watchedCalendarIDs, fallback.watchedCalendarIDs)
        leadMinutes = value(.leadMinutes, fallback.leadMinutes)
        minAttendees = value(.minAttendees, fallback.minAttendees)
        enabled = value(.enabled, fallback.enabled)
        ignoreFreeEvents = value(.ignoreFreeEvents, fallback.ignoreFreeEvents)
        ejectOnSleep = value(.ejectOnSleep, fallback.ejectOnSleep)
        pausedUntil = try? container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        skippedEventIDs = value(.skippedEventIDs, fallback.skippedEventIDs)
        ejectAttempts = value(.ejectAttempts, fallback.ejectAttempts)
        ejectRetryDelay = value(.ejectRetryDelay, fallback.ejectRetryDelay)
    }
}

enum ConfigStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TMEjectGuard")
    static let url = directory.appendingPathComponent("config.json")

    // The menu bar app writes the disk selection from the main thread while a
    // pass may be running on a background queue, so every access is serialised.
    private static let lock = NSLock()

    static func load() -> GuardConfig {
        lock.lock(); defer { lock.unlock() }
        return readUnlocked()
    }

    static func save(_ config: GuardConfig) {
        lock.lock(); defer { lock.unlock() }
        writeUnlocked(config)
    }

    /// Read-modify-write as one atomic step. Use this instead of load/save
    /// whenever the new value depends on the old one.
    @discardableResult
    static func mutate<T>(_ body: (inout GuardConfig) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        let original = readUnlocked()
        var config = original
        let result = body(&config)
        // Rewriting an unchanged file would mean a disk write on every pass.
        if config != original { writeUnlocked(config) }
        return result
    }

    private static func readUnlocked() -> GuardConfig {
        guard let data = try? Data(contentsOf: url) else { return GuardConfig() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(GuardConfig.self, from: data)
        } catch {
            // Falling back to defaults discards the user's settings, so say so
            // rather than letting it happen quietly.
            Log.write("config unreadable, falling back to defaults: \(error)")
            return GuardConfig()
        }
    }

    private static func writeUnlocked(_ config: GuardConfig) {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

// MARK: - Disk discovery

enum Disks {
    private static let destinationCacheLock = NSLock()
    private static var destinationCache: (value: [(id: String, name: String, mountPoint: String?)], at: Date)?

    /// Drop the cached destination list. Called when a volume mounts or
    /// unmounts, which is the only time a MountPoint can change.
    static func invalidateDestinationCache() {
        destinationCacheLock.lock(); defer { destinationCacheLock.unlock() }
        destinationCache = nil
    }

    /// Mount points of local Time Machine destinations, keyed by destination UUID.
    /// A destination with no entry here is simply not plugged in.
    ///
    /// Cached for a few seconds: one pass asks for this list several times, and
    /// each miss costs a `tmutil` process.
    static func timeMachineDestinations() -> [(id: String, name: String, mountPoint: String?)] {
        destinationCacheLock.lock()
        if let cache = destinationCache, Date().timeIntervalSince(cache.at) < 5 {
            defer { destinationCacheLock.unlock() }
            return cache.value
        }
        destinationCacheLock.unlock()

        let fresh = readDestinations()
        destinationCacheLock.lock()
        destinationCache = (fresh, Date())
        destinationCacheLock.unlock()
        return fresh
    }

    private static func readDestinations() -> [(id: String, name: String, mountPoint: String?)] {
        let info = Shell.run("/usr/bin/tmutil", ["destinationinfo", "-X"])
        guard info.status == 0,
              let root = Shell.plist(from: info.output),
              let destinations = root["Destinations"] as? [[String: Any]]
        else { return [] }

        return destinations.compactMap { destination in
            // Network destinations have no local disk to eject.
            guard (destination["Kind"] as? String) == "Local",
                  let id = destination["ID"] as? String else { return nil }
            let name = (destination["Name"] as? String) ?? "Time Machine"
            return (id, name, destination["MountPoint"] as? String)
        }
    }

    /// External, ejectable volumes that are mounted right now.
    ///
    /// Internal and non-ejectable volumes are filtered out here, which is what
    /// keeps the boot disk out of reach of every later step.
    static func attachedVolumes() -> [AttachedVolume] {
        let keys: [URLResourceKey] = [
            .volumeIsInternalKey, .volumeIsEjectableKey, .volumeIsBrowsableKey,
            .volumeUUIDStringKey, .volumeLocalizedNameKey, .volumeIsRootFileSystemKey,
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
        else { return [] }

        let destinations = timeMachineDestinations()

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

            let tmID = destinations.first { $0.mountPoint == path }?.id
            return AttachedVolume(
                path: path,
                name: values.volumeLocalizedName ?? url.lastPathComponent,
                volumeUUID: values.volumeUUIDString,
                tmDestinationID: tmID)
        }
    }

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

    /// Merge what is plugged in now, and what Time Machine knows about, into the
    /// remembered list. Disks are never dropped: the user picks from this list
    /// while the disk sits in a drawer.
    static func refreshKnownDisks(in config: inout GuardConfig) {
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
                   existing.name.caseInsensitiveCompare(disk.name) == .orderedSame { return true }
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

        for destination in timeMachineDestinations() {
            upsert(KnownDisk(
                id: destination.id,
                name: destination.name,
                volumeUUID: nil,
                tmDestinationID: destination.id,
                lastSeen: nil))
        }

        for volume in attachedVolumes() {
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

    /// The attached volume backing a remembered disk, if it is plugged in.
    static func attachedVolume(for disk: KnownDisk, among volumes: [AttachedVolume]) -> AttachedVolume? {
        volumes.first { volume in
            if let uuid = disk.volumeUUID, uuid == volume.volumeUUID { return true }
            if let tm = disk.tmDestinationID, tm == volume.tmDestinationID { return true }
            return false
        }
    }
}

// MARK: - Backup status

/// What Time Machine is doing right now. Read on demand while the popover is
/// open, never on a background schedule.
struct BackupStatus {
    var running = false
    var mountPoint: String?
    /// 0...1, or nil when Time Machine has not worked out a figure yet.
    var percent: Double?

    static func current() -> BackupStatus {
        let output = Shell.run("/usr/bin/tmutil", ["status", "-X"])
        guard output.status == 0, let root = Shell.plist(from: output.output) else {
            return BackupStatus()
        }
        var status = BackupStatus()
        status.running = (root["Running"] as? NSNumber)?.boolValue ?? false
        status.mountPoint = root["DestinationMountPoint"] as? String
        // tmutil reports -1 while it is still sizing the job up.
        if let raw = (root["Percent"] as? NSNumber)?.doubleValue ?? Double(root["Percent"] as? String ?? ""),
           raw >= 0 {
            status.percent = min(max(raw, 0), 1)
        }
        return status
    }

    func isBackingUp(to path: String) -> Bool {
        // A running backup with no destination reported is still a reason to
        // show activity on the one disk being guarded.
        running && (mountPoint == nil || mountPoint == path)
    }
}

// MARK: - Calendar

enum Calendar2 {
    /// Callback form. EKEventStore is not thread safe, so a caller that owns
    /// the store on one thread must stay on it - this never blocks or hops.
    static func requestAccess(_ store: EKEventStore, completion: @escaping (Bool) -> Void) {
        store.requestFullAccessToEvents { granted, error in
            if let error { Log.write("calendar access error: \(error.localizedDescription)") }
            completion(granted)
        }
    }

    /// Blocking form, for the command line tool where there is no run loop to
    /// return to.
    static func requestAccess(_ store: EKEventStore, timeout: TimeInterval = 30) -> Bool {
        var granted = false
        let semaphore = DispatchSemaphore(value: 0)
        store.requestFullAccessToEvents { ok, error in
            granted = ok
            if let error { Log.write("calendar access error: \(error.localizedDescription)") }
            semaphore.signal()
        }
        // Never let a hung permission prompt wedge the caller.
        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            Log.write("calendar access timed out")
            return false
        }
        return granted
    }

    /// A personal focus block has no other attendees; a real meeting does. That
    /// single signal separates "Focus" and "Home-office" from "Weekly sync/review"
    /// without any title matching.
    static func isRealMeeting(_ event: EKEvent, config: GuardConfig) -> Bool {
        if event.isAllDay { return false }
        if event.status == .canceled { return false }
        if config.ignoreFreeEvents && event.availability == .free { return false }
        if let id = event.eventIdentifier, config.skippedEventIDs.contains(id) { return false }
        guard let attendees = event.attendees, attendees.count >= config.minAttendees else {
            // minAttendees of 0 or 1 means "any timed event counts".
            return config.minAttendees <= 1
        }
        if let me = attendees.first(where: { $0.isCurrentUser }), me.participantStatus == .declined {
            return false
        }
        return true
    }

    /// The calendars the guard looks at. Returns nil for "all of them", which
    /// is what EventKit's predicate wants, and an empty array for "none" -
    /// a selection that resolves to nothing must match nothing, not everything.
    static func watchedCalendars(_ store: EKEventStore, config: GuardConfig) -> [EKCalendar]? {
        guard !config.watchAllCalendars else { return nil }
        return store.calendars(for: .event)
            .filter { config.watchedCalendarIDs.contains($0.calendarIdentifier) }
    }

    static func nextMeeting(_ store: EKEventStore, within minutes: Double, config: GuardConfig) -> EKEvent? {
        let calendars = watchedCalendars(store, config: config)
        if let calendars, calendars.isEmpty { return nil }
        let now = Date()
        let predicate = store.predicateForEvents(
            withStart: now, end: now.addingTimeInterval(minutes * 60), calendars: calendars)
        return store.events(matching: predicate)
            .filter { $0.startDate > now && isRealMeeting($0, config: config) }
            .min { $0.startDate < $1.startDate }
    }
}

// MARK: - Ejecting

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

        var lastOutput = ""
        for attempt in 1...max(1, config.ejectAttempts) {
            let result = Shell.run("/usr/sbin/diskutil", ["eject", volume.path])
            if result.status == 0 {
                Log.write("ejected \(volume.name) on attempt \(attempt)")
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
        let stop = Shell.run("/usr/bin/tmutil", ["stopbackup"])
        Log.write("tmutil stopbackup -> status \(stop.status)\(stop.output.isEmpty ? "" : ": \(stop.output)")")
    }

    static func blockingProcesses(at path: String) -> String {
        let lsof = Shell.run("/usr/sbin/lsof", ["+D", path])
        let names = Set(lsof.output.split(separator: "\n").dropFirst().compactMap {
            $0.split(separator: " ").first.map(String.init)
        })
        return names.sorted().prefix(4).joined(separator: ", ")
    }
}

// MARK: - The guard itself

enum GuardRunner {
    struct Outcome {
        var meeting: EKEvent?
        var ejected: [String] = []
        var failed: [(name: String, detail: String)] = []
    }

    /// One pass. Safe to call every 30 s: once a disk is ejected it is no longer
    /// attached, so every later pass is a no-op.
    @discardableResult
    static func tick(store: EKEventStore, dryRun: Bool = false) -> Outcome {
        let config = ConfigStore.mutate { config -> GuardConfig in
            Disks.refreshKnownDisks(in: &config)
            return config
        }

        var outcome = Outcome()
        guard config.isActive else { return outcome }

        // Nothing guarded is plugged in, so do not touch the calendar at all.
        let targets = guardedAttachedVolumes(config)
        guard !targets.isEmpty else { return outcome }

        guard let meeting = Calendar2.nextMeeting(
            store, within: config.leadMinutes, config: config) else { return outcome }
        outcome.meeting = meeting

        let minutesAhead = Int((meeting.startDate.timeIntervalSince(Date()) / 60).rounded())
        let title = meeting.title ?? "Meeting"

        for target in targets {
            Log.write("trigger: \"\(title)\" in \(minutesAhead) min -> ejecting \(target.name) (\(target.path))")
            let result = eject(target, config: config, dryRun: dryRun)
            if result.succeeded {
                outcome.ejected.append(target.name)
            } else {
                outcome.failed.append((target.name, result.detail))
            }
        }

        announce(outcome, meetingTitle: title, minutesAhead: minutesAhead)
        return outcome
    }

    static func eject(_ volume: AttachedVolume, config: GuardConfig, dryRun: Bool) -> Ejector.Result {
        Ejector.eject(volume, config: config, dryRun: dryRun)
    }

    /// Guarded disks that are plugged in right now.
    static func guardedAttachedVolumes(_ config: GuardConfig) -> [AttachedVolume] {
        let attached = Disks.attachedVolumes()
        return config.knownDisks
            .filter { config.watchedDiskIDs.contains($0.id) }
            .compactMap { Disks.attachedVolume(for: $0, among: attached) }
    }

    /// Eject every guarded disk without consulting the calendar. Used by the
    /// "eject now" menu item and by the optional eject-on-sleep hook.
    @discardableResult
    static func ejectGuarded(reason: String, config: GuardConfig, notifyOnSuccess: Bool = true) -> Outcome {
        var outcome = Outcome()
        for volume in guardedAttachedVolumes(config) {
            Log.write("\(reason) -> ejecting \(volume.name) (\(volume.path))")
            let result = Ejector.eject(volume, config: config)
            if result.succeeded {
                outcome.ejected.append(volume.name)
            } else {
                outcome.failed.append((volume.name, result.detail))
            }
        }
        if notifyOnSuccess && !outcome.ejected.isEmpty {
            Notify.post(title: "\(outcome.ejected.joined(separator: ", ")) ejected",
                         body: "\(reason). Safe to unplug.")
        }
        for failure in outcome.failed {
            Notify.post(title: "Could not eject \(failure.name)",
                         body: "Held by \(failure.detail.isEmpty ? "an unknown process" : failure.detail).")
        }
        return outcome
    }

    static func announce(_ outcome: Outcome, meetingTitle: String, minutesAhead: Int) {
        if !outcome.ejected.isEmpty {
            Notify.post(
                title: "\(outcome.ejected.joined(separator: ", ")) ejected",
                body: "\(meetingTitle) in \(minutesAhead) min. Safe to unplug.")
        }
        for failure in outcome.failed {
            Notify.post(
                title: "Could not eject \(failure.name)",
                body: "Held by \(failure.detail.isEmpty ? "an unknown process" : failure.detail). Do not unplug it.")
        }
    }
}
