// Command line face of tm-eject-guard: inspect state, pick disks, force a pass.
// The menu bar app is the normal way to use this; the CLI exists for setup,
// scripting and debugging.

import EventKit
import Foundation

func usage() -> Never {
    print("""
    tm-eject-guard - eject guarded external disks before a meeting starts

      tm-eject-guard                  show disks, selection and the next meeting
      tm-eject-guard --list           list remembered disks
      tm-eject-guard --watch NAME     guard this disk (name or id, case insensitive)
      tm-eject-guard --unwatch NAME   stop guarding it
      tm-eject-guard --forget NAME    drop a disk from the remembered list
      tm-eject-guard --run            run one pass now (ejects if a meeting is due)
      tm-eject-guard --dry-run        same, but never eject
      tm-eject-guard --eject-now      eject every guarded disk regardless of calendar
      tm-eject-guard --calendars      list calendars and which ones are watched
      tm-eject-guard --watch-cal NAME   watch this calendar (repeatable)
      tm-eject-guard --unwatch-cal NAME stop watching it
      tm-eject-guard --lead MINUTES   set how long before a meeting to eject
      tm-eject-guard --enable         turn the guard on
      tm-eject-guard --disable        turn the guard off

    Config: \(ConfigStore.url.path)
    Log:    \(Log.url.path)
    """)
    exit(0)
}

var config = ConfigStore.mutate { config -> GuardConfig in
    Disks.refreshKnownDisks(in: &config)
    return config
}

/// Resolve a user supplied disk reference against the remembered list.
func findDisk(_ needle: String) -> KnownDisk? {
    config.knownDisks.first { $0.id.caseInsensitiveCompare(needle) == .orderedSame }
        ?? config.knownDisks.first { $0.name.caseInsensitiveCompare(needle) == .orderedSame }
        ?? config.knownDisks.first { $0.name.localizedCaseInsensitiveContains(needle) }
}

func printDisks() {
    let attached = Disks.attachedVolumes()
    if config.knownDisks.isEmpty {
        print("no external disks remembered yet - plug one in and run this again")
        return
    }
    print("remembered disks:")
    for disk in config.knownDisks {
        let watched = config.watchedDiskIDs.contains(disk.id) ? "[x]" : "[ ]"
        let live = Disks.attachedVolume(for: disk, among: attached)
        let state = live.map { "attached at \($0.path)" } ?? "not attached"
        let tm = disk.isTimeMachineDestination ? " (Time Machine)" : ""
        print("  \(watched) \(disk.name)\(tm) - \(state)")
        print("        id: \(disk.id)")
    }
}

var arguments = Array(CommandLine.arguments.dropFirst())
var action = "status"
var pendingValue: String?

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
    case "--forget": action = "forget"; pendingValue = value()
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

case "watch", "unwatch", "forget":
    guard let needle = pendingValue, let disk = findDisk(needle) else {
        FileHandle.standardError.write("no remembered disk matches \"\(pendingValue ?? "")\"\n".data(using: .utf8)!)
        printDisks()
        exit(1)
    }
    ConfigStore.mutate { config in
        switch action {
        case "watch":
            if !config.watchedDiskIDs.contains(disk.id) { config.watchedDiskIDs.append(disk.id) }
        case "forget":
            config.watchedDiskIDs.removeAll { $0 == disk.id }
            config.knownDisks.removeAll { $0.id == disk.id }
        default:
            config.watchedDiskIDs.removeAll { $0 == disk.id }
        }
    }
    switch action {
    case "watch": print("guarding: \(disk.name)")
    case "forget": print("forgotten: \(disk.name)")
    default: print("no longer guarding: \(disk.name)")
    }

case "calendars", "watch-cal", "unwatch-cal":
    let store = EKEventStore()
    guard Calendar2.requestAccess(store) else {
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
        config = ConfigStore.mutate { config -> GuardConfig in
            if action == "watch-cal" {
                if !config.watchedCalendarIDs.contains(calendar.calendarIdentifier) {
                    config.watchedCalendarIDs.append(calendar.calendarIdentifier)
                }
            } else {
                config.watchedCalendarIDs.removeAll { $0 == calendar.calendarIdentifier }
            }
            return config
        }
    }
    if config.watchedCalendarIDs.isEmpty {
        print("watching ALL calendars (no selection made)")
    }
    for calendar in calendars.sorted(by: { $0.title < $1.title }) {
        let watched = config.watchedCalendarIDs.isEmpty
            || config.watchedCalendarIDs.contains(calendar.calendarIdentifier)
        print("  \(watched ? "[x]" : "[ ]") \(calendar.title)  (\(calendar.source.title))")
    }

case "run", "dry-run":
    let store = EKEventStore()
    guard Calendar2.requestAccess(store) else {
        FileHandle.standardError.write(
            "calendar access denied - System Settings > Privacy & Security > Calendars\n".data(using: .utf8)!)
        exit(3)
    }
    let outcome = GuardRunner.tick(store: store, dryRun: action == "dry-run")
    if let meeting = outcome.meeting {
        let minutes = Int(meeting.startDate.timeIntervalSinceNow / 60)
        print("meeting: \"\(meeting.title ?? "?")\" in \(minutes) min")
    } else {
        print("no qualifying meeting within \(Int(config.leadMinutes)) min - nothing to do")
    }
    if !outcome.ejected.isEmpty { print("ejected: \(outcome.ejected.joined(separator: ", "))") }
    for failure in outcome.failed { print("FAILED: \(failure.name) - held by \(failure.detail)") }
    if !outcome.failed.isEmpty { exit(1) }

case "eject-now":
    let outcome = GuardRunner.ejectGuarded(reason: "manual eject", config: config, notifyOnSuccess: false)
    if outcome.ejected.isEmpty && outcome.failed.isEmpty {
        print("no guarded disk is attached")
    }
    for name in outcome.ejected { print("ejected: \(name)") }
    for failure in outcome.failed { print("FAILED: \(failure.name) - held by \(failure.detail)") }
    if !outcome.failed.isEmpty { exit(1) }

default:
    printDisks()
    print("")
    var state = config.enabled ? "enabled" : "disabled"
    if let until = config.pausedUntil, until > Date() {
        state += " (paused until \(DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)))"
    }
    print("guard  : \(state), \(Int(config.leadMinutes)) min before a meeting")
    print("filter : events with at least \(config.minAttendees) attendees, not declined, not all day")
    print("cals   : \(config.watchedCalendarIDs.isEmpty ? "all" : "\(config.watchedCalendarIDs.count) selected")")

    let store = EKEventStore()
    if Calendar2.requestAccess(store) {
        if let meeting = Calendar2.nextMeeting(store, within: 24 * 60, config: config) {
            let minutes = Int(meeting.startDate.timeIntervalSinceNow / 60)
            print("next   : \"\(meeting.title ?? "?")\" in \(minutes) min (\(meeting.calendar.title))")
        } else {
            print("next   : no qualifying meeting in the next 24 h")
        }
    } else {
        print("next   : calendar access denied")
    }
}
