// tm-eject-guard - eject the Time Machine USB disk shortly before a meeting starts,
// so the drive is never yanked out while mounted.
//
// Run periodically by a LaunchAgent (every 60 s). Idempotent: once the volume is
// gone every later run is a no-op.

import EventKit
import Foundation

// MARK: - Configuration

struct Config {
    // The Time Machine destination UUID is the identity we eject by: it lives on
    // the disk itself, so no other volume can impersonate it by name.
    var destinationID = "EFDC7CBB-D8C5-460C-BCB3-A06E45CF7D91"  // "Time Machine WD"
    var volumeName = "Time Machine WD"  // only used if tmutil cannot resolve the ID
    var leadMinutes = 6.0               // act when a meeting starts within this many minutes
    var minAttendees = 2                // real meeting vs. personal focus block
    var ejectAttempts = 6               // retries while the volume is busy
    var ejectRetryDelay = 15.0          // seconds between retries
    var dryRun = false
    var check = false                   // report state and exit, never eject
}

var cfg = Config()
var args = Array(CommandLine.arguments.dropFirst())
while let arg = args.first {
    args.removeFirst()
    func next() -> String? { args.isEmpty ? nil : args.removeFirst() }
    switch arg {
    case "--dry-run": cfg.dryRun = true
    case "--check": cfg.check = true
    case "--destination": cfg.destinationID = next() ?? cfg.destinationID
    case "--volume": cfg.volumeName = next() ?? cfg.volumeName
    case "--lead": cfg.leadMinutes = Double(next() ?? "") ?? cfg.leadMinutes
    case "--help", "-h":
        print("""
        tm-eject-guard [--check] [--dry-run] [--destination UUID] [--volume NAME] [--lead MINUTES]

          --check        print the resolved disk + next meeting, never eject
          --dry-run      run the full decision and log it, but do not eject
          --destination  Time Machine destination UUID (default: \(cfg.destinationID))
          --volume       volume name used only as a fallback (default: \(cfg.volumeName))
          --lead         minutes before a meeting to eject (default: \(Int(cfg.leadMinutes)))

        Destination UUIDs come from: tmutil destinationinfo
        """)
        exit(0)
    default:
        FileHandle.standardError.write("unknown argument: \(arg)\n".data(using: .utf8)!)
        exit(64)
    }
}

// MARK: - Logging

let logURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Logs/tm-eject-guard.log")

let stamp: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "yyyy-MM-dd HH:mm:ss"
    return f
}()

func log(_ message: String) {
    let line = "\(stamp.string(from: Date()))  \(message)\n"
    guard let data = line.data(using: .utf8) else { return }
    // Echo to stderr only when run by hand; under launchd the file is the log.
    if isatty(STDERR_FILENO) == 1 {
        FileHandle.standardError.write(data)
    }
    // Keep the log from growing without bound.
    if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int,
       size > 512_000 {
        try? FileManager.default.removeItem(at: logURL)
    }
    if let handle = try? FileHandle(forWritingTo: logURL) {
        handle.seekToEndOfFile()
        handle.write(data)
        try? handle.close()
    } else {
        try? data.write(to: logURL)
    }
}

// MARK: - Shell helper

@discardableResult
func run(_ launchPath: String, _ arguments: [String]) -> (status: Int32, output: String) {
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

func plist(from output: String) -> [String: Any]? {
    guard let data = output.data(using: .utf8),
          let root = try? PropertyListSerialization.propertyList(
              from: data, options: [], format: nil) as? [String: Any]
    else { return nil }
    return root
}

func notify(title: String, body: String) {
    // AppleScript string literals: backslashes first, then quotes.
    func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }
    run("/usr/bin/osascript", ["-e",
        "display notification \"\(esc(body))\" with title \"\(esc(title))\" sound name \"Submarine\""])
}

// MARK: - Locating the disk

struct TargetVolume {
    let path: String
    let how: String
}

/// A path is only a candidate if it is a directory directly inside /Volumes.
/// This is the backstop that keeps a malformed mount point from ever reaching
/// `diskutil eject`.
func isMountedVolume(_ path: String) -> Bool {
    guard path.hasPrefix("/Volumes/"), path.count > "/Volumes/".count else { return false }
    guard URL(fileURLWithPath: path).deletingLastPathComponent().path == "/Volumes" else { return false }
    var isDirectory: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory),
          isDirectory.boolValue else { return false }
    return true
}

/// Resolve the one disk we are allowed to eject.
/// Returns nil whenever the configured Time Machine disk is not attached.
func resolveTargetVolume() -> TargetVolume? {
    let info = run("/usr/bin/tmutil", ["destinationinfo", "-X"])
    if info.status == 0,
       let root = plist(from: info.output),
       let destinations = root["Destinations"] as? [[String: Any]] {

        if let destination = destinations.first(where: {
            ($0["ID"] as? String)?.caseInsensitiveCompare(cfg.destinationID) == .orderedSame
        }) {
            // A network destination has no local disk to eject - never touch it.
            guard (destination["Kind"] as? String) == "Local" else { return nil }
            // No MountPoint means the disk is simply not plugged in right now.
            guard let mount = destination["MountPoint"] as? String, isMountedVolume(mount) else {
                // Unless a volume with the expected name is sitting there anyway,
                // in which case tmutil is not reporting MountPoint the way we
                // assume and the guard would silently never fire. Say so loudly
                // rather than do nothing.
                if isMountedVolume("/Volumes/\(cfg.volumeName)") {
                    log("WARNING: \"\(cfg.volumeName)\" is mounted but destination "
                        + "\(cfg.destinationID) reports no MountPoint - guard is inactive. "
                        + "Check 'tmutil destinationinfo -X'.")
                }
                return nil
            }
            return TargetVolume(path: mount, how: "destination \(cfg.destinationID)")
        }

        // The destination list was readable but our UUID is not in it: the
        // destination was removed or re-created. Do not guess.
        log("destination \(cfg.destinationID) is no longer configured - run 'tmutil destinationinfo'")
        return nil
    }

    // tmutil itself failed. Fall back to the volume name so a broken tmutil does
    // not silently disable the guard.
    let byName = "/Volumes/\(cfg.volumeName)"
    guard isMountedVolume(byName) else { return nil }
    log("tmutil destinationinfo failed - falling back to volume name")
    return TargetVolume(path: byName, how: "volume name fallback")
}

let target = resolveTargetVolume()

// Nothing plugged in means nothing to do. Skip the calendar entirely so the
// common case costs no Calendar access.
if target == nil && !cfg.check {
    exit(0)
}

// MARK: - Calendar

let store = EKEventStore()
var granted = false
let sem = DispatchSemaphore(value: 0)
store.requestFullAccessToEvents { ok, error in
    granted = ok
    if let error { log("calendar access error: \(error.localizedDescription)") }
    sem.signal()
}
// Guard against a hung TCC prompt so launchd never accumulates stuck processes.
if sem.wait(timeout: .now() + 30) == .timedOut {
    log("calendar access timed out")
    exit(3)
}
guard granted else {
    log("calendar access denied - grant it in System Settings > Privacy & Security > Calendars")
    exit(3)
}

let now = Date()
let horizon = now.addingTimeInterval(cfg.leadMinutes * 60)
let predicate = store.predicateForEvents(withStart: now, end: horizon, calendars: nil)

func isRealMeeting(_ event: EKEvent) -> Bool {
    if event.isAllDay { return false }
    if event.status == .canceled { return false }
    guard let attendees = event.attendees, attendees.count >= cfg.minAttendees else { return false }
    if let me = attendees.first(where: { $0.isCurrentUser }), me.participantStatus == .declined {
        return false
    }
    return true
}

let upcoming = store.events(matching: predicate)
    .filter { $0.startDate > now && isRealMeeting($0) }
    .sorted { $0.startDate < $1.startDate }

if cfg.check {
    if let target {
        print("disk     : \(target.path)")
        print("matched  : \(target.how)")
    } else {
        print("disk     : Time Machine destination \(cfg.destinationID) is not attached")
        if isMountedVolume("/Volumes/\(cfg.volumeName)") {
            print("WARNING  : a volume named \"\(cfg.volumeName)\" IS mounted but did not match")
            print("           the destination UUID - either it is a different disk, or tmutil")
            print("           is not reporting MountPoint. Run: tmutil destinationinfo -X")
        }
    }
    print("lead     : \(Int(cfg.leadMinutes)) min, min attendees: \(cfg.minAttendees)")
    if let next = upcoming.first {
        let mins = Int(next.startDate.timeIntervalSince(now) / 60)
        print("trigger  : \"\(next.title ?? "?")\" in \(mins) min (\(next.calendar.title))")
    } else {
        print("trigger  : no qualifying meeting within the lead window")
    }
    exit(0)
}

guard let target, let meeting = upcoming.first else { exit(0) }

let minutesAhead = Int((meeting.startDate.timeIntervalSince(now) / 60).rounded())
let title = meeting.title ?? "Meeting"
log("trigger: \"\(title)\" in \(minutesAhead) min -> ejecting \(target.path) (\(target.how))")

if cfg.dryRun {
    log("dry-run: would stop backup and eject \(target.path)")
    exit(0)
}

// MARK: - Eject

// Stop a backup that is writing to this disk; ejecting underneath backupd is
// exactly what we are trying to avoid. A backup to another destination is left
// alone.
let status = run("/usr/bin/tmutil", ["status", "-X"])
let statusRoot = plist(from: status.output)
let backupRunning = (statusRoot?["Running"] as? NSNumber)?.boolValue ?? true
let backupTarget = statusRoot?["DestinationMountPoint"] as? String
if backupRunning && (backupTarget == nil || backupTarget == target.path) {
    let stop = run("/usr/bin/tmutil", ["stopbackup"])
    log("tmutil stopbackup -> status \(stop.status)\(stop.output.isEmpty ? "" : ": \(stop.output)")")
}

var ejected = false
var lastOutput = ""
for attempt in 1...cfg.ejectAttempts {
    let result = run("/usr/sbin/diskutil", ["eject", target.path])
    if result.status == 0 {
        ejected = true
        log("ejected on attempt \(attempt)")
        break
    }
    lastOutput = result.output
    log("eject attempt \(attempt)/\(cfg.ejectAttempts) failed: \(result.output)")
    if attempt < cfg.ejectAttempts {
        Thread.sleep(forTimeInterval: cfg.ejectRetryDelay)
    }
}

let diskLabel = URL(fileURLWithPath: target.path).lastPathComponent
if ejected {
    notify(title: "\(diskLabel) odpojený",
           body: "\(title) o \(minutesAhead) min - disk môžeš bezpečne vytiahnuť.")
} else {
    // Name what is holding the volume so the failure is actionable.
    let blockers = run("/usr/sbin/lsof", ["+D", target.path])
    let names = Set(blockers.output.split(separator: "\n").dropFirst().compactMap {
        $0.split(separator: " ").first.map(String.init)
    }).sorted().prefix(4).joined(separator: ", ")
    log("EJECT FAILED: \(lastOutput) | holding: \(names.isEmpty ? "unknown" : names)")
    notify(title: "\(diskLabel) sa NEPODARILO odpojiť",
           body: "Drží ho: \(names.isEmpty ? "neznáme" : names). Nevyťahuj disk, odpoj ho ručne.")
    exit(1)
}
