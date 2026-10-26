#if os(tvOS)
import SwiftUI

/// A spinner and a short status line in the top-trailing corner, for a wait
/// that has a reason worth naming (a Watch Party sync). Plain loading uses
/// `PlayerLoadingSpinner`.
struct PlayerBufferingCapsule: View {
    let message: LocalizedStringKey
    @State private var isVisible = false

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .tint(.white)
                .progressViewStyle(.circular)
                .scaleEffect(0.9)

            Text(message)
                .font(.siloSmall.weight(.medium))
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .siloPlayerGlass(in: Capsule())
        .shadow(color: .black.opacity(0.45), radius: 18, y: 7)
        .padding(.top, 64)
        .padding(.trailing, 80)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
        .allowsHitTesting(false)
        .transition(.opacity)
        .opacity(isVisible ? 1 : 0)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        .accessibilityHidden(!isVisible)
        .task {
            isVisible = false
            try? await Task.sleep(for: PlayerLoadingSpinner.showDelay)
            // The wait ending removes this view and cancels the delay.
            guard !Task.isCancelled else { return }
            isVisible = true
        }
    }
}
#endif
