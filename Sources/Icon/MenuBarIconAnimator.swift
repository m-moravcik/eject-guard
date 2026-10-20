import AppKit
import Observation

/// Plays the menu bar icon's eject and reconnect animations.
///
/// A MenuBarExtra label is rasterised into the status item, so SwiftUI's symbol
/// effects never run there (measured, see DEVELOPMENT.md). Instead the label
/// redraws the icon for `phase`, and a 30 Hz ticker advances it. The ticker
/// exists only while the animation plays: none at rest, none outliving the
/// animation, and a burst of ejects restarts the one that is running rather
/// than starting another. The same pattern as VibeRes and ClipShot.
@Observable
@MainActor
final class MenuBarIconAnimator {
    /// Cancels a running ticker.
    typealias Cancel = () -> Void
    /// Starts a repeating ticker and returns how to stop it.
    typealias StartTicker = (_ interval: TimeInterval, _ tick: @escaping @MainActor @Sendable () -> Void) -> Cancel

    static let frameInterval: TimeInterval = 1.0 / 30

    /// Which animation is playing.
    enum Clip: Sendable, Equatable {
        /// A disk came off: crouch, launch, land on the empty bar.
        case eject
        /// A disk came back after a meeting: the slot closes and fills.
        case reconnect

        var duration: Double {
            switch self {
            case .eject: return LiftIcon.duration
            case .reconnect: return LiftIcon.reconnectDuration
            }
        }
    }

    /// Seconds into the animation; nil at rest.
    private(set) var phase: Double?
    /// The animation `phase` belongs to.
    private(set) var clip: Clip = .eject

    @ObservationIgnored private let now: () -> TimeInterval
    @ObservationIgnored private let reduceMotion: () -> Bool
    @ObservationIgnored private let startTicker: StartTicker
    @ObservationIgnored private var cancelTicker: Cancel?
    @ObservationIgnored private var startedAt: TimeInterval = 0

    /// The clock, the Reduce Motion setting and the ticker are injected so a
    /// test can step the animation frame by frame.
    init(
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion },
        startTicker: @escaping StartTicker = MenuBarIconAnimator.timerTicker
    ) {
        self.now = now
        self.reduceMotion = reduceMotion
        self.startTicker = startTicker
    }

    var isTicking: Bool { cancelTicker != nil }

    /// An eject pass has finished. Plays only when at least one disk actually
    /// came off: a failed eject, a stopped network backup or a pass with
    /// nothing to do is not an eject, and the icon must not celebrate one.
    func ejectFinished(ejectedDisks: Int) {
        guard ejectedDisks > 0 else { return }
        play(.eject)
    }

    /// A reconnect pass has finished, and the disk list has caught up with
    /// it. Plays only when a disk was actually mounted again: one unplugged
    /// during the meeting, or one that failed, is not a return.
    func reconnectFinished(reconnectedDisks: Int) {
        guard reconnectedDisks > 0 else { return }
        play(.reconnect)
    }

    /// Starts an animation, or starts over if one is already playing: the
    /// latest event wins, on the one ticker. With Reduce Motion on, the icon
    /// goes straight to its state.
    func play(_ clip: Clip = .eject) {
        guard !reduceMotion() else {
            stop()
            return
        }
        self.clip = clip
        startedAt = now()
        phase = 0
        if cancelTicker == nil {
            cancelTicker = startTicker(Self.frameInterval) { [weak self] in self?.tick() }
        }
    }

    func tick() {
        let elapsed = now() - startedAt
        if elapsed >= clip.duration {
            stop()
        } else {
            phase = elapsed
        }
    }

    func stop() {
        cancelTicker?()
        cancelTicker = nil
        phase = nil
    }

    /// A main run loop timer in the common modes, so the animation keeps
    /// running while the popover is tracking.
    nonisolated static func timerTicker(
        interval: TimeInterval,
        tick: @escaping @MainActor @Sendable () -> Void
    ) -> Cancel {
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }
}
