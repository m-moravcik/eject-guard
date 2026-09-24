// What a disk is, and what the user has decided about it.

import Foundation

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
struct AttachedVolume: Equatable {
    var path: String
    var name: String
    var volumeUUID: String?
    var tmDestinationID: String?
}


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
    /// Guard is off until this moment.
    var pausedUntil: Date?
    /// How long the popover's pause row pauses for. A setting rather than a
    /// submenu, so the popover keeps one row and stays reviewable.
    var pauseHours: Double = 1
    /// Events the user chose to ignore once. Bounded - see `skip(_:)`.
    var skippedEventIDs: [String] = []

    static let maxSkippedEvents = 50

    /// Record a skip, keeping the list bounded. Stale identifiers cost nothing
    /// but the file should not grow forever.
    mutating func skip(_ eventID: String) {
        skippedEventIDs.removeAll { $0 == eventID }
        skippedEventIDs.append(eventID)
        if skippedEventIDs.count > Self.maxSkippedEvents {
            skippedEventIDs.removeFirst(skippedEventIDs.count - Self.maxSkippedEvents)
        }
    }

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
        case pausedUntil, pauseHours, skippedEventIDs, ejectAttempts, ejectRetryDelay
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
        pauseHours = value(.pauseHours, fallback.pauseHours)
        skippedEventIDs = value(.skippedEventIDs, fallback.skippedEventIDs)
        ejectAttempts = value(.ejectAttempts, fallback.ejectAttempts)
        ejectRetryDelay = value(.ejectRetryDelay, fallback.ejectRetryDelay)
    }
}

enum ConfigStore {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/EjectGuard")
    /// Where releases before 1.3, still called TM Eject Guard, kept it.
    static let legacyDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/TMEjectGuard")
    static let url = directory.appendingPathComponent("config.json")

    // The menu bar app writes the disk selection from the main thread while a
    // pass may be running on a background queue, so every access is serialised.
    private static let lock = NSLock()

    static func load() -> GuardConfig {
        lock.lock(); defer { lock.unlock() }
        migrateOnce()
        repairPermissionsOnce()
        return readUnlocked()
    }

    /// Only ever touched with `lock` held.
    nonisolated(unsafe) private static var migrationChecked = false

    /// Before the first read or write, so neither the app nor the CLI can
    /// create an empty config in the new place while the old one still holds
    /// every setting.
    private static func migrateOnce() {
        guard !migrationChecked else { return }
        migrationChecked = true
        if migrate(from: legacyDirectory, to: directory) {
            Log.write("moved settings from \(legacyDirectory.path) to \(directory.path)")
        }
    }

    /// Moves the old folder to the new name, once. A move and not a copy, so
    /// there are never two configs drifting apart. When the new folder already
    /// exists both are left alone: that one is the newer truth.
    static func migrate(from legacy: URL, to current: URL) -> Bool {
        let files = FileManager.default
        guard files.fileExists(atPath: legacy.path),
              !files.fileExists(atPath: current.path) else { return false }
        do {
            try files.createDirectory(at: current.deletingLastPathComponent(),
                                      withIntermediateDirectories: true)
            try files.moveItem(at: legacy, to: current)
            return true
        } catch {
            Log.write("could not move settings from \(legacy.path): \(error)")
            return false
        }
    }

    /// Only ever touched from `load()`, which holds `lock`.
    nonisolated(unsafe) private static var permissionsChecked = false

    /// An earlier version wrote this file with the default umask.
    private static func repairPermissionsOnce() {
        guard !permissionsChecked else { return }
        permissionsChecked = true
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func save(_ config: GuardConfig) {
        lock.lock(); defer { lock.unlock() }
        migrateOnce()
        writeUnlocked(config)
    }

    /// Read-modify-write as one atomic step. Use this instead of load/save
    /// whenever the new value depends on the old one.
    @discardableResult
    static func mutate<T>(_ body: (inout GuardConfig) -> T) -> T {
        lock.lock(); defer { lock.unlock() }
        migrateOnce()
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
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: url, options: .atomic)
        // An atomic write replaces the file, so the mode has to be reapplied.
        try? FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
