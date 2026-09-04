import SwiftUI

/// Small badge showing a rating value with a source label.
/// Plezy style: pill-shaped chip with muted background.
struct RatingBadge: View {
    let source: String
    let value: Double

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "star.fill")
                .font(.system(size: 10))
                .foregroundColor(.siloWarning)

            Text(String(format: "%.1f", value))
                .font(.siloCaption)
                .foregroundColor(.siloOnSurface)
                .fontWeight(.semibold)

            Text(source)
                .font(.siloSmall)
                .foregroundColor(.siloSecondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            Capsule().fill(Color.siloSurfaceElevated)
        )
    }
}
