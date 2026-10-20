// The menu bar icon: Eject Guard's own symbol, the app icon in miniature.
//
// An eject triangle over a bar. The bar is the state: a thin empty line while
// nothing is guarded, a solid slab while a disk is guarded, filling up while
// Time Machine writes. When the guard ejects a disk, the triangle crouches as
// the bar drains, launches out of the frame, and drops back onto an empty bar.
//
// Drawn with Core Graphics as one template image per pose, so it is sharp at
// every backing scale, every animation frame comes from the same paths, and
// the menu bar tints it like any system symbol: on light, dark, highlighted
// and tinted-wallpaper bars. One ink; only coverage and opacity vary.

import AppKit

/// What the icon is saying right now.
enum StatusIconState: CaseIterable, Sendable {
    case ejecting, backingUp, armed, idle, off
    /// Mounting a disk back after the meeting it was unmounted for.
    case reconnecting
    /// A disk unmounted for a meeting, to be mounted again once it is over.
    case waitingToReconnect

    /// The state for what the app is doing. First match wins.
    ///
    /// A backup ranks above a reconnect: a locked Time Machine disk is
    /// brought back by starting a backup to it, and the icon then says the
    /// more specific thing. A reconnect ranks above off, since it runs
    /// whether or not guarding is on. Something else still guarded and
    /// plugged in ranks above a disk waiting to come back.
    static func current(ejecting: Bool, backingUp: Bool, reconnecting: Bool, active: Bool,
                        guardedTargets: Bool, waitingToReconnect: Bool) -> StatusIconState {
        if ejecting { return .ejecting }
        if backingUp { return .backingUp }
        if reconnecting { return .reconnecting }
        if !active { return .off }
        if guardedTargets { return .armed }
        if waitingToReconnect { return .waitingToReconnect }
        return .idle
    }
}

enum LiftIcon {
    /// The status item's frame, in points, y down. The menu bar scales down a
    /// label taller than 16 pt, and a fixed width keeps the status item from
    /// changing width between states.
    static let canvas = CGSize(width: 22, height: 16)

    // MARK: Geometry (points, y down)

    /// The weight of a regular SF Symbol at 15 pt, the size the neighbours in
    /// the menu bar draw at.
    static let line: CGFloat = 1.4

    /// The eject triangle. As wide as the bar, so the glyph's body is as wide
    /// as the `externaldrive` it replaces.
    static let apex = CGPoint(x: 11, y: 0.9)
    static let baseY: CGFloat = 8.0
    static let halfWidth: CGFloat = 8.0

    /// The full bar: a solid slab while a disk is guarded. On whole points,
    /// so it is crisp at 1x, with a clear pixel row between it and the
    /// triangle.
    static let bar = CGRect(x: 2.8, y: 10.0, width: 16.4, height: 4.0)
    static let barRadius: CGFloat = 1.6

    /// The empty bar is a line across the slab, so idle and armed differ in
    /// shape and not only in fill: a line against a slab reads at 1x, where
    /// an outline against a fill does not. Half a point below the slab's
    /// middle, so it covers one whole pixel row at 1x rather than two halves.
    static let trackY: CGFloat = 12.5
    static let trackEnds: ClosedRange<CGFloat> = (bar.minX + line / 2)...(bar.maxX - line / 2)

    /// While Time Machine writes, the whole bar shows faintly behind the
    /// progress, the way the app icon draws it.
    static let dimTrackOpacity = 0.3
    /// The least of the bar backup progress fills, so 0 % is not empty.
    static let minimumFill: CGFloat = 1.6

    /// The off slash, and the gap cut around it so it reads in front.
    static let slash = (from: CGPoint(x: 4.3, y: 0.7), to: CGPoint(x: 18.0, y: 13.1))
    static let slashGap: CGFloat = 3.4

    /// While Time Machine writes, its mark sits in the bottom-right corner
    /// the way an SF Symbol badge does: the clock with the arrow round it,
    /// as on the `externaldrive.fill.badge.timemachine` this icon replaced,
    /// with a gap cut around it so it reads in front. Drawn as paths rather
    /// than the system glyph, so it is centred and weighted for this canvas
    /// and does not change with the OS. The bar shortens to end before it.
    enum Badge {
        static let center = CGPoint(x: 18.2, y: 10.75)
        static let radius: CGFloat = 3.0
        static let weight: CGFloat = 1.1
        static let handWeight: CGFloat = 1.0
        /// The arc runs clockwise from the arrowhead on the left, over the
        /// top, and stops short of it in the lower left. Degrees, y down.
        static let arc = (from: 180.0, to: 495.0)
        static let gap: CGFloat = 1.0
    }
    static let badgeBar = CGRect(x: 2.8, y: 10.0, width: 10.6, height: 4.0)

    /// Ejecting: the triangle a little off the bar, speed lines where the bar was.
    static let ejectingLift: CGFloat = -0.2
    static let speedLines: [(y: CGFloat, ends: ClosedRange<CGFloat>)] = [
        (11.0, 6.0...16.0),
        (13.7, 8.6...13.4),
    ]

    // MARK: Poses

    enum Track: Hashable, Sendable {
        /// The empty bar: a thin line.
        case line
        /// The whole bar, faint, behind the progress.
        case dim
        /// No bar at all: speed lines take its place.
        case none
    }

    /// Everything that varies between states and frames. Hashable, so resting
    /// poses can be cached.
    struct Pose: Hashable, Sendable {
        /// Vertical offset of the triangle; negative is up.
        var lift: CGFloat = 0
        /// Vertical scale of the triangle about its base: under 1 crouches,
        /// over 1 stretches. Its width moves the other way, so it squashes
        /// rather than shrinks.
        var stretch: CGFloat = 1
        /// 0 an outline, 1 solid.
        var solid: Double = 0
        var track: Track = .line
        /// The solid part of the bar, as fractions of its width.
        var fillFrom: Double = 0
        var fillTo: Double = 0
        var fillOpacity: Double = 1
        /// The fill is a segment travelling across, cut by the bar's ends.
        var sweeping = false
        /// Speed lines under the triangle, 0...1, and how far they have moved
        /// from where the ejecting state draws them; negative is up.
        var speed: Double = 0
        var speedOffset: CGFloat = 0
        var slashed = false
        /// The Time Machine badge, and the shorter bar that goes with it.
        var badge = false
    }

    /// The resting pose of each state.
    ///
    /// - Parameters:
    ///   - percent: 0...1 while Time Machine knows how far it is, nil while it
    ///     is still sizing the job up.
    ///   - phase: the step of the backup breathing, see `breatheSteps`.
    ///   - guarding: the triangle is solid only while a disk is guarded, so a
    ///     backup nobody guards does not look armed.
    static func pose(_ state: StatusIconState, percent: Double? = nil, phase: Int = 0,
                     guarding: Bool = false) -> Pose {
        switch state {
        // The two reconnect states have no art of their own. The eject
        // animation lands on the empty bar, and until the disk is mounted
        // again nothing guarded is plugged in, so they keep that pose. What
        // tells them apart is the label and the popover row ("Reconnects at
        // 14:50"). Claiming armed before the mount succeeds would promise
        // the disk is back, and the eject pose would read as one more eject.
        case .idle, .waitingToReconnect, .reconnecting:
            return Pose()
        case .armed:
            return Pose(solid: 1, fillTo: 1)
        case .off:
            return Pose(slashed: true)
        case .ejecting:
            return Pose(lift: ejectingLift, solid: 1, track: .none, speed: 1)
        case .backingUp:
            let t = Double(((phase % breatheSteps) + breatheSteps) % breatheSteps) / Double(breatheSteps)
            // 0.55 at the ends of the cycle, 1 in the middle: progress can sit
            // on one number for minutes, and a still icon reads as a dead one.
            let breath = 0.55 + 0.45 * (0.5 - 0.5 * cos(2 * .pi * t))
            var pose = Pose(solid: guarding ? 1 : 0, track: .dim, fillOpacity: breath, badge: true)
            if let percent {
                pose.fillTo = min(1, max(0, percent))
            } else {
                // Until Time Machine has a figure, a short segment travels
                // across: working, without claiming to know how far.
                let width = 0.35
                pose.fillFrom = 1.35 * t - width
                pose.fillTo = pose.fillFrom + width
                pose.sweeping = true
            }
            return pose
        }
    }

    /// Steps of the backup breathing cycle. Eight steps a quarter second apart:
    /// slow enough to read as breathing rather than blinking.
    static let breatheSteps = 8

    // MARK: Eject animation

    /// Length of the eject animation, in seconds. The last frames are the
    /// resting pose, so stopping is invisible.
    static let duration: Double = 2.0

    /// The beats, in seconds. It waits a beat so the eye finds it, crouches
    /// slowly enough to notice while the bar drains, launches out of the
    /// frame trailing speed lines, and drops back onto the empty bar with a
    /// squash and a little hop.
    enum Beat {
        static let crouch = 0.45...1.0
        static let drain = 0.45...1.0
        static let spring = 1.0...1.14
        static let launch = 1.0...1.3
        /// Out of the frame in between; the triangle comes back in its
        /// resting style.
        static let fall = 1.38...1.64
        static let squash = 1.62...1.8
        static let hop = 1.74...1.96
    }

    /// How far above its rest the triangle is out of the frame.
    static let launchHeight: CGFloat = 13
    /// How deep the crouch goes, and how far the launch stretches.
    static let crouchDepth: CGFloat = 0.22
    static let launchStretch: CGFloat = 0.18
    static let landingSquash: CGFloat = 0.2
    static let hopHeight: CGFloat = 1.0

    /// A frame of the eject animation, landing on `rest`: whatever the icon
    /// shows once it ends, usually the idle pose.
    static func pose(at t: Double, landingOn rest: Pose = Pose()) -> Pose {
        guard t < duration else { return rest }
        // Starts as the guarded disk it is ejecting: solid, full bar.
        var pose = Pose(solid: 1, fillTo: 1)

        if t < Beat.launch.lowerBound {
            pose.stretch = 1 - crouchDepth * CGFloat(Curve.easeInOut(Curve.progress(t, Beat.crouch)))
        } else if t < Beat.fall.lowerBound {
            // Springs out of the crouch into a stretch as it takes off.
            let spring = CGFloat(Curve.easeOut(Curve.progress(t, Beat.spring)))
            pose.stretch = 1 - crouchDepth + (crouchDepth + launchStretch) * spring
            pose.lift = -launchHeight * CGFloat(Curve.easeIn(Curve.progress(t, Beat.launch)))
        } else {
            let fall = Curve.progress(t, Beat.fall)
            pose.stretch = 1 + launchStretch * CGFloat(1 - fall)
                - landingSquash * CGFloat(Curve.bump(Curve.progress(t, Beat.squash)))
            pose.lift = -launchHeight * CGFloat(1 - Curve.easeIn(fall))
                - hopHeight * CGFloat(Curve.bump(Curve.progress(t, Beat.hop)))
        }

        // The bar drains right to left while it crouches.
        pose.fillTo = 1 - Curve.easeInOut(Curve.progress(t, Beat.drain))

        // Speed lines trail the launch, once it is clear of the bar.
        if t >= Beat.launch.lowerBound && t < Beat.fall.lowerBound {
            pose.speed = Double(min(1, max(0, (-pose.lift - 2.5) / 2)))
            pose.speedOffset = pose.lift
        }

        // Out of the frame, it changes into its resting self, so it comes
        // back as the icon it settles into.
        if t >= Beat.fall.lowerBound {
            pose.solid = rest.solid
            pose.track = rest.track
            pose.fillFrom = rest.fillFrom
            pose.fillTo = rest.fillTo
            pose.fillOpacity = rest.fillOpacity
            pose.sweeping = rest.sweeping
            pose.slashed = rest.slashed
            pose.badge = rest.badge
        }
        return pose
    }

    // MARK: Drawing

    /// Draws `pose` into `context`, whose user space is the 22 x 16 pt canvas
    /// with y down. Everything goes into one transparency layer, so the gap
    /// cut around the slash never reaches what is behind the image.
    static func draw(_ pose: Pose, in context: CGContext) {
        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.setStrokeColor(CGColor(gray: 0, alpha: 1))
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.beginTransparencyLayer(auxiliaryInfo: nil)

        drawBar(pose, in: context)
        drawTriangle(pose, in: context)
        if pose.badge { drawBadge(in: context) }

        if pose.speed > 0 {
            context.saveGState()
            context.setAlpha(pose.speed)
            for speedLine in speedLines {
                let y = speedLine.y + pose.speedOffset
                let path = CGMutablePath()
                path.move(to: CGPoint(x: speedLine.ends.lowerBound, y: y))
                path.addLine(to: CGPoint(x: speedLine.ends.upperBound, y: y))
                stroke(path, line, in: context)
            }
            context.restoreGState()
        }

        if pose.slashed {
            let path = CGMutablePath()
            path.move(to: slash.from)
            path.addLine(to: slash.to)
            erase(path.copy(strokingWithWidth: slashGap, lineCap: .round, lineJoin: .round, miterLimit: 10),
                  in: context)
            stroke(path, line, in: context)
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }

    /// The triangle on its own, in the pose's place.
    static func trianglePath(_ pose: Pose) -> CGPath {
        // Squash and stretch about the middle of the base, keeping the area.
        let sx = 1 / max(0.5, pose.stretch)
        let width = halfWidth * (1 + (sx - 1) * 0.5)
        let top = baseY - (baseY - apex.y) * pose.stretch
        let path = CGMutablePath()
        path.move(to: CGPoint(x: apex.x, y: top + pose.lift))
        path.addLine(to: CGPoint(x: apex.x + width, y: baseY + pose.lift))
        path.addLine(to: CGPoint(x: apex.x - width, y: baseY + pose.lift))
        path.closeSubpath()
        return path
    }

    private static func drawTriangle(_ pose: Pose, in context: CGContext) {
        let path = trianglePath(pose)
        // The outline is always drawn, so the solid triangle has the same
        // rounded corners and the same extent as the empty one.
        stroke(path, line, in: context)
        if pose.solid > 0 {
            context.saveGState()
            context.setAlpha(pose.solid)
            context.addPath(path)
            context.fillPath()
            context.restoreGState()
        }
    }

    private static func drawBar(_ pose: Pose, in context: CGContext) {
        let bar = pose.badge ? Self.badgeBar : Self.bar
        let slab = CGPath(roundedRect: bar, cornerWidth: barRadius, cornerHeight: barRadius, transform: nil)
        switch pose.track {
        case .line:
            let path = CGMutablePath()
            path.move(to: CGPoint(x: trackEnds.lowerBound, y: trackY))
            path.addLine(to: CGPoint(x: trackEnds.upperBound, y: trackY))
            stroke(path, line, in: context)
        case .dim:
            context.saveGState()
            context.setAlpha(dimTrackOpacity)
            context.addPath(slab)
            context.fillPath()
            context.restoreGState()
        case .none:
            break
        }

        let from = max(0, pose.fillFrom), to = min(1, pose.fillTo)
        context.saveGState()
        defer { context.restoreGState() }
        context.setAlpha(pose.fillOpacity)
        if pose.sweeping {
            guard to > from else { return }
            context.addPath(slab)
            context.clip()
            context.fill(CGRect(x: bar.minX + bar.width * from, y: bar.minY,
                                width: bar.width * (to - from), height: bar.height))
            return
        }
        let fraction = to - from
        var height = bar.height
        var midY = bar.midY
        if pose.track == .line {
            // Draining into the empty line: the last of it thins down to the
            // line itself, so it runs out instead of ending in a stub, while
            // a full fill sits on the slab.
            let u = min(1, max(0, fraction / 0.3))
            let s = CGFloat(u * u * (3 - 2 * u))
            height = line + (bar.height - line) * s
            midY = trackY + (bar.midY - trackY) * s
        }
        // Backup progress at 0 % still shows a sliver, so the bar never
        // looks like nothing is happening.
        let width = max(pose.track == .dim ? minimumFill : height, bar.width * fraction)
        guard fraction > 0 || pose.track == .dim else { return }
        let x = min(bar.minX + bar.width * from, bar.maxX - width)
        let rect = CGRect(x: x, y: midY - height / 2, width: width, height: height)
        let radius = min(barRadius, height / 2)
        context.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.fillPath()
    }

    /// The Time Machine mark: an arc with an arrowhead, and two clock hands.
    static func badgeParts() -> (arc: CGPath, arrow: CGPath, hands: CGPath) {
        let c = Badge.center, r = Badge.radius
        let arc = CGMutablePath()
        arc.addArc(center: c, radius: r, startAngle: Badge.arc.from * .pi / 180,
                   endAngle: Badge.arc.to * .pi / 180, clockwise: false)
        // Pointing down: the arc turns anticlockwise, back in time.
        let arrow = CGMutablePath()
        arrow.addLines(between: [CGPoint(x: c.x - r - 1.45, y: c.y - 0.3),
                                 CGPoint(x: c.x - r + 1.45, y: c.y - 0.3),
                                 CGPoint(x: c.x - r, y: c.y + 1.5)])
        arrow.closeSubpath()
        let hands = CGMutablePath()
        hands.addLines(between: [CGPoint(x: c.x, y: c.y - 1.6), c, CGPoint(x: c.x + 1.1, y: c.y + 1.1)])
        return (arc, arrow, hands)
    }

    private static func drawBadge(in context: CGContext) {
        let parts = badgeParts()
        let c = Badge.center
        let outer = Badge.radius + Badge.weight / 2 + Badge.gap
        erase(CGPath(ellipseIn: CGRect(x: c.x - outer, y: c.y - outer, width: outer * 2, height: outer * 2),
                     transform: nil), in: context)
        erase(parts.arrow.copy(strokingWithWidth: 2 * Badge.gap + 0.6, lineCap: .round, lineJoin: .round,
                               miterLimit: 10), in: context)
        stroke(parts.arc, Badge.weight, in: context)
        context.addPath(parts.arrow)
        context.fillPath()
        // A thin stroke over the fill rounds the arrowhead's corners.
        stroke(parts.arrow, 0.6, in: context)
        stroke(parts.hands, Badge.handWeight, in: context)
    }

    private static func stroke(_ path: CGPath, _ width: CGFloat, in context: CGContext) {
        context.addPath(path.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10))
        context.fillPath()
    }

    private static func erase(_ path: CGPath, in context: CGContext) {
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.addPath(path)
        context.fillPath()
        context.restoreGState()
    }

    // MARK: Images

    @MainActor private static var cache: [Pose: NSImage] = [:]

    /// The template image of `pose`, drawn at whatever scale it is displayed,
    /// so it is crisp at 1x and 2x. Resting poses repeat, so images are
    /// cached; animation frames rarely do, so the cache is kept small.
    @MainActor
    static func image(_ pose: Pose) -> NSImage {
        if let image = cache[pose] { return image }
        let image = NSImage(size: canvas, flipped: true) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(pose, in: context)
            return true
        }
        image.isTemplate = true
        if cache.count >= 64 { cache.removeAll() }
        cache[pose] = image
        return image
    }

    // MARK: Curves

    /// Timestamp-driven curves. Each hits its end points exactly, so a pose at
    /// the end of a beat is the next beat's start.
    enum Curve {
        static func progress(_ t: Double, _ beat: ClosedRange<Double>) -> Double {
            min(1, max(0, (t - beat.lowerBound) / (beat.upperBound - beat.lowerBound)))
        }

        static func easeIn(_ u: Double) -> Double { u * u * u }
        static func easeOut(_ u: Double) -> Double { 1 - pow(1 - u, 3) }
        static func easeInOut(_ u: Double) -> Double { u < 0.5 ? 4 * u * u * u : 1 - pow(-2 * u + 2, 3) / 2 }
        /// 0 -> 1 -> 0.
        static func bump(_ u: Double) -> Double { sin(.pi * u) }
    }
}
