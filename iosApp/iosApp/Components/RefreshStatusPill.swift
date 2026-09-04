import SwiftUI

struct RefreshStatusPill: View {
    static let minimumVisibleDuration: TimeInterval = 1.5

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
                .tint(.continuumOnSurface)

            Text("Refreshing")
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
        .accessibilityLabel("Refreshing")
    }
}
