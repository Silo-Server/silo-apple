import SwiftUI

/// First-load placeholders in the geometry of poster grids and rows: quiet
/// static fills, no shimmer, replaced in place by the real cards.
struct PosterSkeletonCard: View {
    var body: some View {
        RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
            .fill(Color.white.opacity(0.09))
            .aspectRatio(SiloTheme.posterCardWidth / SiloTheme.posterCardHeight, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .accessibilityHidden(true)
    }
}

/// Section rows of poster placeholders, for row-based pages still loading.
struct PosterRowsSkeleton: View {
    var rowCount = 3
    var cardCount = 6
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var cardWidth: CGFloat {
        SiloTheme.posterCardWidth * uiCustomization.cardPresentation.posterSize.scale
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SiloTheme.largePadding) {
            ForEach(0..<rowCount, id: \.self) { _ in
                VStack(alignment: .leading, spacing: 12) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(width: 140, height: 16)
                    HStack(spacing: 12) {
                        ForEach(0..<cardCount, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: SiloTheme.cornerRadius, style: .continuous)
                                .fill(Color.white.opacity(0.09))
                                .frame(
                                    width: cardWidth,
                                    height: cardWidth * SiloTheme.posterCardHeight / SiloTheme.posterCardWidth
                                )
                        }
                    }
                }
            }
        }
        .padding(.horizontal, SiloTheme.padding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Loading")
    }
}
