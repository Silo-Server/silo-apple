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
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.white.opacity(0.14), lineWidth: 0.8)
        }
        .shadow(color: .black.opacity(0.28), radius: 14, x: 0, y: 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Refreshing")
    }
}
