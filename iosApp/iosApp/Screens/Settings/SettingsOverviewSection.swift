#if os(iOS)
import SwiftUI

/// Labeled card grouping related Settings destinations, matching the web
/// app's section hierarchy while keeping native controls inside the card.
struct SettingsOverviewSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.caption)
                .bold()
                .tracking(1.5)
                .foregroundStyle(Color.continuumSecondaryText)
                .padding(.horizontal, 4)

            VStack(spacing: 0) {
                content
            }
            .background(Color.continuumSurfaceElevated.opacity(0.88))
            .clipShape(RoundedRectangle(cornerRadius: 18))
            .overlay {
                RoundedRectangle(cornerRadius: 18)
                    .strokeBorder(Color.continuumOutline, lineWidth: 1)
            }
        }
    }
}
#endif
