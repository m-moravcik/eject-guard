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
        static let popoverMaxHeight: CGFloat = 620
        static let rowVerticalPadding: CGFloat = 3
        static let iconColumn: CGFloat = 16
    }

    enum Typography {
        static let cardTitle: Font = .system(size: 13, weight: .semibold)
        static let cardSubtitle: Font = .system(size: 11).monospacedDigit()
        static let badge: Font = .system(size: 9, weight: .bold)
        static let row: Font = .system(size: 13)
        static let note: Font = .system(size: 10)
        /// All-caps section labels ("NEXT MEETING", "DISKS").
        static let sectionHeader: Font = .system(size: 9, weight: .semibold, design: .rounded)
    }

    enum Palette {
        static let cardFill = Color.secondary.opacity(0.10)
        static let cardFillHover = Color.secondary.opacity(0.18)
        static let cardFillActive = Color.accentColor.opacity(0.14)
        static let separator = Color.secondary.opacity(0.15)
    }
}
