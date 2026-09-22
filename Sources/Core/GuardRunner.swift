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
        var failed: [(name: String, detail: String)] = []
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
        guard config.isActive else { return outcome }

        // Nothing guarded is plugged in, so do not touch the calendar at all.
        let targets = guardedAttachedVolumes(config)
        guard !targets.isEmpty else { return outcome }

        guard let meeting = Meetings.nextMeeting(
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

    /// Guarded disks that are plugged in right now. Scans, so it must not run
    /// on the main thread.
    static func guardedAttachedVolumes(_ config: GuardConfig) -> [AttachedVolume] {
        Disks.guardedVolumes(config, among: Disks.scan().attached)
    }

    /// Eject every guarded disk without consulting the calendar. Used by the
    /// "eject now" menu item and by the optional eject-on-sleep hook.
    @discardableResult
    static func ejectGuarded(reason: Reason, config: GuardConfig, notifyOnSuccess: Bool = true) -> Outcome {
        var outcome = Outcome()
        for volume in guardedAttachedVolumes(config) {
            Log.write("\(reason.logLine) -> ejecting \(volume.name) (\(volume.path))")
            let result = Ejector.eject(volume, config: config)
            if result.succeeded {
                outcome.ejected.append(volume.name)
            } else {
                outcome.failed.append((volume.name, result.detail))
            }
        }
        if notifyOnSuccess && !outcome.ejected.isEmpty {
            Notify.post(title: ejectedTitle(outcome.ejected),
                        body: Loc.t("notify.safeToUnplug", "%@. Safe to unplug.", reason.spoken))
        }
        for failure in outcome.failed {
            Notify.post(title: failedTitle(failure.name),
                        body: heldBy(failure.detail))
        }
        return outcome
    }

    static func announce(_ outcome: Outcome, meetingTitle: String, minutesAhead: Int) {
        if !outcome.ejected.isEmpty {
            let reason = Reason.meeting(title: meetingTitle, minutesAhead: minutesAhead)
            Notify.post(title: ejectedTitle(outcome.ejected),
                        body: Loc.t("notify.safeToUnplug", "%@. Safe to unplug.", reason.spoken))
        }
        for failure in outcome.failed {
            Notify.post(title: failedTitle(failure.name),
                        body: Loc.t("notify.doNotUnplug", "%@ Do not unplug it.", heldBy(failure.detail)))
        }
    }

    // MARK: - Notification wording

    private static func ejectedTitle(_ names: [String]) -> String {
        Loc.t("notify.ejected", "%@ ejected", names.joined(separator: ", "))
    }

    private static func failedTitle(_ name: String) -> String {
        Loc.t("notify.couldNotEject", "Could not eject %@", name)
    }

    /// "Held by Finder." - or by something we could not name.
    private static func heldBy(_ detail: String) -> String {
        let who = detail.isEmpty
            ? Loc.t("notify.unknownProcess", "an unknown process")
            : detail
        return Loc.t("notify.heldBy", "Held by %@.", who)
    }
}
