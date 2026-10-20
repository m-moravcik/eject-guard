// The menu bar icon, and the only state most people will ever read.
//
// Split in two on purpose. `StatusIcon` reads the controller; `StatusIconArt`
// takes plain values and draws. Only the second one can be rendered offscreen
// and looked at, and an icon nobody can look at is an icon nobody reviews.
// The drawing itself, and the eject animation's timing, live in
// Sources/Icon (`LiftIcon`, `MenuBarIconAnimator`), where the tests reach them.

import SwiftUI

/// A View rather than a computed image in the Scene body: observation is
/// registered when a view body is evaluated, so this is what reliably redraws
/// when a disk is plugged in or an eject starts.
struct StatusIcon: View {
    let controller: GuardController

    private var state: StatusIconState {
        if controller.isBusy { return .ejecting }
        // Ahead of off and idle: a backup is worth seeing whether or not
        // anything is guarded.
        if controller.isBackupRunning { return .backingUp }
        if !controller.config.isActive { return .off }
        return controller.hasGuardedTargets ? .armed : .idle
    }

    private var label: String {
        switch state {
        case .ejecting: return Loc.t("status.ejecting", "Ejecting")
        case .off: return Loc.t("status.off", "Guarding is off")
        case .backingUp:
            let names = controller.backingUpNames.joined(separator: ", ")
            guard let percent = controller.backupPercent else {
                return Loc.t("status.backingUp", "Backing up %@", names)
            }
            return Loc.t("status.backingUpPercent", "Backing up %1$@ - %2$@",
                         names, Format.percent(percent))
        case .armed:
            let names = controller.guardedTargetNames.joined(separator: ", ")
            return Loc.t("status.guarding", "Guarding %@", names)
        case .idle: return Loc.t("status.idle", "No guarded disk connected")
        }
    }

    var body: some View {
        StatusIconArt(state: state,
                      percent: controller.backupPercent,
                      phase: controller.backupPhase,
                      guarding: controller.config.isActive && controller.hasGuardedTargets,
                      ejectPhase: controller.iconAnimator.phase)
            // `label` is already translated; the name in front of it never is.
            .accessibilityLabel(Text(verbatim: "Eject Guard: \(label)"))
    }
}

/// The drawing, with nothing to observe. Everything it needs is an argument, so
/// it renders the same way in the menu bar and in the preview harness.
///
/// One template image per pose, on the fixed 22 x 16 pt canvas: a MenuBarExtra
/// label is rendered to a static image, so SwiftUI's own effects never run
/// there, and the label stays a plain `Image`, which the menu bar tints like a
/// system symbol and never scales.
struct StatusIconArt: View {
    let state: StatusIconState
    /// 0...1, or nil while Time Machine is still sizing the job up.
    var percent: Double?
    /// The backup breathing step, see `GuardController.backupPhase`.
    var phase: Int = 0
    /// A disk is guarded, so the triangle is solid during a backup too.
    var guarding = false
    /// Seconds into the eject animation, nil at rest. See `MenuBarIconAnimator`.
    var ejectPhase: Double?

    var pose: LiftIcon.Pose {
        let rest = LiftIcon.pose(state, percent: percent, phase: phase, guarding: guarding)
        // A new eject under way says so, rather than finishing the last one's
        // celebration.
        guard let ejectPhase, state != .ejecting else { return rest }
        return LiftIcon.pose(at: ejectPhase, landingOn: rest)
    }

    var body: some View {
        // Still an Image after this, so the menu bar treats it as one; in an
        // offscreen render it takes the foreground colour like a symbol.
        Image(nsImage: LiftIcon.image(pose))
            .renderingMode(.template)
    }
}
