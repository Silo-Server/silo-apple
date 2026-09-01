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

    @State private var pendingDetailNavigationItemId: String?
    #if os(tvOS)
    @Environment(AppRouter.self) private var router
    @State private var detailNavigationTask: Task<Void, Never>?
    @State private var detailNavigationGeneration = 0
    #endif

    private var isContinueWatching: Bool {
        section.isContinueWatchingSection
    }

    private var hasEpisodeItems: Bool {
        section.items.contains(where: { $0.type.lowercased() == "episode" })
    }

    /// True when the row should render 16:9 episode stills instead of posters.
    /// A dedicated "Next Up" row always does. For other episode-bearing rows
    /// the platforms differ: tvOS Skyline keeps every episode row as a still,
    /// and keeps Continue Watching as a still-based resume row even when the
    /// row currently contains movies only. iOS/iPadOS/macOS reserve stills for
    /// Continue Watching rows that actually contain episodes and render
    /// episode-discovery rows (e.g. "Recently Released Episodes") as ordinary
    /// series posters with an S·E badge.
    private var isEpisodeRow: Bool {
        if section.sectionType.lowercased().contains("next") {
            return true
        }
        #if os(tvOS)
        if isContinueWatching {
            return true
        }
        return hasEpisodeItems
        #else
        return isContinueWatching && hasEpisodeItems
        #endif
    }

    /// Audiobook covers are square, so rows made entirely of audiobooks
    /// (Continue Listening, audiobook library rails) use 1:1 tiles
    /// instead of stretching the cover into a 2:3 poster.
    private var isAudiobookRow: Bool {
        !section.items.isEmpty && section.items.allSatisfy(\.isAudiobook)
    }

    private var layout: MediaRowLayout {
        if isEpisodeRow { return .thumbnail }
        if isAudiobookRow { return .square }
        return .poster
    }

    private var showProgress: Bool {
        isContinueWatching || isEpisodeRow
    }

    var body: some View {
        MediaRow(
            title: section.title,
            items: section.items,
            onItemTap: selectItem,
            onItemPlay: playItem,
            onSeeAll: onSeeAll,
            showProgress: showProgress,
            loadingItemId: pendingDetailNavigationItemId,
            icon: isContinueWatching ? "play.circle.fill" : nil,
            layout: layout,
            prefersDefaultFocusOnFirstItem: prefersDefaultFocusOnFirstItem,
            defaultFocusPriority: defaultFocusPriority,
            focusRequest: focusRequest,
            detailReturnFocusRequest: detailReturnFocusRequest,
            onRemoveFromContinueWatching: isContinueWatching ? onRemoveFromContinueWatching : nil,
            onOpenContextDetail: nil,
            showsPlayInContextMenu: isContinueWatching,
            onSetWatched: { item, played in
                await setWatched(item, played: played)
            },
            onMoveUp: onMoveUp,
            onItemFocus: onItemFocus,
            onFocusedItemIdChange: { focusedItemId in
                cancelPendingDetailNavigation(unlessFocusedOn: focusedItemId)
            },
            cardWidth: cardWidth,
            cardVerticalPadding: cardVerticalPadding,
            onMoveDown: onMoveDown,
            focusRestorationOwner: focusRestorationOwner
        )
        .onDisappear { cancelPendingDetailNavigation() }
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

        #if os(tvOS)
        if isContinueWatching {
            let isEpisode = item.type.lowercased() == "episode"
                || item.episodeNumber != nil
            if isEpisode,
               let seriesId = item.seriesId?.trimmingCharacters(in: .whitespacesAndNewlines),
               !seriesId.isEmpty,
               let seasonNumber = item.seasonNumber {
                prepareSeriesDetailAndNavigate(
                    to: seriesId,
                    from: item,
                    seasonNumber: seasonNumber,
                    episodeContentId: item.contentId
                )
            } else {
                onItemTap(item.contentId, item)
            }
            return
        }

        if SiloMediaType.isSeries(item.type) {
            prepareSeriesDetailAndNavigate(to: item.contentId, from: item)
            return
        }
        #endif
        onItemTap(contentId, item)
    }

    #if os(tvOS)
    /// A cold Series payload cannot be reconstructed safely from an episode
    /// card. Keep the fully-rendered source rail on screen while joining the
    /// existing metadata flight, then push only after the destination cache
    /// can paint a real header on its first frame.
    private func prepareSeriesDetailAndNavigate(
        to seriesContentId: String,
        from item: SectionItem,
        seasonNumber: Int? = nil,
        episodeContentId: String? = nil
    ) {
        guard pendingDetailNavigationItemId == nil else { return }

        let cacheKey = CacheKey.itemDetail(seriesContentId)
        if let _: ItemDetail = ResponseCache.shared.get(cacheKey) {
            finishSeriesDetailNavigation(
                to: seriesContentId,
                from: item,
                seasonNumber: seasonNumber,
                episodeContentId: episodeContentId
            )
            return
        }

        pendingDetailNavigationItemId = item.contentId
        detailNavigationGeneration &+= 1
        let generation = detailNavigationGeneration
        detailNavigationTask = Task { @MainActor in
            defer {
                if detailNavigationGeneration == generation {
                    pendingDetailNavigationItemId = nil
                    detailNavigationTask = nil
                }
            }

            do {
                let detail = try await MetadataRequestPool.shared.itemDetail(
                    contentId: seriesContentId
                )
                try Task.checkCancellation()
                ResponseCache.shared.set(detail, for: cacheKey)
            } catch is CancellationError {
                return
            } catch {
                // Preserve the existing retry/error destination when the
                // preload itself fails; the important cold path still waits
                // on the populated cache instead of pushing a blank shell.
            }

            guard !Task.isCancelled,
                  detailNavigationGeneration == generation,
                  pendingDetailNavigationItemId == item.contentId else { return }
            finishSeriesDetailNavigation(
                to: seriesContentId,
                from: item,
                seasonNumber: seasonNumber,
                episodeContentId: episodeContentId
            )
        }
    }

    private func finishSeriesDetailNavigation(
        to seriesContentId: String,
        from item: SectionItem,
        seasonNumber: Int?,
        episodeContentId: String?
    ) {
        if let seasonNumber, let episodeContentId {
            TVSeriesDetailNavigationContextStore.stage(
                seriesContentId: seriesContentId,
                seasonNumber: seasonNumber,
                episodeContentId: episodeContentId
            )
        }
        onItemTap(seriesContentId, item)
    }

    private func cancelPendingDetailNavigation(unlessFocusedOn focusedItemId: String?) {
        guard let pendingDetailNavigationItemId,
              focusedItemId != pendingDetailNavigationItemId else { return }
        detailNavigationGeneration &+= 1
        detailNavigationTask?.cancel()
        detailNavigationTask = nil
        self.pendingDetailNavigationItemId = nil
    }

    private func cancelPendingDetailNavigation() {
        detailNavigationGeneration &+= 1
        detailNavigationTask?.cancel()
        detailNavigationTask = nil
        pendingDetailNavigationItemId = nil
    }
    #else
    private func cancelPendingDetailNavigation(unlessFocusedOn focusedItemId: String?) {}
    private func cancelPendingDetailNavigation() {}
    #endif

    /// Home injects a model-owned mutation so its membership-driven rows and
    /// cache update immediately. Shared SectionRow callers retain the original
    /// direct API behavior when no owning model provides an action.
    private func setWatched(_ item: SectionItem, played: Bool) async -> Bool {
        if let onSetWatched {
            return await onSetWatched(item, played)
        }

        do {
            try await ContinuumAPI.shared.setWatched(
                contentId: item.contentId,
                played: played
            )
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
            return true
        } catch {
            print("[SectionRow] Failed to update watched state for \(item.contentId): \(error)")
            return false
        }
    }

}
