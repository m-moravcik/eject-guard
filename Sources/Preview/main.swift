// Development harness: renders the popover contents straight to a PNG.
//
// MenuBarExtra popovers cannot be opened programmatically, so this is the only
// way to review the layout without screenshotting the whole desktop. Not
// shipped - see build.sh.

import AppKit
import SwiftUI

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)

    // Icon mode renders the menu bar icon instead of the popover. It needs no
    // controller and no calendar, because StatusIconArt takes plain values.
    if CommandLine.arguments.contains("icons") {
        renderIconSheet()
        exit(0)
    }

    // Demo mode renders invented disks and a meeting, for the screenshot in the
    // README. Without it the shot shows this Mac's real calendar and disks.
    // Hero wraps the demo popover in a menu bar and a desktop, as it looks
    // open: the published screenshot.
    let banner = CommandLine.arguments.contains("banner")
    let hero = banner || CommandLine.arguments.contains("hero")
    let demo = hero || CommandLine.arguments.contains("demo")
    let controller = GuardController()
    if demo { controller.loadDemo() } else { controller.start() }

    let output = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : NSTemporaryDirectory() + "menu-content.png"

    // Let the calendar permission callback and the first disk scan land before
    // rendering, otherwise the shot shows a half populated view.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        // Render both appearances: a menu bar utility is judged in whichever
        // one the user runs, and contrast bugs only show up in one of them.
        for scheme in [ColorScheme.light, .dark] {
            let popover = MenuContent()
                .environment(controller)
                // The harness never updates itself; this is only here because
                // the popover reads the status out of the environment.
                .environment(UpdateStatus())
                .environment(\.colorScheme, scheme)
                // The real popover sits on ultraThinMaterial over the desktop,
                // which an offscreen render has nothing to blur. Substitute a
                // solid background so contrast matches what the eye will see.
                .background(scheme == .dark
                            ? Color(red: 0.14, green: 0.14, blue: 0.15)
                            : Color(red: 0.96, green: 0.96, blue: 0.97))

            let view = Group {
                if hero {
                    HeroScene(popover: popover, scheme: scheme, banner: banner)
                } else {
                    popover
                }
            }
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2

            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let png = bitmap.representation(using: .png, properties: [:])
            else {
                FileHandle.standardError.write("render failed\n".data(using: .utf8)!)
                exit(1)
            }

            let suffix = scheme == .dark ? "-dark" : "-light"
            let path = output.replacingOccurrences(of: ".png", with: "\(suffix).png")
            do {
                try png.write(to: URL(fileURLWithPath: path))
                print("wrote \(path)  \(Int(image.size.width))x\(Int(image.size.height)) pt")
            } catch {
                FileHandle.standardError.write("write failed: \(error)\n".data(using: .utf8)!)
                exit(1)
            }
        }
        app.terminate(nil)
    }

    app.run()
}


/// A contact sheet of every menu bar state, at the size the menu bar draws them
/// and again enlarged.
///
/// The menu bar icon is the part of this app that is hardest to look at: it is
/// 16 points wide, it only shows some states while a backup is actually
/// running, and a MenuBarExtra label cannot be opened on demand. Rendering it
/// offscreen is the only way the backup animation gets reviewed rather than
/// hoped about.
@MainActor
func renderIconSheet() {
    struct Sample {
        let title: String
        let state: StatusIconState
        var percent: Double?
        var phase: Int = 0
    }

    var samples: [Sample] = [
        Sample(title: "idle", state: .idle),
        Sample(title: "armed", state: .armed),
        Sample(title: "off", state: .off),
        Sample(title: "ejecting", state: .ejecting),
        Sample(title: "0%", state: .backingUp, percent: 0),
        Sample(title: "35%", state: .backingUp, percent: 0.35),
        Sample(title: "78%", state: .backingUp, percent: 0.78),
        Sample(title: "100%", state: .backingUp, percent: 1),
    ]
    // The indeterminate sweep, one column per step of its cycle.
    for phase in 0..<GuardController.breatheSteps {
        samples.append(Sample(title: "…\(phase)", state: .backingUp, percent: nil, phase: phase))
    }

    let sheet = VStack(alignment: .leading, spacing: 14) {
        ForEach([ColorScheme.light, .dark], id: \.self) { scheme in
            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                    VStack(spacing: 6) {
                        // Actual size, on the menu bar's own tinted background.
                        StatusIconArt(state: sample.state,
                                      percent: sample.percent,
                                      phase: sample.phase)
                            .frame(width: 26, height: 22)
                            .background(scheme == .dark
                                        ? Color(white: 0.18) : Color(white: 0.82))
                        Text(sample.title)
                            .font(.system(size: 8))
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(10)
            .environment(\.colorScheme, scheme)
            .background(scheme == .dark ? Color(white: 0.10) : Color(white: 0.95))
        }
    }
    .padding(12)
    .background(Color(white: 0.5))

    let renderer = ImageRenderer(content: sheet)
    // The icon is 16 points wide; 6x is what makes a 2 point bar reviewable.
    renderer.scale = 6
    let path = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : NSTemporaryDirectory() + "status-icons.png"
    guard let image = renderer.nsImage,
          let tiff = image.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]),
          (try? png.write(to: URL(fileURLWithPath: path))) != nil
    else {
        FileHandle.standardError.write("icon render failed\n".data(using: .utf8)!)
        exit(1)
    }
    print("wrote \(path)")
}


/// The popover as it looks when it is open: hanging under its menu bar icon,
/// with the window's rounded corners and shadow, over a plain desktop. Every
/// part that carries information is the real view; only the desktop, the
/// menu bar strip and the clock are scenery.
struct HeroScene<Popover: View>: View {
    let popover: Popover
    let scheme: ColorScheme
    /// Banner is the 16:9 portfolio image: the same scene, wider, with the
    /// app's icon and name on the empty half of the desktop.
    var banner = false

    private var dark: Bool { scheme == .dark }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                Spacer()
                // Only the symbol: a MenuBarExtra label keeps the image and
                // drops the track StatusIconArt stacks under it, so that is
                // all the real menu bar shows.
                Image(systemName: StatusIconState.backingUp.symbol)
                    .font(.system(size: 15))
                    .frame(width: 30, height: 22)
                    .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(Color.primary.opacity(0.14)))
                Image(systemName: "wifi")
                    .font(.system(size: 13, weight: .medium))
                Text(Format.clock(Date()))
                    .font(.system(size: 13, weight: .medium))
                    .monospacedDigit()
            }
            .padding(.horizontal, 14)
            .frame(height: 24)
            .background(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.45))

            HStack(spacing: 0) {
                if banner {
                    VStack(spacing: 20) {
                        if let icon = NSImage(contentsOfFile: "docs/icon.png") {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 168, height: 168)
                        }
                        Text("Eject Guard")
                            .font(.system(size: 40, weight: .bold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 30)
                } else {
                    Spacer()
                }
                popover
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(dark ? Color.white.opacity(0.14) : Color.black.opacity(0.10), lineWidth: 0.5))
                    .shadow(color: .black.opacity(dark ? 0.5 : 0.22), radius: 24, y: 12)
            }
            .padding(.top, 6)
            // Near the right edge macOS keeps the window on screen rather than
            // centring it under the icon, so it sits flush with a small margin.
            .padding(.trailing, banner ? 96 : 10)
            .padding(.bottom, banner ? 0 : 48)
            .frame(maxHeight: banner ? .infinity : nil, alignment: .top)
        }
        .frame(width: banner ? 960 : 480, height: banner ? 540 : nil)
        .background(
            LinearGradient(colors: dark
                           ? [Color(red: 0.10, green: 0.13, blue: 0.24), Color(red: 0.20, green: 0.14, blue: 0.30)]
                           : [Color(red: 0.72, green: 0.83, blue: 0.95), Color(red: 0.86, green: 0.80, blue: 0.93)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, scheme)
    }
}
