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
    /// Long-press actions, forwarded to every card in the row.
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil
    /// Continue Watching reports only the card that has finished settling in
    /// the center. Home uses it to change a fixed backdrop wash; no feed layout
    /// state depends on this callback.
    var onCenteredResumeItemChange: ((SectionItem?) -> Void)? = nil
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var visibleItemId: String?
    @Environment(AppRouter.self) private var router

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

    private var isAudiobookRow: Bool {
        !section.items.isEmpty && section.items.allSatisfy(\.isAudiobook)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
            HomeSectionHeader(
                title: section.title,
                icon: isResume ? "play.circle.fill" : nil,
                style: headerStyle
            )

            rowScroller
        }
    }

    @ViewBuilder
    private var rowScroller: some View {
        cardsScroll
            .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
            .scrollPosition(id: $visibleItemId, anchor: .center)
            .environment(\.itemDetailBrowseSource, detailBrowseSource)
            .onAppear {
                let initialId = validSelectionId(
                    preferred: visibleItemId ?? section.items.first?.contentId
                )
                visibleItemId = initialId
                publishResumeSelection(initialId)
            }
            .onChange(of: section.items.map(\.contentId)) { _, newIds in
                let preferred = newIds.contains(visibleItemId ?? "")
                    ? visibleItemId
                    : newIds.first
                visibleItemId = preferred
                publishResumeSelection(preferred)
            }
            .onScrollPhaseChange { _, newPhase in
                guard newPhase == .idle else { return }
                publishResumeSelection(visibleItemId)
            }
            #if os(iOS)
            .onChange(of: router.presentedItemDetail) { _, presentation in
                guard presentation?.browseSource?.originID == detailBrowseSource.originID,
                      let contentID = presentation?.contentId,
                      section.items.contains(where: { $0.contentId == contentID })
                else { return }

                withAnimation(.easeInOut(duration: 0.28)) {
                    visibleItemId = contentID
                }
            }
            #endif
    }

    private var cardsScroll: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: cardSpacing) {
                ForEach(section.items) { item in
                    Group {
                        if usesStills {
                            HomeStillCard(
                                item: item,
                                width: HomeFeedMetrics.stillWidth
                                    * uiCustomization.cardPresentation.posterSize.scale,
                                showsCaption: uiCustomization.cardPresentation.caption.showsTitle,
                                showsMetadata: uiCustomization.cardPresentation.caption.showsMetadata,
                                onRemoveFromContinueWatching: removalAction(for: item),
                                onSetWatched: watchedAction(for: item)
                            )
                        } else {
                            HomePosterCard(
                                item: item,
                                width: posterWidth * uiCustomization.cardPresentation.posterSize.scale,
                                showsCaption: uiCustomization.cardPresentation.caption.showsTitle,
                                showsMetadata: uiCustomization.cardPresentation.caption.showsMetadata,
                                showsProgress: isResume,
                                aspect: isAudiobookRow ? .square : .poster,
                                episodeBadge: episodeBadge(for: item),
                                onRemoveFromContinueWatching: removalAction(for: item),
                                onSetWatched: watchedAction(for: item)
                            )
                        }
                    }
                    .id(item.contentId)
                }
            }
            .scrollTargetLayout()
        }
        .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
        .scrollClipDisabled()
    }

    private var detailBrowseSource: ItemDetailBrowseSource {
        ItemDetailBrowseSource(
            originID: "home:\(section.id)",
            contentIDs: section.items.map(\.contentId)
        )
    }

    private func validSelectionId(preferred: String?) -> String? {
        guard let preferred,
              section.items.contains(where: { $0.contentId == preferred }) else {
            return section.items.first?.contentId
        }
        return preferred
    }

    private func publishResumeSelection(_ id: String?) {
        guard isResume, let onCenteredResumeItemChange else { return }
        let selected = id.flatMap { id in
            section.items.first(where: { $0.contentId == id })
        }
        onCenteredResumeItemChange(selected)
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
}
#endif
