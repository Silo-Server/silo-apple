import SwiftUI

/// The player's one loading indicator: a plain spinner over the picture, for
/// the first load and for every stall after it. It never takes a touch or
/// focus, so the controls under it stay usable.
struct PlayerLoadingSpinner: View {
    /// A stall shorter than this shows nothing.
    static let showDelay: Duration = .milliseconds(500)
    /// Once shown, the spinner stays at least this long, so a stall that ends
    /// just after it appears does not flash it.
    static let minimumVisible: Duration = .milliseconds(500)

    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .tint(.white)
            #if os(tvOS)
            // The default tvOS spinner is lost across a room on a 1080p screen.
            .scaleEffect(2)
            #else
            .controlSize(.large)
            #endif
            .shadow(color: .black.opacity(0.5), radius: 12)
            .allowsHitTesting(false)
            .accessibilityLabel("Loading")
    }
}

extension View {
    /// Drives `isVisible` from `isActive` on the spinner's timing: on after
    /// `PlayerLoadingSpinner.showDelay` of continuous activity, and off no
    /// sooner than `PlayerLoadingSpinner.minimumVisible` after it came on.
    func playerLoadingSpinnerVisibility(isActive: Bool, isVisible: Binding<Bool>) -> some View {
        modifier(PlayerLoadingSpinnerTiming(isActive: isActive, isVisible: isVisible))
    }
}

private struct PlayerLoadingSpinnerTiming: ViewModifier {
    let isActive: Bool
    @Binding var isVisible: Bool
    @State private var shownAt: ContinuousClock.Instant?

    func body(content: Content) -> some View {
        content.task(id: isActive) {
            if isActive {
                guard !isVisible else { return }
                try? await Task.sleep(for: PlayerLoadingSpinner.showDelay)
                guard !Task.isCancelled else { return }
                shownAt = .now
                withAnimation(.easeOut(duration: 0.2)) { isVisible = true }
            } else {
                if isVisible, let shownAt {
                    try? await Task.sleep(until: shownAt + PlayerLoadingSpinner.minimumVisible, clock: .continuous)
                    guard !Task.isCancelled else { return }
                }
                withAnimation(.easeOut(duration: 0.2)) { isVisible = false }
            }
        }
    }
}
