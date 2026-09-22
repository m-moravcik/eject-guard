import AppKit
import EventKit
import Observation
import UserNotifications

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

    private(set) var backup = BackupStatus()
    /// Advances while a guarded disk is being backed up, and is what makes the
    /// menu bar icon move. A MenuBarExtra label is rendered to a static image,
    /// so SwiftUI's own symbol effects never run there - measured, not assumed.
    /// The only animation available is one we redraw ourselves.
    private(set) var backupPhase = 0

    /// nil until we have asked. False means an eject will happen silently,
    /// which is worth saying out loud since the notification is the only
    /// feedback at the moment it matters.
    private(set) var notificationsEnabled: Bool?

    /// Calendars offered in Settings. Read once access is granted.
    private(set) var calendars: [EKCalendar] = []

    let store = EKEventStore()
    private let work = DispatchQueue(label: "sk.moravcik.tmejectguard.work")

    private var ejectTimer: Timer?
    private var heartbeat: Timer?
    /// Asks Time Machine what it is doing, but only while a guarded disk is
    /// plugged in - see `updateBackupWatch`.
    private var backupTimer: Timer?
    /// Advances `backupPhase`. Pure bookkeeping, no process is spawned.
    private var breatheTimer: Timer?
    private var pendingReschedule: DispatchWorkItem?
    private var isScanning = false
    private var rescanWhenIdle = false

    /// Meetings already acted on, successfully or not. Without this a failed
    /// eject would reschedule itself into the past, fire again immediately, and
    /// loop for as long as the meeting stays in the window. In memory only, so
    /// a restart is a clean slate.
    private var handledMeetings: Set<String> = []

    private func key(for meeting: EKEvent) -> String {
        meeting.eventIdentifier ?? "\(meeting.startDate.timeIntervalSince1970)"
    }

    /// How far ahead to look for the meeting to schedule against. A full day,
    /// because at 08:55 the guard must already know about the 09:00 meeting
    /// even though it was still "tomorrow" an hour ago. What the popover shows
    /// is a separate question - see `meetingIsToday`.
    private let horizonMinutes: Double = 24 * 60
    /// Backstop cadence. Only covers a missed notification, so it can be slow.
    private let heartbeatSeconds: TimeInterval = 300
    /// While a backup runs the menu bar shows progress, so it is read often.
    /// Otherwise this is only here to notice one starting.
    private let backupPollWhileRunning: TimeInterval = 5
    private let backupPollWhileIdle: TimeInterval = 20
    /// Eight steps of a two second cycle: slow enough to read as breathing
    /// rather than blinking, cheap enough to run for the length of a backup.
    static let breatheSteps = 8
    private let breatheInterval: TimeInterval = 0.25

    var knownDisks: [KnownDisk] { config.knownDisks }

    /// Reads the last snapshot. Never scans, because this is called from view
    /// bodies on the main actor.
    var guardedVolumes: [AttachedVolume] {
        Disks.guardedVolumes(config, among: attached)
    }

    /// The scheduler looks a day ahead; the popover only reports what is still
    /// happening today. Tomorrow's first meeting is calendar noise here.
    var meetingIsToday: Bool {
        guard let meeting = nextMeeting else { return false }
        return Foundation.Calendar.current.isDateInToday(meeting.startDate)
    }

    /// The meeting most recently skipped, while it is still ahead of us. This
    /// is what makes the skip undoable instead of a one way door.
    var skippedMeeting: EKEvent? {
        guard let id = config.skippedEventIDs.last,
              let event = store.event(withIdentifier: id),
              event.startDate > Date() else { return nil }
        return event
    }

    func isGuarded(_ disk: KnownDisk) -> Bool { config.watchedDiskIDs.contains(disk.id) }

    func isBackingUp(_ disk: KnownDisk) -> Bool {
        guard let volume = Disks.attachedVolume(for: disk, among: attached) else { return false }
        return backup.isBackingUp(to: volume.path)
    }

    /// True when Time Machine is writing to a disk this app is guarding.
    var isGuardedBackupRunning: Bool {
        guardedVolumes.contains { backup.isBackingUp(to: $0.path) }
    }

    /// 0...1, or nil while Time Machine is still sizing the job up.
    var guardedBackupPercent: Double? {
        isGuardedBackupRunning ? backup.percent : nil
    }

    /// Reading this spawns `tmutil`, so that part stays off the main actor.
    ///
    /// Called both by the popover while it is open and, since the menu bar icon
    /// shows backup progress, by `backupTimer`. That timer only runs while a
    /// guarded disk is actually plugged in, which is the only time the answer
    /// can be anything but "no".
    func refreshBackupStatus() {
        work.async { [weak self] in
            let status = BackupStatus.current()
            Task { @MainActor in
                guard let self else { return }
                self.backup = status
                // Both the poll interval and the breathing depend on the
                // answer, so every answer re-evaluates them. The call is cheap:
                // it rebuilds a timer only when the interval actually changed.
                self.updateBackupWatch()
            }
        }
    }

    // MARK: - Backup watch

    /// Start, restart or stop the backup poll to match the current state.
    ///
    /// The cost of knowing is one `tmutil status` every few seconds, and only
    /// while a guarded disk is attached and guarding is on - which is exactly
    /// when a backup can be running and when the answer is worth showing. With
    /// nothing plugged in, nothing is polled at all.
    private func updateBackupWatch() {
        let wanted = config.isActive && !guardedVolumes.isEmpty
        guard wanted else {
            stopBackupWatch()
            if backup.running { backup = BackupStatus() }
            return
        }

        let interval = backup.running ? backupPollWhileRunning : backupPollWhileIdle
        if backupTimer?.timeInterval != interval {
            backupTimer?.invalidate()
            backupTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                MainActor.assumeIsolated { self.refreshBackupStatus() }
            }
            // A backup is minutes long; the poll does not need to be punctual.
            backupTimer?.tolerance = interval / 4
        }

        // The breathing only exists while there is something to breathe about.
        if isGuardedBackupRunning {
            if breatheTimer == nil {
                breatheTimer = Timer.scheduledTimer(
                    withTimeInterval: breatheInterval, repeats: true) { _ in
                    MainActor.assumeIsolated {
                        self.backupPhase = (self.backupPhase + 1) % Self.breatheSteps
                    }
                }
            }
        } else {
            breatheTimer?.invalidate()
            breatheTimer = nil
            backupPhase = 0
        }
    }

    private func stopBackupWatch() {
        backupTimer?.invalidate()
        backupTimer = nil
        breatheTimer?.invalidate()
        breatheTimer = nil
        backupPhase = 0
    }

    var hiddenDiskCount: Int { config.dismissedDiskIDs.count }

    func refreshNotificationStatus() {
        // UNUserNotificationCenter.current() traps when the executable has no
        // bundle identifier, which is exactly the preview harness.
        guard Bundle.main.bundleIdentifier != nil else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor [weak self] in self?.notificationsEnabled = allowed }
        }
    }

    func dismissFailure() { lastFailure = nil }

    func isAttached(_ disk: KnownDisk) -> Bool {
        Disks.attachedVolume(for: disk, among: attached) != nil
    }

    // MARK: - Lifecycle

    func start() {
        reloadDisks()
        refreshNotificationStatus()

        // The permission callback arrives on an arbitrary queue; the store
        // itself is only ever touched back on the main actor.
        Meetings.requestAccess(store) { granted in
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

    /// Re-read the disk picture.
    ///
    /// Scanning spawns `tmutil`, so it happens on the work queue and only the
    /// merge runs on the main actor. Doing the scan inline is what froze the app:
    /// `Process.waitUntilExit` pumps the run loop, the run loop delivered the
    /// next volume notification, and the second pass blocked on the config lock
    /// the first pass was still holding.
    private func reloadDisks() {
        guard !isScanning else {
            // A scan is already in flight and the world changed again; run one
            // more when it lands rather than queueing a pile of them.
            rescanWhenIdle = true
            return
        }
        isScanning = true
        work.async { [weak self] in
            let snapshot = Disks.scan()
            Task { @MainActor in
                guard let self else { return }
                self.isScanning = false
                self.config = ConfigStore.mutate { config -> GuardConfig in
                    Disks.merge(snapshot, into: &config)
                    return config
                }
                self.attached = snapshot.attached
                // Once the disk that failed to eject is gone, the warning is
                // stale - it must not sit in the popover for days.
                if self.guardedVolumes.isEmpty { self.lastFailure = nil }
                if self.rescanWhenIdle {
                    self.rescanWhenIdle = false
                    self.reloadDisks()
                } else {
                    self.reschedule()
                }
            }
        }
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
        // After the reload, so it reads the settings that are now in force.
        updateBackupWatch()
        guard calendarAccess == .granted else { return }

        // Surface the next meeting even when the guard cannot act on it, so the
        // popover explains itself instead of just looking idle.
        let meeting = Meetings.nextMeeting(store, within: horizonMinutes, config: config)
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
              let meeting = Meetings.nextMeeting(
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
        let reason = GuardRunner.Reason.meeting(
            title: meeting.title ?? Loc.t("meeting.untitled", "Meeting"),
            minutesAhead: minutesAhead)
        runEject(reason: reason, notifyOnSuccess: true)
    }

    private func runEject(reason: GuardRunner.Reason, notifyOnSuccess: Bool) {
        let config = self.config
        // Check against the snapshot we already have; the eject itself rescans
        // on the work queue.
        guard !guardedVolumes.isEmpty else { return }
        isBusy = true
        work.async { [weak self] in
            let outcome = GuardRunner.ejectGuarded(
                reason: reason, config: config, notifyOnSuccess: notifyOnSuccess)
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                self.lastFailure = outcome.failed.first.map {
                    Loc.t("failure.heldBy", "%1$@: held by %2$@", $0.name, $0.detail)
                }
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

    /// Hides a disk for good. Time Machine destinations are rediscovered on
    /// every pass, so remembering the dismissal is the only way to keep one
    /// that will never be plugged into this Mac out of the list.
    func hide(_ disk: KnownDisk) {
        update { config in
            config.watchedDiskIDs.removeAll { $0 == disk.id }
            config.knownDisks.removeAll { $0.id == disk.id }
            if !config.dismissedDiskIDs.contains(disk.id) {
                config.dismissedDiskIDs.append(disk.id)
            }
        }
    }

    func restoreHiddenDisks() {
        update { $0.dismissedDiskIDs = [] }
        // reloadDisks reschedules once the scan lands.
        reloadDisks()
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
        update { $0.skip(id) }
    }

    func undoLastSkip() {
        update { config in
            guard !config.skippedEventIDs.isEmpty else { return }
            config.skippedEventIDs.removeLast()
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
        runEject(reason: .menu(), notifyOnSuccess: false)
    }

    /// Best effort only.
    ///
    /// macOS gives sleep observers a short window, and stopping a running backup
    /// alone was measured at ~11 s. Blocking the main thread here would delay
    /// sleep and could still be cut off mid-eject, so the work is handed to the
    /// background queue with a single attempt and no retries. If the machine
    /// sleeps first, the log says so.
    private func handleSleep() {
        var adjusted = config
        guard adjusted.ejectOnSleep, adjusted.isActive, !guardedVolumes.isEmpty else { return }
        adjusted.ejectAttempts = 1
        // An immutable copy crosses to the other queue; a captured var would not.
        let snapshot = adjusted
        work.async {
            Log.write("sleep: attempting one eject before the Mac sleeps")
            GuardRunner.ejectGuarded(reason: .sleep(), config: snapshot)
        }
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
        if minutes < 60 { return Loc.t("relative.minutes", "in %d min", minutes) }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0
            ? Loc.t("relative.hours", "in %d h", hours)
            : Loc.t("relative.hoursMinutes", "in %1$d h %2$d min", hours, rest)
    }

    static func clock(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
