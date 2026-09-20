#if !os(tvOS)
import SwiftUI

/// Compact season-loading placeholder with the exact artwork/caption rhythm of
/// the real episode rail. It is intentionally static—no shimmer, blur, or
/// timer—so it stays cheap while artwork and playback metadata are decoding.
struct PhoneEpisodeRailSkeleton: View {
    var captionStyleOverride: CardCaptionStyle? = nil
    @State private var uiCustomization = UICustomizationPreferences.shared

    private var cardWidth: CGFloat {
        240 * uiCustomization.cardPresentation.posterSize.scale
    }

    private var stillHeight: CGFloat { cardWidth * 9 / 16 }

    private var captionStyle: CardCaptionStyle {
        captionStyleOverride ?? uiCustomization.cardPresentation.caption
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .top, spacing: 14) {
                ForEach(0..<3, id: \.self) { index in
                    episodeCard(index: index)
                }
            }
            .padding(.horizontal, SiloTheme.safePadding)
            .padding(.vertical, 4)
        }
        .scrollDisabled(true)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func episodeCard(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.09 + Double(index) * 0.01))
                .frame(width: cardWidth, height: stillHeight)

            if captionStyle.showsTitle {
                VStack(alignment: .leading, spacing: 4) {
                    skeletonLine(width: 62, height: 8, opacity: 0.12)
                    skeletonLine(width: cardWidth * 0.68, height: 12, opacity: 0.16)

                    if captionStyle.showsMetadata {
                        skeletonLine(width: cardWidth * 0.42, height: 9, opacity: 0.10)
                        skeletonLine(width: cardWidth * 0.92, height: 9, opacity: 0.09)
                        skeletonLine(width: cardWidth * 0.78, height: 9, opacity: 0.09)
                        skeletonLine(width: cardWidth * 0.55, height: 9, opacity: 0.09)
                    }
                }
            }
        }
        .frame(width: cardWidth, alignment: .leading)
    }

    private func skeletonLine(width: CGFloat, height: CGFloat, opacity: Double) -> some View {
        RoundedRectangle(cornerRadius: height / 2, style: .continuous)
            .fill(Color.white.opacity(opacity))
            .frame(width: width, height: height)
    }
}

#endif
