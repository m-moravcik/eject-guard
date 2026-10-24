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
    /// The Time Machine destinations the last scan reported.
    private(set) var reportedDestinationIDs: Set<String> = []
    private(set) var nextMeeting: EKEvent?
    private(set) var ejectDate: Date?
    private(set) var calendarAccess: CalendarAccess = .pending
    private(set) var isBusy = false
    /// Mounting a disk back, which can take a minute and a half for a locked
    /// Time Machine volume. Kept apart from `isBusy`, which the menu bar and
    /// the footer show as an eject; an eject waits for it all the same.
    private(set) var isReconnecting = false
    private(set) var lastFailure: String?

    private(set) var backup = BackupStatus() {
        didSet {
            if failedBackupRequest?.took(backup) == true { failedBackupRequest = nil }
        }
    }
    /// Advances while Time Machine is backing up, and is what makes the
    /// menu bar icon move. A MenuBarExtra label is rendered to a static image,
    /// so SwiftUI's own symbol effects never run there - measured, not assumed.
    /// The only animation available is one we redraw ourselves.
    private(set) var backupPhase = 0
    /// A stop or a start the user asked for, until Time Machine shows it took.
    private(set) var backupRequest: BackupRequest?
    /// A stop or a start that did not take, until Time Machine shows otherwise.
    /// Kept apart from `lastFailure`, which is about the eject pass.
    private(set) var failedBackupRequest: BackupRequest?

    var backupFailure: String? {
        guard let request = failedBackupRequest else { return nil }
        switch request.kind {
        case .stop:
            return Loc.t("failure.backupNotStopped", "%@: the backup could not be stopped", request.name)
        case .start:
            return Loc.t("failure.backupNotStarted", "%@: the backup could not be started", request.name)
        }
    }

    /// Plays the menu bar icon's eject animation once a guarded disk has
    /// actually come off. Runs a timer only while it plays.
    let iconAnimator = MenuBarIconAnimator()

    /// nil until we have asked. False means an eject will happen silently,
    /// which is worth saying out loud since the notification is the only
    /// feedback at the moment it matters.
    private(set) var notificationsEnabled: Bool?

    /// Calendars offered in Settings. Read once access is granted.
    private(set) var calendars: [EKCalendar] = []

    let store = EKEventStore()
    private let work = DispatchQueue(label: "sk.moravcik.tmejectguard.work")

    private var ejectTimer: Timer?
    /// Fires when the earliest disk unmounted for a meeting is due back.
    private var reconnectTimer: Timer?
    private var heartbeat: Timer?
    /// Asks Time Machine what it is doing, but only while somewhere it could
    /// be writing to is reachable - see `updateBackupWatch`.
    private var backupTimer: Timer?
    /// A status read is waiting on `work`. The queue is serial, so while a
    /// pass spends minutes retrying an unmount every poll would otherwise
    /// queue its own read, and they would all run back to back afterwards.
    private var isBackupRefreshQueued = false
    /// Advances `backupPhase`. Pure bookkeeping, no process is spawned.
    private var breatheTimer: Timer?
    private var pendingReschedule: DispatchWorkItem?
    private var isScanning = false
    private var rescanWhenIdle = false
    /// Run once a scan started after they were asked for has landed, so
    /// they see the disks as they are now, not as a scan already under way
    /// found them.
    private var afterNextScan: [@MainActor () -> Void] = []

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
    static let breatheSteps = LiftIcon.breatheSteps
    private let breatheInterval: TimeInterval = 0.25

    var knownDisks: [KnownDisk] { config.knownDisks }

    /// Reads the last snapshot. Never scans, because this is called from view
    /// bodies on the main actor.
    var guardedVolumes: [AttachedVolume] {
        Disks.guardedVolumes(config, among: attached)
    }

    /// Guarded network Time Machine destinations. Nothing to eject; the guard
    /// stops a backup running to one.
    var guardedNetworkDestinations: [KnownDisk] {
        Disks.guardedNetworkDestinations(config)
    }

    /// Anything the guard could act on right now: a guarded disk plugged in,
    /// or a guarded network destination, which is always there.
    var hasGuardedTargets: Bool {
        !guardedVolumes.isEmpty || !guardedNetworkDestinations.isEmpty
    }

    /// Guarded network destinations Time Machine is writing to right now.
    var guardedNetworkBackups: [KnownDisk] {
        guardedNetworkDestinations.filter { backup.isBackingUp(toDestination: $0.tmDestinationID) }
    }

    /// What the menu bar icon names while armed.
    var guardedTargetNames: [String] {
        guardedVolumes.map(\.name) + guardedNetworkDestinations.map(\.name)
    }

    /// What the menu bar icon names while a backup runs. Guarded or not:
    /// progress is shown for every backup. A destination the app has never
    /// seen still gets a name, since the backup is real either way.
    var backingUpNames: [String] {
        guard backup.running else { return [] }
        let names = backup.destinationNames(attached: attached, known: config.knownDisks)
        return names.isEmpty ? ["Time Machine"] : names
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

    /// The disk was unmounted for a meeting and is waiting to be mounted again.
    func pendingReconnect(for disk: KnownDisk) -> PendingReconnect? {
        guard let uuid = disk.volumeUUID else { return nil }
        return config.pendingReconnects.first { $0.volumeUUID == uuid }
    }

    func isBackingUp(_ disk: KnownDisk) -> Bool {
        if disk.isNetworkDestination { return backup.isBackingUp(toDestination: disk.tmDestinationID) }
        guard let volume = Disks.attachedVolume(for: disk, among: attached) else { return false }
        return backup.isBackingUp(to: volume)
    }

    /// True when Time Machine is writing anywhere, guarded or not.
    var isBackupRunning: Bool { backup.running }

    /// 0...1, or nil while Time Machine is still sizing the job up.
    var backupPercent: Double? {
        isBackupRunning ? backup.percent : nil
    }

    /// "Stop backup" has something to stop: any backup, guarded or not, since
    /// stopping one is the user's call. Not while an eject pass runs, which
    /// stops what it has to on its own.
    var canStopBackup: Bool {
        isBackupRunning && backupRequest == nil && !isBusy && !isReconnecting
    }

    var isStoppingBackup: Bool { backupRequest?.kind == .stop }

    /// "Back up now" is offered for `disk`: a destination Time Machine can
    /// reach right now, guarded or not.
    func offersBackUpNow(_ disk: KnownDisk) -> Bool {
        destinationToStart(disk) != nil
    }

    /// Time Machine runs one backup at a time, so only while nothing else
    /// runs or has been asked for.
    func canBackUpNow(_ disk: KnownDisk) -> Bool {
        offersBackUpNow(disk) && !isBackupRunning && backupRequest == nil && !isBusy && !isReconnecting
    }

    /// Asked to back up to `disk`, and Time Machine has not started yet.
    func isStartingBackup(_ disk: KnownDisk) -> Bool {
        guard let id = backupRequest?.startingDestinationID else { return false }
        return id == disk.tmDestinationID
    }

    private func destinationToStart(_ disk: KnownDisk) -> String? {
        BackupControl.destinationToStart(disk, attached: attached, reportedDestinationIDs: reportedDestinationIDs)
    }

    /// Reading this spawns `tmutil`, so that part stays off the main actor.
    ///
    /// Called both by the popover while it is open and, since the menu bar icon
    /// shows backup progress, by `backupTimer`. That timer only runs while a
    /// Time Machine destination is reachable, which is the only time the
    /// answer can be anything but "no".
    func refreshBackupStatus() {
        #if PREVIEW
        // Demo state is what the harness renders; a real tmutil read must
        // never overwrite it, and the harness reads nothing from this Mac.
        if PreviewDemo.isActive { return }
        #endif
        guard !isBackupRefreshQueued else { return }
        isBackupRefreshQueued = true
        work.async { [weak self] in
            let status = BackupStatus.current()
            Task { @MainActor in
                guard let self else { return }
                self.isBackupRefreshQueued = false
                self.backup = status
                self.settleBackupRequest()
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
    /// while a Time Machine destination is reachable - which is exactly when a
    /// backup can be running. Guarding has no say: progress is shown for a
    /// disk nobody ticked, and with guarding off. With no destination plugged
    /// in, nothing is polled at all. A network destination counts as attached:
    /// a backup to it can start at any time. A guarded target counts too, in
    /// case the scan that would have tied it to Time Machine timed out.
    private func updateBackupWatch() {
        let wanted = hasGuardedTargets || Disks.hasTimeMachineTarget(config, among: attached)
        guard wanted else {
            stopBackupWatch()
            if backup.running { backup = BackupStatus() }
            return
        }

        // A request waits on the answer, so it is read as often as progress.
        let interval = backup.running || backupRequest != nil ? backupPollWhileRunning : backupPollWhileIdle
        // A backup already running at launch would otherwise wait out a whole
        // idle interval before the icon shows it. The read lands back here
        // with the timer in place, so this runs once per watch.
        let starting = backupTimer == nil
        if backupTimer?.timeInterval != interval {
            backupTimer?.invalidate()
            backupTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
                MainActor.assumeIsolated { self.refreshBackupStatus() }
            }
            // A backup is minutes long; the poll does not need to be punctual.
            backupTimer?.tolerance = interval / 4
        }
        if starting { refreshBackupStatus() }

        // The breathing only exists while there is something to breathe about.
        if isBackupRunning {
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
        UNUserNotificationCenter.current().getNotificationSettings { [weak self] settings in
            let allowed = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor in self?.notificationsEnabled = allowed }
        }
    }

    func dismissFailure() {
        lastFailure = nil
        failedBackupRequest = nil
    }

    /// Ends the welcome tour, finished or skipped. Settings can clear it again.
    func setOnboardingShown(_ shown: Bool) {
        update { $0.onboardingShown = shown }
    }

    func isAttached(_ disk: KnownDisk) -> Bool {
        attachedVolume(for: disk) != nil
    }

    func attachedVolume(for disk: KnownDisk) -> AttachedVolume? {
        Disks.attachedVolume(for: disk, among: attached)
    }

    /// ⌘E has something to do: a guarded disk to eject. A backup to a
    /// guarded share is stopped on the way; on its own, "Stop backup" stops it.
    var canEjectNow: Bool {
        !isBusy && !isReconnecting && !guardedVolumes.isEmpty
    }

    // MARK: - Lifecycle

    func start() {
        reloadDisks()
        refreshNotificationStatus()

        // The permission callback arrives on an arbitrary queue; the store
        // itself is only ever touched back on the main actor.
        Meetings.requestAccess(store) { [weak self] granted in
            Task { @MainActor in
                guard let self else { return }
                self.calendarAccess = granted ? .granted : .denied
                if granted { self.calendars = self.store.calendars(for: .event) }
                self.reschedule()
            }
        }

        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                // Time Machine mounts snapshots all through a backup. None of
                // them can change the list, and every rescan spawns tmutil.
                let volume = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
                guard Disks.mayChangeDiskList(volumePath: volume?.path) else { return }
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
    private func reloadDisks(then done: (@MainActor () -> Void)? = nil) {
        if let done { afterNextScan.append(done) }
        guard !isScanning else {
            // A scan is already in flight and the world changed again; run one
            // more when it lands rather than queueing a pile of them.
            rescanWhenIdle = true
            return
        }
        isScanning = true
        let landed = afterNextScan
        afterNextScan = []
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
                self.reportedDestinationIDs = Set(snapshot.destinations.map(\.id))
                // Once the disk that failed to eject is gone, or the backup
                // that would not stop has ended, the warning is stale - it
                // must not sit in the popover for days.
                if self.guardedVolumes.isEmpty && self.guardedNetworkBackups.isEmpty {
                    self.lastFailure = nil
                }
                for done in landed { done() }
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
        // Independent of guarding and of calendar access: a disk the guard
        // unmounted is put back even if either went away since.
        scheduleReconnect()
        guard calendarAccess == .granted else { return }

        // Surface the next meeting even when the guard cannot act on it, so the
        // popover explains itself instead of just looking idle.
        let meeting = Meetings.nextMeeting(store, within: horizonMinutes, config: config)
        nextMeeting = meeting

        guard config.isActive, hasGuardedTargets, let meeting,
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

    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        guard let earliest = config.pendingReconnects.map(\.notBefore).min() else { return }
        if earliest <= Date() {
            reconnect()
            return
        }
        let timer = Timer(fireAt: earliest.addingTimeInterval(2), interval: 0,
                          target: self, selector: #selector(reconnectTimerFired),
                          userInfo: nil, repeats: false)
        timer.tolerance = 10
        RunLoop.main.add(timer, forMode: .common)
        reconnectTimer = timer
    }

    @objc private func reconnectTimerFired() { reconnect() }

    /// Read the calendar here, where the store lives, and mount on the work
    /// queue. A meeting still running pushes the reconnect to its end.
    private func reconnect() {
        guard !isBusy, !isReconnecting else { return }
        let busyUntil = calendarAccess == .granted ? Meetings.busyUntil(store, config: config) : nil
        isReconnecting = true
        work.async { [weak self] in
            let reconnected = GuardRunner.reconnectDue(busyUntil: busyUntil).reconnected.count
            Task { @MainActor in
                guard let self else { return }
                // Still reconnecting until the disk list shows the disk back:
                // otherwise the icon would drop to the empty line in between,
                // and the animation would land on a state about to change.
                self.reloadDisks {
                    self.isReconnecting = false
                    self.iconAnimator.reconnectFinished(reconnectedDisks: reconnected)
                }
            }
        }
    }

    /// Decide here, on the main actor where the event store lives, then hand
    /// only the ejecting to a background queue. Ejecting can block for well over
    /// a minute while a volume is busy, and it needs no EventKit at all.
    private func fire() {
        guard !isBusy, !isReconnecting else { return }
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
        runEject(reason: reason, notifyOnSuccess: true, reconnectAfter: meeting.endDate)
    }

    private func runEject(reason: GuardRunner.Reason, notifyOnSuccess: Bool, reconnectAfter: Date? = nil) {
        let config = self.config
        // Check against the snapshot we already have; the eject itself rescans
        // on the work queue.
        guard hasGuardedTargets else { return }
        isBusy = true
        // The pass stops a backup to a guarded disk itself; a request still
        // waiting on Time Machine would only end up reading as a failure.
        backupRequest = nil
        work.async { [weak self] in
            let outcome = GuardRunner.ejectGuarded(
                reason: reason, config: config, notifyOnSuccess: notifyOnSuccess,
                reconnectAfter: reconnectAfter)
            Task { @MainActor in
                guard let self else { return }
                self.isBusy = false
                // Only a disk that actually came off is celebrated: not a
                // failure, and not a backup to a share that was only stopped.
                // Unmounted for a meeting counts: the disk came off all the
                // same, and the icon lands on the dashed slot until it is back.
                self.iconAnimator.ejectFinished(ejectedDisks: outcome.takenOff.count)
                self.lastFailure = outcome.failed.first.map {
                    Loc.t("failure.heldBy", "%1$@: held by %2$@", $0.name, GuardRunner.holder($0.detail))
                } ?? outcome.unstoppedBackups.first.map {
                    Loc.t("failure.backupNotStopped", "%@: the backup could not be stopped", $0)
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

    func canForget(_ disk: KnownDisk) -> Bool {
        Disks.canForget(disk, attached: attached, reportedDestinationIDs: reportedDestinationIDs)
    }

    /// Forgets a disk that is not plugged in. Unlike hiding, nothing is kept:
    /// it is listed again the next time it is plugged in. The popover asks
    /// first when the disk is guarded.
    func forget(_ disk: KnownDisk) {
        guard canForget(disk) else { return }
        Log.write("forgot \"\(disk.name)\" - by hand")
        // The update reschedules, which re-arms the reconnect timer without
        // an entry this disk had.
        update { $0.forget(disk) }
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
        guard !isBusy, !isReconnecting else { return }
        reloadConfig()
        runEject(reason: .menu(), notifyOnSuccess: false)
    }

    /// Stops whatever Time Machine is writing, guarded or not. Not
    /// remembered: nothing starts it again after a meeting, and Time Machine
    /// carries on at its next backup.
    func stopBackup() {
        guard canStopBackup else { return }
        let request = BackupRequest(kind: .stop, name: backingUpNames.joined(separator: ", "),
                                    deadline: Date().addingTimeInterval(BackupControl.stopBudget))
        send(request) { BackupControl.stop() }
    }

    /// Starts a backup to `disk` now, guarded or not.
    func backUpNow(_ disk: KnownDisk) {
        guard canBackUpNow(disk), let id = destinationToStart(disk) else { return }
        let name = disk.name
        let request = BackupRequest(kind: .start(destinationID: id), name: name,
                                    deadline: Date().addingTimeInterval(BackupControl.startBudget))
        send(request) { BackupControl.start(destinationID: id, name: name) }
    }

    /// Hands the request to Time Machine on the work queue, where every
    /// process runs. Whether it took is read off the status polls that follow
    /// rather than waited out there: a stop to a share takes most of a
    /// minute, and an eject pass may need the queue in the meantime.
    private func send(_ request: BackupRequest, _ ask: @escaping @Sendable () -> Bool) {
        backupRequest = request
        failedBackupRequest = nil
        updateBackupWatch()
        work.async { [weak self] in
            let taken = ask()
            Task { @MainActor in
                guard let self, self.backupRequest == request else { return }
                if taken {
                    self.refreshBackupStatus()
                } else {
                    self.fail(request)
                }
            }
        }
    }

    private func settleBackupRequest() {
        guard let request = backupRequest else { return }
        switch request.settle(backup, now: Date()) {
        case .pending: break
        case .done: backupRequest = nil
        case .failed: fail(request)
        }
    }

    private func fail(_ request: BackupRequest) {
        backupRequest = nil
        failedBackupRequest = request
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
        guard adjusted.ejectOnSleep, adjusted.isActive, hasGuardedTargets else { return }
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

#if PREVIEW
// MARK: - Demo state

/// Invented disks and a meeting for the published screenshot, so it never shows
/// whatever is on the calendar and plugged in on the machine that renders it.
/// Compiled into the preview harness only; the app never sets it.
extension GuardController {
    /// - Parameter showingTour: render the welcome tour instead of the
    ///   popover it covers on a fresh install.
    func loadDemo(showingTour: Bool = false) {
        let timeMachine = KnownDisk(id: "demo-tm", name: "Time Machine",
                                    volumeUUID: "demo-tm-uuid", tmDestinationID: "demo-tm-dest")
        let archive = KnownDisk(id: "demo-archive", name: "Archive HDD", volumeUUID: "demo-archive-uuid")
        let portable = KnownDisk(id: "demo-t7", name: "Samsung T7", volumeUUID: "demo-t7-uuid")
        let share = KnownDisk(id: "demo-nas", name: "NAS Backup",
                              tmDestinationID: "demo-nas", network: true)

        var demo = GuardConfig()
        demo.knownDisks = [archive, share, portable, timeMachine]
        demo.watchedDiskIDs = [timeMachine.id, archive.id, share.id]
        demo.onboardingShown = !showingTour
        config = demo

        attached = [
            AttachedVolume(path: "/Volumes/Time Machine", name: timeMachine.name,
                           volumeUUID: timeMachine.volumeUUID, tmDestinationID: timeMachine.tmDestinationID,
                           connection: .usb),
            AttachedVolume(path: "/Volumes/Samsung T7", name: portable.name,
                           volumeUUID: portable.volumeUUID, connection: .thunderbolt),
        ]

        var status = BackupStatus()
        status.running = true
        status.mountPoint = "/Volumes/Time Machine"
        status.destinationID = timeMachine.tmDestinationID
        status.percent = 0.42
        backup = status

        // In the language being rendered, so a Slovak shot has no English
        // meeting in it.
        let names: [String: (meeting: String, calendar: String)] = [
            "sk": ("Porada k návrhu", "Práca"),
            "cs": ("Porada k návrhu", "Práce"),
            "de": ("Design-Review", "Arbeit"),
        ]
        let language = Bundle.main.preferredLocalizations.first ?? "en"
        let demoNames = names[language] ?? ("Design review", "Work")
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = demoNames.calendar
        let meeting = EKEvent(eventStore: store)
        meeting.title = demoNames.meeting
        meeting.calendar = calendar
        meeting.startDate = (PreviewDemo.now ?? Date()).addingTimeInterval(12 * 60)
        meeting.endDate = meeting.startDate.addingTimeInterval(45 * 60)
        nextMeeting = meeting
        ejectDate = meeting.startDate.addingTimeInterval(-demo.leadMinutes * 60)

        calendarAccess = .granted
        notificationsEnabled = true
        PreviewDemo.isActive = true
    }

    /// The demo with `count` disks, more than the list shows without
    /// scrolling once there are enough of them. `paused` adds the banner a
    /// pause shows, for measuring the popover at its tallest.
    func loadManyDisksDemo(_ count: Int, paused: Bool = false) {
        loadDemo()
        let names = ["Archive HDD", "Backup SSD", "Camera Cards", "Lacie Rugged", "Photos 2024",
                     "Samsung T7", "SanDisk Extreme", "Scratch", "Time Machine", "Video Projects",
                     "WD Elements", "Zeta"]
        var demo = config
        demo.knownDisks = (0..<count).map { index in
            let name = names[index % names.count]
            return KnownDisk(id: "demo-\(index)", name: index < names.count ? name : "\(name) \(index)",
                             volumeUUID: "demo-\(index)-uuid",
                             tmDestinationID: name == "Time Machine" ? "demo-tm-dest" : nil)
        }
        demo.watchedDiskIDs = demo.knownDisks.filter { $0.name == "Archive HDD" || $0.name == "Time Machine" }.map(\.id)
        if paused { demo.pausedUntil = Date().addingTimeInterval(3600) }
        config = demo
        attached = demo.knownDisks.filter { $0.name == "Time Machine" || $0.name == "Samsung T7" }.map { disk in
            AttachedVolume(path: "/Volumes/\(disk.name)", name: disk.name, volumeUUID: disk.volumeUUID,
                           tmDestinationID: disk.tmDestinationID, connection: .usb)
        }
        backup = BackupStatus()
    }

    /// The demo with disks that share a name, for reviewing how a row tells
    /// them apart and what its context menu offers. One pair differs in size,
    /// the other only in its UUID.
    func loadDisksDemo() {
        loadDemo()
        let small = KnownDisk(id: "demo-t7a", name: "Samsung T7", volumeUUID: "1C2F6A0B-demo",
                              capacity: 1_000_000_000_000)
        let large = KnownDisk(id: "demo-t7b", name: "Samsung T7", volumeUUID: "9E41D7C3-demo",
                              absentSince: Date().addingTimeInterval(-3 * 86_400),
                              capacity: 2_000_000_000_000)
        let first = KnownDisk(id: "demo-u1", name: "Untitled", volumeUUID: "4BEED8FB-demo",
                              capacity: 64_000_000_000)
        let second = KnownDisk(id: "demo-u2", name: "Untitled", volumeUUID: "7496A0AE-demo",
                               capacity: 64_000_000_000)
        var demo = config
        // Few enough that the list does not scroll, which ImageRenderer
        // could not draw: `many` shows that.
        demo.knownDisks = [small, large, demo.knownDisks[3], first, second]
        demo.watchedDiskIDs = [demo.knownDisks[2].id, large.id]
        config = demo
        attached = attached.filter { $0.volumeUUID != "demo-t7-uuid" } + [
            AttachedVolume(path: "/Volumes/Samsung T7", name: small.name,
                           volumeUUID: small.volumeUUID, connection: .usb, capacity: small.capacity),
        ]
        reportedDestinationIDs = ["demo-tm-dest", "demo-nas"]
        var status = backup
        status.running = false
        backup = status
    }

    /// The README motion demo: one guarded Time Machine disk and one portable
    /// disk nobody ticked. `setMotionFrame` then moves it through a meeting.
    func loadMotionDemo() {
        let timeMachine = KnownDisk(id: "demo-tm", name: "Time Machine",
                                    volumeUUID: "demo-tm-uuid", tmDestinationID: "demo-tm-dest")
        let portable = KnownDisk(id: "demo-t7", name: "Samsung T7", volumeUUID: "demo-t7-uuid")
        var demo = GuardConfig()
        demo.knownDisks = [timeMachine, portable]
        demo.watchedDiskIDs = [timeMachine.id]
        demo.onboardingShown = true
        config = demo
        calendarAccess = .granted
        notificationsEnabled = true
        PreviewDemo.isActive = true
    }

    /// One moment of the motion demo, set the way the real controller sets it
    /// at that point: `isBusy` while an eject pass runs, the Time Machine disk
    /// in `attached` only while it is mounted, `ejectDate` only while a
    /// guarded disk is connected and the meeting has not been acted on, and a
    /// pending reconnect from the unmount until the disk list shows it back.
    func setMotionFrame(timeMachineMounted: Bool, backupPercent: Double??,
                        meeting: EKEvent?, ejectDate: Date?, busy: Bool,
                        reconnectsAt: Date?, reconnecting: Bool) {
        var volumes: [AttachedVolume] = []
        if timeMachineMounted {
            volumes.append(AttachedVolume(path: "/Volumes/Time Machine", name: "Time Machine",
                                          volumeUUID: "demo-tm-uuid", tmDestinationID: "demo-tm-dest",
                                          connection: .usb))
        }
        volumes.append(AttachedVolume(path: "/Volumes/Samsung T7", name: "Samsung T7",
                                      volumeUUID: "demo-t7-uuid", connection: .thunderbolt))
        attached = volumes

        config.pendingReconnects = reconnectsAt.map {
            [PendingReconnect(volumeUUID: "demo-tm-uuid", name: "Time Machine", notBefore: $0,
                              tmDestinationID: "demo-tm-dest", stoppedBackup: true)]
        } ?? []

        var status = BackupStatus()
        // Outer nil: no backup. Inner nil: Time Machine is still sizing it up.
        if let percent = backupPercent {
            status.running = true
            status.mountPoint = "/Volumes/Time Machine"
            status.destinationID = "demo-tm-dest"
            status.percent = percent
        }
        backup = status
        nextMeeting = meeting
        self.ejectDate = ejectDate
        isBusy = busy
        isReconnecting = reconnecting
    }

    /// A demo meeting with no attendees list: the harness never asks the
    /// store for events, so nothing filters it.
    func demoMeeting(_ title: String, start: Date, minutes: Double) -> EKEvent {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Work"
        let meeting = EKEvent(eventStore: store)
        meeting.title = title
        meeting.calendar = calendar
        meeting.startDate = start
        meeting.endDate = start.addingTimeInterval(minutes * 60)
        return meeting
    }
}

/// Knobs only the preview harness turns.
enum PreviewDemo {
    /// Demo data is loaded: nothing may read this Mac's Time Machine state.
    nonisolated(unsafe) static var isActive = false
    /// The time the demo pretends it is, for "in 5 min" and the menu bar clock.
    nonisolated(unsafe) static var now: Date?
    /// Turns of the stand-in spinner, which ImageRenderer cannot animate.
    nonisolated(unsafe) static var spinnerTurns: Double = 0
}
#endif

// MARK: - Formatting

enum Format {
    static func relative(_ date: Date) -> String {
        #if PREVIEW
        let now = PreviewDemo.now ?? Date()
        #else
        let now = Date()
        #endif
        let minutes = Int((date.timeIntervalSince(now) / 60).rounded())
        if minutes <= 0 { return "now" }
        if minutes < 60 { return Loc.t("relative.minutes", "in %d min", minutes) }
        let hours = minutes / 60
        let rest = minutes % 60
        return rest == 0
            ? Loc.t("relative.hours", "in %d h", hours)
            : Loc.t("relative.hoursMinutes", "in %1$d h %2$d min", hours, rest)
    }

    /// A backup percentage the way the Time Machine menu shows it: one
    /// decimal, in the user's locale ("13,5 %" in Slovak, "13.5%" in English).
    static func percent(_ fraction: Double) -> String {
        fraction.formatted(.percent.precision(.fractionLength(1)))
    }

    static func clock(_ date: Date) -> String {
        DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
    }
}
