#if os(tvOS)
import SwiftUI

/// Transport controls under the scrubber. Post-redesign this is an
/// icon-only row with no container pill — the buttons float on the bottom
/// gradient, VidHub-style, so the overlay stays visually quiet. A single
/// `focusSection()` keeps D-pad left/right pinned within transport; vertical
/// presses remain inside the visible controls.
///
/// Consolidates what used to be three separate entry points (chapters,
/// tracks, settings) into one `options` button that opens `TVPlayerInfoHUD`;
/// the HUD's tab bar handles routing to the right pane.
struct TVPlayerTransportCluster: View {
    let viewModel: PlayerViewModel
    let onOpenHUD: () -> Void
    let onMoveToScrubber: () -> Void
    let onDismiss: () -> Void
    /// False while the scrubber's timeline-scrub mode is active — pulls every
    /// button out of the focus graph so a Down press/swipe on the puck finds
    /// no target and focus stays on the scrub.
    var allowsFocus: Bool = true

    @FocusState.Binding var focusedButton: FocusTarget?

    enum FocusTarget: Hashable {
        case skipBack, playPause, skipForward, nextUp, options, dismiss
    }

    var body: some View {
        HStack(spacing: 14) {
            primaryRow
            Spacer(minLength: 24)
            secondaryRow
        }
        .focusSection()
        .onMoveCommand { direction in
            switch direction {
            case .up:
                onMoveToScrubber()
            default:
                break
            }
        }
    }

    private var primaryRow: some View {
        HStack(spacing: 10) {
            iconButton(
                systemName: "gobackward.10",
                focus: .skipBack,
                accessibilityLabel: "Skip back 10 seconds"
            ) { viewModel.skipBackward() }

            iconButton(
                systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                focus: .playPause,
                accessibilityLabel: viewModel.isPlaying ? "Pause" : "Play",
                isPrimary: true
            ) { viewModel.togglePlayPause() }

            iconButton(
                systemName: "goforward.30",
                focus: .skipForward,
                accessibilityLabel: "Skip forward 30 seconds"
            ) { viewModel.skipForward() }
        }
    }

    private var secondaryRow: some View {
        HStack(spacing: 10) {
            if viewModel.canShowNextUpScreen {
                iconButton(
                    systemName: "rectangle.stack.fill",
                    focus: .nextUp,
                    accessibilityLabel: "Show Up Next",
                    action: viewModel.showNextUpNow
                )
            }
            iconButton(
                systemName: "slider.horizontal.3",
                focus: .options,
                accessibilityLabel: "Info and options",
                action: onOpenHUD
            )
            iconButton(
                systemName: "xmark",
                focus: .dismiss,
                accessibilityLabel: "Close player",
                action: onDismiss
            )
        }
    }

    // Uniform sizes on both rows keep the buttons reading as a single
    // transport group. Focus is signaled by filling the circle white — no
    // scale transform so the buttons never cross the bounds of their
    // circular hit target.
    private static let buttonSize: CGFloat = 66
    private static let primarySymbolSize: CGFloat = 30
    private static let secondarySymbolSize: CGFloat = 25

    @ViewBuilder
    private func iconButton(
        systemName: String,
        focus: FocusTarget,
        accessibilityLabel: String,
        isPrimary: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedButton == focus
        let symbolSize: CGFloat = isPrimary ? Self.primarySymbolSize : Self.secondarySymbolSize

        // Bare `.focusable(true)` rather than a Button: tvOS's built-in
        // ButtonStyles render a full-bounds focused surface under the
        // button that renders as an oversized halo — we want just the
        // colored disc. `onTapGesture` delivers Select-press semantics.
        Image(systemName: systemName)
            .font(.system(size: symbolSize, weight: .semibold))
            .foregroundStyle(isFocused ? Color.black : Color.white)
            .frame(width: Self.buttonSize, height: Self.buttonSize)
            .background(
                Circle().fill(isFocused ? Color.white : Color.black.opacity(0.35))
            )
            .overlay(
                Circle().stroke(
                    Color.white.opacity(isFocused ? 0 : 0.22),
                    lineWidth: 1
                )
            )
            .animation(.easeOut(duration: ContinuumTheme.fastDuration), value: isFocused)
            .contentShape(Circle())
            .focusable(allowsFocus)
            .focused($focusedButton, equals: focus)
            .onTapGesture(perform: action)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }
}
#endif
