import SwiftUI

/// Displays a placeholder when a list or grid has no content.
struct EmptyStateView: View {
    let icon: String
    let title: String
    var subtitle: String? = nil

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(.siloOnSurface.opacity(0.3))

            Text(title)
                .font(.siloSubheadline)
                .foregroundColor(.siloOnSurface)

            if let subtitle {
                Text(subtitle)
                    .font(.siloCaption)
                    .foregroundColor(.siloSecondaryText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, SiloTheme.largePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
