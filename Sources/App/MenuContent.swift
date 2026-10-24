import EventKit
import SwiftUI

struct MenuContent: View {
    /// Which welcome step to open on. Only the preview harness sets it.
    var onboardingStep = 0
    @Environment(GuardController.self) private var controller
    @Environment(\.openSettings) private var openSettings
    @Environment(UpdateStatus.self) private var updateStatus
    @Environment(\.updater) private var updater
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The one abnormal state worth a banner, the most pressing first.
    private enum Banner: Equatable {
        case calendarAccess
        case paused(until: Date)
        case guardingOff
        case notificationsOff
    }

    private var banner: Banner? {
        if controller.calendarAccess == .denied { return .calendarAccess }
        if controller.config.isPaused, let until = controller.config.pausedUntil { return .paused(until: until) }
        if !controller.config.enabled { return .guardingOff }
        if controller.notificationsEnabled == false { return .notificationsOff }
        return nil
    }

    var body: some View {
        Group {
            // A fresh install gets the welcome tour in place of the popover,
            // as in VibeRes, until it is finished or skipped.
            if !controller.config.onboardingShown {
                OnboardingView(initialStep: onboardingStep)
            } else {
                popover
            }
        }
        .frame(width: Design.Layout.popoverWidth)
        .frame(maxHeight: Design.Layout.popoverMaxHeight)
        // Lock the popover to its intrinsic height instead of the tallest state
        // it has ever shown.
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
        // Time Machine progress is only interesting to someone looking at it,
        // so this runs while the popover is open and stops when it closes.
        .task {
            controller.refreshNotificationStatus()
            while !Task.isCancelled {
                controller.refreshBackupStatus()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private var popover: some View {
        VStack(spacing: 0) {
            // A failed eject, or else a stop or start that did not take,
            // first, as VibeRes puts its problems: it is about something that
            // just went wrong and still needs dealing with.
            if let failure = controller.lastFailure ?? controller.backupFailure {
                ProblemRow(message: failure) { controller.dismissFailure() }
                    .transition(.row(reduceMotion: reduceMotion))
            }

            // Only when there is something staged. Sparkle installs on quit
            // by default, and a menu bar app can go weeks without quitting, so
            // this is the moment the update becomes real. Near the top, as in
            // VibeRes: it asks for a click.
            if updateStatus.isUpdateReady {
                UpdateReadyBanner { updater?.installUpdate() }
                    .transition(.row(reduceMotion: reduceMotion))
            }

            Group {
                switch banner {
                case .calendarAccess:
                    CalendarAccessBanner()
                case .paused(let until):
                    StateBanner(icon: "pause.circle.fill",
                                tint: .orange,
                                title: Loc.t("banner.pausedUntil", "Paused until %@", Format.clock(until)),
                                detail: Loc.t("banner.pausedDetail", "Nothing will be ejected until then."))
                case .guardingOff:
                    StateBanner(icon: "xmark.circle.fill",
                                tint: .orange,
                                title: Loc.t("banner.guardingOff", "Guarding is off"),
                                detail: Loc.t("banner.guardingOffDetail", "Turn it back on in Settings."))
                case .notificationsOff:
                    StateBanner(icon: "bell.slash.fill",
                                tint: .orange,
                                title: Loc.t("banner.notificationsOff", "Notifications are off"),
                                detail: Loc.t("banner.notificationsOffDetail", "Disks will still be ejected, but silently."))
                case nil:
                    EmptyView()
                }
            }
            .transition(.row(reduceMotion: reduceMotion))

            VStack(spacing: 0) {
                DisksSection()

                Divider()
                    .padding(.horizontal, Design.Spacing.m)
                    .padding(.vertical, Design.Spacing.m)

                NextMeetingSection()
            }
            .padding(.top, Design.Spacing.m)

            FooterBar()
        }
        // The rows around these make room before they fade in, and close up
        // only after they have faded out. On values seen here rather than
        // where they change, so it reaches every row of the popover.
        .animation(Design.Motion.rows(arriving: (controller.lastFailure ?? controller.backupFailure) != nil,
                                      reduceMotion: reduceMotion),
                   value: controller.lastFailure ?? controller.backupFailure)
        .animation(Design.Motion.rows(arriving: updateStatus.isUpdateReady, reduceMotion: reduceMotion),
                   value: updateStatus.isUpdateReady)
        // A banner coming or going on its own; one swapping with another.
        // The paused banner never comes on its own: Pause swaps for Resume
        // with it, so the rows close up over the Pause row first.
        .animation(Design.Motion.rows(arriving: banner != nil && !controller.config.isPaused, reduceMotion: reduceMotion),
                   value: banner != nil)
        .animation(Design.Motion.rows(arriving: false, reduceMotion: reduceMotion),
                   value: banner)
        .animation(Design.Motion.rows(arriving: controller.config.watchedDiskIDs.isEmpty, reduceMotion: reduceMotion),
                   value: controller.config.watchedDiskIDs.isEmpty)
        // Today's meeting and the line saying there is none swap places.
        .animation(Design.Motion.rows(arriving: false, reduceMotion: reduceMotion),
                   value: controller.meetingIsToday)
        .animation(Design.Motion.rows(arriving: controller.skippedMeeting != nil, reduceMotion: reduceMotion),
                   value: controller.skippedMeeting?.eventIdentifier)
        .animation(Design.Motion.rows(arriving: controller.offersStopBackup, reduceMotion: reduceMotion),
                   value: controller.offersStopBackup)
        // Pause and Resume swap places, with or without the paused banner.
        .animation(Design.Motion.rows(arriving: false, reduceMotion: reduceMotion),
                   value: controller.config.isPaused)
    }
}

// MARK: - Shared pieces

/// 9pt semibold rounded with a touch of letter spacing, as elsewhere in the
/// toolbelt - but `.secondary` rather than `.tertiary`. Measured off the
/// rendered popover, tertiary gives 2.74:1 against the dark background, under
/// the 4.5:1 WCAG asks for at this size. Secondary measures 5.6:1.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Design.Typography.sectionHeader)
            .foregroundStyle(.secondary)
            .tracking(0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Design.Spacing.l)
            .padding(.top, Design.Spacing.s)
            .padding(.bottom, Design.Spacing.xs)
    }
}

struct MenuRow: View {
    let icon: String
    let label: String
    var shortcut: String?
    var isEnabled = true
    /// The row is doing what it says ("Ejecting…", "Stopping backup…"): its
    /// icon pulses until that is done. It takes no second click, so it keeps
    /// the system's disabled look, but not the extra fade of a row with
    /// nothing to do: on a faded icon the pulse was all but invisible in a
    /// recording. The label says it too, so Reduce Motion stops the pulse and
    /// loses nothing.
    var isWorking = false
    let action: () -> Void

    @State private var isHovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var highlighted: Bool { isHovering && isEnabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .symbolEffect(.pulse, options: .repeating, isActive: isWorking && !reduceMotion)
                    .frame(width: Design.Layout.iconColumn, alignment: .center)
                    .accessibilityHidden(true)

                // A new label replaces the old one at once, as in a menu,
                // rather than crossfading with it while the rows move.
                Text(label)
                    .font(Design.Typography.row)
                    .contentTransition(.identity)

                Spacer(minLength: Design.Spacing.s)

                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 12).monospacedDigit())
                        .foregroundStyle(highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.secondary))
                        .accessibilityHidden(true)
                }
            }
            .foregroundStyle(highlighted ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, Design.Spacing.l)
            .padding(.vertical, Design.Layout.rowVerticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.row, style: .continuous)
                    .fill(highlighted ? Color.accentColor : Color.clear)
                    .padding(.horizontal, Design.Spacing.s)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled || isWorking ? 1 : 0.4)
        .onHover { isHovering = $0 }
        .accessibilityLabel(label)
    }
}

/// Shown only when the guard is in an abnormal state. In the normal case the
/// popover leads with the disks, which is what people actually came for.
private struct StateBanner: View {
    let icon: String
    let tint: Color
    let title: String
    let detail: String

    var body: some View {
        HStack(spacing: Design.Spacing.m) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(Design.Typography.cardTitle)
                Text(detail)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Design.Spacing.l)
        .padding(.top, Design.Spacing.l)
    }
}

private struct CalendarAccessBanner: View {
    @Environment(GuardController.self) private var controller

    var body: some View {
        Button { controller.openCalendarSettings() } label: {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Loc.t("calendar.accessNeeded", "Calendar access needed"))
                        .font(Design.Typography.cardTitle)
                    Text(Loc.t("calendar.accessDetail", "Without it the guard cannot see your meetings."))
                        .font(Design.Typography.note)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, Design.Spacing.l)
            .padding(.vertical, Design.Spacing.m)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The error row, drawn as VibeRes draws it: red, the whole message, and a
/// small cross to acknowledge it.
private struct ProblemRow: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: Design.Spacing.s) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(Design.Typography.note)
                .accessibilityHidden(true)
            Text(message)
                .font(Design.Typography.note)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: Design.Spacing.s)
            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Loc.t("problem.dismiss", "Dismiss"))
            .help(Loc.t("problem.dismiss", "Dismiss"))
        }
        .foregroundStyle(.red)
        .padding(.horizontal, Design.Spacing.l)
        .padding(.top, Design.Spacing.m)
    }
}

/// The VibeRes update card: green, at the top, the whole card is the button.
/// Insets match `DiskCard` so its edges line up with the disks under it.
private struct UpdateReadyBanner: View {
    let install: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: install) {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Loc.t("banner.updateReady", "Update ready"))
                        .font(Design.Typography.cardTitle)
                    Text(Loc.t("banner.updateReadyDetail", "Click to restart into the new version"))
                        .font(Design.Typography.note)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Design.Spacing.l)
            .padding(.vertical, Design.Spacing.m)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card)
                .fill(isHovering ? Design.Palette.updateFillHover : Design.Palette.updateFill))
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .padding(.horizontal, Design.Spacing.m)
        .padding(.top, Design.Spacing.m)
        .accessibilityElement(children: .combine)
        .help(Loc.t("banner.updateReadyHelp", "Installs the downloaded update and relaunches Eject Guard."))
    }
}

// MARK: - Disks

private struct DisksSection: View {
    @Environment(GuardController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The rows' natural height, measured; past the cap they scroll.
    @State private var rowsHeight: CGFloat = 0

    var body: some View {
        VStack(spacing: Design.Spacing.xs) {
            SectionHeader(title: Loc.t("section.disks", "DISKS"))

            if controller.knownDisks.isEmpty {
                Text(Loc.t("disks.empty", "No external disks seen yet.\nPlug one in and it shows up here."))
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, Design.Spacing.l)
                    .padding(.horizontal, Design.Spacing.m)
            } else if rowsHeight > Design.Layout.diskListMaxHeight {
                // Only once the rows outgrow the cap, so a list that fits
                // looks exactly as it did. The scroller sits at the popover's
                // edge, outside the cards.
                ScrollView {
                    rows
                }
                .frame(height: Design.Layout.diskListMaxHeight)
            } else {
                rows
            }
        }
    }

    private var rows: some View {
        // Two disks of one name read the same, so each gets what tells it
        // apart: its size, or the start of its UUID.
        let details = Disks.distinguishingDetails(for: controller.knownDisks)
        return VStack(spacing: Design.Spacing.xs) {
            ForEach(Array(controller.knownDisks.enumerated()), id: \.element.id) { index, disk in
                DiskCard(disk: disk, shortcutIndex: index, detail: details[disk.id])
            }
            // The one thing a new user has to do, said where they are looking
            // rather than only in the README.
            if controller.config.watchedDiskIDs.isEmpty {
                Text(Loc.t("disks.hint", "Click a disk to guard it."))
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Spacing.s)
                    .padding(.top, Design.Spacing.xs)
                    .transition(.row(reduceMotion: reduceMotion))
            }
        }
        .padding(.horizontal, Design.Spacing.m)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { rowsHeight = $0 }
    }
}

private struct DiskCard: View {
    @Environment(GuardController.self) private var controller
    let disk: KnownDisk
    /// Position in the list, which is also its keyboard shortcut.
    let shortcutIndex: Int
    /// Set only when another listed disk has the same name.
    var detail: String?

    @State private var isHovering = false
    /// Goes up each time the disk becomes guarded while on screen, for the
    /// checkmark's one bounce.
    @State private var guardings = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Only the first nine get one; past that the number stops being a shortcut
    /// and starts being a lookup.
    private var shortcut: Character? {
        guard shortcutIndex < 9 else { return nil }
        return Character("\(shortcutIndex + 1)")
    }

    private var guarded: Bool { controller.isGuarded(disk) }
    private var connected: Bool { controller.isAttached(disk) }

    private var backingUp: Bool { controller.isBackingUp(disk) }
    /// "Back up now" was clicked, and Time Machine has not started yet.
    private var starting: Bool { controller.isStartingBackup(disk) }

    private var subtitle: String {
        guard let detail else { return status }
        return "\(status) · \(detail)"
    }

    private var status: String {
        if backingUp {
            if let percent = controller.backup.percent {
                return Loc.t("disk.backingUpPercent", "Backing up… %@", Format.percent(percent))
            }
            return Loc.t("disk.backingUp", "Backing up…")
        }
        if starting { return Loc.t("disk.startingBackup", "Starting backup…") }
        let watch = guarded ? Loc.t("disk.guarded", "Guarded") : Loc.t("disk.notGuarded", "Not guarded")
        // Unmounted for a meeting: "Disconnected" would read as unplugged.
        // Only a guarded disk is ever waiting, so "Guarded" goes unsaid and
        // the time fits the row.
        if !connected, let pending = controller.pendingReconnect(for: disk) {
            return Loc.t("disk.reconnectsAt", "Reconnects at %@", Format.clock(pending.notBefore))
        }
        return "\(watch) · \(connectionLabel)"
    }

    /// How the disk reaches the Mac, named when we know it. "Connected" is
    /// the fallback, never a guess.
    private var connectionLabel: String {
        if disk.isNetworkDestination { return Loc.t("disk.network", "Network") }
        guard let volume = controller.attachedVolume(for: disk) else {
            return Loc.t("disk.disconnected", "Disconnected")
        }
        switch volume.connection {
        case .usb: return "USB"
        case .thunderbolt: return "Thunderbolt"
        case .sdCard: return Loc.t("disk.sdCard", "SD card")
        case nil: return Loc.t("disk.connected", "Connected")
        }
    }

    /// One shape per kind, filled while it is plugged in. A share is never
    /// filled: whether it is reachable is not known until a backup starts.
    private var symbol: String {
        if disk.isNetworkDestination { return "externaldrive.connected.to.line.below" }
        let base = disk.isTimeMachineDestination ? "externaldrive.badge.timemachine" : "externaldrive"
        guard connected else { return base }
        return disk.isTimeMachineDestination ? "externaldrive.fill.badge.timemachine" : "externaldrive.fill"
    }

    private var fill: Color {
        if guarded { return Design.Palette.cardFillActive }
        return isHovering ? Design.Palette.cardFillHover : Design.Palette.cardFill
    }

    var body: some View {
        Button { controller.toggleGuard(disk) } label: {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: symbol)
                    .font(.system(size: 18))
                    .foregroundStyle(guarded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.secondary))
                    .frame(width: 26)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: Design.Spacing.s) {
                        Text(disk.name)
                            .font(Design.Typography.cardTitle)
                            .lineLimit(1)
                        if disk.isTimeMachineDestination {
                            Text("TM")
                                .help(Loc.t("disk.timeMachineBadge", "A Time Machine backup destination"))
                                .font(Design.Typography.badge)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.22), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: Design.Spacing.s) {
                        if backingUp || starting {
                            #if PREVIEW
                            // ImageRenderer cannot draw the AppKit-backed spinner
                            // and paints a placeholder instead; a still arc of
                            // the same size stands in for the screenshot.
                            Circle()
                                .trim(from: 0, to: 0.7)
                                .stroke(.secondary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                                .frame(width: 8, height: 8)
                                .rotationEffect(.degrees(360 * PreviewDemo.spinnerTurns))
                                .frame(width: 10, height: 10)
                            #else
                            ProgressView()
                                .controlSize(.mini)
                                .scaleEffect(0.7)
                                .frame(width: 10, height: 10)
                            #endif
                        }
                        // The detail after the status where the line has
                        // room, on a line of its own where it does not: cut
                        // off, it would be the very part that tells the two
                        // disks apart.
                        ViewThatFits(in: .horizontal) {
                            Text(subtitle)
                                .lineLimit(1)
                            if let detail {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(status)
                                    Text(detail)
                                }
                                .lineLimit(1)
                            }
                        }
                        .font(Design.Typography.cardSubtitle)
                        .foregroundStyle(Design.Palette.cardSubtitle)
                        // Time Machine's progress ticks up between polls.
                        .rollingNumbers(on: backingUp ? controller.backup.percent : nil,
                                        counting: backingUp && controller.backup.percent != nil,
                                        reduceMotion: reduceMotion)
                    }
                }

                Spacer(minLength: Design.Spacing.s)

                if let shortcut {
                    Text("⌘\(String(shortcut))")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }

                // One symbol that changes, rather than two in an if/else, so
                // the swap to the checkmark is the system's symbol replace
                // instead of one image cut for another. It bounces once when
                // the disk becomes guarded, as a VibeRes pill does when it
                // turns active. Reduce Motion: the swap crossfades, no bounce.
                Image(systemName: guarded ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(guarded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
                    .symbolEffect(.bounce, options: .nonRepeating, value: guardings)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Design.Spacing.l)
            .padding(.vertical, Design.Spacing.m)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.card))
            // The fill, the tints and the status line cross over to the new
            // state together. Colour only, so Reduce Motion keeps it.
            .animation(Design.Motion.quick, value: isHovering)
            .animation(Design.Motion.quick, value: guarded)
        }
        .buttonStyle(PressableButtonStyle(scale: Design.Motion.cardPressScale))
        .onChange(of: guarded) { _, nowGuarded in
            if nowGuarded, !reduceMotion { guardings += 1 }
        }
        .modifier(OptionalShortcut(key: shortcut))
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(disk.name), \(subtitle)")
        .contextMenu {
            // Any destination Time Machine can reach, guarded or not, as the
            // system menu offers it. Greyed out while a backup runs: Time
            // Machine runs one at a time, and the footer stops it.
            if controller.offersBackUpNow(disk) {
                Button(Loc.t("disk.backUpNow", "Back up now")) { controller.backUpNow(disk) }
                    .disabled(!controller.canBackUpNow(disk))
                Divider()
            }
            // Anything can be hidden, including a Time Machine destination that
            // belongs to another Mac and will never be plugged into this one.
            // Settings has the way back.
            Button(Loc.t("disk.hide", "Hide this disk")) { controller.hide(disk) }
            Text(Loc.t("disk.hideHint", "Restore it later in Settings"))
            // Only while it is unplugged: one that is plugged in would be
            // listed again by the very next scan.
            if controller.canForget(disk) {
                Divider()
                Button(Loc.t("disk.forget", "Forget this disk")) { forget() }
                Text(Loc.t("disk.forgetHint", "Listed again when you plug it in"))
            }
        }
    }

    /// A guarded disk is asked about first: forgetting one also stops
    /// guarding it, and a click in a context menu is easy to get wrong.
    /// An app-modal NSAlert rather than a SwiftUI alert, which a menu bar
    /// popover closes along with itself. The popover may well close when the
    /// alert takes focus; `runModal` still hands back the answer, and only
    /// values captured here are used after it. Checked offscreen by closing
    /// a stand-in popover window while the alert was up: Forget came back as
    /// the first button, Return as Cancel.
    private func forget() {
        guard guarded else {
            controller.forget(disk)
            return
        }
        let alert = ForgetConfirmation.alert(
            for: disk, reconnectPending: controller.pendingReconnect(for: disk) != nil)
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        controller.forget(disk)
    }
}

/// The question asked before a guarded disk is forgotten. Apart from the
/// row so the preview harness renders the very same alert.
@MainActor
enum ForgetConfirmation {
    static func alert(for disk: KnownDisk, reconnectPending: Bool) -> NSAlert {
        var message = Loc.t("disk.forgetConfirmDetail", "It is guarded. Forgetting it stops guarding it, and the next time you plug it in it is listed as not guarded.")
        if reconnectPending {
            message += " " + Loc.t("disk.forgetConfirmReconnect", "It will not be reconnected after the meeting either.")
        }
        let alert = NSAlert()
        alert.messageText = Loc.t("disk.forgetConfirm", "Forget “%@”?", disk.name)
        alert.informativeText = message
        let forget = alert.addButton(withTitle: Loc.t("disk.forgetConfirmButton", "Forget"))
        let cancel = alert.addButton(withTitle: Loc.t("disk.forgetCancel", "Cancel"))
        // Destructive, so Return cancels, as macOS asks of such an alert.
        forget.hasDestructiveAction = true
        forget.keyEquivalent = ""
        cancel.keyEquivalent = "\r"
        return alert
    }
}

/// `keyboardShortcut` takes no optional, and a tenth disk has no key left.
private struct OptionalShortcut: ViewModifier {
    let key: Character?

    func body(content: Content) -> some View {
        if let key {
            content.keyboardShortcut(KeyEquivalent(key), modifiers: .command)
        } else {
            content
        }
    }
}

// MARK: - Next meeting

private struct NextMeetingSection: View {
    @Environment(GuardController.self) private var controller
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: Design.Spacing.xs) {
            SectionHeader(title: Loc.t("section.nextMeeting", "NEXT MEETING"))

            if let meeting = controller.nextMeeting, controller.meetingIsToday {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title ?? Loc.t("meeting.untitledEvent", "Untitled"))
                        .font(Design.Typography.cardTitle)
                        .lineLimit(1)
                    VStack(alignment: .leading, spacing: 0) {
                        // "in 7 min" is worked out when it is drawn, and
                        // nothing else here changes by the minute, so without
                        // the timeline an open popover kept the minute it
                        // opened on. The minutes count down rather than flick.
                        TimelineView(.everyMinute) { _ in
                            let countdown = countdown(for: meeting)
                            Text(countdown)
                                .rollingNumbers(on: countdown, countsDown: true, reduceMotion: reduceMotion)
                        }
                        // Swapped at once: crossfading while the rows move,
                        // the old and new plan overlapped.
                        if let plan {
                            Text(plan)
                                .contentTransition(.identity)
                        }
                    }
                    .font(Design.Typography.cardSubtitle)
                    .foregroundStyle(Design.Palette.cardSubtitle)
                    .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Spacing.l)
                .padding(.vertical, Design.Spacing.m)
                .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
                .padding(.horizontal, Design.Spacing.m)
                .padding(.bottom, Design.Spacing.xs)
                .transition(.row(reduceMotion: reduceMotion))

                MenuRow(icon: "forward.end", label: Loc.t("meeting.skip", "Skip this meeting")) {
                    controller.skipNextMeeting()
                }
                .transition(.row(reduceMotion: reduceMotion))
            } else {
                Text(emptyText)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.bottom, Design.Spacing.xs)
                    .transition(.row(reduceMotion: reduceMotion))
            }

            // Skipping is one click and would otherwise be irreversible, so the
            // way back stays on screen until the meeting is behind us.
            if let skipped = controller.skippedMeeting {
                MenuRow(icon: "arrow.uturn.backward",
                        label: Loc.t("meeting.undoSkip", "Undo skip: %@", skipped.title ?? Loc.t("meeting.lowercase", "meeting"))) {
                    controller.undoLastSkip()
                }
                .transition(.row(reduceMotion: reduceMotion))
            }
        }
    }

    private var emptyText: String {
        switch controller.calendarAccess {
        case .pending: return Loc.t("meeting.checking", "Checking your calendar…")
        case .denied: return Loc.t("meeting.noAccess", "No calendar access.")
        case .granted: return Loc.t("meeting.noneToday", "No more meetings today.")
        }
    }

    /// "in 7 min · Work": the line that counts down.
    private func countdown(for meeting: EKEvent) -> String {
        "\(Format.relative(meeting.startDate)) · \(meeting.calendar.title)"
    }

    /// What the guard will do about the meeting, when there is anything to say.
    private var plan: String? {
        if let ejectDate = controller.ejectDate {
            // With only a network destination guarded there is nothing to
            // eject, and saying so would promise the wrong thing.
            return controller.guardedVolumes.isEmpty
                ? Loc.t("meeting.stopsBackupAt", "Stops a running backup at %@", Format.clock(ejectDate))
                : Loc.t("meeting.ejectsAt", "Ejects at %@", Format.clock(ejectDate))
        }
        if controller.guardedVolumes.isEmpty { return Loc.t("meeting.noGuardedDisk", "No guarded disk connected") }
        if !controller.config.isActive { return Loc.t("meeting.guardOff", "Guard is off") }
        return nil
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(GuardController.self) private var controller
    @Environment(\.openSettings) private var openSettings
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var paused: Bool { controller.config.isPaused }

    private var pauseLabel: String {
        let hours = controller.config.pauseHours
        return Loc.t("footer.pauseHours", "Pause for %d hours", Int(hours))
    }

    /// Naming the disk beats a bare "Eject now": this acts on guarded disks
    /// that are connected, which is not the same set as "everything plugged in".
    private var ejectLabel: String {
        let volumes = controller.guardedVolumes
        if controller.isBusy {
            return volumes.isEmpty
                ? Loc.t("footer.stoppingBackup", "Stopping backup…")
                : Loc.t("footer.ejecting", "Ejecting…")
        }
        switch volumes.count {
        case 0: return Loc.t("footer.ejectNow", "Eject now")
        case 1: return Loc.t("footer.ejectOne", "Eject %@", volumes[0].name)
        default: return Loc.t("footer.ejectMany", "Eject %d disks", volumes.count)
        }
    }

    /// The standard panel, as in VibeRes: version, icon and the one sentence
    /// that says what the app is for, without opening Settings to find it.
    private func showAbout() {
        let credits = NSAttributedString(
            string: Loc.t("about.description", "Ejects your external disks a few minutes before a meeting starts, so a spinning drive is never unplugged while it is still mounted.")
                + "\n\nMIT · github.com/m-moravcik/eject-guard",
            attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    private var ejectHelp: String {
        let volumes = controller.guardedVolumes
        guard !volumes.isEmpty else { return Loc.t("footer.ejectHelpNone", "No guarded disk is connected.") }
        return Loc.t("footer.ejectHelp", "Ejects %@. Disks you have not ticked are left alone.", volumes.map(\.name).joined(separator: ", "))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Native NSMenu metrics, measured on macOS 26: a separator item is
            // 11pt (5 + 1 + 5) and the menu keeps 5pt at its bottom edge.
            Divider()
                .padding(.top, Design.Layout.menuInset)

            VStack(spacing: 0) {
                MenuRow(
                    icon: "eject",
                    label: ejectLabel,
                    shortcut: "⌘E",
                    isEnabled: controller.canEjectNow,
                    isWorking: controller.isBusy
                ) { controller.ejectNow() }
                    .keyboardShortcut("e")
                    .help(ejectHelp)

                if controller.offersStopBackup {
                    MenuRow(
                        icon: "stop.circle",
                        label: controller.isStoppingBackup
                            ? Loc.t("footer.stoppingBackup", "Stopping backup…")
                            : Loc.t("footer.stopBackup", "Stop backup"),
                        isEnabled: controller.canStopBackup,
                        isWorking: controller.isStoppingBackup
                    ) { controller.stopBackup() }
                        .help(Loc.t("footer.stopBackupHelp", "Stops the backup to %@. Time Machine carries on at its next backup.",
                                    controller.backingUpNames.joined(separator: ", ")))
                        .transition(.row(reduceMotion: reduceMotion))
                }

                // The two swap places as the paused banner comes and goes,
                // so they fade around the rows moving, as the banner does.
                if paused {
                    MenuRow(icon: "play.circle", label: Loc.t("footer.resume", "Resume guarding")) {
                        controller.resume()
                    }
                    .transition(.row(reduceMotion: reduceMotion))
                } else {
                    MenuRow(icon: "pause.circle", label: pauseLabel) {
                        controller.pause(for: controller.config.pauseHours * 3600)
                    }
                    .transition(.row(reduceMotion: reduceMotion))
                }

                MenuRow(icon: "gearshape", label: Loc.t("footer.settings", "Settings…"), shortcut: "⌘,") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",")

                MenuRow(icon: "info.circle", label: Loc.t("footer.about", "About Eject Guard")) {
                    showAbout()
                }

                MenuRow(icon: "power", label: Loc.t("footer.quit", "Quit"), shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(.vertical, Design.Layout.menuInset)
        }
    }
}
