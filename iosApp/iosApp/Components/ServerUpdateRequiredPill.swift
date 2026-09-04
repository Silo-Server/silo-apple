import SwiftUI

/// Shown in the same overlay slot as `ServerUnreachablePill` when the
/// connected server answered the v2 contract probe as v1-only. The server is
/// reachable, so this is not an offline state; it is a request to update it.
struct ServerUpdateRequiredPill: View {
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.up.circle")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(.continuumOnSurface)

            Text("Server update required")
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
        .accessibilityLabel(APIv2Error.serverUpdateRequiredMessage)
    }
}
