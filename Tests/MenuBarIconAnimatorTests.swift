import XCTest
@testable import TMEjectGuardIcon

/// The eject animation runs on a ticker that must exist only while it plays,
/// and must play only when a disk actually came off. Clock, Reduce Motion and
/// ticker are injected, so these step it frame by frame without waiting and
/// without a real timer.
@MainActor
final class MenuBarIconAnimatorTests: XCTestCase {
    /// A fake clock and ticker: `fire(after:)` is one frame.
    @MainActor
    final class Rig {
        var time: TimeInterval = 100
        var started = 0
        var cancelled = 0
        var tick: (@MainActor @Sendable () -> Void)?
        var reduceMotion = false

        func animator() -> MenuBarIconAnimator {
            MenuBarIconAnimator(
                now: { self.time },
                reduceMotion: { self.reduceMotion },
                startTicker: { _, tick in
                    self.started += 1
                    self.tick = tick
                    return { self.cancelled += 1; self.tick = nil }
                })
        }

        func fire(after seconds: TimeInterval) {
            time += seconds
            tick?()
        }
    }

    func testNothingRunsAtRest() {
        let rig = Rig()
        let animator = rig.animator()
        XCTAssertFalse(animator.isTicking)
        XCTAssertNil(animator.phase)
        XCTAssertEqual(rig.started, 0)
    }

    /// A failed eject, or a pass that only stopped a backup to a share, ejected
    /// nothing. The icon must not celebrate it.
    func testAnEjectThatEjectedNothingDoesNotPlay() {
        let rig = Rig()
        let animator = rig.animator()
        animator.ejectFinished(ejectedDisks: 0)
        XCTAssertFalse(animator.isTicking)
        XCTAssertNil(animator.phase)
        XCTAssertEqual(rig.started, 0)
    }

    func testARealEjectPlaysAndAdvances() {
        let rig = Rig()
        let animator = rig.animator()
        animator.ejectFinished(ejectedDisks: 1)
        XCTAssertTrue(animator.isTicking)
        XCTAssertEqual(animator.phase, 0)
        rig.fire(after: 0.25)
        XCTAssertEqual(animator.phase, 0.25)
        XCTAssertEqual(rig.started, 1)
    }

    func testTheAnimationEndsAtRestWithNoTickerLeft() {
        let rig = Rig()
        let animator = rig.animator()
        animator.ejectFinished(ejectedDisks: 2)
        let frames = Int((LiftIcon.duration / MenuBarIconAnimator.frameInterval).rounded(.up)) + 1
        for _ in 0..<frames { rig.fire(after: MenuBarIconAnimator.frameInterval) }

        XCTAssertNil(animator.phase)
        XCTAssertFalse(animator.isTicking)
        XCTAssertEqual(rig.started, 1)
        XCTAssertEqual(rig.cancelled, 1)
        XCTAssertNil(rig.tick)
    }

    func testABurstOfEjectsRestartsInsteadOfStacking() {
        let rig = Rig()
        let animator = rig.animator()
        animator.ejectFinished(ejectedDisks: 1)
        rig.fire(after: 0.6)
        animator.ejectFinished(ejectedDisks: 1)
        XCTAssertEqual(animator.phase, 0, "the second eject starts the animation over")
        animator.ejectFinished(ejectedDisks: 1)
        rig.fire(after: 0.5)

        XCTAssertEqual(rig.started, 1, "one ticker, however many ejects")
        XCTAssertEqual(animator.phase, 0.5)
        rig.fire(after: LiftIcon.duration)
        XCTAssertNil(animator.phase)
        XCTAssertEqual(rig.cancelled, 1)
    }

    func testReduceMotionGoesStraightToTheState() {
        let rig = Rig()
        rig.reduceMotion = true
        let animator = rig.animator()
        animator.ejectFinished(ejectedDisks: 1)

        XCTAssertNil(animator.phase)
        XCTAssertFalse(animator.isTicking)
        XCTAssertEqual(rig.started, 0)
    }

    /// Turning Reduce Motion on mid-animation: the next eject stops it at once.
    func testReduceMotionStopsOneAlreadyPlaying() {
        let rig = Rig()
        let animator = rig.animator()
        animator.ejectFinished(ejectedDisks: 1)
        rig.reduceMotion = true
        animator.ejectFinished(ejectedDisks: 1)

        XCTAssertNil(animator.phase)
        XCTAssertFalse(animator.isTicking)
        XCTAssertEqual(rig.cancelled, 1)
    }

    /// The real ticker is a run loop timer that is gone once cancelled.
    func testTheRealTickerStopsWhenCancelled() {
        @MainActor final class Count { var ticks = 0 }
        let count = Count()
        let cancel = MenuBarIconAnimator.timerTicker(interval: 0.01) { count.ticks += 1 }
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        cancel()
        let after = count.ticks
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        XCTAssertGreaterThan(after, 0)
        XCTAssertEqual(count.ticks, after, "no tick after cancel")
    }
}
