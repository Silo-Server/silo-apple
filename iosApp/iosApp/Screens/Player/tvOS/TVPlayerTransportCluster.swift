#if os(tvOS)
import SwiftUI

/// Transport controls under the scrubber: a row of discs with no container
/// pill, floating on the bottom gradient so the overlay stays visually quiet.
/// Next Up and the menu button carry their name beside the icon.
/// A single `focusSection()` keeps D-pad left/right pinned within transport;
/// vertical presses remain inside the visible controls.
///
/// Chapters, tracks and settings share one `options` button that opens
/// `TVPlayerInfoHUD`; the HUD's tab bar routes to the right pane.
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
                systemName: SeekIntervalLabel.symbolName(.backward, seconds: viewModel.skipIntervals.backward),
                focus: .skipBack,
                accessibilityLabel: Text(SeekIntervalLabel.accessibilityLabel(.backward, seconds: viewModel.skipIntervals.backward))
            ) { viewModel.skipBackward() }

            iconButton(
                systemName: viewModel.isPlaying ? "pause.fill" : "play.fill",
                focus: .playPause,
                accessibilityLabel: Text(viewModel.isPlaying ? LocalizedStringResource.playerAudioPause : .playerAudioPlay),
                isPrimary: true
            ) { viewModel.togglePlayPause() }

            iconButton(
                systemName: SeekIntervalLabel.symbolName(.forward, seconds: viewModel.skipIntervals.forward),
                focus: .skipForward,
                accessibilityLabel: Text(SeekIntervalLabel.accessibilityLabel(.forward, seconds: viewModel.skipIntervals.forward))
            ) { viewModel.skipForward() }
        }
    }

    private var secondaryRow: some View {
        HStack(spacing: 10) {
            if viewModel.canShowNextUpScreen {
                labeledButton(
                    systemName: "rectangle.stack.fill",
                    title: .playerControlsNextUp,
                    focus: .nextUp,
                    action: viewModel.showNextUpNow
                )
            }
            labeledButton(
                systemName: "slider.horizontal.3",
                title: .playerControlsPlaybackMenu,
                focus: .options,
                action: onOpenHUD
            )
            iconButton(
                systemName: "xmark",
                focus: .dismiss,
                accessibilityLabel: Text(.playerAudioClose),
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
        accessibilityLabel: Text,
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
            .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
            .contentShape(Circle())
            .focusable(allowsFocus)
            .focused($focusedButton, equals: focus)
            .onTapGesture(perform: action)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(.isButton)
    }

    private static let labelTextSize: CGFloat = 24

    /// A capsule the height of the discs with the icon and its visible name,
    /// built and focused like `iconButton`. VoiceOver reads the visible name.
    @ViewBuilder
    private func labeledButton(
        systemName: String,
        title: LocalizedStringResource,
        focus: FocusTarget,
        action: @escaping () -> Void
    ) -> some View {
        let isFocused = focusedButton == focus

        HStack(spacing: 10) {
            Image(systemName: systemName)
                .font(.system(size: Self.secondarySymbolSize, weight: .semibold))
            Text(title)
                .font(.system(size: Self.labelTextSize, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        .foregroundStyle(isFocused ? Color.black : Color.white)
        .padding(.horizontal, 22)
        .frame(height: Self.buttonSize)
        .background(
            Capsule().fill(isFocused ? Color.white : Color.black.opacity(0.35))
        )
        .overlay(
            Capsule().stroke(
                Color.white.opacity(isFocused ? 0 : 0.22),
                lineWidth: 1
            )
        )
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: isFocused)
        .contentShape(Capsule())
        .focusable(allowsFocus)
        .focused($focusedButton, equals: focus)
        .onTapGesture(perform: action)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(.isButton)
    }
}
#endif
