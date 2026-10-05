import SwiftUI

extension ResolvedSection {
    var isContinueWatchingSection: Bool {
        let type = sectionType.lowercased()
        return type == "continue_watching" || type == "in_progress"
    }
}

/// A single section row on the home screen.
/// Wraps MediaRow and handles "continue watching" progress display.
/// Picks the thumbnail layout for episode-centric sections (Next Up,
/// and Continue Watching resume rows).
struct SectionRow: View {
    let section: ResolvedSection
    /// Destination ID plus the card that initiated navigation. Continue
    /// Watching may substitute a parent Series ID while retaining the episode
    /// card as context for the detail route seed.
    let onItemTap: (_ destinationContentId: String, _ item: SectionItem) -> Void
    var onSeeAll: (() -> Void)? = nil
    var onRemoveFromContinueWatching: ((SectionItem) -> Void)? = nil
    var onSetWatched: ((SectionItem, Bool) async -> Bool)? = nil
    var prefersDefaultFocusOnFirstItem: Bool = false
    /// Forwarded to `MediaRow` — see `MediaRow.defaultFocusPriority`.
    var defaultFocusPriority: DefaultFocusEvaluationPriority = .userInitiated
    /// Programmatic focus kick forwarded to the underlying `MediaRow` — used
    /// when an unrelated view (e.g. the tvOS top menu) hands focus down into
    /// this row rather than the user d-padding into it.
    var focusRequest: Int = 0
    /// Optional exact item target for the programmatic focus kick.
    var focusRequestItemId: String? = nil
    /// tvOS detail-pop token forwarded to `MediaRow`; the row's ownership gate
    /// ensures only the launch row restores its exact previously focused card.
    var detailReturnFocusRequest: Int = 0
    var onMoveUp: (() -> Void)? = nil
    /// tvOS-only: card-focus reports forwarded from `MediaRow` so hosts
    /// can drive the Skyline focus marquee with `(item, row title)`.
    var onItemFocus: ((SectionItem) -> Void)? = nil
    /// Optional poster/square card width forwarded to `MediaRow` —
    /// Skyline's dense landing rows (§5.6) pass a compact width.
    var cardWidth: CGFloat? = nil
    /// Optional tvOS card-strip padding override. Skyline uses this to keep
    /// the focused row short enough for the next row title preview.
    var cardVerticalPadding: CGFloat? = nil
    /// Down at the row boundary — forwarded to `MediaRow` for the section pager.
    var onMoveDown: (() -> Void)? = nil
    /// Live tvOS ownership gate for context-menu focus restoration.
    var focusRestorationOwner: Binding<Bool>? = nil
    #if !os(tvOS)
    @State private var detailBrowseOriginID = UUID().uuidString
    #endif
    /// Reports watched changes for rows without an owning model's handler.
    @State private var watchedFeedback = MediaActionFeedback()

    #if os(tvOS)
    @Environment(\.browseLibraryId) private var playbackLibraryId
    @Environment(AppRouter.self) private var router
    #endif
    @Environment(\.allowsDirectPlayback) private var allowsDirectPlayback

    private var isContinueWatching: Bool {
        section.isContinueWatchingSection
    }

    private var isEpisodeRow: Bool { Self.isEpisodeRow(section) }

    private var layout: MediaRowLayout { Self.layout(for: section) }

    /// True when the row should render 16:9 episode stills instead of posters.
    /// A dedicated "Next Up" row always does. For other episode-bearing rows
    /// the platforms differ: tvOS Skyline keeps every episode row as a still,
    /// and keeps Continue Watching as a still-based resume row even when the
    /// row currently contains movies only. iOS/iPadOS/macOS reserve stills for
    /// Continue Watching rows that actually contain episodes and render
    /// episode-discovery rows (e.g. "Recently Released Episodes") as ordinary
    /// series posters with an S·E badge.
    private static func isEpisodeRow(_ section: ResolvedSection) -> Bool {
        if section.sectionType.lowercased().contains("next") {
            return true
        }
        let hasEpisodeItems = section.items.contains(where: { $0.type.lowercased() == "episode" })
        #if os(tvOS)
        if section.isContinueWatchingSection {
            return true
        }
        return hasEpisodeItems
        #else
        return section.isContinueWatchingSection && hasEpisodeItems
        #endif
    }

    /// The card shape a section's row uses. Audiobook covers are square, so
    /// rows made entirely of audiobooks (Continue Listening, audiobook
    /// library rails) use 1:1 tiles instead of stretching the cover into a
    /// 2:3 poster.
    static func layout(for section: ResolvedSection) -> MediaRowLayout {
        if isEpisodeRow(section) { return .thumbnail }
        if !section.items.isEmpty, section.items.allSatisfy(\.isAudiobook) { return .square }
        return .poster
    }

    /// Library and recommendation rows draw their episode stills (Next Up)
    /// at Home's still width. tvOS keeps the shared Skyline thumbnail width.
    static var thumbnailCardWidth: CGFloat? {
        #if os(tvOS)
        nil
        #else
        HomeFeedMetrics.stillWidth
        #endif
    }

    private var showProgress: Bool {
        isContinueWatching || isEpisodeRow
    }

    var body: some View {
        #if os(tvOS)
        mediaRow
        #else
        // Continue Watching uses Home's row on every page, so a library's
        // resume cards keep Home's stills, size and play button.
        if isContinueWatching {
            HomeFeedRow(
                section: section,
                onRemoveFromContinueWatching: onRemoveFromContinueWatching,
                onSetWatched: { item, played in
                    await setWatched(item, played: played)
                }
            )
            .mediaActionFeedback(watchedFeedback)
        } else {
            mediaRow
        }
        #endif
    }

    private var mediaRow: some View {
        MediaRow(
            title: section.title,
            items: section.items,
            onItemTap: selectItem,
            onItemPlay: allowsDirectPlayback ? playItem : nil,
            onSeeAll: onSeeAll,
            showProgress: showProgress,
            icon: isContinueWatching ? "play.circle.fill" : nil,
            layout: layout,
            prefersDefaultFocusOnFirstItem: prefersDefaultFocusOnFirstItem,
            defaultFocusPriority: defaultFocusPriority,
            focusRequest: focusRequest,
            focusRequestItemId: focusRequestItemId,
            detailReturnFocusRequest: detailReturnFocusRequest,
            onRemoveFromContinueWatching: isContinueWatching ? onRemoveFromContinueWatching : nil,
            onOpenContextDetail: nil,
            showsPlayInContextMenu: isContinueWatching,
            onSetWatched: { item, played in
                await setWatched(item, played: played)
            },
            onMoveUp: onMoveUp,
            onItemFocus: onItemFocus,
            cardWidth: cardWidth,
            thumbnailCardWidth: Self.thumbnailCardWidth,
            cardVerticalPadding: cardVerticalPadding,
            onMoveDown: onMoveDown,
            focusRestorationOwner: focusRestorationOwner
        )
        .mediaActionFeedback(watchedFeedback)
        #if !os(tvOS)
        .environment(
            \.itemDetailBrowseSource,
            ItemDetailBrowseSource(
                originID: detailBrowseOriginID,
                contentIDs: section.items.map(\.contentId)
            )
        )
        #endif
    }

    private func playItem(_ item: SectionItem) {
        #if os(tvOS)
        router.presentPlayer(
            contentId: item.contentId,
            libraryId: playbackLibraryId,
            resumePosition: item.positionSeconds,
            prefersLastUsedVersion: isContinueWatching,
            posterURL: item.posterUrl,
            backdropURL: item.backdropUrl
        )
        #endif
    }

    /// Continue Watching Select opens context instead of immediately playing:
    /// episodes land on their parent Series with the exact season and episode
    /// active, while movies retain their own detail page. Direct Resume/Play
    /// remains available from the remote Play/Pause command and long press.
    private func selectItem(_ contentId: String) {
        guard let item = section.items.first(where: { $0.contentId == contentId }) else {
            return
        }

        onItemTap(contentId, item)
    }

    /// Home injects a model-owned mutation so its membership-driven rows and
    /// cache update immediately. Shared SectionRow callers use the card
    /// dispatcher and report its outcome here, because the card leaves
    /// reporting to whoever supplies its watched action.
    private func setWatched(_ item: SectionItem, played: Bool) async -> Bool {
        if let onSetWatched {
            return await onSetWatched(item, played)
        }

        let outcome = await MediaCardWatchedSync.setWatched(
            contentId: item.contentId, played: played, seriesId: item.seriesId
        )
        // The card confirms an applied change itself; reporting it here too
        // would play the success haptic twice.
        guard outcome == .applied else {
            watchedFeedback.report(outcome)
            return false
        }
        NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        return true
    }

}
