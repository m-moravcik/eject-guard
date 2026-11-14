// Command line face of eject-guard: inspect state, pick disks, act now.
// The menu bar app is the normal way to use this; the CLI exists for setup,
// scripting, your own triggers and debugging.
//
// It ships inside the app at Contents/Helpers/eject-guard. While the app runs,
// anything that acts on a disk or changes the guard goes through the app over
// the control socket (see Control.swift), so there is one pass at a time and
// the popover shows the change at once. Without the app it acts on its own.

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
      eject-guard --unskip         undo the most recent skipped meeting
      eject-guard --unskip-all     undo every skipped meeting
      eject-guard --run            run one pass now (unmounts before a meeting, reconnects after)
      eject-guard --dry-run        same, but never unmount or mount
      eject-guard --eject-now      eject every guarded disk regardless of calendar
      eject-guard --pause MINUTES  pause the guard
      eject-guard --resume         resume a paused guard
      eject-guard --skip-next      leave the disks alone for today's next meeting
      eject-guard --stop-backup    stop the running Time Machine backup, guarded or not
      eject-guard --calendars      list calendars and which ones are watched
      eject-guard --watch-cal NAME   watch this calendar (repeatable)
      eject-guard --unwatch-cal NAME stop watching it
      eject-guard --lead MINUTES   set how long before a meeting to eject
      eject-guard --enable         turn the guard on
      eject-guard --disable        turn the guard off
      eject-guard --json           print the state as JSON (with no other command)
      eject-guard --version        print the version

    While Eject Guard is running, actions go through the app. Exit codes: 0 done,
    1 failed, 3 calendar access denied, 64 bad usage.

    Config: \(ConfigStore.url.path)
    Log:    \(Log.url.path)
    """)
    exit(0)
}

// Before anything reads the config: help should never have side effects, and
// the first read of the config can move its folder (see ConfigStore.migrate).
if CommandLine.arguments.contains(where: { $0 == "--help" || $0 == "-h" }) { usage() }
if CommandLine.arguments.contains("--version") {
    // Stamped by build.sh into the plist embedded in this binary, so it is
    // always the version of the app it shipped in.
    print(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown")
    exit(0)
}

/// Prints a response the way every action ends, and exits with its code.
func finish(_ response: Control.Response) -> Never {
    for line in response.lines { print(line) }
    for line in response.errors { FileHandle.standardError.write("\(line)\n".data(using: .utf8)!) }
    exit(response.exitCode)
}

/// The running app's answer, or nil when it is not running and this tool
/// should act on its own. Any other failure is an answer too: falling back to
/// acting alone while the app may be acting as well is the race this avoids.
func askApp(_ request: Control.Request) -> Control.Response? {
    switch Control.send(request) {
    case .success(let response): return response
    case .failure(.notRunning): return nil
    case .failure(.timedOut): return .failure("Eject Guard did not answer in time - see the log")
    case .failure(.refused(let why)), .failure(.io(let why)): return .failure("could not reach Eject Guard: \(why)")
    }
}

/// After a change to the config file: the app rereads it now rather than at
/// its next pass. Nothing to do when it is not running.
func tellAppToReload() {
    _ = Control.send(Control.Request(command: .reload))
}

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

var arguments = Array(CommandLine.arguments.dropFirst())
var action = "status"
var pendingValue: String?
/// --yes: forget a guarded disk without asking.
var confirmed = false
var json = false
var pauseMinutes: Int?

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
    case "--pause":
        action = "pause"
        let text = value()
        guard let minutes = Int(text), minutes > 0 else {
            FileHandle.standardError.write("--pause needs a positive number of minutes\n".data(using: .utf8)!)
            exit(64)
        }
        pauseMinutes = minutes
    case "--resume": action = "resume"
    case "--skip-next": action = "skip-next"
    case "--stop-backup": action = "stop-backup"
    case "--json": json = true
    case "--watch": action = "watch"; pendingValue = value()
    case "--unwatch": action = "unwatch"; pendingValue = value()
    case "--hide": action = "hide"; pendingValue = value()
    case "--forget-disk": action = "forget-disk"; pendingValue = value()
    case "--yes": confirmed = true
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
        config = ConfigStore.mutate { config -> GuardConfig in
            config.leadMinutes = minutes
            return config
        }
        tellAppToReload()
        print("lead time: \(Int(minutes)) min")
    case "--enable", "--disable":
        let enabled = argument == "--enable"
        config = ConfigStore.mutate { config -> GuardConfig in
            config.enabled = enabled
            return config
        }
        tellAppToReload()
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
    tellAppToReload()
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
    tellAppToReload()
    Log.write("forgot \"\(disk.name)\" - by hand, from the command line")
    print("forgotten: \(disk.name) - listed again when it is plugged in")

case "unhide":
    let restored = ConfigStore.mutate { config -> Int in
        let count = config.dismissedDiskIDs.count
        config.dismissedDiskIDs = []
        return count
    }
    tellAppToReload()
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
    tellAppToReload()
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
        tellAppToReload()
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
    // A real pass next to the app's own would be two schedulers acting on one
    // disk. A dry run unmounts nothing, so it may run either way.
    if action == "run", askApp(Control.Request(command: .ping)) != nil {
        finish(.failure("Eject Guard is running and runs these passes itself. "
                        + "Use --eject-now to act now, --dry-run to see what a pass would do, "
                        + "or quit the app to run a pass from here."))
    }
    let store = EKEventStore()
    guard Meetings.requestAccess(store) else {
        FileHandle.standardError.write(
            "calendar access denied - System Settings > Privacy & Security > Calendars\n".data(using: .utf8)!)
        exit(3)
    }
    let dryRun = action == "dry-run"
    let outcome = GuardRunner.tick(store: store, dryRun: dryRun)
    var lines: [String] = []
    var errors: [String] = []
    if let meeting = outcome.meeting {
        let minutes = Int(meeting.startDate.timeIntervalSinceNow / 60)
        lines.append("meeting: \"\(meeting.title ?? "?")\" in \(minutes) min")
    } else {
        lines.append("no qualifying meeting within \(Int(config.leadMinutes)) min - nothing to do")
    }
    if !outcome.unmounted.isEmpty {
        lines.append("\(dryRun ? "would unmount" : "unmounted") until the meeting ends: \(outcome.unmounted.joined(separator: ", "))")
    }
    for name in outcome.ejected { lines.append("\(dryRun ? "would eject" : "ejected") (no volume UUID to find it again): \(name)") }
    for failure in outcome.failed { errors.append("FAILED: \(failure.name) - held by \(GuardRunner.holder(failure.detail))") }
    for name in outcome.reconnect.reconnected { lines.append("\(dryRun ? "would reconnect" : "reconnected"): \(name)") }
    for name in outcome.reconnect.failed { errors.append("FAILED to reconnect: \(name) - unplug it and plug it back in") }
    Reports.appendBackupStops(outcome, lines: &lines, errors: &errors)
    finish(Control.Response(exitCode: errors.isEmpty ? 0 : 1, lines: lines, errors: errors))

case "eject-now":
    if let answer = askApp(Control.Request(command: .ejectNow)) { finish(answer) }
    let outcome = GuardRunner.ejectGuarded(reason: .manual(), config: config, notifyOnSuccess: false)
    finish(Reports.eject(outcome))

case "pause":
    if let answer = askApp(Control.Request(command: .pause, minutes: pauseMinutes)) { finish(answer) }
    let until = Date().addingTimeInterval(TimeInterval(pauseMinutes ?? 0) * 60)
    ConfigStore.mutate { $0.pausedUntil = until }
    finish(Reports.paused(until: until))

case "resume":
    if let answer = askApp(Control.Request(command: .resume)) { finish(answer) }
    ConfigStore.mutate { $0.pausedUntil = nil }
    finish(Reports.resumed)

case "skip-next":
    if let answer = askApp(Control.Request(command: .skipNext)) { finish(answer) }
    let store = EKEventStore()
    guard Meetings.requestAccess(store) else { finish(Reports.calendarAccessDenied) }
    guard let meeting = Meetings.nextMeetingToday(store, config: config),
          let id = meeting.eventIdentifier
    else { finish(Reports.nothingToSkip) }
    ConfigStore.mutate { $0.skip(id) }
    finish(Reports.skipped(title: meeting.title, start: meeting.startDate))

case "stop-backup":
    if let answer = askApp(Control.Request(command: .stopBackup)) { finish(answer) }
    finish(Reports.stopBackup(attached: snapshot.attached, known: config.knownDisks))

default:
    if json {
        let attached = snapshot.attached
        let store = EKEventStore()
        let access = Meetings.requestAccess(store)
        let meeting = access ? Meetings.nextMeeting(store, within: 24 * 60, config: config) : nil
        let paused = config.pausedUntil.flatMap { $0 > Date() ? $0 : nil }
        print(StatusReport.json(StatusReport(
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown",
            enabled: config.enabled,
            pausedUntil: paused,
            leadMinutes: config.leadMinutes,
            appRunning: askApp(Control.Request(command: .ping)) != nil,
            disks: config.knownDisks.map { disk in
                StatusReport.Disk(
                    id: disk.id, name: disk.name,
                    guarded: config.watchedDiskIDs.contains(disk.id),
                    attached: Disks.attachedVolume(for: disk, among: attached) != nil,
                    timeMachine: disk.isTimeMachineDestination,
                    network: disk.isNetworkDestination)
            },
            pendingReconnects: config.pendingReconnects.map {
                StatusReport.Reconnect(name: $0.name, notBefore: $0.notBefore)
            },
            nextMeeting: meeting.map {
                StatusReport.Meeting(title: $0.title ?? "", start: $0.startDate, calendar: $0.calendar.title)
            },
            calendarAccess: access)))
        exit(0)
    }
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
