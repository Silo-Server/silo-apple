#if os(tvOS)
import Foundation

/// Shared cache of `ItemDetailViewModel` instances keyed by contentId.
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

    private var entries: [String: ItemDetailViewModel] = [:]
    /// Access order, oldest first. `contentId` at `order.last` is the
    /// most-recently touched entry.
    private var order: [String] = []
    private let capacity = 20

    private init() {}

    /// Returns the cached view model for `contentId`, creating one on
    /// first visit. Touches the LRU order. Callers should trigger a
    /// `loadDetail` refresh themselves after binding the result —
    /// the cache deliberately doesn't kick off network work.
    func viewModel(for contentId: String) -> ItemDetailViewModel {
        if let existing = entries[contentId] {
            touch(contentId)
            return existing
        }
        let vm = ItemDetailViewModel()
        // Home/library focus enrichment may already have fetched the full
        // catalog payload before the user presses Select. Hydrate it here so
        // TVItemDetailView's very first body evaluation can paint that cached
        // hero instead of waiting for its `.task` to begin.
        vm.hydrateFromCache(contentId: contentId)
        entries[contentId] = vm
        order.append(contentId)
        evictIfNeeded()
        return vm
    }

    /// Peek without creating or touching. Used by invalidation helpers
    /// that need to walk the parent chain from an existing entry.
    func peek(_ contentId: String) -> ItemDetailViewModel? {
        entries[contentId]
    }

    /// Invalidate the cached entry and any parent series/season entries
    /// derived from its `ItemDetail`. Meant for mutations that change
    /// userData the parent page reads back (mark-watched, playback
    /// progress, etc.). "Invalidate" = trigger a fresh fetch if the
    /// entry is still resident — the cached data keeps painting so the
    /// user never sees a spinner.
    func markStaleFamily(contentId: String) {
        refresh(contentId)

        guard let vm = entries[contentId], let detail = vm.detail else { return }

        if let seriesId = detail.seriesId {
            refresh(seriesId)
            if let seasonNumber = detail.seasonNumber, seasonNumber > 0 {
                refresh("\(seriesId)-S\(seasonNumber)")
            }
        }
    }

    /// Refresh a single entry. No-op if we don't hold one.
    func markStale(contentId: String) {
        refresh(contentId)
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
        guard let vm = entries[contentId] else { return }
        Task { await vm.loadDetail(contentId: contentId) }
    }

    private func touch(_ contentId: String) {
        if let idx = order.firstIndex(of: contentId) {
            order.remove(at: idx)
        }
        order.append(contentId)
    }

    private func evictIfNeeded() {
        while order.count > capacity {
            let oldest = order.removeFirst()
            entries.removeValue(forKey: oldest)
        }
    }
}
#endif
