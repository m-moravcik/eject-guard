// The menu bar icon, and the only state most people will ever read.
//
// Split in two on purpose. `StatusIcon` reads the controller; `StatusIconArt`
// takes plain values and draws. Only the second one can be rendered offscreen
// and looked at, and an icon nobody can look at is an icon nobody reviews.

import SwiftUI

/// What the icon is saying right now.
enum StatusIconState: CaseIterable {
    case ejecting, backingUp, armed, idle, off

    /// Each state gets its own shape, not just a different badge. A badge swap
    /// is too quiet to notice during the few seconds an eject takes.
    var symbol: String {
        switch self {
        case .ejecting: return "eject.fill"
        case .off: return "externaldrive.badge.xmark"
        // The badge Time Machine itself uses, so the icon says what is
        // happening rather than only that something is.
        case .backingUp: return "externaldrive.fill.badge.timemachine"
        case .armed: return "externaldrive.fill.badge.checkmark"
        case .idle: return "externaldrive"
        }
    }
}

/// A View rather than a computed symbol name in the Scene body: observation is
/// registered when a view body is evaluated, so this is what reliably redraws
/// when a disk is plugged in or an eject starts.
struct StatusIcon: View {
    let controller: GuardController

    private var state: StatusIconState {
        if controller.isBusy { return .ejecting }
        if !controller.config.isActive { return .off }
        if controller.guardedVolumes.isEmpty { return .idle }
        return controller.isGuardedBackupRunning ? .backingUp : .armed
    }

    private var label: String {
        switch state {
        case .ejecting: return Loc.t("status.ejecting", "Ejecting")
        case .off: return Loc.t("status.off", "Guarding is off")
        case .backingUp:
            let names = controller.guardedVolumes.map(\.name).joined(separator: ", ")
            guard let percent = controller.guardedBackupPercent else {
                return Loc.t("status.backingUp", "Backing up %@", names)
            }
            return Loc.t("status.backingUpPercent", "Backing up %1$@ - %2$d%%",
                         names, Int(percent * 100))
        case .armed:
            let names = controller.guardedVolumes.map(\.name).joined(separator: ", ")
            return Loc.t("status.guarding", "Guarding %@", names)
        case .idle: return Loc.t("status.idle", "No guarded disk connected")
        }
    }

    var body: some View {
        StatusIconArt(state: state,
                      percent: controller.guardedBackupPercent,
                      phase: controller.backupPhase)
            .accessibilityLabel("Eject Guard: \(label)")
    }
}

/// The drawing, with nothing to observe. Everything it needs is an argument, so
/// it renders the same way in the menu bar and in the preview harness.
struct StatusIconArt: View {
    let state: StatusIconState
    /// 0...1, or nil while Time Machine is still sizing the job up.
    var percent: Double?
    var phase: Int = 0

    /// Fixed rather than inherited. The backing-up state stacks a progress bar
    /// under the glyph, and without a fixed size that extra height shrinks the
    /// glyph - so the icon would visibly shrink the moment a backup started and
    /// grow back when it finished. Caught by rendering the states side by side.
    private static let glyphSize: CGFloat = 15

    var body: some View {
        if state == .backingUp {
            VStack(spacing: 1) {
                Image(systemName: state.symbol)
                    .font(.system(size: Self.glyphSize))
                BackupTrack(percent: percent, phase: phase)
            }
        } else {
            Image(systemName: state.symbol)
                .font(.system(size: Self.glyphSize))
        }
    }
}

/// The thin bar under the drive while Time Machine is writing to it.
///
/// Determinate once Time Machine has a percentage. Until then it reports -1,
/// and a bar sitting at zero reads as a stalled backup, so a short segment
/// travels instead: honest about working without claiming to know how far.
///
/// Both forms breathe, because progress can sit on one number for minutes and a
/// still icon in a menu bar reads as a dead one. The breathing is driven by
/// `GuardController.backupPhase` rather than by SwiftUI: a MenuBarExtra label
/// is rendered to a static image, so `.symbolEffect` and friends never run
/// there. That was measured on this machine, not assumed.
struct BackupTrack: View {
    let percent: Double?
    let phase: Int

    private static let width: CGFloat = 15
    private static let height: CGFloat = 2

    /// 0..<1 through one cycle.
    private var t: Double { Double(phase) / Double(GuardController.breatheSteps) }

    /// 0.55 at the ends of the cycle, 1 in the middle.
    private var breath: Double { 0.55 + 0.45 * (0.5 - 0.5 * cos(2 * .pi * t)) }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().opacity(0.25)
            if let percent {
                // A hairline even at 0%, so the track never looks empty.
                Capsule()
                    .frame(width: max(Self.height, Self.width * percent))
                    .opacity(breath)
            } else {
                Capsule()
                    .frame(width: Self.width * 0.35)
                    .offset(x: Self.width * 1.35 * t - Self.width * 0.35)
                    .opacity(breath)
            }
        }
        .frame(width: Self.width, height: Self.height)
        // The travelling segment starts and ends outside the track.
        .clipShape(Capsule())
    }
}
