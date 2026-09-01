import SwiftUI

/// Companion to `RefreshStatusPill`: shown in the same overlay slot when the
/// last refresh could not reach the server but cached content is still
/// painted, so stale data is never presented as fresh. Clears automatically —
/// `ConnectionMonitor` re-probes while unreachable and flips state on the
/// first successful response.
struct ServerUnreachablePill: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: ConnectionMonitor.shared.isDeviceOnline
                ? "exclamationmark.arrow.trianglehead.2.clockwise.rotate.90"
                : "wifi.slash")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.continuumOnSurface)

            Text(ConnectionMonitor.shared.isDeviceOnline
                ? "Can't reach server — showing cached content"
                : "You're offline — showing cached content")
                .font(.continuumCaption)
                .fontWeight(.semibold)
                .foregroundColor(.continuumOnSurface)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        #if os(iOS)
        .background(Color(white: 0.10), in: Capsule())
        #else
        .background(.ultraThinMaterial, in: Capsule())
        #endif
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Can't reach the server. Showing cached content.")
    }
}
