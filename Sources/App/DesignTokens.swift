import SwiftUI

/// Single source of truth for spacing, radii, typography and colors, so future
/// tweaks do not sprawl across views.
enum Design {
    enum Spacing {
        static let xs: CGFloat = 2
        static let s: CGFloat = 4
        static let m: CGFloat = 8
        static let l: CGFloat = 12
    }

    enum Radius {
        static let card: CGFloat = 8
        static let row: CGFloat = 4
    }

    enum Layout {
        static let popoverWidth: CGFloat = 300
        /// Measured with the preview harness (`./preview.sh many`), the rest
        /// of the popover is 293pt with today's meeting and its skip row, a
        /// disk row 47pt and the gap between rows 2pt.
        ///
        /// The disk list scrolls past six rows and half of a seventh, the half
        /// row saying there is more. The popover is then 609pt, inside the
        /// 620pt it always kept to.
        static let diskListMaxHeight: CGFloat = 316
        /// A backstop, not the layout: the scrolling list keeps the popover
        /// under it. Banners add 49pt each (update ready, paused: measured
        /// together at 98pt), and "Stop backup" a 24pt row while Time Machine
        /// runs, so the tallest state stays around 765pt. The smallest screen
        /// a 13-inch MacBook that runs macOS 14 opens at is 1440 x 900
        /// points, 876pt under a 24pt menu bar; this leaves about 100pt for
        /// the Dock.
        static let popoverMaxHeight: CGFloat = 775
        /// A 13pt line plus 4 + 4 is 24pt, the height of a native menu item
        /// on macOS 26 (measured with `NSMenu.size`).
        static let rowVerticalPadding: CGFloat = 4
        /// Space a native menu keeps around a separator and at its edges.
        static let menuInset: CGFloat = 5
        static let iconColumn: CGFloat = 16
    }

    enum Typography {
        static let cardTitle: Font = .system(size: 13, weight: .semibold)
        static let cardSubtitle: Font = .system(size: 11).monospacedDigit()
        static let badge: Font = .system(size: 9, weight: .bold)
        static let row: Font = .system(size: 13)
        /// Secondary annotations under a control. 11pt, as in VibeRes: macOS
        /// treats 11pt as the floor for text that carries meaning, and these
        /// render in `.secondary`, which takes the contrast down with them.
        static let note: Font = .system(size: 11)
        /// All-caps section labels ("NEXT MEETING", "DISKS"). VibeRes' size.
        static let sectionHeader: Font = .system(size: 10, weight: .semibold, design: .rounded)
    }

    enum Palette {
        static let cardFill = Color.secondary.opacity(0.10)
        static let cardFillHover = Color.secondary.opacity(0.18)
        static let cardFillActive = Color.accentColor.opacity(0.14)
        static let separator = Color.secondary.opacity(0.15)
        /// The line under a card's title. Text whose digits roll
        /// (`rollingNumbers`) is drawn without the material's vibrancy while
        /// it rolls, and `.secondary` then turns near black for most of a
        /// second, recorded on macOS 26. The plain label colour reads the same
        /// at rest and keeps it while rolling.
        static let cardSubtitle = Color(nsColor: .secondaryLabelColor)
        /// The update-ready card, the same green wash as VibeRes.
        static let updateFill = Color.green.opacity(0.10)
        static let updateFillHover = Color.green.opacity(0.18)
    }

    /// How the popover moves. The vocabulary is VibeRes' (`Design.Motion`
    /// there), so the sibling apps move alike. Calm rather than playful:
    /// springs settle without a visible bounce, everything is interruptible,
    /// and under Reduce Motion a movement becomes a crossfade or its end state.
    enum Motion {
        /// Hover tints and small state changes: a crossfade, not a pop. Also
        /// what every movement below becomes under Reduce Motion.
        static let quick: Animation = .easeInOut(duration: 0.18)
        /// Rows that make room for something new, or close up after it.
        static let layout: Animation = .smooth(duration: 0.25)
        /// A backup percentage or a countdown rolls its digits to the new
        /// value, so it reads as a clock that is running.
        static let number: Animation = .smooth(duration: 0.35)

        /// A disk card gives under the pointer, confirming the click before
        /// the guard changes.
        static let press: Animation = .snappy(duration: 0.14)
        static let cardPressScale: CGFloat = 0.985

        /// A row that takes a place the others make room for (a problem, a
        /// banner, Stop backup, Undo skip) fades in once they mostly have,
        /// and leaves by fading before they close up over it (`closeUp`), so
        /// no text crosses another.
        static let rowIn: Animation = .easeInOut(duration: 0.18).delay(0.2)
        static let rowOut: Animation = .easeOut(duration: 0.1)
        /// Rows closing up after something left: `layout`, a beat later.
        static let closeUp: Animation = layout.delay(0.08)
        /// Under Reduce Motion the rows around such a row do not move: they
        /// jump to their end state once the row leaving has faded (`rowOut`),
        /// and the row arriving fades in after that (`rowInReduced`). A zero
        /// duration would make SwiftUI ignore the delay.
        static let jump: Animation = .linear(duration: 0.001).delay(0.1)
        static let rowInReduced: Animation = quick.delay(0.1)

        /// How the rest of the popover moves when a row arrives or leaves:
        /// it makes room at once for an arriving row (`layout`) and closes up
        /// only after a leaving one has faded (`closeUp`); Reduce Motion:
        /// `jump`. A row swapping with another both leaves and arrives, so it
        /// always closes up.
        static func rows(arriving: Bool, reduceMotion: Bool) -> Animation {
            reduceMotion ? jump : arriving ? layout : closeUp
        }

        /// How far an onboarding step slides in from the side it comes from.
        static let stepSlide: CGFloat = 24
    }
}
