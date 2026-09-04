import SwiftUI

/// Displays a content rating (e.g. PG-13, TV-MA) in a pill chip.
/// Plezy style: muted background, no border stroke.
struct ContentRatingBadge: View {
    let rating: String

    var body: some View {
        if !rating.isEmpty {
            Text(rating)
                .font(.siloSmall)
                .fontWeight(.medium)
                .foregroundColor(.siloOnSurface)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(Color.white.opacity(0.15))
                )
        }
    }
}
