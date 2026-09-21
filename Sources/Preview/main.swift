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

    let controller = GuardController()
    controller.start()

    let output = CommandLine.arguments.count > 1
        ? CommandLine.arguments[1]
        : NSTemporaryDirectory() + "menu-content.png"

    // Let the calendar permission callback and the first disk scan land before
    // rendering, otherwise the shot shows a half populated view.
    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
        // Render both appearances: a menu bar utility is judged in whichever
        // one the user runs, and contrast bugs only show up in one of them.
        for scheme in [ColorScheme.light, .dark] {
            let view = MenuContent()
                .environment(controller)
                .environment(\.colorScheme, scheme)
                // The real popover sits on ultraThinMaterial over the desktop,
                // which an offscreen render has nothing to blur. Substitute a
                // solid background so contrast matches what the eye will see.
                .background(scheme == .dark
                            ? Color(red: 0.14, green: 0.14, blue: 0.15)
                            : Color(red: 0.96, green: 0.96, blue: 0.97))

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
