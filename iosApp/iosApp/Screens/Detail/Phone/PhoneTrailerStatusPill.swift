#if !os(tvOS)
import SwiftUI

/// Feedback for the "Find Trailers" action, shown under the detail page's
/// action row.
///
/// Same chrome as `RefreshStatusPill` — this is the detail page's local
/// version of the same idea, but the copy is supplied by
/// `TrailerFetchCoordinator.statusMessage` and the terminal outcomes
/// (cooldown / disabled / nothing found) clear themselves after a beat so a
/// dead end never becomes permanent furniture on the page. While the fetch
/// is running the pill persists, because the poll can take a while and the
/// spinner is the only sign anything is happening.
struct PhoneTrailerStatusPill: View {
    let message: String
    /// True while the request or poll is in flight — spinner instead of a
    /// glyph, and no auto-dismiss.
    let isFetching: Bool
    /// Invoked once a terminal message has been visible long enough; the
    /// owner acknowledges it on the coordinator.
    let onAutoDismiss: () -> Void

    /// Terminal copy is a full sentence rather than a one-word status, so it
    /// gets twice `RefreshStatusPill`'s floor to be read comfortably.
    private static let terminalVisibleDuration: TimeInterval = 3

    var body: some View {
        HStack(spacing: 10) {
            if isFetching {
                ProgressView()
                    .controlSize(.small)
                    .tint(.continuumOnSurface)
            } else {
                Image(systemName: "info.circle")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.continuumOnSurface)
            }

            Text(message)
                .font(.continuumCaption)
                .fontWeight(.semibold)
                .foregroundColor(.continuumOnSurface)
                .lineLimit(1)
                .minimumScaleFactor(0.85)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(message)
        // Keyed on the copy *and* the phase so the timer restarts when
        // "Finding trailers…" is replaced by its outcome.
        .task(id: dismissKey) {
            guard !isFetching else { return }
            try? await Task.sleep(for: .seconds(Self.terminalVisibleDuration))
            guard !Task.isCancelled else { return }
            onAutoDismiss()
        }
    }

    private var dismissKey: String {
        "\(isFetching)|\(message)"
    }
}
#endif
