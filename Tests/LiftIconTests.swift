import AppKit
import XCTest
@testable import TMEjectGuardIcon

/// The menu bar icon is drawn in code, so nothing but these checks stops a
/// change from shipping an icon the menu bar cannot tint (a non-template image
/// stays black on a dark bar), one the menu bar shrinks (taller than 16 pt),
/// or one that looks smaller than its neighbours, which this one once did.
///
/// Sizes are measured in pixels at 2x, anchored on `externaldrive` at 15 pt,
/// the symbol this icon replaced and the size its neighbours draw at.
@MainActor
final class LiftIconTests: XCTestCase {
    struct Ink: Equatable {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        var width: Int { maxX < 0 ? 0 : maxX - minX + 1 }
        var height: Int { maxY < 0 ? 0 : maxY - minY + 1 }
    }

    /// Coverage over this counts as ink, the same threshold the menu bar
    /// comparisons were made with.
    private static let threshold: CGFloat = 0.16

    private static func bitmap(width: Int, height: Int) -> NSBitmapImageRep {
        NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    }

    /// An image drawn the way the status item draws it, at `scale`.
    private static func render(_ image: NSImage, scale: CGFloat = 2) -> NSBitmapImageRep {
        let rep = bitmap(width: Int(image.size.width * scale), height: Int(image.size.height * scale))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    private static func render(_ pose: LiftIcon.Pose, scale: CGFloat = 2) -> NSBitmapImageRep {
        render(LiftIcon.image(pose), scale: scale)
    }

    /// The pose drawn with room around it, so ink the canvas would clip shows.
    private static func unclipped(_ pose: LiftIcon.Pose, draw: ((CGContext) -> Void)? = nil,
                                  pad: CGFloat = 8) -> (rep: NSBitmapImageRep, canvas: Ink) {
        let size = NSSize(width: LiftIcon.canvas.width + 2 * pad, height: LiftIcon.canvas.height + 2 * pad)
        let image = NSImage(size: size, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: pad, y: pad)
            if let draw { draw(context) } else { LiftIcon.draw(pose, in: context) }
            return true
        }
        let p = Int(pad * 2)
        let canvas = Ink(minX: p, minY: p,
                         maxX: p + Int(LiftIcon.canvas.width * 2) - 1, maxY: p + Int(LiftIcon.canvas.height * 2) - 1)
        return (render(image), canvas)
    }

    private static func ink(_ rep: NSBitmapImageRep) -> Ink {
        var ink = Ink()
        for y in 0..<rep.pixelsHigh {
            for x in 0..<rep.pixelsWide where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > threshold {
                ink.minX = min(ink.minX, x); ink.maxX = max(ink.maxX, x)
                ink.minY = min(ink.minY, y); ink.maxY = max(ink.maxY, y)
            }
        }
        return ink
    }

    /// Pixels more than half covered in one image and not in the other.
    private static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> Int {
        guard a.pixelsWide == b.pixelsWide, a.pixelsHigh == b.pixelsHigh else { return .max }
        var count = 0
        for y in 0..<a.pixelsHigh {
            for x in 0..<a.pixelsWide {
                let ca = (a.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
                let cb = (b.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
                if ca != cb { count += 1 }
            }
        }
        return count
    }

    private static func symbol(_ name: String) -> NSBitmapImageRep {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)!
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 15, weight: .regular))!
        return render(image)
    }

    /// One entry per distinct pose. Reconnecting draws the waiting pose on
    /// purpose, see `testReconnectingKeepsTheSlot`.
    private static let resting: [(String, LiftIcon.Pose)] = [
        ("idle", LiftIcon.pose(.idle)),
        ("armed", LiftIcon.pose(.armed)),
        ("off", LiftIcon.pose(.off)),
        ("ejecting", LiftIcon.pose(.ejecting)),
        ("waiting to reconnect", LiftIcon.pose(.waitingToReconnect)),
        ("backing up", LiftIcon.pose(.backingUp, percent: 0.42, phase: 4, guarding: true)),
        ("backing up, unguarded", LiftIcon.pose(.backingUp, percent: 0.42, phase: 4)),
        ("backing up, sizing", LiftIcon.pose(.backingUp, percent: nil, phase: 3, guarding: true)),
    ]

    private static let frames: [Double] = Array(
        stride(from: 0.0, through: LiftIcon.duration, by: MenuBarIconAnimator.frameInterval))

    // MARK: - Template and canvas

    func testEveryStateAndFrameIsATemplateOnTheFixedCanvas() {
        for (name, pose) in Self.resting {
            let image = LiftIcon.image(pose)
            XCTAssertTrue(image.isTemplate, name)
            XCTAssertEqual(image.size, LiftIcon.canvas, name)
        }
        for t in Self.frames {
            let image = LiftIcon.image(LiftIcon.pose(at: t))
            XCTAssertTrue(image.isTemplate, "frame at \(t) s")
            XCTAssertEqual(image.size, LiftIcon.canvas, "frame at \(t) s")
        }
        XCTAssertLessThanOrEqual(LiftIcon.canvas.height, 16, "the menu bar scales a taller label down")
    }

    /// Nothing at rest is clipped by the canvas. The launch leaves the frame on
    /// purpose; every other frame stays inside it.
    func testEveryStateAndEveryFrameOnTheGroundFitsTheCanvas() {
        for (name, pose) in Self.resting {
            let (rep, canvas) = Self.unclipped(pose)
            let ink = Self.ink(rep)
            XCTAssertGreaterThanOrEqual(ink.minX, canvas.minX, name)
            XCTAssertGreaterThanOrEqual(ink.minY, canvas.minY, name)
            XCTAssertLessThanOrEqual(ink.maxX, canvas.maxX, name)
            XCTAssertLessThanOrEqual(ink.maxY, canvas.maxY, name)
        }
        // In the air from take-off until it lands; on the ground otherwise.
        for t in Self.frames where !(LiftIcon.Beat.launch.lowerBound...LiftIcon.Beat.fall.upperBound).contains(t) {
            let pose = LiftIcon.pose(at: t)
            let (rep, canvas) = Self.unclipped(pose)
            let ink = Self.ink(rep)
            // The hop may graze the top edge by a pixel; the sides and bottom never.
            XCTAssertGreaterThanOrEqual(ink.minY, canvas.minY - 2, "frame at \(t) s")
            XCTAssertGreaterThanOrEqual(ink.minX, canvas.minX, "frame at \(t) s")
            XCTAssertLessThanOrEqual(ink.maxX, canvas.maxX, "frame at \(t) s")
            XCTAssertLessThanOrEqual(ink.maxY, canvas.maxY, "frame at \(t) s")
        }
    }

    // MARK: - Size against the neighbours

    /// Ink 25 to 29 px tall at 2x in every resting state: the height of a
    /// regular SF Symbol at 15 pt, which is what the neighbours draw.
    func testInkHeightMatchesTheNeighbours() {
        for (name, pose) in Self.resting {
            let ink = Self.ink(Self.render(pose))
            XCTAssertTrue((25...29).contains(ink.height), "\(name) is \(ink.height) px tall at 2x")
        }
    }

    /// The body, not only the total ink, has to be as large as the drive it
    /// replaced: the triangle and the bar together are at least as tall as
    /// `externaldrive`, and the triangle on its own is as wide.
    func testBodyIsAsLargeAsExternaldrive() {
        let drive = Self.ink(Self.symbol("externaldrive"))
        XCTAssertEqual(drive.width, 35, "externaldrive moved; re-check the anchors")
        XCTAssertEqual(drive.height, 25, "externaldrive moved; re-check the anchors")

        let body = Self.ink(Self.render(LiftIcon.pose(.armed)))
        XCTAssertGreaterThanOrEqual(body.height, drive.height, "body \(body.width) x \(body.height) px")

        let triangleOnly = Self.ink(Self.unclipped(LiftIcon.Pose()) { context in
            context.setLineWidth(LiftIcon.line)
            context.setLineJoin(.round)
            context.addPath(LiftIcon.trianglePath(LiftIcon.Pose()))
            context.strokePath()
        }.rep)
        XCTAssertGreaterThanOrEqual(triangleOnly.height * 3, drive.height * 2,
                                    "triangle \(triangleOnly.width) x \(triangleOnly.height) px")
        XCTAssertGreaterThanOrEqual(triangleOnly.width, drive.width - 1,
                                    "triangle \(triangleOnly.width) x \(triangleOnly.height) px")
    }

    /// As wide as the drive in every state: never narrower by more than a
    /// pixel, never wider, except that a backup adds its badge, and then no
    /// wider than the `externaldrive.fill.badge.timemachine` it replaced.
    func testWidthMatchesExternaldrive() {
        let drive = Self.ink(Self.symbol("externaldrive"))
        let badged = Self.ink(Self.symbol("externaldrive.fill.badge.timemachine"))
        for (name, pose) in Self.resting {
            let ink = Self.ink(Self.render(pose))
            XCTAssertGreaterThanOrEqual(ink.width, drive.width - 1, "\(name) is \(ink.width) px wide")
            let limit = pose.badge ? badged.width : drive.width + 1
            XCTAssertLessThanOrEqual(ink.width, limit, "\(name) is \(ink.width) px wide")
        }
    }

    /// The line is as heavy as the drive's outline: 1.4 pt, about 3 px at 2x.
    func testLineWeightMatchesExternaldrive() {
        let rep = Self.render(LiftIcon.pose(.idle))
        let x = rep.pixelsWide / 2
        let run = (0..<rep.pixelsHigh).filter { y in
            y > Int(LiftIcon.bar.minY * 2) && (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.5
        }.count

        let drive = Self.symbol("externaldrive")
        let ink = Self.ink(drive)
        let y = ink.minY + ink.height * 3 / 4
        let outline = (ink.minX..<(ink.minX + ink.width / 2)).prefix {
            (drive.colorAt(x: $0, y: y)?.alphaComponent ?? 0) > 0.5
        }.count
        XCTAssertGreaterThan(run, 0)
        XCTAssertLessThanOrEqual(abs(run - outline), 1, "line \(run) px, externaldrive \(outline) px")
    }

    // MARK: - States read apart

    /// Every state has its own silhouette at 2x, by a real share of the glyph.
    func testEveryStateHasItsOwnSilhouette() {
        let states: [(String, LiftIcon.Pose)] = Self.resting.filter { !$0.0.hasPrefix("backing up,") }
        let images = states.map { Self.render($0.1) }
        for i in images.indices {
            for j in images.indices where j > i {
                let d = Self.difference(images[i], images[j])
                XCTAssertGreaterThanOrEqual(d, 60, "\(states[i].0) vs \(states[j].0): \(d) px")
            }
        }
    }

    /// Idle against armed was the weak pair: outline against fill alone does
    /// not read at 1x. A line against a slab and an outline against a solid
    /// triangle has to change a good share of the 1x icon.
    func testIdleAndArmedReadApartAt1x() {
        let idle = Self.render(LiftIcon.pose(.idle), scale: 1)
        let armed = Self.render(LiftIcon.pose(.armed), scale: 1)
        let armedInk = (0..<armed.pixelsHigh).flatMap { y in (0..<armed.pixelsWide).map { (y, $0) } }
            .filter { armed.colorAt(x: $0.1, y: $0.0).map { $0.alphaComponent > 0.5 } ?? false }.count
        let d = Self.difference(idle, armed)
        XCTAssertGreaterThanOrEqual(d * 3, armedInk, "\(d) of \(armedInk) px change at 1x")
    }

    /// The armed slab and the backup's slab sit on `LiftIcon.bar`'s whole
    /// pixel rows at 1x: crisp edges, and no jump when a backup starts.
    func testFullBarSitsOnItsPixelRowsAt1x() {
        func rows(_ pose: LiftIcon.Pose) -> [Bool] {
            let rep = Self.render(pose, scale: 1)
            let x = Int(LiftIcon.bar.minX + 4)
            return (Int(LiftIcon.bar.minY) - 1...Int(LiftIcon.bar.maxY)).map { y in
                (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9
            }
        }
        let expected = [false] + Array(repeating: true, count: Int(LiftIcon.bar.height)) + [false]
        XCTAssertEqual(rows(LiftIcon.pose(.armed)), expected, "armed")
        XCTAssertEqual(rows(LiftIcon.pose(.backingUp, percent: 1, phase: 4, guarding: true)), expected,
                       "backing up")
    }

    /// The bar follows Time Machine's figure, and the badge is there at every
    /// figure, including while it is still sizing the job up.
    func testBackupProgressFillsTheBar() {
        func covered(_ percent: Double) -> Int {
            let rep = Self.render(LiftIcon.pose(.backingUp, percent: percent, phase: 4))
            return (0..<rep.pixelsWide).filter { x in
                (rep.colorAt(x: x, y: Int(LiftIcon.trackY * 2))?.alphaComponent ?? 0) > 0.9
            }.count
        }
        XCTAssertLessThan(covered(0), covered(0.35))
        XCTAssertLessThan(covered(0.35), covered(0.78))
        XCTAssertLessThan(covered(0.78), covered(1))
        for phase in 0..<LiftIcon.breatheSteps {
            XCTAssertTrue(LiftIcon.pose(.backingUp, percent: nil, phase: phase).badge)
            XCTAssertTrue(LiftIcon.pose(.backingUp, percent: 0.5, phase: phase).badge)
        }
        XCTAssertFalse(LiftIcon.pose(.armed).badge)
    }

    // MARK: - The eject animation

    /// It starts as the guarded disk, waits a beat before anything moves, and
    /// its last frames are the resting icon, so starting and stopping show no
    /// jump.
    func testAnimationWaitsABeatAndEndsAtRest() {
        let armed = Self.render(LiftIcon.pose(.armed))
        XCTAssertEqual(LiftIcon.pose(at: 0), LiftIcon.pose(.armed))
        for t in stride(from: 0.0, through: 0.4, by: MenuBarIconAnimator.frameInterval) {
            XCTAssertEqual(Self.difference(Self.render(LiftIcon.pose(at: t)), armed), 0, "frame at \(t) s")
        }
        for (name, rest) in Self.resting where name != "ejecting" {
            let last = LiftIcon.pose(at: LiftIcon.duration - MenuBarIconAnimator.frameInterval, landingOn: rest)
            XCTAssertEqual(Self.difference(Self.render(last), Self.render(rest)), 0, name)
            XCTAssertEqual(LiftIcon.pose(at: LiftIcon.duration, landingOn: rest), rest, name)
        }
        XCTAssertLessThanOrEqual(LiftIcon.duration, 2)
    }

    /// The choreography: it crouches while the bar drains, leaves the frame,
    /// lands with a squash and hops once - the small overshoot - before it
    /// settles.
    func testAnimationCrouchesLaunchesAndBouncesBack() {
        let samples = stride(from: 0.0, through: LiftIcon.duration, by: 0.01).map { ($0, LiftIcon.pose(at: $0)) }
        let beforeLaunch = samples.filter { $0.0 < LiftIcon.Beat.launch.lowerBound }
        XCTAssertLessThan(beforeLaunch.map(\.1.stretch).min() ?? 1, 0.85, "a visible crouch")
        XCTAssertEqual(beforeLaunch.last?.1.fillTo ?? 1, 0, accuracy: 0.01, "drained by take-off")

        let gone = samples.filter { $0.1.lift < -(LiftIcon.baseY + LiftIcon.line) }
        XCTAssertFalse(gone.isEmpty, "the triangle leaves the frame")

        let landed = samples.filter { $0.0 > LiftIcon.Beat.fall.upperBound }
        XCTAssertLessThan(landed.map(\.1.stretch).min() ?? 1, 0.9, "it squashes as it lands")
        XCTAssertLessThan(landed.map(\.1.lift).min() ?? 0, -0.5, "and hops once")
        XCTAssertEqual(Double(landed.last?.1.lift ?? 1), 0, accuracy: 0.01, "then settles")
    }

    /// The animation comes back as the icon it settles into: outline on an
    /// empty bar after an eject left nothing guarded.
    func testAnimationLandsOnTheEmptyBar() {
        let landing = LiftIcon.pose(at: LiftIcon.Beat.fall.upperBound + 0.05)
        XCTAssertEqual(landing.solid, 0)
        XCTAssertEqual(landing.track, .line)
        XCTAssertEqual(landing.fillTo, 0)
    }

    // MARK: - The 1.5 reconnect states

    /// The disk is still away while it is mounted again, so reconnecting
    /// keeps the slot until the mount has worked and the animation plays.
    func testReconnectingKeepsTheSlot() {
        XCTAssertEqual(LiftIcon.pose(.waitingToReconnect).track, .slot)
        XCTAssertEqual(LiftIcon.pose(.reconnecting), LiftIcon.pose(.waitingToReconnect))
    }

    func testTheStateFollowsWhatTheAppIsDoing() {
        func state(ejecting: Bool = false, backingUp: Bool = false, reconnecting: Bool = false,
                   active: Bool = true, guarded: Bool = false, waiting: Bool = false) -> StatusIconState {
            StatusIconState.current(ejecting: ejecting, backingUp: backingUp, reconnecting: reconnecting,
                                    active: active, guardedTargets: guarded, waitingToReconnect: waiting)
        }
        XCTAssertEqual(state(), .idle)
        XCTAssertEqual(state(guarded: true), .armed)
        XCTAssertEqual(state(waiting: true), .waitingToReconnect)
        XCTAssertEqual(state(guarded: true, waiting: true), .armed, "another guarded disk is still there")
        XCTAssertEqual(state(active: false, waiting: true), .off)
        XCTAssertEqual(state(reconnecting: true, active: false, waiting: true), .reconnecting,
                       "a reconnect runs with guarding off too")
        // A locked Time Machine disk comes back through a backup to it.
        XCTAssertEqual(state(backingUp: true, reconnecting: true), .backingUp)
        XCTAssertEqual(state(ejecting: true, backingUp: true, reconnecting: true), .ejecting)
    }

    /// An unmount for a meeting plays the eject animation and settles on the
    /// state it leaves behind.
    func testAnUnmountLandsOnWaitingToReconnect() {
        let rest = LiftIcon.pose(.waitingToReconnect)
        XCTAssertEqual(LiftIcon.pose(at: LiftIcon.duration, landingOn: rest), rest)
    }

    // MARK: - The reconnect animation

    private static let reconnectFrames: [Double] = Array(
        stride(from: 0.0, through: LiftIcon.reconnectDuration, by: MenuBarIconAnimator.frameInterval))

    /// Every frame is a template image on the fixed canvas, with no ink
    /// outside it: the settle never leaves the frame.
    func testEveryReconnectFrameFitsTheCanvas() {
        for rest in [LiftIcon.pose(.armed), LiftIcon.pose(.idle)] {
            for t in Self.reconnectFrames {
                let pose = LiftIcon.pose(reconnectingAt: t, landingOn: rest)
                let image = LiftIcon.image(pose)
                XCTAssertTrue(image.isTemplate, "frame at \(t) s")
                XCTAssertEqual(image.size, LiftIcon.canvas, "frame at \(t) s")
                let (rep, canvas) = Self.unclipped(pose)
                let ink = Self.ink(rep)
                XCTAssertGreaterThanOrEqual(ink.minX, canvas.minX, "frame at \(t) s")
                XCTAssertGreaterThanOrEqual(ink.minY, canvas.minY, "frame at \(t) s")
                XCTAssertLessThanOrEqual(ink.maxX, canvas.maxX, "frame at \(t) s")
                XCTAssertLessThanOrEqual(ink.maxY, canvas.maxY, "frame at \(t) s")
            }
        }
    }

    /// It starts as the slot the icon waited on, so starting is invisible,
    /// and ends exactly on the state the disk came back to: armed, or the
    /// empty line when nothing is guarded.
    func testReconnectStartsOnTheSlotAndEndsOnItsState() {
        let waiting = Self.render(LiftIcon.pose(.waitingToReconnect))
        XCTAssertEqual(Self.difference(Self.render(LiftIcon.pose(reconnectingAt: 0)), waiting), 0)
        XCTAssertEqual(Self.difference(Self.render(LiftIcon.pose(reconnectingAt: 0.25)), waiting), 0,
                       "a beat before anything moves")

        for (name, rest) in [("armed", LiftIcon.pose(.armed)), ("idle", LiftIcon.pose(.idle))] {
            XCTAssertEqual(LiftIcon.pose(reconnectingAt: LiftIcon.reconnectDuration, landingOn: rest), rest, name)
            let last = LiftIcon.pose(reconnectingAt: LiftIcon.reconnectDuration - MenuBarIconAnimator.frameInterval,
                                     landingOn: rest)
            XCTAssertLessThanOrEqual(Self.difference(Self.render(last), Self.render(rest)), 2, name)
        }
        XCTAssertGreaterThanOrEqual(LiftIcon.reconnectDuration, 1.5)
        XCTAssertLessThanOrEqual(LiftIcon.reconnectDuration, 2.4)
    }

    /// The choreography: the gaps close, the slot fills, and the triangle
    /// presses down, comes up solid and overshoots only a little.
    func testReconnectClosesFillsAndSettles() {
        let samples = stride(from: 0.0, through: LiftIcon.reconnectDuration, by: 0.01)
            .map { LiftIcon.pose(reconnectingAt: $0) }
        XCTAssertLessThan(samples.map(\.stretch).min() ?? 1, 0.9, "a visible press")
        XCTAssertLessThanOrEqual(samples.map(\.stretch).max() ?? 1, 1 + LiftIcon.releaseOvershoot + 0.001)
        XCTAssertEqual(samples.map(\.lift).max() ?? 1, 0, "it never leaves the bar")
        let filling = samples.filter { $0.slotFill > 0 && $0.slotFill < 1 }
        XCTAssertTrue(filling.allSatisfy { $0.slotClosed > 0.99 }, "the gaps close before it fills")
    }

    /// A backup that starts as the disk comes back has its own state.
    func testReconnectGivesWayToABackup() {
        let backup = LiftIcon.pose(.backingUp, percent: 0.1, phase: 4, guarding: true)
        XCTAssertEqual(LiftIcon.pose(reconnectingAt: 0.5, landingOn: backup), backup)
    }

    // MARK: - Pixel snap

    /// The base, a 1.4 pt line, sits on a device pixel row at 1x and 2x, in
    /// every resting pose: one solid row at 1x rather than two half-grey
    /// ones, and no half-covered row at 2x.
    func testTheBaseSitsOnWholePixelRows() {
        for scale in [1, 2] {
            for (name, pose) in Self.resting where !pose.slashed {
                let rep = Self.render(pose, scale: CGFloat(scale))
                let x = Int(LiftIcon.apex.x) * scale
                let ys = (5 * scale)...(9 * scale + scale - 1)
                let alphas = ys.map { rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0 }
                let solid = alphas.filter { $0 > 0.75 }.count
                let grey = alphas.filter { $0 > 0.3 && $0 <= 0.75 }.count
                XCTAssertEqual(grey, 0, "\(name) at \(scale)x: \(alphas.map { Int($0 * 100) })")
                if pose.solid == 0 {
                    XCTAssertEqual(solid, scale == 1 ? 1 : 3, "\(name) at \(scale)x: \(alphas.map { Int($0 * 100) })")
                }
            }
        }
        XCTAssertEqual(LiftIcon.baseOffset(scale: 1), 0.5)
        XCTAssertEqual(LiftIcon.baseOffset(scale: 2), 0.25)
    }
}
