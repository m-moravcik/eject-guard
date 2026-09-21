import AppKit
import EventKit
import Observation

/// Observable state behind the menu bar UI, and the scheduler that decides when
/// to eject.
///
/// Nothing here polls. The controller recomputes only when something it depends
/// on actually changes - a volume mounts, the calendar store changes, the Mac
/// wakes, or the user edits a setting - and then sleeps until a single timer
/// fires at exactly the right moment. A slow heartbeat is kept purely as a
/// backstop for a notification that never arrives.
@MainActor
@Observable
final class GuardController {
    enum CalendarAccess {
        case pending, granted, denied
    }

    private(set) var config = GuardConfig()
    private(set) var attached: [AttachedVolume] = []
    private(set) var nextMeeting: EKEvent?
    private(set) var ejectDate: Date?
    private(set) var calendarAccess: CalendarAccess = .pending
    private(set) var isBusy = false
    private(set) var lastFailure: String?

    /// Calendars offered in Settings. Read once access is granted.
    private(set) var calendars: [EKCalendar] = []

    let store = EKEventStore()
    private let work = DispatchQueue(label: "sk.moravcik.tmejectguard.work")

    private var ejectTimer: Timer?
    private var heartbeat: Timer?
    private var pendingReschedule: DispatchWorkItem?

    /// Meetings already acted on, successfully or not. Without this a failed
    /// eject would reschedule itself into the past, fire again immediately, and
    /// loop for as long as the meeting stays in the window. In memory only, so
    /// a restart is a clean slate.
    private var handledMeetings: Set<String> = []

    private func key(for meeting: EKEvent) -> String {
        meeting.eventIdentifier ?? "\(meeting.startDate.timeIntervalSince1970)"
    }

    /// How far ahead to look for the meeting we will schedule against. A full
    /// day so that in the evening the popover still names tomorrow's first
    /// meeting instead of claiming there is nothing.
    private let horizonMinutes: Double = 24 * 60
    /// Backstop cadence. Only covers a missed notification, so it can be slow.
    private let heartbeatSeconds: TimeInterval = 300

    var knownDisks: [KnownDisk] { config.knownDisks }

    var guardedVolumes: [AttachedVolume] {
        config.knownDisks
            .filter { config.watchedDiskIDs.contains($0.id) }
            .compactMap { Disks.attachedVolume(for: $0, among: attached) }
    }

    func isGuarded(_ disk: KnownDisk) -> Bool { config.watchedDiskIDs.contains(disk.id) }

    func isAttached(_ disk: KnownDisk) -> Bool {
        Disks.attachedVolume(for: disk, among: attached) != nil
    }

    // MARK: - Lifecycle

    func start() {
        reloadDisks()

        // The permission callback arrives on an arbitrary queue; the store
        // itself is only ever touched back on the main actor.
        Calendar2.requestAccess(store) { granted in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.calendarAccess = granted ? .granted : .denied
                if granted { self.calendars = self.store.calendars(for: .event) }
                self.reschedule()
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.reloadDisks()
                    self?.scheduleReschedule()
                }
            }
        }
        workspace.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
            [weak self] _ in
            // A timer that should have fired during sleep never did, so the
            // whole schedule has to be rebuilt against the current time.
            MainActor.assumeIsolated {
                self?.reloadDisks()
                self?.scheduleReschedule()
            }
        }
        workspace.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.handleSleep() }
        }

        // EventKit tells us when the local calendar store changes, which is the
        // whole reason this does not need polling. Sync bursts fire this many
        // times in a row, hence the debounce.
        NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.calendars = self.store.calendars(for: .event)
                self.scheduleReschedule(after: 2)
            }
        }

        heartbeat = Timer.scheduledTimer(withTimeInterval: heartbeatSeconds, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        heartbeat?.tolerance = 60
    }

    // MARK: - State

    /// Re-read the disk picture. Only called on mount, unmount and wake.
    private func reloadDisks() {
        Disks.invalidateDestinationCache()
        config = ConfigStore.mutate { config -> GuardConfig in
            Disks.refreshKnownDisks(in: &config)
            return config
        }
        attached = Disks.attachedVolumes()
    }

    func reloadConfig() {
        config = ConfigStore.load()
    }

    /// Apply a settings change and rebuild the schedule around it.
    func update(_ body: (inout GuardConfig) -> Void) {
        config = ConfigStore.mutate { config -> GuardConfig in
            body(&config)
            return config
        }
        reschedule()
    }

    // MARK: - Scheduling

    private func scheduleReschedule(after delay: TimeInterval = 0.4) {
        pendingReschedule?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.reschedule() }
        }
        pendingReschedule = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    /// Work out the single moment we need to wake up at, and arm one timer for
    /// it. Cheap: one calendar query, no process spawning.
    func reschedule() {
        ejectTimer?.invalidate()
        ejectTimer = nil
        nextMeeting = nil
        ejectDate = nil

        reloadConfig()
        guard calendarAccess == .granted else { return }

        // Surface the next meeting even when the guard cannot act on it, so the
        // popover explains itself instead of just looking idle.
        let meeting = Calendar2.nextMeeting(store, within: horizonMinutes, config: config)
        nextMeeting = meeting

        guard config.isActive, !guardedVolumes.isEmpty, let meeting,
              !handledMeetings.contains(key(for: meeting)) else { return }

        let fireAt = meeting.startDate.addingTimeInterval(-config.leadMinutes * 60)
        ejectDate = fireAt

        if fireAt <= Date() {
            fire()
            return
        }

        // Two seconds of slack so the pass re-validates inside its own lead
        // window rather than one tick short of it.
        let timer = Timer(fireAt: fireAt.addingTimeInterval(2), interval: 0,
                          target: self, selector: #selector(timerFired),
                          userInfo: nil, repeats: false)
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        ejectTimer = timer
    }

    @objc private func timerFired() { fire() }

    /// Decide here, on the main actor where the event store lives, then hand
    /// only the ejecting to a background queue. Ejecting can block for well over
    /// a minute while a volume is busy, and it needs no EventKit at all.
    private func fire() {
        guard !isBusy else { return }
        reloadConfig()

        // Re-validate rather than trusting the schedule: the meeting may have
        // been cancelled or declined since the timer was armed.
        guard config.isActive,
              let meeting = Calendar2.nextMeeting(
                  store, within: config.leadMinutes + 1, config: config),
              !handledMeetings.contains(key(for: meeting))
        else {
            reschedule()
            return
        }

        // Mark it before ejecting, not after: a failure must not turn into an
        // endless retry loop. The user still has "Eject now".
        handledMeetings.insert(key(for: meeting))
        let minutesAhead = Int((meeting.startDate.timeIntervalSinceNow / 60).rounded())
        let reason = "\(meeting.title ?? "Meeting") in \(minutesAhead) min"
        runEject(reason: reason, notifyOnSuccess: true)
    }

    private func runEject(reason: String, notifyOnSuccess: Bool) {
        let config = self.config
        guard !GuardRunner.guardedAttachedVolumes(config).isEmpty else { return }
        isBusy = true
        work.async { [weak self] in
            let outcome = GuardRunner.ejectGuarded(
                reason: reason, config: config, notifyOnSuccess: notifyOnSuccess)
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastFailure = outcome.failed.first.map { "\($0.name): held by \($0.detail)" }
                self.reloadDisks()
                self.reschedule()
            }
        }
    }

    // MARK: - Actions

    func toggleGuard(_ disk: KnownDisk) {
        update { config in
            if let index = config.watchedDiskIDs.firstIndex(of: disk.id) {
                config.watchedDiskIDs.remove(at: index)
            } else {
                config.watchedDiskIDs.append(disk.id)
            }
        }
    }

    func forget(_ disk: KnownDisk) {
        update { config in
            config.watchedDiskIDs.removeAll { $0 == disk.id }
            config.knownDisks.removeAll { $0.id == disk.id }
        }
    }

    var watchingAllCalendars: Bool { config.watchAllCalendars }

    func isWatched(_ calendar: EKCalendar) -> Bool {
        config.watchAllCalendars || config.watchedCalendarIDs.contains(calendar.calendarIdentifier)
    }

    func setWatchAllCalendars(_ all: Bool) {
        let everyID = calendars.map(\.calendarIdentifier)
        update { config in
            config.watchAllCalendars = all
            // Turning "all" off starts from everything ticked, so the next
            // click is an exclusion rather than a blank slate.
            config.watchedCalendarIDs = all ? [] : everyID
        }
    }

    func setWatched(_ calendar: EKCalendar, _ watched: Bool) {
        let everyID = calendars.map(\.calendarIdentifier)
        update { config in
            if config.watchAllCalendars {
                config.watchAllCalendars = false
                config.watchedCalendarIDs = everyID
            }
            if watched {
                if !config.watchedCalendarIDs.contains(calendar.calendarIdentifier) {
                    config.watchedCalendarIDs.append(calendar.calendarIdentifier)
                }
            } else {
                config.watchedCalendarIDs.removeAll { $0 == calendar.calendarIdentifier }
            }
            // Everything ticked is the same thing as "all", so collapse back
            // and keep the master toggle honest.
            if Set(config.watchedCalendarIDs) == Set(everyID) {
                config.watchAllCalendars = true
                config.watchedCalendarIDs = []
            }
        }
    }

    func skipNextMeeting() {
        guard let id = nextMeeting?.eventIdentifier else { return }
        update { config in
            config.skippedEventIDs.append(id)
            // Bounded: these are never removed otherwise, and stale identifiers
            // cost nothing but keep the file growing.
            if config.skippedEventIDs.count > 50 {
                config.skippedEventIDs.removeFirst(config.skippedEventIDs.count - 50)
            }
        }
    }

    func pause(for seconds: TimeInterval) {
        update { $0.pausedUntil = Date().addingTimeInterval(seconds) }
    }

    func resume() {
        update { $0.pausedUntil = nil }
    }

    func ejectNow() {
        guard !isBusy else { return }
        reloadConfig()
        runEject(reason: "Ejected from the menu", notifyOnSuccess: false)
    }

    /// macOS waits only briefly for sleep observers, so this makes a single
    /// attempt and never retries.
    private func handleSleep() {
        var config = ConfigStore.load()
        guard config.ejectOnSleep, config.isActive else { return }
        config.ejectAttempts = 1
        GuardRunner.ejectGuarded(reason: "Mac going to sleep", config: config)
    }

    func openCalendarSettings() {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Formatting

enum Format {
    static func relative(_ date: Date) -> String {
        let minutes = Int((date.timeIntervalSinceNow / 60).rounded())
        if minutes <= 0 { return "now" }
        if minutes < 60 { return "in \(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0 ? "in \(hours) h" : "in \(hours) h \(rest) min"
    }

    static func clock(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
