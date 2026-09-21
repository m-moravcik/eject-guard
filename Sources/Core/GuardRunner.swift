// Putting it together: scan, decide, eject, say what happened.

import EventKit
import Foundation

enum GuardRunner {
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
