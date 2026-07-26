#if !os(tvOS)
import SwiftUI

/// One horizontal rail. Shared by every variant so the differences between
/// layouts stay structural rather than incidental.
struct HomeFeedRow: View {
    let section: ResolvedSection
    var headerStyle: HomeSectionHeader.Style = .standard
    var posterWidth: CGFloat = HomeFeedMetrics.posterWidth
    var cardSpacing: CGFloat = HomeFeedMetrics.cardSpacing
    /// Forces poster shape even for episode-bearing rows.
    var forcesPosters: Bool = false
    /// Quality badges. Off for dense rows, where a badge covers a third of
    /// the artwork and density is the whole point.
    var showsBadges: Bool = true

    private var isResume: Bool { HomeFeed.isResume(section) }

    private var hasEpisodes: Bool {
        section.items.contains { $0.type.lowercased() == "episode" }
    }

    /// Resume rows always render as 16:9 stills — showing where you are
    /// inside a runtime is the entire job of the row, and a 2:3 poster can't
    /// do it. "Next Up" is episode-shaped for the same reason.
    private var usesStills: Bool {
        guard !forcesPosters else { return false }
        if isResume { return true }
        return section.sectionType.lowercased().contains("next") && hasEpisodes
    }

    /// A badge every card in the row carries is not a badge, it's a texture.
    /// On a library that is uniformly 4K Dolby Vision, stamping `DV` on all
    /// twelve tiles says exactly as much as stamping nothing — which is how
    /// the shipping build ended up with `480P` on everything. So the row only
    /// badges when its items actually differ, and the detail page carries the
    /// full spec line regardless.
    private var badgesAreInformative: Bool {
        guard showsBadges else { return false }
        let stamped = section.items.map { HomeFeedMeta.notableBadges(for: $0).joined() }
        return Set(stamped).count > 1
    }

    private var isAudiobookRow: Bool {
        !section.items.isEmpty && section.items.allSatisfy(\.isAudiobook)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
            HomeSectionHeader(
                title: displayTitle,
                icon: isResume ? "play.circle.fill" : nil,
                style: headerStyle
            )

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: cardSpacing) {
                    ForEach(section.items) { item in
                        if usesStills {
                            HomeStillCard(item: item)
                        } else {
                            HomePosterCard(
                                item: item,
                                width: posterWidth,
                                showsBadges: badgesAreInformative,
                                showsProgress: isResume
                            )
                        }
                    }
                }
                .scrollTargetLayout()
            }
            .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
            .scrollClipDisabled()
        }
    }

    /// Server section titles read like query descriptions — "Recently
    /// Released in Movies", "Recently Added in TV Shows". Trimming the
    /// "in <library>" tail leaves a curated-sounding label without needing
    /// a server change, and the library context is already implied by the
    /// artwork in the row.
    private var displayTitle: String {
        guard let range = section.title.range(of: " in ", options: [.caseInsensitive]) else {
            return section.title
        }
        return String(section.title[..<range.lowerBound])
    }
}
#endif
