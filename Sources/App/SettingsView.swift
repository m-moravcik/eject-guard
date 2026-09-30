import EventKit
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable { case general, meetings, calendars, about }

    /// SwiftUI keeps this view alive between opens, so without a reset the
    /// window reopens on whichever tab was left - as VibeRes found. Every
    /// open starts on General, where the settings people change live.
    @State private var selectedTab: Tab
    private let initialTab: Tab

    /// `initialTab` exists for the preview harness, which renders each tab.
    init(initialTab: Tab = .general) {
        self.initialTab = initialTab
        _selectedTab = State(initialValue: initialTab)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            GeneralSettings()
                .tabItem { Label(Loc.t("settings.tab.general", "General"), systemImage: "gearshape") }
                .tag(Tab.general)
            MeetingSettings()
                .tabItem { Label(Loc.t("settings.tab.meetings", "Meetings"), systemImage: "person.2") }
                .tag(Tab.meetings)
            CalendarSettings()
                .tabItem { Label(Loc.t("settings.tab.calendars", "Calendars"), systemImage: "calendar") }
                .tag(Tab.calendars)
            AboutSettings()
                .tabItem { Label(Loc.t("settings.tab.about", "About"), systemImage: "info.circle") }
                .tag(Tab.about)
        }
        // VibeRes' size, so the two apps' windows match, and sized so neither
        // General nor Meetings scrolls: General used to hold both and needed
        // 782 pt. Calendars is a list and may.
        .frame(width: 470, height: 400)
        .task { selectedTab = initialTab }
    }
}

/// An explanation under a section rather than a row inside it: a row costs a
/// separator and a full row's padding, which is what made General scroll.
private struct SectionNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Design.Typography.note)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - General

/// How the app itself behaves. What counts as a meeting lives in Meetings.
private struct GeneralSettings: View {
    @Environment(GuardController.self) private var controller
    @State private var launchAtLogin = LoginItem.isEnabled

    var body: some View {
        Form {
            Section {
                Toggle(Loc.t("settings.launchAtLogin", "Launch at login"), isOn: launchAtLoginBinding)
                Picker(Loc.t("settings.pauseFor", "Pause for"), selection: pauseBinding) {
                    Text(Loc.t("settings.hours", "%d hours", 1)).tag(1.0)
                    Text(Loc.t("settings.hours", "%d hours", 4)).tag(4.0)
                    Text(Loc.t("settings.hours", "%d hours", 8)).tag(8.0)
                }
                Toggle(Loc.t("settings.ejectOnSleep", "Also eject when the Mac goes to sleep"), isOn: ejectOnSleepBinding)
            } footer: {
                SectionNote(text: Loc.t("settings.ejectOnSleepFooter", "macOS allows only a moment before sleeping, so this makes a single attempt without retries."))
            }

            Section {
                Button(Loc.t("settings.restoreHidden", "Restore hidden disks (%d)", controller.hiddenDiskCount)) {
                    controller.restoreHiddenDisks()
                }
                .disabled(controller.hiddenDiskCount == 0)
                // Only once the tour is behind the user: on a fresh install
                // they are already in it.
                if controller.config.onboardingShown {
                    Button(Loc.t("settings.replayTour", "Replay welcome tour")) {
                        controller.setOnboardingShown(false)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // The recorded intent, not the registration: if that dropped and
            // re-registering failed, the toggle should still show what the
            // user asked for rather than silently reading off.
            launchAtLogin = controller.config.launchAtLoginIntent ?? LoginItem.isEnabled
        }
    }

    private var pauseBinding: Binding<Double> {
        Binding(get: { controller.config.pauseHours },
                set: { value in controller.update { $0.pauseHours = value } })
    }

    private var ejectOnSleepBinding: Binding<Bool> {
        Binding(get: { controller.config.ejectOnSleep },
                set: { value in controller.update { $0.ejectOnSleep = value } })
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(get: { launchAtLogin }, set: { wanted in
            // The intent first: it is what the user asked for, and it has to
            // outlive a failed registration so the next launch can retry.
            controller.update { $0.launchAtLoginIntent = wanted }
            launchAtLogin = wanted
            guard LoginItem.setEnabled(wanted) else { return }
            // SMAppService applies asynchronously; give it a moment before
            // reading back what the system actually did.
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(150))
                launchAtLogin = LoginItem.isEnabled
            }
        })
    }
}

// MARK: - Meetings

/// When the guard acts, and on what.
private struct MeetingSettings: View {
    @Environment(GuardController.self) private var controller

    private let leadOptions: [Double] = [3, 5, 10, 15, 20]

    var body: some View {
        Form {
            Section {
                Picker(Loc.t("settings.eject", "Eject"), selection: leadBinding) {
                    ForEach(leadOptions, id: \.self) { minutes in
                        Text(Loc.t("settings.leadMinutes", "%d minutes before a meeting", Int(minutes))).tag(minutes)
                    }
                }
            } footer: {
                SectionNote(text: Loc.t("settings.timingFooter", "Stopping a running Time Machine backup can take up to a minute, so leave a few minutes of room."))
            }

            Section {
                Picker(Loc.t("settings.treatAsMeeting", "Treat as a meeting"), selection: attendeesBinding) {
                    Text(Loc.t("settings.withAttendees", "Events with other attendees")).tag(2)
                    Text(Loc.t("settings.anyTimedEvent", "Any event with a time")).tag(1)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                SectionNote(text: Loc.t("settings.whatCountsFooter", "Attendees are what separate a real meeting from blocks like Focus or Home-office, without matching on titles."))
            }

            Section {
                Toggle(Loc.t("settings.ignoreFree", "Ignore events marked as Free"), isOn: ignoreFreeBinding)
            }
        }
        .formStyle(.grouped)
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

    private let repository = "https://github.com/m-moravcik/eject-guard"

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
            // The app's own icon, as Finder and the Dock show it: on macOS 26
            // the system renders it from Assets.car, glass included. At the
            // size the standard About panel uses.
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                // The name right below says the same thing.
                .accessibilityHidden(true)
                .padding(.top, Design.Spacing.l)

            VStack(spacing: Design.Spacing.s) {
                // A name, not a sentence: it reads the same in every language.
                Text(verbatim: "Eject Guard")
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
                    // What "automatically" commits to, in VibeRes' words: the
                    // download happens on its own, the restart never does.
                    Text(Loc.t("about.checkAutomaticallyFooter", "Downloads updates in the background and offers to restart when one is ready. Eject Guard never restarts on its own."))
                        .font(Design.Typography.note)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Design.Spacing.l)
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
