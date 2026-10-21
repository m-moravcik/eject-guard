// README motion demo: renders the hero animation frame by frame.
//
// A guarded Time Machine disk is backing up, a meeting is about to start, the
// guard stops the backup and unmounts the disk, and the menu bar icon plays
// its eject animation onto the dashed slot of a disk waiting to reconnect.
// Once the meeting is over the disk is mounted again, the slot fills, and
// Time Machine carries on. Time is compressed; every frame is the real
// popover and the real menu bar icon drawn from demo state, rendered
// offscreen. Nothing is read from or done to this Mac's disks, calendar or
// Time Machine.
//
// Frames are written as PNG; readme-motion.sh turns them into GIF and MP4.

import AppKit
import EventKit
import SwiftUI

/// Seconds of the loop, and where each beat starts.
private enum Beat {
    static let length = 10.0
    static let tick54 = 0.6
    static let tick55 = 1.2
    /// The eject timer fires: an eject pass is running.
    static let fire = 1.4
    /// The popover's two second poll sees the backup stopped.
    static let backupStopped = 1.9
    /// The disk is unmounted; the icon plays its eject animation and lands
    /// on the slot.
    static let unmounted = 2.4
    /// The meeting has started.
    static let meetingStarted = 4.9
    /// The meeting is over and the reconnect pass is mounting the disk.
    static let reconnecting = 5.9
    /// The disk list shows the disk back; the icon settles onto it.
    static let reconnected = 6.4
    /// The popover's next poll sees the backup the reconnect started, still
    /// sized up, once the settle is over.
    static let backupStarts = 8.3
    static let backupCounting = 8.9
    /// From here the end state dissolves into the first frame, so the loop
    /// has no seam.
    static let seam = 9.4
}

private func today(_ hour: Int, _ minute: Int) -> Date {
    Foundation.Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: Date())!
}

/// Everything that changes over the loop, for one instant.
private struct MotionFrame {
    var now: Date
    var mounted = true
    /// Outer nil: no backup. Inner nil: still sizing it up.
    var backup: Double?? = .some(0.42)
    var meetingTitle = "Design review"
    var meetingStart = today(11, 0)
    var ejectDate: Date? = today(10, 55)
    var busy = false
    /// The meeting's end, while the disk waits to be mounted again.
    var reconnectsAt: Date?
    var reconnecting = false
    /// The icon animation playing, and seconds into it.
    var clip: MenuBarIconAnimator.Clip = .eject
    var animationPhase: Double?

    static func at(_ t: Double) -> MotionFrame {
        var f = MotionFrame(now: today(10, 53))
        if t >= Beat.tick54 { f.now = today(10, 54); f.backup = .some(0.421) }
        if t >= Beat.tick55 { f.now = today(10, 55); f.backup = .some(0.422) }
        if t >= Beat.fire { f.busy = true }
        if t >= Beat.backupStopped { f.backup = .none }
        if t >= Beat.unmounted {
            f.busy = false
            f.mounted = false
            f.reconnectsAt = today(11, 45)
            // Acted on, and nothing guarded is connected: no eject time.
            f.ejectDate = nil
            if t < Beat.unmounted + LiftIcon.duration { f.animationPhase = t - Beat.unmounted }
        }
        if t >= Beat.meetingStarted {
            f.now = today(11, 0)
            f.meetingTitle = "Team sync"
            f.meetingStart = today(14, 0)
        }
        // The pending entry stays in the controller's config until the disk
        // list catches up with the mount, as in `GuardController.reconnect`.
        if t >= Beat.reconnecting {
            f.now = today(11, 45)
            f.reconnecting = true
        }
        if t >= Beat.reconnected {
            f.reconnecting = false
            f.reconnectsAt = nil
            f.mounted = true
            f.ejectDate = today(13, 55)
            f.clip = .reconnect
            if t < Beat.reconnected + LiftIcon.reconnectDuration { f.animationPhase = t - Beat.reconnected }
        }
        if t >= Beat.backupStarts { f.backup = .some(nil) }
        if t >= Beat.backupCounting { f.now = today(11, 46); f.backup = .some(0.124) }
        return f
    }
}

@MainActor
func renderMotion(outputDir: String, scheme: ColorScheme, fps: Int) {
    let controller = GuardController()
    controller.loadMotionDemo()
    try? FileManager.default.createDirectory(atPath: outputDir, withIntermediateDirectories: true)

    let count = Int((Beat.length * Double(fps)).rounded())
    // The loop's first frame, kept as pixels: the seam dissolves into it.
    // A view would read the controller at render time, which by then holds
    // a later instant.
    let first = render(scene(controller: controller, at: 0, scheme: scheme))
    // MOTION_ONLY=0,40,85 renders just those frames, for quick review.
    let only = ProcessInfo.processInfo.environment["MOTION_ONLY"].map {
        Set($0.split(separator: ",").compactMap { Int($0) })
    }
    for index in 0..<count where only?.contains(index) ?? true {
        let t = Double(index) / Double(fps)
        let current = render(scene(controller: controller, at: t, scheme: scheme))
        var mix = 0.0
        if t >= Beat.seam {
            // Eased, so the dissolve starts and lands softly. It lands on the
            // last frame, which is then the first one exactly.
            let u = min(1, (t - Beat.seam) / (Double(count - 1) / Double(fps) - Beat.seam))
            mix = u * u * (3 - 2 * u)
        }
        let path = String(format: "%@/frame-%04d.png", outputDir, index)
        writePNG(current, over: first, mix: mix, to: path)
    }
    print("wrote \(count) frames to \(outputDir) at \(fps) fps")
}

/// The stage for one instant. The controller is set to this instant first, so
/// the popover reads it exactly as it reads the real controller.
@MainActor
private func scene(controller: GuardController, at t: Double, scheme: ColorScheme) -> some View {
    let f = MotionFrame.at(t)
    PreviewDemo.now = f.now
    // The system spinner turns about once a second.
    PreviewDemo.spinnerTurns = t
    controller.setMotionFrame(
        timeMachineMounted: f.mounted, backupPercent: f.backup,
        meeting: controller.demoMeeting(f.meetingTitle, start: f.meetingStart, minutes: 45),
        ejectDate: f.ejectDate, busy: f.busy,
        reconnectsAt: f.reconnectsAt, reconnecting: f.reconnecting)

    // StatusIcon's own rule, read off the same controller. StatusIcon itself
    // takes the animation phase from the live animator, whose clock is real
    // time; the demo steps it by frame instead.
    let state = StatusIconState.current(
        ejecting: controller.isBusy,
        backingUp: controller.isBackupRunning,
        reconnecting: controller.isReconnecting,
        active: controller.config.isActive,
        guardedTargets: controller.hasGuardedTargets,
        waitingToReconnect: !controller.config.pendingReconnects.isEmpty)
    // GuardController advances the breathing four times a second.
    let icon = StatusIconArt(state: state, percent: controller.backupPercent,
                             phase: Int(t / 0.25) % GuardController.breatheSteps,
                             guarding: controller.config.isActive && controller.hasGuardedTargets,
                             animationPhase: f.animationPhase, clip: f.clip)

    let popover = MenuContent()
        .environment(controller)
        .environment(UpdateStatus(isUpdateReady: false))
        .environment(\.colorScheme, scheme)
        .background(scheme == .dark
                    ? Color(red: 0.14, green: 0.14, blue: 0.15)
                    : Color(red: 0.96, green: 0.96, blue: 0.97))
    return MotionStage(popover: popover, icon: icon, now: f.now, scheme: scheme)
}

/// The desktop: a menu bar strip with the real icon at its real size, the
/// popover open under it, and the same icon enlarged on the empty side so
/// its 22 pt animation can be read at README width. Only the desktop, the
/// strip, the clock and the magnifier frame are scenery.
private struct MotionStage<Popover: View>: View {
    let popover: Popover
    let icon: StatusIconArt
    let now: Date
    let scheme: ColorScheme

    private var dark: Bool { scheme == .dark }
    /// The ink the menu bar gives its neighbours, as in HeroScene.
    private var ink: Color { Color(white: dark ? 0.86 : 0.12) }
    private var barTint: Color { dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45) }
    private var zoom: CGFloat { 6 }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Spacer()
                icon
                    .foregroundStyle(ink)
                    .frame(width: 30, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.14)))
                Image(systemName: "wifi")
                    .font(.system(size: 13, weight: .medium))
                Text(Format.clock(now))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(barTint)

            HStack(alignment: .top, spacing: 0) {
                magnifier
                    .frame(maxWidth: .infinity)
                    .padding(.top, 44)
                popover
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 24, y: 12)
            }
            .padding(.top, 6)
            .padding(.trailing, 10)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(width: 600, height: 452)
        .background(
            LinearGradient(colors: dark
                           ? [Color(red: 0.10, green: 0.13, blue: 0.24), Color(red: 0.20, green: 0.14, blue: 0.30)]
                           : [Color(red: 0.72, green: 0.83, blue: 0.95), Color(red: 0.86, green: 0.80, blue: 0.93)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, scheme)
    }

    /// The menu bar item enlarged: its highlight and the icon on the bar's
    /// own tint, cropped to the status item as the menu bar crops it.
    private var magnifier: some View {
        let z = zoom
        // LiftIcon's own drawing, run at the enlarged size: scaling up the
        // 22 pt template image would blur it.
        return Image(decorative: enlargedIcon(icon.pose, zoom: z, scale: 3), scale: 3)
            .renderingMode(.template)
            .foregroundStyle(ink)
            .frame(width: 22 * z, height: 16 * z)
            .clipped()
            .frame(width: 30 * z, height: 22 * z)
            .background(RoundedRectangle(cornerRadius: 5 * z, style: .continuous)
                .fill(Color.primary.opacity(0.10)))
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(dark ? Color(white: 0.16).opacity(0.85) : Color.white.opacity(0.62)))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous)
                .strokeBorder(dark ? Color.white.opacity(0.12) : Color.black.opacity(0.06), lineWidth: 0.5))
            .shadow(color: .black.opacity(dark ? 0.35 : 0.12), radius: 16, y: 8)
    }
}

/// `pose` drawn by LiftIcon into a bitmap `zoom` times its 22 x 16 pt size,
/// at `scale` pixels per point.
@MainActor
private func enlargedIcon(_ pose: LiftIcon.Pose, zoom: CGFloat, scale: CGFloat) -> CGImage {
    let factor = zoom * scale
    let width = Int(LiftIcon.canvas.width * factor), height = Int(LiftIcon.canvas.height * factor)
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // LiftIcon draws with y down, as in its flipped NSImage.
    context.translateBy(x: 0, y: CGFloat(height))
    context.scaleBy(x: factor, y: -factor)
    LiftIcon.draw(pose, in: context)
    return context.makeImage()!
}

/// The GIF is 960 px wide from a 600 pt stage: rendered at 1800 px, so
/// ffmpeg's downscale keeps 11 pt text crisp.
@MainActor
private func render(_ view: some View) -> CGImage {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 3
    guard let image = renderer.cgImage else {
        FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
        exit(1)
    }
    return image
}

/// Every frame as 8 bit sRGB, with `first` laid over it at `mix`. ImageRenderer hands back 16 bits for some
/// frames and not others, and ffmpeg wants one format for the whole sequence.
private func writePNG(_ rendered: CGImage, over first: CGImage, mix: Double, to path: String) {
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let context = CGContext(data: nil, width: rendered.width, height: rendered.height,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { exit(1) }
    let bounds = CGRect(x: 0, y: 0, width: rendered.width, height: rendered.height)
    context.draw(rendered, in: bounds)
    if mix > 0 {
        context.setAlpha(mix)
        context.draw(first, in: bounds)
    }
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil) else { exit(1) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        FileHandle.standardError.write("write failed: \(path)\n".data(using: .utf8)!)
        exit(1)
    }
}
