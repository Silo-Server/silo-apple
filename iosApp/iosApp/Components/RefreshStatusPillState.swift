import SwiftUI

/// Drives `RefreshStatusPill` for a pull-to-refresh: visible while the
/// refresh runs and for at least `RefreshStatusPill.minimumVisibleDuration`,
/// so a fast refresh doesn't flash it.
@MainActor
@Observable
final class RefreshStatusPillState {
    private(set) var isVisible = false
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    func run(_ refresh: () async -> Void) async {
        hideTask?.cancel()
        let startedAt = ContinuousClock.now
        isVisible = true
        await refresh()
        let remaining = Duration.seconds(RefreshStatusPill.minimumVisibleDuration) - startedAt.duration(to: .now)
        hideTask = Task {
            if remaining > .zero {
                try? await Task.sleep(for: remaining)
            }
            guard !Task.isCancelled else { return }
            isVisible = false
        }
    }
}
