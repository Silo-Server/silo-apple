import SwiftUI

struct RefreshStatusPill: View {
    static let minimumVisibleDuration: TimeInterval = 1.5

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.siloOnSurface)

            Text("Refreshing")
                .font(.siloCaption)
                .fontWeight(.semibold)
                .foregroundColor(.siloOnSurface)
        }
        .siloStatusCapsule()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Refreshing")
    }
}

extension View {
    /// Floating status-capsule chrome shared by the refresh, offline and
    /// trailer-status pills.
    func siloStatusCapsule() -> some View {
        self
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
            }
            .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
    }
}

/// Shared state machine behind the pull-to-refresh pill: the pill stays up for
/// `RefreshStatusPill.minimumVisibleDuration` even when the refresh finishes
/// sooner, so it never flashes.
@Observable
@MainActor
final class RefreshStatusState {
    private(set) var isRefreshing = false
    private var refreshStartedAt: Date?
    private var refreshHideTask: Task<Void, Never>?

    func show() {
        refreshHideTask?.cancel()
        refreshStartedAt = Date()
        isRefreshing = true
    }

    func scheduleHide() {
        let elapsed = Date().timeIntervalSince(refreshStartedAt ?? Date())
        let remaining = RefreshStatusPill.minimumVisibleDuration - elapsed
        refreshHideTask?.cancel()
        refreshHideTask = Task { @MainActor in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }

            self.isRefreshing = false
            self.refreshStartedAt = nil
            self.refreshHideTask = nil
        }
    }
}
