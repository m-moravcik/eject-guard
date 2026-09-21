import EventKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            CalendarSettings()
                .tabItem { Label("Calendars", systemImage: "calendar") }
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
                Picker("Eject", selection: leadBinding) {
                    ForEach(leadOptions, id: \.self) { minutes in
                        Text("\(Int(minutes)) minutes before a meeting").tag(minutes)
                    }
                }
                Text("Stopping a running Time Machine backup takes around ten seconds, so leave a few minutes of room.")
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Timing")
            }

            Section {
                Picker("Treat as a meeting", selection: attendeesBinding) {
                    Text("Events with other attendees").tag(2)
                    Text("Any event with a time").tag(1)
                }
                .pickerStyle(.radioGroup)

                Text("Attendees are what separate a real meeting from blocks like Focus or Home-office, without matching on titles.")
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)

                Toggle("Ignore events marked as Free", isOn: ignoreFreeBinding)
            } header: {
                Text("What counts")
            }

            Section {
                Toggle("Also eject when the Mac goes to sleep", isOn: ejectOnSleepBinding)
                Text("macOS allows only a moment before sleeping, so this makes a single attempt without retries.")
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)

                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, wanted in
                        setLoginItem(wanted)
                    }
            } header: {
                Text("Behaviour")
            }

            Section {
                Button("Open log") { NSWorkspace.shared.open(Log.url) }
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
                Toggle("Watch all calendars", isOn: Binding(
                    get: { watchingAll },
                    set: { controller.setWatchAllCalendars($0) }))
                Text(watchingAll
                     ? "Every calendar counts. Untick one below to narrow it down."
                     : "Only the ticked calendars count.")
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
