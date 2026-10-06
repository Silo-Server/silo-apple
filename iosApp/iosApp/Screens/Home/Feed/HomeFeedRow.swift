#if !os(tvOS)
import SwiftUI

/// One horizontal rail. Shared by every variant so the differences between
/// layouts stay structural rather than incidental.
struct HomeFeedRow: View {
    let section: ResolvedSection
    /// Long-press actions, forwarded to every card in the row.
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil
    @State private var uiCustomization = UICustomizationPreferences.shared
    @State private var visibleItemId: String?
    @Environment(AppRouter.self) private var router

    private var isResume: Bool { HomeFeed.isResume(section) }
    private var usesStills: Bool { Self.usesStills(section) }
    private var isAudiobookRow: Bool { Self.isAudiobookRow(section) }

    /// Resume rows render as 16:9 stills — showing where you are inside a
    /// runtime is the entire job of the row, and a 2:3 poster can't do it.
    /// "Next Up" is episode-shaped for the same reason. Audiobook rows are
    /// the exception: their art is square with no backdrop, so a still would
    /// crop the cover — they keep the square poster card, which carries its
    /// own progress rail on resume rows.
    private static func usesStills(_ section: ResolvedSection) -> Bool {
        guard !isAudiobookRow(section) else { return false }
        if HomeFeed.isResume(section) { return true }
        return section.sectionType.lowercased().contains("next")
            && section.items.contains { $0.type.lowercased() == "episode" }
    }

    private static func isAudiobookRow(_ section: ResolvedSection) -> Bool {
        !section.items.isEmpty && section.items.allSatisfy(\.isAudiobook)
    }

    private static var stillWidth: CGFloat {
        HomeFeedMetrics.stillWidth * UICustomizationPreferences.shared.cardPresentation.posterSize.scale
    }

    /// Width of a poster card in a row, after the Poster Size setting.
    static var posterWidth: CGFloat {
        HomeFeedMetrics.posterWidth * UICustomizationPreferences.shared.cardPresentation.posterSize.scale
    }

    /// The artwork a card in `section`'s row draws, and its size.
    static func cardArtwork(for item: SectionItem, in section: ResolvedSection) -> CardArtwork? {
        if usesStills(section) {
            return CardArtwork(url: HomeStillCard.art(for: item).url, pointSize: HomeStillCard.artworkSize(width: stillWidth))
        }
        guard let url = item.posterUrl else { return nil }
        return CardArtwork(
            url: url,
            pointSize: HomePosterCard.artworkSize(width: posterWidth, aspect: isAudiobookRow(section) ? .square : .poster)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: HomeFeedMetrics.headerGap) {
            HomeSectionHeader(
                title: section.title,
                icon: isResume ? "play.circle.fill" : nil
            )

            rowScroller
        }
    }

    @ViewBuilder
    private var rowScroller: some View {
        cardsScroll
            .mediaRailScrolling()
            .scrollPosition(id: $visibleItemId, anchor: HorizontalMediaRailLayout.scrollAnchor)
            .environment(\.itemDetailBrowseSource, detailBrowseSource)
            .onAppear {
                let initialId = validSelectionId(
                    preferred: visibleItemId ?? section.items.first?.contentId
                )
                visibleItemId = initialId
            }
            .onChange(of: section.items.map(\.contentId)) { _, newIds in
                let preferred = newIds.contains(visibleItemId ?? "")
                    ? visibleItemId
                    : newIds.first
                visibleItemId = preferred
            }
            #if os(iOS)
            .onChange(of: router.presentedItemDetail) { _, presentation in
                // Only iPad's horizontally paged detail deck drives its source
                // row. An iPhone detail opens in place; scrolling the row while
                // its zoom transition is restoring it creates a visible drift.
                guard !HorizontalMediaRailLayout.isPhone,
                      presentation?.browseSource?.originID == detailBrowseSource.originID,
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
            LazyHStack(alignment: HorizontalMediaRailLayout.cardAlignment, spacing: HomeFeedMetrics.cardSpacing) {
                ForEach(section.items) { item in
                    Group {
                        if usesStills {
                            HomeStillCard(
                                item: item,
                                width: Self.stillWidth,
                                showsCaption: uiCustomization.cardPresentation.caption.showsTitle,
                                showsMetadata: uiCustomization.cardPresentation.caption.showsMetadata,
                                opensResumeContext: isResume,
                                onRemoveFromContinueWatching: removalAction(for: item),
                                onSetWatched: watchedAction(for: item)
                            )
                        } else {
                            HomePosterCard(
                                item: item,
                                width: Self.posterWidth,
                                showsCaption: uiCustomization.cardPresentation.caption.showsTitle,
                                showsMetadata: uiCustomization.cardPresentation.caption.showsMetadata,
                                showsProgress: isResume,
                                opensResumeContext: isResume,
                                aspect: isAudiobookRow ? .square : .poster,
                                episodeAccessibilityLabel: episodeAccessibilityLabel(for: item),
                                onRemoveFromContinueWatching: removalAction(for: item),
                                onSetWatched: watchedAction(for: item)
                            )
                        }
                    }
                    .id(item.contentId)
                    .onAppear { warmCards(after: item) }
                }
            }
            .scrollTargetLayout()
            .phoneMediaRailBounds()
        }
        .contentMargins(.horizontal, HomeFeedMetrics.gutter, for: .scrollContent)
        .scrollClipDisabled()
    }

    /// Decode the next cards before a swipe brings them into view.
    private func warmCards(after item: SectionItem) {
        guard let index = section.items.firstIndex(where: { $0.id == item.id }) else { return }
        ArtworkLookahead.warmCards(after: index, in: section.items) { Self.cardArtwork(for: $0, in: section) }
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

    /// Episode context for accessibility when episode-discovery cards are
    /// visually captioned with their series name.
    private func episodeAccessibilityLabel(for item: SectionItem) -> String? {
        EpisodeCardCaption.accessibilityLabel(for: item)
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
