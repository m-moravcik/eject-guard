// The app's side of the control socket: what a CLI request does here.
//
// Every request lands on the main actor and goes through the same methods the
// popover calls, so a `--pause` from a script and a click on Pause are the same
// change, shown the same way. See Control.swift for the channel itself.
//
// Not compiled into the preview harness, which must never open a socket in the
// user's real support folder.

import Foundation

extension GuardController {
    /// Starts listening. A failure is logged, never fatal: without the socket
    /// the CLI still works, it just acts on its own.
    func startControlServer() -> ControlServer? {
        let server = ControlServer { [weak self] request, reply in
            Task { @MainActor in
                guard let self else {
                    reply(.failure("Eject Guard is quitting"))
                    return
                }
                self.handle(request, reply: reply)
            }
        }
        do {
            try server.start()
            return server
        } catch {
            Log.write("control: could not listen on \(Control.socketURL.path): \(error)")
            return nil
        }
    }

    func handle(_ request: Control.Request, reply: @escaping @Sendable (Control.Response) -> Void) {
        switch request.command {
        case .ping:
            reply(.ok())

        case .reload:
            // reschedule() rereads the config before anything else.
            reschedule()
            reply(.ok())

        case .ejectNow:
            guard !isBusy, !isReconnecting else {
                reply(Reports.busy)
                return
            }
            reloadConfig()
            Log.write("eject now: asked from the command line")
            ejectFromCommandLine { reply(Reports.eject($0)) }

        case .pause:
            guard let minutes = request.minutes, minutes > 0 else {
                reply(Reports.badMinutes(request.minutes))
                return
            }
            pause(for: TimeInterval(minutes) * 60)
            reply(config.pausedUntil.map(Reports.paused(until:)) ?? .failure("the pause did not take"))

        case .resume:
            resume()
            reply(Reports.resumed)

        case .skipNext:
            guard calendarAccess != .denied else {
                reply(Reports.calendarAccessDenied)
                return
            }
            reschedule()
            // Today only, as the popover's Skip this meeting.
            guard let meeting = nextMeeting, Calendar.current.isDateInToday(meeting.startDate) else {
                reply(Reports.nothingToSkip)
                return
            }
            skipNextMeeting()
            reply(Reports.skipped(title: meeting.title, start: meeting.startDate))

        case .stopBackup:
            if isBackupRunning {
                answerStopBackup(reply)
            } else {
                refreshBackupStatus { [weak self] in
                    guard let self else {
                        reply(.failure("Eject Guard is quitting"))
                        return
                    }
                    self.answerStopBackup(reply)
                }
            }
        }
    }

    private func answerStopBackup(_ reply: @escaping @Sendable (Control.Response) -> Void) {
        guard isBackupRunning else {
            reply(Reports.noBackupRunning)
            return
        }
        guard !isStoppingBackup else {
            reply(Reports.stopAlreadyRequested)
            return
        }
        guard canStopBackup else {
            reply(Reports.busy)
            return
        }
        let names = backingUpNames.joined(separator: ", ")
        stopBackup { taken in reply(taken ? Reports.stopRequested(names) : Reports.stopNotTaken) }
    }
}
