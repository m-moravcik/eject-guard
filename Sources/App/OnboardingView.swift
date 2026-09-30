import SwiftUI

/// Three-step welcome tour shown in the popover on a fresh install, as VibeRes
/// has it: inside the popover rather than a window of its own, because the
/// popover is the first thing a menu bar app shows. Finishing or skipping
/// records it in the config; Settings can replay it.
struct OnboardingView: View {
    @Environment(GuardController.self) private var controller
    @State private var step: Int

    /// `initialStep` exists for the preview harness, which renders each step.
    init(initialStep: Int = 0) {
        _step = State(initialValue: initialStep)
    }

    private struct Step {
        /// Nil shows the app's own icon: the welcome step introduces the app.
        let symbol: String?
        let title: String
        let body: String
    }

    private var steps: [Step] {
        [
            Step(symbol: nil,
                 title: Loc.t("onboarding.welcome.title", "Welcome to Eject Guard"),
                 body: Loc.t("onboarding.welcome.body", "It ejects your external disks a few minutes before a meeting, so you can pick up the laptop and go.")),
            Step(symbol: "externaldrive.fill.badge.checkmark",
                 title: Loc.t("onboarding.guard.title", "Pick the disks to guard"),
                 body: Loc.t("onboarding.guard.body", "Click a disk to guard it. Only guarded disks are ever ejected, and a running Time Machine backup is stopped first.")),
            Step(symbol: "calendar.badge.clock",
                 title: Loc.t("onboarding.meetings.title", "It reads your calendar"),
                 body: Loc.t("onboarding.meetings.body", "Events with other attendees count as meetings. Change that, the lead time and the calendars in Settings.")),
        ]
    }

    private var isLast: Bool { step == steps.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(Loc.t("onboarding.skip", "Skip")) { finish() }
                    .buttonStyle(.plain)
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(Loc.t("onboarding.step", "%d of %d", step + 1, steps.count))
                    .font(Design.Typography.note)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, Design.Spacing.l)
            .padding(.top, Design.Spacing.l)

            let current = steps[step]
            VStack(spacing: 10) {
                Group {
                    if let symbol = current.symbol {
                        Image(systemName: symbol)
                            .font(.system(size: 36))
                            .foregroundStyle(.tint)
                    } else {
                        // As Finder and the Dock draw it, glass included on
                        // macOS 26. The icon art carries its own margin, so it
                        // is drawn larger than the symbols to look the same size.
                        Image(nsImage: NSApp.applicationIconImage)
                            .resizable()
                            .frame(width: 56, height: 56)
                    }
                }
                .frame(height: 56)
                .accessibilityHidden(true)
                .padding(.top, Design.Spacing.s)
                Text(current.title)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                Text(current.body)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            // A new identity per step, so SwiftUI runs the transition.
            .id(step)
            .transition(.opacity.combined(with: .move(edge: .trailing)))
            .padding(.horizontal, 18)
            .padding(.top, Design.Spacing.m)
            .padding(.bottom, Design.Spacing.l)

            HStack(spacing: 6) {
                ForEach(0..<steps.count, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 6, height: 6)
                }
            }
            .accessibilityHidden(true)
            .padding(.bottom, Design.Spacing.m)

            HStack {
                Button(Loc.t("onboarding.back", "Back")) {
                    withAnimation(.easeInOut(duration: 0.18)) { step = max(0, step - 1) }
                }
                .controlSize(.small)
                .buttonStyle(.bordered)
                .disabled(step == 0)

                Spacer()

                Button(isLast ? Loc.t("onboarding.done", "Done") : Loc.t("onboarding.next", "Next")) {
                    if isLast {
                        finish()
                    } else {
                        withAnimation(.easeInOut(duration: 0.18)) { step += 1 }
                    }
                }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, Design.Spacing.l)
            .padding(.bottom, Design.Spacing.l)
        }
    }

    private func finish() {
        controller.setOnboardingShown(true)
    }
}
