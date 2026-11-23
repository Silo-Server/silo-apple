#if os(tvOS)
import SwiftUI

/// The playback error screen on Apple TV: a centered card with the player's
/// pill buttons. Retry takes focus when it is offered, otherwise Go Back.
/// Movement between the two is native focus; Menu stays with the player
/// shell's `onExitCommand`.
struct TVPlayerErrorCard: View {
    let message: String
    /// The Retry pill's title, or nil when retrying cannot help.
    let retryTitle: String?
    let onRetry: () -> Void
    let onGoBack: () -> Void

    private enum FocusTarget: Hashable {
        case retry
        case goBack
    }

    @FocusState private var focusedTarget: FocusTarget?
    @Namespace private var focusNamespace

    private var initialFocusTarget: FocusTarget {
        retryTitle == nil ? .goBack : .retry
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 52, weight: .semibold))
                .foregroundStyle(Color.siloWarning)
                .accessibilityHidden(true)

            Text(.playerErrorCantPlayTitle)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            // Server and engine messages arrive as written and can run long.
            Text(message)
                .font(.siloBody)
                .foregroundStyle(.white.opacity(0.65))
                .multilineTextAlignment(.center)
                .lineLimit(5)

            HStack(spacing: 24) {
                if let retryTitle {
                    Button(action: onRetry) {
                        pillLabel(Text(retryTitle), systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(TVPillButtonStyle(kind: .secondary))
                    .focused($focusedTarget, equals: .retry)
                    .prefersDefaultFocus(true, in: focusNamespace)
                }

                Button(action: onGoBack) {
                    pillLabel(Text(.playerGoBack), systemImage: "chevron.backward")
                }
                .buttonStyle(TVPillButtonStyle(kind: .secondary))
                .focused($focusedTarget, equals: .goBack)
                .prefersDefaultFocus(retryTitle == nil, in: focusNamespace)
            }
            .padding(.top, 18)
            .focusScope(focusNamespace)
        }
        .padding(.horizontal, 64)
        .padding(.vertical, 52)
        .frame(width: 960)
        .siloPlayerGlass(in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.18), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.6), radius: 26, y: 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Nothing else on screen is focusable, and the card mounts in place
        // of the view that held focus, so seed it on every appearance: a
        // Retry that fails again mounts a new card.
        .onAppear {
            Task { @MainActor in
                await Task.yield()
                focusedTarget = initialFocusTarget
            }
        }
    }

    private func pillLabel(_ title: Text, systemImage: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.system(size: 25, weight: .semibold))
            title
                .font(.system(size: 26, weight: .semibold))
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
        }
        // Grows for longer translations.
        .frame(minWidth: 120)
    }
}
#endif
