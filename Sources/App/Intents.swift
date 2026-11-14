// Shortcuts actions.
//
// VISION.md: users who want other triggers wire them up themselves, and the
// app owns none of them. These actions are the Shortcuts end of that, next to
// the command line tool: a Focus mode, a time of day or a Stream Deck button
// can run them, and the app decides nothing new.
//
// Each action goes through `GuardController.handle`, the same path a CLI
// request takes over the control socket, so the popover shows the change and
// only one pass ever runs. A failure is thrown, so Shortcuts stops the
// shortcut and shows why; success returns the same line the CLI prints, for a
// shortcut that wants to show or log it.
//
// build.sh compiles these with const values and runs appintentsmetadataprocessor,
// which writes the Metadata.appintents Shortcuts reads; without it the actions
// would compile and never appear.

import AppIntents
import Foundation

/// Why an action did not do what it was asked.
struct GuardIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

@MainActor
private func runGuardRequest(_ request: Control.Request) async throws -> String {
    guard let controller = GuardController.shared else {
        throw GuardIntentError(message: "Eject Guard is not ready yet")
    }
    let response = await withCheckedContinuation { continuation in
        controller.handle(request) { continuation.resume(returning: $0) }
    }
    guard response.exitCode == 0 else {
        throw GuardIntentError(message: (response.errors + response.lines).joined(separator: "\n"))
    }
    return response.lines.joined(separator: "\n")
}

struct EjectNowIntent: AppIntent {
    static let title = LocalizedStringResource("intent.ejectNow.title", defaultValue: "Eject Guarded Disks")
    static let description = IntentDescription(
        LocalizedStringResource("intent.ejectNow.description",
                                defaultValue: "Stops a backup to a guarded disk and ejects every guarded disk, as ⌘E does."))

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await runGuardRequest(Control.Request(command: .ejectNow)))
    }
}

struct PauseGuardIntent: AppIntent {
    static let title = LocalizedStringResource("intent.pause.title", defaultValue: "Pause Eject Guard")
    static let description = IntentDescription(
        LocalizedStringResource("intent.pause.description",
                                defaultValue: "Leaves your disks alone before meetings for a while."))

    @Parameter(title: LocalizedStringResource("intent.pause.minutes", defaultValue: "Minutes"),
               default: 60, inclusiveRange: (1, 1440))
    var minutes: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Pause Eject Guard for \(\.$minutes) minutes")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await runGuardRequest(Control.Request(command: .pause, minutes: minutes)))
    }
}

struct ResumeGuardIntent: AppIntent {
    static let title = LocalizedStringResource("intent.resume.title", defaultValue: "Resume Eject Guard")
    static let description = IntentDescription(
        LocalizedStringResource("intent.resume.description", defaultValue: "Ends a pause."))

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await runGuardRequest(Control.Request(command: .resume)))
    }
}

struct SkipNextMeetingIntent: AppIntent {
    static let title = LocalizedStringResource("intent.skipNext.title", defaultValue: "Skip Next Meeting")
    static let description = IntentDescription(
        LocalizedStringResource("intent.skipNext.description",
                                defaultValue: "Leaves your disks alone for today's next meeting."))

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await runGuardRequest(Control.Request(command: .skipNext)))
    }
}

struct StopBackupIntent: AppIntent {
    static let title = LocalizedStringResource("intent.stopBackup.title", defaultValue: "Stop Time Machine Backup")
    static let description = IntentDescription(
        LocalizedStringResource("intent.stopBackup.description",
                                defaultValue: "Stops the running Time Machine backup, whichever disk it writes to."))

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        .result(value: try await runGuardRequest(Control.Request(command: .stopBackup)))
    }
}

/// The actions Shortcuts and Spotlight offer without any setup.
struct EjectGuardShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: EjectNowIntent(),
                    phrases: ["Eject guarded disks with \(.applicationName)", "\(.applicationName) eject now"],
                    shortTitle: LocalizedStringResource("intent.ejectNow.short", defaultValue: "Eject Now"),
                    systemImageName: "eject")
        AppShortcut(intent: PauseGuardIntent(),
                    phrases: ["Pause \(.applicationName)"],
                    shortTitle: LocalizedStringResource("intent.pause.short", defaultValue: "Pause"),
                    systemImageName: "pause.circle")
        AppShortcut(intent: ResumeGuardIntent(),
                    phrases: ["Resume \(.applicationName)"],
                    shortTitle: LocalizedStringResource("intent.resume.short", defaultValue: "Resume"),
                    systemImageName: "play.circle")
        AppShortcut(intent: SkipNextMeetingIntent(),
                    phrases: ["Skip the next meeting in \(.applicationName)"],
                    shortTitle: LocalizedStringResource("intent.skipNext.short", defaultValue: "Skip Next Meeting"),
                    systemImageName: "forward")
    }
}
