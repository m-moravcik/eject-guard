import EventKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label(Loc.t("settings.tab.general", "General"), systemImage: "gearshape") }
            CalendarSettings()
                .tabItem { Label(Loc.t("settings.tab.calendars", "Calendars"), systemImage: "calendar") }
            AboutSettings()
                .tabItem { Label(Loc.t("settings.tab.about", "About"), systemImage: "info.circle") }
        }
        .frame(width: 440)
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @Environment(GuardController.self) private var controller
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private let leadOptions: [Double] = [3, 5, 10, 15, 20]

    var body: some View {
        Form {
            Section {
                Picker(Loc.t("settings.eject", "Eject"), selection: leadBinding) {
                    ForEach(leadOptions, id: \.self) { minutes in
                        Text(Loc.t("settings.leadMinutes", "%d minutes before a meeting", Int(minutes))).tag(minutes)
                    }
                }
                Text(Loc.t("settings.timingFooter", "Stopping a running Time Machine backup takes around ten seconds, so leave a few minutes of room."))
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
            } header: {
                Text(Loc.t("settings.section.timing", "Timing"))
            }

            Section {
                Picker(Loc.t("settings.treatAsMeeting", "Treat as a meeting"), selection: attendeesBinding) {
                    Text(Loc.t("settings.withAttendees", "Events with other attendees")).tag(2)
                    Text(Loc.t("settings.anyTimedEvent", "Any event with a time")).tag(1)
                }
                .pickerStyle(.radioGroup)

                Text(Loc.t("settings.whatCountsFooter", "Attendees are what separate a real meeting from blocks like Focus or Home-office, without matching on titles."))
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)

                Toggle(Loc.t("settings.ignoreFree", "Ignore events marked as Free"), isOn: ignoreFreeBinding)
            } header: {
                Text(Loc.t("settings.section.whatCounts", "What counts"))
            }

            Section {
                Toggle(Loc.t("settings.ejectOnSleep", "Also eject when the Mac goes to sleep"), isOn: ejectOnSleepBinding)
                Text(Loc.t("settings.ejectOnSleepFooter", "macOS allows only a moment before sleeping, so this makes a single attempt without retries."))
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)

                Picker(Loc.t("settings.pauseFor", "Pause for"), selection: pauseBinding) {
                    Text(Loc.t("settings.hours", "%d hours", 1)).tag(1.0)
                    Text(Loc.t("settings.hours", "%d hours", 4)).tag(4.0)
                    Text(Loc.t("settings.hours", "%d hours", 8)).tag(8.0)
                }

                Toggle(Loc.t("settings.launchAtLogin", "Launch at login"), isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in
                        setLoginItem(wanted)
                    }
            } header: {
                Text(Loc.t("settings.section.behaviour", "Behaviour"))
            }

            Section {
                Button(Loc.t("about.openLog", "Open log")) { NSWorkspace.shared.open(Log.url) }
                Button(Loc.t("settings.restoreHidden", "Restore hidden disks (%d)", controller.hiddenDiskCount)) {
                    controller.restoreHiddenDisks()
                }
                .disabled(controller.hiddenDiskCount == 0)
            }
        }
        .formStyle(.grouped)
        .onAppear { launchAtLogin = SMAppService.mainApp.status == .enabled }
    }

    private var leadBinding: Binding<Double> {
        Binding(get: { controller.config.leadMinutes },
                set: { value in controller.update { $0.leadMinutes = value } })
    }

    private var attendeesBinding: Binding<Int> {
        Binding(get: { controller.config.minAttendees >= 2 ? 2 : 1 },
                set: { value in controller.update { $0.minAttendees = value } })
    }

    private var ignoreFreeBinding: Binding<Bool> {
        Binding(get: { controller.config.ignoreFreeEvents },
                set: { value in controller.update { $0.ignoreFreeEvents = value } })
    }

    private var pauseBinding: Binding<Double> {
        Binding(get: { controller.config.pauseHours },
                set: { value in controller.update { $0.pauseHours = value } })
    }

    private var ejectOnSleepBinding: Binding<Bool> {
        Binding(get: { controller.config.ejectOnSleep },
                set: { value in controller.update { $0.ejectOnSleep = value } })
    }

    private func setLoginItem(_ wanted: Bool) {
        do {
            if wanted {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            Log.write("login item toggle failed: \(error.localizedDescription)")
        }
        // Report what the system actually did, not what was asked for.
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

// MARK: - Calendars

private struct CalendarSettings: View {
    @Environment(GuardController.self) private var controller

    private var grouped: [(source: String, calendars: [EKCalendar])] {
        Dictionary(grouping: controller.calendars, by: { $0.source.title })
            .map { (source: $0.key, calendars: $0.value.sorted { $0.title < $1.title }) }
            .sorted { $0.source < $1.source }
    }

    private var watchingAll: Bool { controller.watchingAllCalendars }

    var body: some View {
        Form {
            Section {
                Toggle(Loc.t("settings.watchAllCalendars", "Watch all calendars"), isOn: Binding(
                    get: { watchingAll },
                    set: { controller.setWatchAllCalendars($0) }))
                Text(watchingAll
                     ? Loc.t("settings.everyCalendarCounts", "Every calendar counts. Untick one below to narrow it down.")
                     : Loc.t("settings.tickedCalendarsCount", "Only the ticked calendars count."))
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
            }

            ForEach(grouped, id: \.source) { group in
                Section(group.source) {
                    ForEach(group.calendars, id: \.calendarIdentifier) { calendar in
                        Toggle(isOn: Binding(
                            get: { controller.isWatched(calendar) },
                            set: { controller.setWatched(calendar, $0) }
                        )) {
                            HStack(spacing: Design.Spacing.m) {
                                Circle()
                                    .fill(Color(nsColor: calendar.color ?? .secondaryLabelColor))
                                    .frame(width: 9, height: 9)
                                Text(calendar.title)
                            }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - About

private struct AboutSettings: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        guard let short else { return Loc.t("about.developmentBuild", "development build") }
        return build.map { Loc.t("about.versionBuild", "Version %@ (%@)", short, $0) }
            ?? Loc.t("about.version", "Version %@", short)
    }

    private let repository = "https://github.com/m-moravcik/tm-eject-guard"

    @Environment(\.updater) private var updater

    /// Phrased for the user. The gate returns a case rather than a sentence
    /// because Core is compiled into the bundle-less CLI, which has no
    /// translations to resolve.
    private var updatesOffReason: String {
        // Deliberately one wording for both cases: to a user they are both
        // "this copy is not a real install", and separating them would only
        // invite guessing at the difference.
        Loc.t("about.updatesUnavailable", "This build cannot update itself.")
    }

    var body: some View {
        VStack(spacing: Design.Spacing.l) {
            Image(systemName: "externaldrive.badge.checkmark")
                .font(.system(size: 44))
                .foregroundStyle(Color.accentColor)
                .padding(.top, Design.Spacing.l)

            VStack(spacing: Design.Spacing.s) {
                Text("TM Eject Guard")
                    .font(.system(size: 16, weight: .semibold))
                Text(version)
                    .font(Design.Typography.cardSubtitle)
                    .foregroundStyle(.secondary)
            }

            Text(Loc.t("about.description", "Ejects your external disks a few minutes before a meeting starts, so a spinning drive is never unplugged while it is still mounted."))
                .font(Design.Typography.row)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Design.Spacing.l)

            if let updater, updater.isAvailable {
                VStack(spacing: Design.Spacing.s) {
                    Button(Loc.t("about.checkForUpdates", "Check for Updates…")) { updater.checkForUpdates() }
                    Toggle(Loc.t("about.checkAutomatically", "Check automatically"), isOn: Binding(
                        get: { updater.automaticallyChecksForUpdates },
                        set: { updater.automaticallyChecksForUpdates = $0 }
                    ))
                    .toggleStyle(.checkbox)
                    .font(Design.Typography.note)
                }
            } else {
                Text(updatesOffReason)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: Design.Spacing.m) {
                Button(Loc.t("about.sourceCode", "Source code")) {
                    if let url = URL(string: repository) { NSWorkspace.shared.open(url) }
                }
                Button(Loc.t("about.openLog", "Open log")) { NSWorkspace.shared.open(Log.url) }
                Button(Loc.t("about.showConfig", "Show config")) {
                    NSWorkspace.shared.activateFileViewerSelecting([ConfigStore.url])
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.bottom, Design.Spacing.l)
    }
}
