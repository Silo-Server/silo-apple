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
    /// Long-press actions, forwarded to every card in the row.
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil

    private var isResume: Bool { HomeFeed.isResume(section) }

    private var hasEpisodes: Bool {
        section.items.contains { $0.type.lowercased() == "episode" }
    }

    /// Resume rows render as 16:9 stills — showing where you are inside a
    /// runtime is the entire job of the row, and a 2:3 poster can't do it.
    /// "Next Up" is episode-shaped for the same reason. Audiobook rows are
    /// the exception: their art is square with no backdrop, so a still would
    /// crop the cover — they keep the square poster card, which carries its
    /// own progress rail on resume rows.
    private var usesStills: Bool {
        guard !forcesPosters, !isAudiobookRow else { return false }
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
                            HomeStillCard(
                                item: item,
                                onRemoveFromContinueWatching: removalAction(for: item),
                                onSetWatched: watchedAction(for: item)
                            )
                        } else {
                            HomePosterCard(
                                item: item,
                                width: posterWidth,
                                showsBadges: badgesAreInformative,
                                showsProgress: isResume,
                                aspect: isAudiobookRow ? .square : .poster,
                                episodeBadge: episodeBadge(for: item),
                                onRemoveFromContinueWatching: removalAction(for: item),
                                onSetWatched: watchedAction(for: item)
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

    /// "S2 · E10" for an episode drawn as a poster. Episode-discovery rows
    /// caption with the series name, so without this several episodes of one
    /// series render as identical cards.
    private func episodeBadge(for item: SectionItem) -> String? {
        guard item.type.lowercased() == "episode",
              let season = item.seasonNumber,
              let episode = item.episodeNumber else { return nil }
        return "S\(season) · E\(episode)"
    }

    /// Removal is only offered where it means something — a resume row.
    private func removalAction(for item: SectionItem) -> (() -> Void)? {
        guard isResume, let onRemoveFromContinueWatching else { return nil }
        return { onRemoveFromContinueWatching(item) }
    }

    private func watchedAction(for item: SectionItem) -> ((Bool) async -> Bool)? {
        guard let onSetWatched else { return nil }
        return { played in await onSetWatched(item, played) }
    }

    /// Server section titles read like query descriptions — "Recently
    /// Released in Movies", "Recently Added in TV Shows". Trimming the
    /// "in <library>" tail leaves a curated-sounding label without needing
    /// a server change, and the library context is already implied by the
    /// artwork in the row.
    ///
    /// Only generated titles are trimmed: an admin-named custom section
    /// ("Made in Britain") is someone's deliberate choice, and cutting at
    /// the *last* " in " keeps a generated title whose label itself contains
    /// "in" from losing more than the library tail. `customized` is not a
    /// useful guard here — the server sets it for any profile override
    /// (position, item limit), not just a renamed title.
    private var displayTitle: String {
        guard section.isCustom != true,
              let range = section.title.range(of: " in ", options: [.caseInsensitive, .backwards]) else {
            return section.title
        }
        return String(section.title[..<range.lowerBound])
    }
}
#endif
