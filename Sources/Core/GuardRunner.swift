// Putting it together: scan, decide, eject, say what happened.

import EventKit
import Foundation

enum GuardRunner {
    /// Why an eject is happening, in the two registers it has to be said in.
    ///
    /// The log is English and stays English: it gets grepped and pasted into
    /// issues. The notification is what the user reads, so it is translated.
    /// Keeping them in one value is what stops the two drifting apart.
    struct Reason {
        /// English, for the log.
        let logLine: String
        /// Translated, for the notification body.
        let spoken: String

        static func menu() -> Reason {
            Reason(logLine: "ejected from the menu",
                   spoken: Loc.t("notify.reason.menu", "Ejected from the menu"))
        }

        static func manual() -> Reason {
            Reason(logLine: "manual eject",
                   spoken: Loc.t("notify.reason.manual", "Ejected on request"))
        }

        static func sleep() -> Reason {
            Reason(logLine: "Mac going to sleep",
                   spoken: Loc.t("notify.reason.sleep", "The Mac is going to sleep"))
        }

        static func meeting(title: String, minutesAhead: Int) -> Reason {
            Reason(logLine: "\(title) in \(minutesAhead) min",
                   spoken: Loc.t("notify.reason.meeting", "%1$@ in %2$d min", title, minutesAhead))
        }
    }

    struct Outcome {
        var meeting: EKEvent?
        var ejected: [String] = []
        /// Left attached, with a reconnect waiting for them after the meeting.
        var unmounted: [String] = []
        var failed: [(name: String, detail: String)] = []
        /// Network destinations whose running backup was stopped, or could not be.
        var stoppedBackups: [String] = []
        var unstoppedBackups: [String] = []
        var reconnect = ReconnectOutcome()

        var didNothing: Bool {
            takenOff.isEmpty && failed.isEmpty && stoppedBackups.isEmpty && unstoppedBackups.isEmpty
        }

        var takenOff: [String] { unmounted + ejected }

        /// Only when no disk of this pass was ejected for good may the user be
        /// told the disks come back on their own.
        var allReconnect: Bool { !unmounted.isEmpty && ejected.isEmpty }

        mutating func record(_ stop: Ejector.BackupStop?) {
            guard let stop else { return }
            if stop.succeeded { stoppedBackups.append(stop.name) } else { unstoppedBackups.append(stop.name) }
        }
    }

    /// One full pass: scan, decide, eject. Used by the command line tool and by
    /// the app's timer. Spawns processes, so never call it on the main thread.
    @discardableResult
    static func tick(store: EKEventStore, dryRun: Bool = false) -> Outcome {
        let config = ConfigStore.mutate { config -> GuardConfig in
            Disks.refreshKnownDisks(in: &config)
            return config
        }

        var outcome = Outcome()
        // Before the guard check: a disk unmounted for a meeting is put back
        // even if guarding was switched off since.
        outcome.reconnect = reconnectDue(busyUntil: Meetings.busyUntil(store, config: config), dryRun: dryRun)
        guard config.isActive else { return outcome }

        // Nothing guarded is plugged in, so do not touch the calendar at all.
        let targets = guardedAttachedVolumes(config)
        let networkTargets = Disks.guardedNetworkDestinations(config)
        guard !targets.isEmpty || !networkTargets.isEmpty else { return outcome }

        guard let meeting = Meetings.nextMeeting(
            store, within: config.leadMinutes, config: config) else { return outcome }
        outcome.meeting = meeting

        let minutesAhead = Int((meeting.startDate.timeIntervalSince(Date()) / 60).rounded())
        let title = meeting.title ?? "Meeting"

        for group in Ejector.groups(targets) {
            takeOff(group, because: "trigger: \"\(title)\" in \(minutesAhead) min", config: config,
                    reconnectAfter: meeting.endDate, dryRun: dryRun, into: &outcome)
        }
        for destination in networkTargets {
            outcome.record(Ejector.stopBackup(to: destination, dryRun: dryRun))
        }

        announce(outcome, meetingTitle: title, minutesAhead: minutesAhead)
        return outcome
    }

    /// Take the guarded volumes of one disk off. With `reconnectAfter` they
    /// are unmounted and mounted again after that moment, but only when every
    /// one has a volume UUID to find it by while it is not mounted. Otherwise
    /// the disk is ejected, as before reconnecting existed: unmounted, a
    /// volume without one would never come back.
    private static func takeOff(_ group: Ejector.Group, because logLine: String, config: GuardConfig,
                                reconnectAfter: Date?, dryRun: Bool = false, into outcome: inout Outcome) {
        let findable = group.volumes.allSatisfy { $0.volumeUUID.map(Reconnector.isVolumeUUID) == true }
        let reconnect = findable ? reconnectAfter : nil
        let mode: Ejector.Mode = reconnect == nil ? .eject : .unmount
        let volumes = group.volumes.map { "\($0.name) (\($0.path))" }.joined(separator: ", ")
        Log.write("\(logLine) -> \(mode == .eject ? "ejecting" : "unmounting") \(volumes)")
        for result in Ejector.eject(group, config: config, mode: mode, dryRun: dryRun) {
            guard result.succeeded else {
                outcome.failed.append((result.volume.name, result.detail))
                continue
            }
            guard let reconnect, let uuid = result.volume.volumeUUID else {
                outcome.ejected.append(result.volume.name)
                continue
            }
            outcome.unmounted.append(result.volume.name)
            if !dryRun { scheduleReconnect(result, uuid: uuid, after: reconnect) }
        }
    }

    /// Remember to mount the disk again after the meeting.
    private static func scheduleReconnect(_ result: Ejector.Result, uuid: String, after date: Date) {
        let entry = PendingReconnect(volumeUUID: uuid, name: result.volume.name, notBefore: date,
                                     tmDestinationID: result.volume.tmDestinationID,
                                     stoppedBackup: result.stoppedBackup)
        ConfigStore.mutate { config in
            config.pendingReconnects.removeAll { $0.volumeUUID == uuid }
            config.pendingReconnects.append(entry)
        }
        Log.write("will reconnect \(result.volume.name) after \(date) if it is still plugged in")
    }

    /// Guarded disks that are plugged in right now. Scans, so it must not run
    /// on the main thread.
    static func guardedAttachedVolumes(_ config: GuardConfig) -> [AttachedVolume] {
        Disks.guardedVolumes(config, among: Disks.scan().attached)
    }

    /// Eject every guarded disk, and stop a backup running to a guarded
    /// network destination, without consulting the calendar. Used by the
    /// "eject now" menu item and by the optional eject-on-sleep hook.
    ///
    /// With `reconnectAfter`, disks with a volume UUID are unmounted rather
    /// than ejected and mounted again after that moment if they are still
    /// plugged in.
    @discardableResult
    static func ejectGuarded(reason: Reason, config: GuardConfig, notifyOnSuccess: Bool = true,
                             reconnectAfter: Date? = nil) -> Outcome {
        var outcome = Outcome()
        if reconnectAfter == nil {
            // Ejecting on request or on sleep says the user is leaving. A disk
            // still waiting from a meeting must stay down: on a real USB disk
            // the device can outlive an eject, so it would otherwise be found
            // "still plugged in" and mounted again.
            ConfigStore.mutate { $0.pendingReconnects.removeAll() }
        }
        for group in Ejector.groups(guardedAttachedVolumes(config)) {
            takeOff(group, because: reason.logLine, config: config, reconnectAfter: reconnectAfter, into: &outcome)
        }
        for destination in Disks.guardedNetworkDestinations(config) {
            outcome.record(Ejector.stopBackup(to: destination))
        }
        if notifyOnSuccess && !outcome.takenOff.isEmpty {
            Notify.post(title: ejectedTitle(outcome.takenOff),
                        body: safeToUnplug(reason, reconnects: outcome.allReconnect))
        }
        for failure in outcome.failed {
            Notify.post(title: failedTitle(failure.name),
                        body: heldBy(failure.detail))
        }
        announceBackups(outcome, reason: reason, notifyOnSuccess: notifyOnSuccess)
        return outcome
    }

    /// A stopped backup is said when an eject would be. A failed stop is
    /// always said: the user is about to walk off the network.
    private static func announceBackups(_ outcome: Outcome, reason: Reason, notifyOnSuccess: Bool) {
        if notifyOnSuccess && !outcome.stoppedBackups.isEmpty {
            Notify.post(title: Loc.t("notify.backupStopped", "Backup to %@ stopped",
                                     outcome.stoppedBackups.joined(separator: ", ")),
                        body: Loc.t("notify.backupStoppedDetail",
                                    "%@. Time Machine carries on at its next backup.", reason.spoken))
        }
        for name in outcome.unstoppedBackups {
            Notify.post(title: Loc.t("notify.couldNotStopBackup", "Could not stop the backup to %@", name),
                        body: Loc.t("notify.stayOnNetwork", "Stay on this network until it finishes."))
        }
    }

    static func announce(_ outcome: Outcome, meetingTitle: String, minutesAhead: Int) {
        if !outcome.takenOff.isEmpty {
            let reason = Reason.meeting(title: meetingTitle, minutesAhead: minutesAhead)
            Notify.post(title: ejectedTitle(outcome.takenOff),
                        body: safeToUnplug(reason, reconnects: outcome.allReconnect))
        }
        for failure in outcome.failed {
            Notify.post(title: failedTitle(failure.name),
                        body: Loc.t("notify.doNotUnplug", "%@ Do not unplug it.", heldBy(failure.detail)))
        }
        announceBackups(outcome, reason: .meeting(title: meetingTitle, minutesAhead: minutesAhead),
                        notifyOnSuccess: true)
    }

    // MARK: - Reconnecting

    struct ReconnectOutcome {
        var reconnected: [String] = []
        var failed: [String] = []
    }

    /// Mount again the disks whose meeting is over. `busyUntil` is when the
    /// meetings running now or about to start end; entries due before then
    /// wait for it. Spawns processes, so never call it on the main thread.
    @discardableResult
    static func reconnectDue(busyUntil: Date?, now: Date = Date(), dryRun: Bool = false) -> ReconnectOutcome {
        // Taken out of the config before anything runs, so a second pass
        // starting meanwhile cannot mount the same disk twice.
        let due = ConfigStore.mutate { config -> [PendingReconnect] in
            let (due, waiting) = Reconnector.plan(config.pendingReconnects, now: now, busyUntil: busyUntil)
            // A dry run reports, it does not consume.
            if !dryRun { config.pendingReconnects = waiting }
            return due
        }

        var outcome = ReconnectOutcome()
        if dryRun {
            for entry in due { Log.write("dry-run: would reconnect \(entry.name)") }
            outcome.reconnected = due.map(\.name)
            return outcome
        }
        for entry in due {
            switch Reconnector.reconnect(entry) {
            case .remounted(let backupStarted):
                outcome.reconnected.append(entry.name)
                Notify.post(title: Loc.t("notify.reconnected", "%@ reconnected", entry.name),
                            body: backupStarted
                                ? Loc.t("notify.reconnectedBackup",
                                        "It stayed plugged in through the meeting. Time Machine is backing up again.")
                                : Loc.t("notify.reconnectedDetail", "It stayed plugged in through the meeting."))
            case .alreadyMounted, .unplugged:
                break
            case .failed:
                outcome.failed.append(entry.name)
                Notify.post(title: Loc.t("notify.couldNotReconnect", "Could not reconnect %@", entry.name),
                            body: Loc.t("notify.replug", "Unplug it and plug it back in."))
            }
        }
        return outcome
    }

    // MARK: - Notification wording

    private static func safeToUnplug(_ reason: Reason, reconnects: Bool) -> String {
        reconnects
            ? Loc.t("notify.safeToUnplugReconnects",
                    "%@. Safe to unplug, or leave it in and it reconnects after the meeting.", reason.spoken)
            : Loc.t("notify.safeToUnplug", "%@. Safe to unplug.", reason.spoken)
    }

    private static func ejectedTitle(_ names: [String]) -> String {
        Loc.t("notify.ejected", "%@ ejected", names.joined(separator: ", "))
    }

    private static func failedTitle(_ name: String) -> String {
        Loc.t("notify.couldNotEject", "Could not eject %@", name)
    }

    /// "Held by Finder." - or by something we could not name.
    private static func heldBy(_ detail: String) -> String {
        Loc.t("notify.heldBy", "Held by %@.", holder(detail))
    }

    /// Who holds a disk that would not eject. A timed-out lsof names no one,
    /// and the popover and the notification both say so rather than nothing.
    static func holder(_ detail: String) -> String {
        detail.isEmpty ? Loc.t("notify.unknownProcess", "an unknown process") : detail
    }
}
