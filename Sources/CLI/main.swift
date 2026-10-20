// Command line face of eject-guard: inspect state, pick disks, force a pass.
// The menu bar app is the normal way to use this; the CLI exists for setup,
// scripting and debugging.

import EventKit
import Foundation

func usage() -> Never {
    print("""
    eject-guard - eject guarded external disks before a meeting starts

      eject-guard                  show disks, selection and the next meeting
      eject-guard --list           list remembered disks
      eject-guard --watch NAME     guard this disk (name or id, case insensitive)
      eject-guard --unwatch NAME   stop guarding it
      eject-guard --hide NAME      hide a disk for good (--unhide brings it back)
      eject-guard --unhide         bring back every hidden disk
      eject-guard --forget-disk NAME
                                   forget an unplugged disk until it is plugged in
                                   again; a guarded one asks first (--yes skips that)
      eject-guard --forget NAME    old name of --hide, removed in the next release
      eject-guard --unskip         undo the most recent skipped meeting
      eject-guard --unskip-all     undo every skipped meeting
      eject-guard --run            run one pass now (unmounts before a meeting, reconnects after)
      eject-guard --dry-run        same, but never unmount or mount
      eject-guard --eject-now      eject every guarded disk regardless of calendar
      eject-guard --calendars      list calendars and which ones are watched
      eject-guard --watch-cal NAME   watch this calendar (repeatable)
      eject-guard --unwatch-cal NAME stop watching it
      eject-guard --lead MINUTES   set how long before a meeting to eject
      eject-guard --enable         turn the guard on
      eject-guard --disable        turn the guard off

    Config: \(ConfigStore.url.path)
    Log:    \(Log.url.path)
    """)
    exit(0)
}

// Before anything reads the config: help should never have side effects, and
// the first read of the config can move its folder (see ConfigStore.migrate).
if CommandLine.arguments.contains(where: { $0 == "--help" || $0 == "-h" }) { usage() }

// Kept, so --forget-disk asks the same question of it as the menu item asks
// of the app's last scan.
let snapshot = Disks.scan()
var config = ConfigStore.mutate { config -> GuardConfig in
    Disks.merge(snapshot, into: &config)
    return config
}

/// Resolve a user supplied disk reference against the remembered list.
@MainActor
func findDisk(_ needle: String) -> KnownDisk? {
    config.knownDisks.first { $0.id.caseInsensitiveCompare(needle) == .orderedSame }
        ?? config.knownDisks.first { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
        ?? config.knownDisks.first { $0.name.localizedCaseInsensitiveContains(needle) }
}

@MainActor
func printDisks() {
    let attached = Disks.scan().attached
    if config.knownDisks.isEmpty {
        print("no external disks remembered yet - plug one in and run this again")
        return
    }
    print("remembered disks:")
    for disk in config.knownDisks {
        let watched = config.watchedDiskIDs.contains(disk.id) ? "[x]" : "[ ]"
        let live = Disks.attachedVolume(for: disk, among: attached)
        let state = disk.isNetworkDestination
            ? "network - a running backup is stopped, nothing is ejected"
            : live.map { "attached at \($0.path)" } ?? "not attached"
        let tm = disk.isTimeMachineDestination ? " (Time Machine)" : ""
        print("  \(watched) \(disk.name)\(tm) - \(state)")
        print("        id: \(disk.id)")
    }
}

func printBackupStops(_ outcome: GuardRunner.Outcome) {
    for name in outcome.stoppedBackups { print("stopped backup: \(name)") }
    for name in outcome.unstoppedBackups { print("FAILED: the backup to \(name) is still running") }
}

var arguments = Array(CommandLine.arguments.dropFirst())
var action = "status"
var pendingValue: String?
/// --yes: forget a guarded disk without asking.
var confirmed = false

while !arguments.isEmpty {
    let argument = arguments.removeFirst()
    func value() -> String {
        guard !arguments.isEmpty else {
            FileHandle.standardError.write("\(argument) needs a value\n".data(using: .utf8)!)
            exit(64)
        }
        return arguments.removeFirst()
    }
    switch argument {
    case "--help", "-h": usage()
    case "--list": action = "list"
    case "--run": action = "run"
    case "--dry-run": action = "dry-run"
    case "--eject-now": action = "eject-now"
    case "--watch": action = "watch"; pendingValue = value()
    case "--unwatch": action = "unwatch"; pendingValue = value()
    case "--hide": action = "hide"; pendingValue = value()
    case "--forget":
        // It always hid. One release of warning before the name is free.
        FileHandle.standardError.write(
            ("note: --forget is now --hide and will be removed in the next release. "
                + "To drop an unplugged disk until it is plugged in again, use --forget-disk.\n")
                .data(using: .utf8)!)
        action = "hide"; pendingValue = value()
    case "--forget-disk": action = "forget-disk"; pendingValue = value()
    case "--yes", "-y": confirmed = true
    case "--unhide": action = "unhide"
    case "--unskip": action = "unskip"
    case "--unskip-all": action = "unskip-all"
    case "--calendars": action = "calendars"
    case "--watch-cal": action = "watch-cal"; pendingValue = value()
    case "--unwatch-cal": action = "unwatch-cal"; pendingValue = value()
    case "--lead":
        guard let minutes = Double(value()), minutes > 0 else {
            FileHandle.standardError.write("--lead needs a positive number\n".data(using: .utf8)!)
            exit(64)
        }
        config.leadMinutes = minutes
        ConfigStore.save(config)
        print("lead time: \(Int(minutes)) min")
    case "--enable", "--disable":
        config.enabled = (argument == "--enable")
        ConfigStore.save(config)
        print("guard \(config.enabled ? "enabled" : "disabled")")
    default:
        FileHandle.standardError.write("unknown argument: \(argument)\n".data(using: .utf8)!)
        exit(64)
    }
}

switch action {
case "list":
    printDisks()

case "watch", "unwatch", "hide":
    guard let needle = pendingValue, let disk = findDisk(needle) else {
        FileHandle.standardError.write("no remembered disk matches \"\(pendingValue ?? "")\"\n".data(using: .utf8)!)
        printDisks()
        exit(1)
    }
    ConfigStore.mutate { config in
        switch action {
        case "watch":
            if !config.watchedDiskIDs.contains(disk.id) { config.watchedDiskIDs.append(disk.id) }
        case "hide":
            config.watchedDiskIDs.removeAll { $0 == disk.id }
            config.knownDisks.removeAll { $0.id == disk.id }
            if !config.dismissedDiskIDs.contains(disk.id) {
                config.dismissedDiskIDs.append(disk.id)
            }
        default:
            config.watchedDiskIDs.removeAll { $0 == disk.id }
        }
    }
    switch action {
    case "watch": print("guarding: \(disk.name)")
    case "hide": print("hidden: \(disk.name)")
    default: print("no longer guarding: \(disk.name)")
    }

case "forget-disk":
    guard let needle = pendingValue, let disk = findDisk(needle) else {
        FileHandle.standardError.write("no remembered disk matches \"\(pendingValue ?? "")\"\n".data(using: .utf8)!)
        printDisks()
        exit(1)
    }
    switch Disks.forgetBlocker(disk, attached: snapshot.attached,
                               reportedDestinationIDs: Set(snapshot.destinations.map(\.id))) {
    case .attached?:
        FileHandle.standardError.write(
            "\(disk.name) is plugged in, so the next scan would list it again. Unplug it first, or use --hide.\n"
                .data(using: .utf8)!)
        exit(1)
    case .reportedByTimeMachine?:
        FileHandle.standardError.write(
            "Time Machine still backs up to \(disk.name), so it would be listed again. Use --hide.\n"
                .data(using: .utf8)!)
        exit(1)
    case nil:
        break
    }
    // As in the menu: forgetting a guarded disk stops guarding it, so it is
    // asked about first. Without a terminal to ask on, only --yes will do.
    if config.watchedDiskIDs.contains(disk.id), !confirmed {
        guard isatty(STDIN_FILENO) != 0 else {
            FileHandle.standardError.write(
                "\(disk.name) is guarded. Forgetting it stops guarding it; add --yes to go ahead.\n"
                    .data(using: .utf8)!)
            exit(1)
        }
        print("\(disk.name) is guarded. Forgetting it stops guarding it, and the next time you plug it in "
              + "it is listed as not guarded. Forget it? [y/N] ", terminator: "")
        guard let answer = readLine(), answer.lowercased().hasPrefix("y") else {
            print("left as it was")
            exit(1)
        }
    }
    ConfigStore.mutate { $0.forget(disk) }
    Log.write("forgot \"\(disk.name)\" - by hand, from the command line")
    print("forgotten: \(disk.name) - listed again when it is plugged in")

case "unhide":
    let restored = ConfigStore.mutate { config -> Int in
        let count = config.dismissedDiskIDs.count
        config.dismissedDiskIDs = []
        return count
    }
    print(restored == 0 ? "no hidden disks" : "restored \(restored) hidden disk(s)")

case "unskip", "unskip-all":
    let removed = ConfigStore.mutate { config -> Int in
        if action == "unskip-all" {
            let count = config.skippedEventIDs.count
            config.skippedEventIDs = []
            return count
        }
        guard !config.skippedEventIDs.isEmpty else { return 0 }
        config.skippedEventIDs.removeLast()
        return 1
    }
    print(removed == 0 ? "nothing was skipped" : "un-skipped \(removed) meeting(s)")

case "calendars", "watch-cal", "unwatch-cal":
    let store = EKEventStore()
    guard Meetings.requestAccess(store) else {
        FileHandle.standardError.write("calendar access denied\n".data(using: .utf8)!)
        exit(3)
    }
    let calendars = store.calendars(for: .event)
    if action != "calendars" {
        guard let needle = pendingValue,
              let calendar = calendars.first(where: { $0.title.caseInsensitiveCompare(needle) == .orderedSame })
                  ?? calendars.first(where: { $0.title.localizedCaseInsensitiveContains(needle) })
        else {
            FileHandle.standardError.write("no calendar matches \"\(pendingValue ?? "")\"\n".data(using: .utf8)!)
            exit(1)
        }
        let everyID = calendars.map(\.calendarIdentifier)
        config = ConfigStore.mutate { config -> GuardConfig in
            // Narrowing from "all" starts from everything selected, so one
            // command does not silently drop every other calendar.
            if config.watchAllCalendars {
                config.watchAllCalendars = false
                config.watchedCalendarIDs = everyID
            }
            if action == "watch-cal" {
                if !config.watchedCalendarIDs.contains(calendar.calendarIdentifier) {
                    config.watchedCalendarIDs.append(calendar.calendarIdentifier)
                }
            } else {
                config.watchedCalendarIDs.removeAll { $0 == calendar.calendarIdentifier }
            }
            if Set(config.watchedCalendarIDs) == Set(everyID) {
                config.watchAllCalendars = true
                config.watchedCalendarIDs = []
            }
            return config
        }
    }
    if config.watchAllCalendars {
        print("watching ALL calendars")
    }
    for calendar in calendars.sorted(by: { $0.title < $1.title }) {
        let watched = config.watchAllCalendars
            || config.watchedCalendarIDs.contains(calendar.calendarIdentifier)
        print("  \(watched ? "[x]" : "[ ]") \(calendar.title)  (\(calendar.source.title))")
    }

case "run", "dry-run":
    let store = EKEventStore()
    guard Meetings.requestAccess(store) else {
        FileHandle.standardError.write(
            "calendar access denied - System Settings > Privacy & Security > Calendars\n".data(using: .utf8)!)
        exit(3)
    }
    let dryRun = action == "dry-run"
    let outcome = GuardRunner.tick(store: store, dryRun: dryRun)
    if let meeting = outcome.meeting {
        let minutes = Int(meeting.startDate.timeIntervalSinceNow / 60)
        print("meeting: \"\(meeting.title ?? "?")\" in \(minutes) min")
    } else {
        print("no qualifying meeting within \(Int(config.leadMinutes)) min - nothing to do")
    }
    if !outcome.unmounted.isEmpty {
        print("\(dryRun ? "would unmount" : "unmounted") until the meeting ends: \(outcome.unmounted.joined(separator: ", "))")
    }
    for name in outcome.ejected { print("\(dryRun ? "would eject" : "ejected") (no volume UUID to find it again): \(name)") }
    for failure in outcome.failed { print("FAILED: \(failure.name) - held by \(failure.detail)") }
    for name in outcome.reconnect.reconnected { print("\(dryRun ? "would reconnect" : "reconnected"): \(name)") }
    for name in outcome.reconnect.failed { print("FAILED to reconnect: \(name) - unplug it and plug it back in") }
    printBackupStops(outcome)
    if !outcome.failed.isEmpty || !outcome.unstoppedBackups.isEmpty || !outcome.reconnect.failed.isEmpty {
        exit(1)
    }

case "eject-now":
    let outcome = GuardRunner.ejectGuarded(reason: .manual(), config: config, notifyOnSuccess: false)
    if outcome.didNothing {
        print("no guarded disk is attached, and no backup to a guarded share is running")
    }
    for name in outcome.ejected { print("ejected: \(name)") }
    for failure in outcome.failed { print("FAILED: \(failure.name) - held by \(failure.detail)") }
    printBackupStops(outcome)
    if !outcome.failed.isEmpty || !outcome.unstoppedBackups.isEmpty { exit(1) }

default:
    printDisks()
    print("")
    var state = config.enabled ? "enabled" : "disabled"
    if let until = config.pausedUntil, until > Date() {
        state += " (paused until \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)))"
    }
    print("guard  : \(state), \(Int(config.leadMinutes)) min before a meeting")
    print("filter : events with at least \(config.minAttendees) attendees, not declined, not all day")
    print("cals   : \(config.watchAllCalendars ? "all" : "\(config.watchedCalendarIDs.count) selected")")
    for entry in config.pendingReconnects {
        let at = DateFormatter.localizedString(from: entry.notBefore, dateStyle: .none, timeStyle: .short)
        print("later  : reconnect \(entry.name) after \(at) if it is still plugged in")
    }

    let store = EKEventStore()
    if Meetings.requestAccess(store) {
        if let meeting = Meetings.nextMeeting(store, within: 24 * 60, config: config) {
            let minutes = Int(meeting.startDate.timeIntervalSinceNow / 60)
            print("next   : \"\(meeting.title ?? "?")\" in \(minutes) min (\(meeting.calendar.title))")
        } else {
            print("next   : no qualifying meeting in the next 24 h")
        }
    } else {
        print("next   : calendar access denied")
    }
}
