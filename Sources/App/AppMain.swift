// Menu bar front end. Owns the timer that drives the guard and the UI for
// picking which disks and calendars it applies to.

import AppKit
import EventKit
import ServiceManagement

// MARK: - Small helpers

/// NSMenuItem that calls a closure, so the menu can be built inline instead of
/// scattered across a dozen @objc selectors.
final class ActionMenuItem: NSMenuItem {
    private let handler: () -> Void

    init(_ title: String, checked: Bool = false, enabled: Bool = true, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        self.target = self
        self.state = checked ? .on : .off
        self.isEnabled = enabled
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not supported") }

    @objc private func fire() { handler() }
}

extension NSMenu {
    @discardableResult
    func addInfo(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        addItem(item)
        return item
    }

    func addSubmenu(_ title: String, _ build: (NSMenu) -> Void) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: title)
        build(submenu)
        item.submenu = submenu
        addItem(item)
    }
}

func relativeMinutes(_ date: Date) -> String {
    let minutes = Int((date.timeIntervalSinceNow / 60).rounded())
    if minutes < 1 { return "o chvíľu" }
    if minutes < 60 { return "o \(minutes) min" }
    let hours = minutes / 60
    let rest = minutes % 60
    return rest == 0 ? "o \(hours) h" : "o \(hours) h \(rest) min"
}

// MARK: - App

@main
enum TMEjectGuardApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        // Accessory: menu bar only, no Dock icon and no Cmd-Tab entry.
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let store = EKEventStore()
    private let work = DispatchQueue(label: "sk.moravcik.tmejectguard.work")
    private var timer: Timer?

    private var calendarGranted = false
    private var busy = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu

        work.async { [weak self] in
            guard let self else { return }
            let granted = Calendar2.requestAccess(self.store)
            DispatchQueue.main.async {
                self.calendarGranted = granted
                self.refreshIcon()
                self.tick()
            }
        }

        // 30 s keeps a 6 min lead accurate to well within a minute while costing
        // almost nothing: with no guarded disk attached the pass never even
        // touches the calendar.
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer?.tolerance = 10

        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in self?.tick()
        }
        center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in self?.handleSleep()
        }
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshIcon()
            }
        }

        refreshIcon()
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Guard passes

    private func tick() {
        guard calendarGranted, !busy else { return }
        busy = true
        work.async { [weak self] in
            guard let self else { return }
            GuardRunner.tick(store: self.store)
            DispatchQueue.main.async {
                self.busy = false
                self.refreshIcon()
            }
        }
    }

    /// Best effort eject when the lid closes. macOS only waits a short moment
    /// for sleep observers, so this makes a single attempt and never retries.
    private func handleSleep() {
        var config = ConfigStore.load()
        guard config.ejectOnSleep, config.isActive else { return }
        config.ejectAttempts = 1
        GuardRunner.ejectGuarded(reason: "Mac ide spať", config: config)
        refreshIcon()
    }

    private func ejectNow() {
        busy = true
        refreshIcon()
        work.async { [weak self] in
            let config = ConfigStore.load()
            GuardRunner.ejectGuarded(reason: "ručné odpojenie", config: config, notifyOnSuccess: false)
            DispatchQueue.main.async {
                self?.busy = false
                self?.refreshIcon()
            }
        }
    }

    // MARK: Icon

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let config = ConfigStore.load()
        let guarded = GuardRunner.guardedAttachedVolumes(config)

        let symbol: String
        if busy {
            symbol = "externaldrive.badge.minus"
        } else if !config.isActive {
            symbol = "externaldrive.badge.xmark"
        } else if guarded.isEmpty {
            symbol = "externaldrive"
        } else {
            symbol = "externaldrive.badge.checkmark"
        }

        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "TM Eject Guard")
        image?.isTemplate = true
        button.image = image
        button.title = image == nil ? "TM" : ""
        button.toolTip = guarded.isEmpty
            ? "Žiadny sledovaný disk nie je pripojený"
            : "Stráži: \(guarded.map(\.name).joined(separator: ", "))"
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let config = ConfigStore.load()

        buildStatusSection(menu, config)
        menu.addItem(.separator())
        buildDiskSection(menu, config)
        menu.addItem(.separator())
        buildCalendarSection(menu, config)
        buildTimingSection(menu, config)
        menu.addItem(.separator())
        buildControlSection(menu, config)
        menu.addItem(.separator())
        buildFooter(menu)
    }

    private func buildStatusSection(_ menu: NSMenu, _ config: GuardConfig) {
        if !calendarGranted {
            menu.addItem(ActionMenuItem("⚠️ Chýba prístup ku Kalendáru - otvoriť nastavenia") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
            })
            return
        }

        if let until = config.pausedUntil, until > Date() {
            let clock = DateFormatter.localizedString(from: until, dateStyle: .none, timeStyle: .short)
            menu.addInfo("Pozastavené do \(clock)")
        } else if !config.enabled {
            menu.addInfo("Stráženie vypnuté")
        } else {
            let guarded = GuardRunner.guardedAttachedVolumes(config)
            menu.addInfo(guarded.isEmpty
                ? "Žiadny sledovaný disk nie je pripojený"
                : "Stráži: \(guarded.map(\.name).joined(separator: ", "))")
        }

        if let meeting = Calendar2.nextMeeting(store, within: 12 * 60, config: config) {
            menu.addInfo("Najbližší míting: \(meeting.title ?? "?") \(relativeMinutes(meeting.startDate))")
            menu.addItem(ActionMenuItem("Preskočiť tento míting") {
                guard let id = meeting.eventIdentifier else { return }
                ConfigStore.mutate { $0.skippedEventIDs.append(id) }
                self.refreshIcon()
            })
        } else {
            menu.addInfo("Najbližší míting: žiadny v najbližších 12 h")
        }
    }

    private func buildDiskSection(_ menu: NSMenu, _ config: GuardConfig) {
        menu.addSubmenu("Sledované disky") { submenu in
            if config.knownDisks.isEmpty {
                submenu.addInfo("Žiadne známe externé disky")
            }
            let attached = Disks.attachedVolumes()
            for disk in config.knownDisks {
                let isAttached = Disks.attachedVolume(for: disk, among: attached) != nil
                let suffix = isAttached ? "  ● pripojený" : ""
                let tm = disk.isTimeMachineDestination ? " (Time Machine)" : ""
                submenu.addItem(ActionMenuItem(
                    "\(disk.name)\(tm)\(suffix)",
                    checked: config.watchedDiskIDs.contains(disk.id)
                ) {
                    ConfigStore.mutate { stored in
                        if let index = stored.watchedDiskIDs.firstIndex(of: disk.id) {
                            stored.watchedDiskIDs.remove(at: index)
                        } else {
                            stored.watchedDiskIDs.append(disk.id)
                        }
                    }
                    self.refreshIcon()
                })
            }
            submenu.addItem(.separator())
            submenu.addInfo("Disky sa pridajú samé, keď ich raz pripojíš")
        }

        let guarded = GuardRunner.guardedAttachedVolumes(config)
        menu.addItem(ActionMenuItem(
            guarded.isEmpty ? "Odpojiť teraz" : "Odpojiť teraz (\(guarded.count))",
            enabled: !guarded.isEmpty && !busy
        ) { [weak self] in self?.ejectNow() })
    }

    private func buildCalendarSection(_ menu: NSMenu, _ config: GuardConfig) {
        menu.addSubmenu("Kalendáre") { submenu in
            submenu.addItem(ActionMenuItem(
                "Všetky kalendáre",
                checked: config.watchedCalendarIDs.isEmpty
            ) {
                ConfigStore.mutate { $0.watchedCalendarIDs = [] }
            })
            submenu.addItem(.separator())

            let calendars = store.calendars(for: .event)
                .sorted { ($0.source.title, $0.title) < ($1.source.title, $1.title) }
            var lastSource = ""
            for calendar in calendars {
                if calendar.source.title != lastSource {
                    lastSource = calendar.source.title
                    submenu.addInfo(lastSource)
                }
                let selected = config.watchedCalendarIDs.contains(calendar.calendarIdentifier)
                submenu.addItem(ActionMenuItem("   \(calendar.title)", checked: selected) {
                    ConfigStore.mutate { stored in
                        if let index = stored.watchedCalendarIDs.firstIndex(of: calendar.calendarIdentifier) {
                            stored.watchedCalendarIDs.remove(at: index)
                        } else {
                            stored.watchedCalendarIDs.append(calendar.calendarIdentifier)
                        }
                    }
                })
            }
        }
    }

    private func buildTimingSection(_ menu: NSMenu, _ config: GuardConfig) {
        menu.addSubmenu("Predstih") { submenu in
            for minutes in [3.0, 5.0, 6.0, 10.0, 15.0, 20.0] {
                submenu.addItem(ActionMenuItem(
                    "\(Int(minutes)) min pred mítingom",
                    checked: config.leadMinutes == minutes
                ) {
                    ConfigStore.mutate { $0.leadMinutes = minutes }
                })
            }
        }

        menu.addSubmenu("Čo je míting") { submenu in
            submenu.addItem(ActionMenuItem(
                "Len udalosti s účastníkmi (≥2)",
                checked: config.minAttendees >= 2
            ) {
                ConfigStore.mutate { $0.minAttendees = 2 }
            })
            submenu.addItem(ActionMenuItem(
                "Akákoľvek udalosť s časom",
                checked: config.minAttendees <= 1
            ) {
                ConfigStore.mutate { $0.minAttendees = 1 }
            })
            submenu.addItem(.separator())
            submenu.addItem(ActionMenuItem(
                "Ignorovať udalosti označené Voľný",
                checked: config.ignoreFreeEvents
            ) {
                ConfigStore.mutate { $0.ignoreFreeEvents.toggle() }
            })
        }
    }

    private func buildControlSection(_ menu: NSMenu, _ config: GuardConfig) {
        menu.addItem(ActionMenuItem("Stráženie zapnuté", checked: config.enabled) {
            ConfigStore.mutate { stored in
                stored.enabled.toggle()
                stored.pausedUntil = nil
            }
            self.refreshIcon()
        })

        menu.addSubmenu("Pozastaviť") { submenu in
            let options: [(String, TimeInterval)] = [
                ("na 1 hodinu", 3600), ("na 4 hodiny", 4 * 3600), ("na 8 hodín", 8 * 3600),
            ]
            for (title, seconds) in options {
                submenu.addItem(ActionMenuItem(title) {
                    ConfigStore.mutate { $0.pausedUntil = Date().addingTimeInterval(seconds) }
                    self.refreshIcon()
                })
            }
            submenu.addItem(.separator())
            submenu.addItem(ActionMenuItem(
                "Zrušiť pauzu",
                enabled: (config.pausedUntil ?? .distantPast) > Date()
            ) {
                ConfigStore.mutate { $0.pausedUntil = nil }
                self.refreshIcon()
            })
        }

        menu.addItem(ActionMenuItem(
            "Odpojiť aj pri uspaní Macu",
            checked: config.ejectOnSleep
        ) {
            ConfigStore.mutate { $0.ejectOnSleep.toggle() }
        })
    }

    private func buildFooter(_ menu: NSMenu) {
        let registered = SMAppService.mainApp.status == .enabled
        menu.addItem(ActionMenuItem("Spúšťať pri prihlásení", checked: registered) {
            do {
                if registered {
                    try SMAppService.mainApp.unregister()
                } else {
                    try SMAppService.mainApp.register()
                }
            } catch {
                Log.write("login item toggle failed: \(error.localizedDescription)")
            }
        })

        menu.addItem(ActionMenuItem("Otvoriť log") {
            NSWorkspace.shared.open(Log.url)
        })

        let quit = NSMenuItem(title: "Ukončiť", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }
}
