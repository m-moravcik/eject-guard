import SwiftUI

// Shared motion pieces for the popover, as VibeRes has them. The timings and
// the job of each live in `Design.Motion`; these only apply them, with the
// Reduce Motion fallback in the same place as the movement.

/// A plain button that gives under the pointer: it shrinks a touch while it is
/// pressed and springs back on release. Reduce Motion: it dims instead.
struct PressableButtonStyle: ButtonStyle {
    let scale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        Pressed(label: configuration.label, isPressed: configuration.isPressed, scale: scale)
    }

    private struct Pressed: View {
        let label: ButtonStyleConfiguration.Label
        let isPressed: Bool
        let scale: CGFloat
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            label
                .scaleEffect(isPressed && !reduceMotion ? scale : 1)
                .opacity(isPressed && reduceMotion ? 0.75 : 1)
                .animation(reduceMotion ? Design.Motion.quick : Design.Motion.press, value: isPressed)
        }
    }
}

extension View {
    /// Digits that roll to their new value when `value` changes, downwards
    /// for a countdown. A crossfade instead under Reduce Motion, and while the
    /// text is not `counting`: rolled, words only scramble letter by letter.
    /// Rolling text is drawn without the material's vibrancy, so it wants
    /// `Design.Palette.cardSubtitle` rather than `.secondary`.
    func rollingNumbers(on value: some Equatable, countsDown: Bool = false, counting: Bool = true,
                        reduceMotion: Bool) -> some View {
        contentTransition(counting && !reduceMotion ? .numericText(countsDown: countsDown) : .opacity)
            .animation(reduceMotion ? Design.Motion.quick : Design.Motion.number, value: value)
    }
}

extension AnyTransition {
    /// A row that fades in once the rows around it have made room, and fades
    /// out before they close up. Reduce Motion: the same order around the
    /// rows' `jump`.
    static func row(reduceMotion: Bool) -> AnyTransition {
        .asymmetric(
            insertion: .opacity.animation(reduceMotion ? Design.Motion.rowInReduced : Design.Motion.rowIn),
            removal: .opacity.animation(Design.Motion.rowOut)
        )
    }
}
