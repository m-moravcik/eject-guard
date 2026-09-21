import EventKit
import SwiftUI

struct MenuContent: View {
    @Environment(GuardController.self) private var controller
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            if controller.calendarAccess == .denied {
                CalendarAccessBanner()
            } else if let until = controller.config.pausedUntil, until > Date() {
                StateBanner(icon: "pause.circle.fill",
                            tint: .orange,
                            title: "Paused until \(Format.clock(until))",
                            detail: "Nothing will be ejected until then.")
            } else if !controller.config.enabled {
                StateBanner(icon: "xmark.circle.fill",
                            tint: .orange,
                            title: "Guarding is off",
                            detail: "Turn it back on in Settings.")
            }

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
        .frame(width: Design.Layout.popoverWidth)
        .frame(maxHeight: Design.Layout.popoverMaxHeight)
        // Lock the popover to its intrinsic height instead of the tallest state
        // it has ever shown.
        .fixedSize(horizontal: false, vertical: true)
        .background(.ultraThinMaterial)
    }
}

// MARK: - Shared pieces

/// Matches the section labels used across the rest of the toolbelt: 9pt
/// semibold rounded, tertiary, with a touch of letter spacing.
struct SectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(Design.Typography.sectionHeader)
            .foregroundStyle(.tertiary)
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
    let action: () -> Void

    @State private var isHovering = false

    private var highlighted: Bool { isHovering && isEnabled }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: Design.Layout.iconColumn, alignment: .center)
                    .accessibilityHidden(true)

                Text(label)
                    .font(Design.Typography.row)

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
        .opacity(isEnabled ? 1 : 0.4)
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
                    Text("Calendar access needed")
                        .font(Design.Typography.cardTitle)
                    Text("Without it the guard cannot see your meetings.")
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

// MARK: - Disks

private struct DisksSection: View {
    @Environment(GuardController.self) private var controller

    var body: some View {
        VStack(spacing: Design.Spacing.xs) {
            SectionHeader(title: "DISKS")

            Group {
                if controller.knownDisks.isEmpty {
                    Text("No external disks seen yet.\nPlug one in and it shows up here.")
                        .font(Design.Typography.note)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Design.Spacing.l)
                } else {
                    VStack(spacing: Design.Spacing.xs) {
                        ForEach(controller.knownDisks, id: \.id) { disk in
                            DiskCard(disk: disk)
                        }
                    }
                }
            }
            .padding(.horizontal, Design.Spacing.m)
        }
    }
}

private struct DiskCard: View {
    @Environment(GuardController.self) private var controller
    let disk: KnownDisk

    @State private var isHovering = false

    private var guarded: Bool { controller.isGuarded(disk) }
    private var connected: Bool { controller.isAttached(disk) }

    private var subtitle: String {
        let watch = guarded ? "Guarded" : "Not guarded"
        return "\(watch) · \(connected ? "Connected" : "Disconnected")"
    }

    private var fill: Color {
        if guarded { return Design.Palette.cardFillActive }
        return isHovering ? Design.Palette.cardFillHover : Design.Palette.cardFill
    }

    var body: some View {
        Button { controller.toggleGuard(disk) } label: {
            HStack(spacing: Design.Spacing.m) {
                Image(systemName: connected ? "externaldrive.fill" : "externaldrive")
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
                                .font(Design.Typography.badge)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.secondary.opacity(0.22), in: Capsule())
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(subtitle)
                        .font(Design.Typography.cardSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: Design.Spacing.s)

                Image(systemName: guarded ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 15))
                    .foregroundStyle(guarded ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.tertiary))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, Design.Spacing.l)
            .padding(.vertical, Design.Spacing.m)
            .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(fill))
            .contentShape(RoundedRectangle(cornerRadius: Design.Radius.card))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityLabel("\(disk.name), \(subtitle)")
        .contextMenu {
            // Time Machine destinations are rediscovered automatically, so
            // forgetting one would only make it reappear.
            if !disk.isTimeMachineDestination && !connected {
                Button("Forget this disk") { controller.forget(disk) }
            }
        }
    }
}

// MARK: - Next meeting

private struct NextMeetingSection: View {
    @Environment(GuardController.self) private var controller

    var body: some View {
        VStack(spacing: Design.Spacing.xs) {
            SectionHeader(title: "NEXT MEETING")

            if let meeting = controller.nextMeeting {
                VStack(alignment: .leading, spacing: 2) {
                    Text(meeting.title ?? "Untitled")
                        .font(Design.Typography.cardTitle)
                        .lineLimit(1)
                    Text(detail(for: meeting))
                        .font(Design.Typography.cardSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Design.Spacing.l)
                .padding(.vertical, Design.Spacing.m)
                .background(RoundedRectangle(cornerRadius: Design.Radius.card).fill(Design.Palette.cardFill))
                .padding(.horizontal, Design.Spacing.m)
                .padding(.bottom, Design.Spacing.xs)

                MenuRow(icon: "forward.end", label: "Skip this meeting") {
                    controller.skipNextMeeting()
                }
            } else {
                Text(emptyText)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.bottom, Design.Spacing.xs)
            }
        }
    }

    private var emptyText: String {
        switch controller.calendarAccess {
        case .pending: return "Checking your calendar…"
        case .denied: return "No calendar access."
        case .granted: return "Nothing scheduled in the next 24 hours."
        }
    }

    private func detail(for meeting: EKEvent) -> String {
        var parts = ["\(Format.relative(meeting.startDate)) · \(meeting.calendar.title)"]
        if let ejectDate = controller.ejectDate {
            parts.append("Ejects at \(Format.clock(ejectDate))")
        } else if controller.guardedVolumes.isEmpty {
            parts.append("No guarded disk connected")
        } else if !controller.config.isActive {
            parts.append("Guard is off")
        }
        return parts.joined(separator: "\n")
    }
}

// MARK: - Footer

private struct FooterBar: View {
    @Environment(GuardController.self) private var controller
    @Environment(\.openSettings) private var openSettings

    private var paused: Bool { (controller.config.pausedUntil ?? .distantPast) > Date() }

    var body: some View {
        VStack(spacing: 0) {
            Divider()
                .padding(.top, Design.Spacing.s)

            VStack(spacing: 0) {
                if let failure = controller.lastFailure {
                    HStack(spacing: Design.Spacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(failure)
                            .font(Design.Typography.note)
                            .lineLimit(2)
                    }
                    .padding(.horizontal, Design.Spacing.l)
                    .padding(.vertical, Design.Spacing.s)
                }

                MenuRow(
                    icon: "eject",
                    label: controller.isBusy ? "Ejecting…" : "Eject now",
                    shortcut: "⌘E",
                    isEnabled: !controller.guardedVolumes.isEmpty && !controller.isBusy
                ) { controller.ejectNow() }
                    .keyboardShortcut("e")

                if paused {
                    MenuRow(icon: "play.circle", label: "Resume guarding") {
                        controller.resume()
                    }
                } else {
                    MenuRow(icon: "pause.circle", label: "Pause for 1 hour") {
                        controller.pause(for: 3600)
                    }
                }

                MenuRow(icon: "gearshape", label: "Settings…", shortcut: "⌘,") {
                    NSApp.activate(ignoringOtherApps: true)
                    openSettings()
                }
                .keyboardShortcut(",")

                MenuRow(icon: "power", label: "Quit", shortcut: "⌘Q") {
                    NSApp.terminate(nil)
                }
                .keyboardShortcut("q")
            }
            .padding(.vertical, Design.Spacing.m)
        }
    }
}
