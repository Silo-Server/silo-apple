#if os(tvOS)
import Foundation

/// Shared cache of `ItemDetailViewModel` instances keyed by content ID and browsing library.
///
/// Navigating between series → season → episode pages used to push a
/// fresh view each time, each with a brand-new view model that showed
/// `LoadingView` while the network call ran. The cache lets a returning
/// screen render its last-known detail payload immediately; a background
/// refresh then fans in corrected userData (watched flags, progress,
/// etc.) without painting a spinner.
///
/// Bounded LRU so we don't retain every screen the user has ever visited
/// for a session. Clearing hooks live in `AuthService` so signing out or
/// switching profiles drops per-profile userData.
///
/// All public methods are expected to be called from the main thread —
/// SwiftUI view init, `.task` bodies, `onDisappear`, etc. — so the cache
/// doesn't bother with synchronization. Concurrent access from a
/// background thread is a programmer error.
@MainActor
final class ItemDetailCache {
    static let shared = ItemDetailCache()

    private struct Key: Hashable {
        let contentId: String
        let libraryId: Int?
    }

    private var entries: [Key: ItemDetailViewModel] = [:]
    /// Access order, oldest first. `contentId` at `order.last` is the
    /// most-recently touched entry.
    private var order: [Key] = []
    private let capacity = 20

    private init() {}

    /// Returns the cached view model for `contentId`, creating one on
    /// first visit. Touches the LRU order. Callers should trigger a
    /// `loadDetail` refresh themselves after binding the result —
    /// the cache deliberately doesn't kick off network work.
    func viewModel(for contentId: String, libraryId: Int? = nil) -> ItemDetailViewModel {
        let key = Key(contentId: contentId, libraryId: libraryId)
        if let existing = entries[key] {
            // A source-card preload may have completed after this model was
            // first created. Re-adopt the response before the destination's
            // first body evaluation instead of returning an older empty shell.
            existing.hydrateFromCache(contentId: contentId)
            touch(key)
            return existing
        }
        let vm = ItemDetailViewModel(libraryId: libraryId)
        // Home/library focus enrichment may already have fetched the full
        // catalog payload before the user presses Select. Hydrate it here so
        // TVItemDetailView's very first body evaluation can paint that cached
        // hero instead of waiting for its `.task` to begin.
        vm.hydrateFromCache(contentId: contentId)
        entries[key] = vm
        order.append(key)
        evictIfNeeded()
        return vm
    }

    /// Peek without creating or touching. Used by invalidation helpers
    /// that need to walk the parent chain from an existing entry.
    func peek(_ contentId: String, libraryId: Int? = nil) -> ItemDetailViewModel? {
        entries[Key(contentId: contentId, libraryId: libraryId)]
    }

    /// Invalidate the cached entry and any parent series/season entries
    /// derived from its `ItemDetail`. Meant for mutations that change
    /// userData the parent page reads back (mark-watched, playback
    /// progress, etc.). "Invalidate" = trigger a fresh fetch if the
    /// entry is still resident — the cached data keeps painting so the
    /// user never sees a spinner.
    func markStaleFamily(contentId: String) {
        var targets: Set<String> = [contentId]
        for (key, vm) in entries where key.contentId == contentId {
            guard let detail = vm.detail, let seriesId = detail.seriesId else { continue }
            targets.insert(seriesId)
            if let seasonNumber = detail.seasonNumber {
                targets.insert("\(seriesId)-S\(seasonNumber)")
            }
        }
        for target in targets { refresh(target) }
    }

    /// Refresh resident detail models only after the player's final progress
    /// write has completed. Unlike `markStaleFamily`, this is awaited by the
    /// player teardown path so a catalog read can never overtake the watched
    /// mutation and permanently repaint the pre-play state.
    @discardableResult
    func refreshAfterPlayback(contentIds: Set<String>) async -> Set<String> {
        var targets = contentIds
        for (key, vm) in entries where contentIds.contains(key.contentId) {
            guard let detail = vm.detail,
                  let rawSeriesId = detail.seriesId else { continue }
            let seriesId = rawSeriesId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !seriesId.isEmpty else { continue }
            targets.insert(seriesId)
            if let seasonNumber = detail.seasonNumber {
                targets.insert("\(seriesId)-S\(seasonNumber)")
            }
        }

        // Most-recently visited first: in the normal Series -> player return,
        // the visible combined Series page updates before any older cached
        // episode/season page. Each model keeps painting its cached payload
        // while this non-coalesced authoritative refresh runs.
        let residentTargets = order.reversed().filter { targets.contains($0.contentId) }
        for key in residentTargets {
            guard let viewModel = entries[key] else { continue }
            // Refresh the season the page shows rather than re-running the
            // initial pick, which could move it to an earlier season.
            viewModel.initialResumeSeasonNumber = viewModel.selectedSeason?.seasonNumber
            await viewModel.loadDetail(
                contentId: key.contentId,
                coalescesMetadataRequests: false
            )
        }
        return Set(residentTargets.map(\.contentId))
    }

    /// Drop every cached entry. Called from `AuthService.signOut` and
    /// profile-switch to keep per-profile userData from leaking across
    /// accounts.
    func clearAll() {
        entries.removeAll()
        order.removeAll()
    }

    // MARK: - Internals

    private func refresh(_ contentId: String) {
        for (key, vm) in entries where key.contentId == contentId {
            // A mutation refresh must not join a read dispatched before the write.
            Task {
                await vm.loadDetail(contentId: key.contentId, coalescesMetadataRequests: false)
            }
        }
    }

    private func touch(_ key: Key) {
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
        }
        order.append(key)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
#endif
