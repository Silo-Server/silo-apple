#if !os(tvOS)
import SwiftUI

/// Loading, empty, compact-rail, and expanded-list states for one season.
struct PhoneEpisodePage: View {
    let episodes: [EpisodeListItem]
    let isLoading: Bool
    let usesExpandedList: Bool
    let onSelect: (String) -> Void
    var onPlay: ((String) -> Void)? = nil
    var currentContentId: String? = nil
    var selectsCenteredEpisode = false
    var captionStyleOverride: CardCaptionStyle? = nil

    /// The last real page height is retained while a new season is loading.
    /// Without this, replacing the carousel with a small spinner collapses the
    /// detail stack and changes the vertical scroll offset under the user's
    /// finger.
    @State private var settledContentHeight: CGFloat = 0

    var body: some View {
        Group {
            if isLoading, episodes.isEmpty {
                if usesExpandedList {
                    PhoneEpisodeListSkeleton()
                } else {
                    PhoneEpisodeRailSkeleton(captionStyleOverride: captionStyleOverride)
                }
            } else if episodes.isEmpty {
                Text("No episodes available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, ContinuumTheme.safePadding)
                    .padding(.vertical, 12)
            } else if usesExpandedList {
                PhoneEpisodeList(
                    episodes: episodes,
                    onSelect: onSelect,
                    onPlay: onPlay,
                    currentContentId: currentContentId
                )
            } else {
                PhoneEpisodeRail(
                    episodes: episodes,
                    onSelect: onSelect,
                    onPlay: onPlay,
                    currentContentId: currentContentId,
                    selectsCenteredEpisode: selectsCenteredEpisode,
                    captionStyleOverride: captionStyleOverride
                )
            }
        }
        .frame(
            minHeight: isLoading && episodes.isEmpty && settledContentHeight > 0
                ? settledContentHeight
                : nil,
            alignment: .top
        )
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.size.height
        } action: { height in
            guard !isLoading, !episodes.isEmpty, height > 0 else { return }
            settledContentHeight = height
        }
        .animation(.easeInOut(duration: 0.16), value: isLoading && episodes.isEmpty)
    }
}

/// Compact season-loading placeholder with the exact artwork/caption rhythm of
/// the real episode rail. It is intentionally static—no shimmer, blur, or
/// timer—so it stays cheap while artwork and playback metadata are decoding.
private struct PhoneEpisodeRailSkeleton: View {
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
            .padding(.horizontal, ContinuumTheme.safePadding)
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

/// Regular-width fallback for routes that intentionally keep the iPad list.
/// The redesigned series overview forces the carousel on iPad, but season and
/// episode routes still need a stable loading footprint of their own.
private struct PhoneEpisodeListSkeleton: View {
    var body: some View {
        VStack(spacing: PhoneEpisodeListLayout.rowSpacing) {
            ForEach(0..<3, id: \.self) { index in
                HStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.white.opacity(0.09 + Double(index) * 0.01))
                        .frame(width: 136, height: 76)

                    VStack(alignment: .leading, spacing: 9) {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.15))
                            .frame(width: 150, height: 11)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.10))
                            .frame(maxWidth: .infinity)
                            .frame(height: 9)
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(Color.white.opacity(0.08))
                            .frame(maxWidth: 240)
                            .frame(height: 9)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, ContinuumTheme.safePadding)
        .padding(.vertical, 4)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
#endif
