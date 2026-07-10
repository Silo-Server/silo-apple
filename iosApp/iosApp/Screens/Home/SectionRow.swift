import SwiftUI

/// A single section row on the home screen.
/// Wraps MediaRow and handles "continue watching" progress display.
/// Picks the thumbnail layout for episode-centric sections (Next Up,
/// and Continue Watching resume rows).
struct SectionRow: View {
    let section: ResolvedSection
    let onItemTap: (String) -> Void
    var onSeeAll: (() -> Void)? = nil
    var prefersDefaultFocusOnFirstItem: Bool = false
    /// Programmatic focus kick forwarded to the underlying `MediaRow` — used
    /// when an unrelated view (e.g. the tvOS top menu) hands focus down into
    /// this row rather than the user d-padding into it.
    var focusRequest: Int = 0
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

    #if os(tvOS)
    @Environment(AppRouter.self) private var router
    #endif

    private var isContinueWatching: Bool {
        section.sectionType == "continue_watching" || section.sectionType == "in_progress"
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
            onItemTap: onItemTap,
            onItemPlay: playItem,
            onSeeAll: onSeeAll,
            showProgress: showProgress,
            icon: isContinueWatching ? "play.circle.fill" : nil,
            layout: layout,
            prefersDefaultFocusOnFirstItem: prefersDefaultFocusOnFirstItem,
            focusRequest: focusRequest,
            onRemoveFromContinueWatching: isContinueWatching ? { removeFromContinueWatching($0) } : nil,
            onSetWatched: { setWatched($0, played: $1) },
            onMoveUp: onMoveUp,
            onItemFocus: onItemFocus,
            cardWidth: cardWidth,
            cardVerticalPadding: cardVerticalPadding,
            onMoveDown: onMoveDown
        )
    }

    private func playItem(_ item: SectionItem) {
        #if os(tvOS)
        router.presentPlayer(
            contentId: item.contentId,
            resumePosition: item.positionSeconds,
            posterURL: item.posterUrl,
            backdropURL: item.backdropUrl
        )
        #endif
    }

    private func removeFromContinueWatching(_ item: SectionItem) {
        guard let progressUpdatedAt = item.progressUpdatedAt else { return }

        Task {
            do {
                try await ContinuumAPI.shared.dismissContinueWatchingItem(
                    contentId: item.contentId,
                    progressUpdatedAt: progressUpdatedAt
                )
                NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
            } catch {
                print("[Home] Failed to remove \(item.contentId) from Continue Watching: \(error)")
            }
        }
    }

    private func setWatched(_ item: SectionItem, played: Bool) {
        Task {
            do {
                try await ContinuumAPI.shared.setWatched(contentId: item.contentId, played: played)
                NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
            } catch {
                print("[Home] Failed to update watched state for \(item.contentId): \(error)")
            }
        }
    }
}
