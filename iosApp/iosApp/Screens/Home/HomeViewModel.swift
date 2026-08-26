import Foundation

@Observable
@MainActor
class HomeViewModel {
    typealias DismissContinueWatching = (
        _ contentId: String,
        _ progressUpdatedAt: String
    ) async throws -> Void
    typealias SetWatched = (_ contentId: String, _ played: Bool) async throws -> Void
    typealias FetchHomeSections = () async throws -> SectionsResponse

    var sections: [ResolvedSection] = []
    /// True only on the very first load when no cached data exists.
    /// Returning visits paint cached sections instantly and use
    /// `isRefreshing` for the silent background fetch.
    var isLoading = false
    /// In-flight refresh signal — drives the inline indicator while
    /// painted content stays on screen.
    var isRefreshing = false
    var error: ErrorState?
    private(set) var actionError: ErrorState?
    private var pendingContinueWatchingDismissals = Set<String>()
    private var pendingWatchedUpdates = Set<String>()
    private let dismissContinueWatching: DismissContinueWatching
    private let updateWatchedState: SetWatched
    private let fetchHomeSections: FetchHomeSections

    var isShowingActionError: Bool {
        get { actionError != nil }
        set {
            if !newValue {
                actionError = nil
            }
        }
    }

    /// First non-empty section selected as the server-driven phone hero.
    var featuredSection: ResolvedSection? {
        sections.first { $0.isFeatured && !$0.items.isEmpty }
    }

    /// Sections for Home in server order, excluding the hero source so it is
    /// never repeated as a normal row on iOS or tvOS.
    var regularSections: [ResolvedSection] {
        sections.filter { !$0.isFeatured && !$0.items.isEmpty }
    }

    init(
        dismissContinueWatching: @escaping DismissContinueWatching = { contentId, progressUpdatedAt in
            try await ContinuumAPI.shared.dismissContinueWatchingItem(
                contentId: contentId,
                progressUpdatedAt: progressUpdatedAt
            )
        },
        setWatched: @escaping SetWatched = { contentId, played in
            try await ContinuumAPI.shared.setWatched(contentId: contentId, played: played)
        },
        fetchHomeSections: @escaping FetchHomeSections = {
            try await StartupContentPrefetcher.fetchHomeSections()
        }
    ) {
        self.dismissContinueWatching = dismissContinueWatching
        self.updateWatchedState = setWatched
        self.fetchHomeSections = fetchHomeSections

        // Hydrate from the shared cache so the first render after a
        // navigation paints last-known data without any network wait.
        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
            sections = cached.sections.filter { !$0.items.isEmpty }
        }
    }

    func loadSections() async {
        if sections.isEmpty {
            isLoading = true
        } else {
            isRefreshing = true
        }
        error = nil

        do {
            try await fetchAndApplySections()
        } catch let err {
            // Don't blow away painted content on a transient failure —
            // surface the error only when there's nothing to show.
            if sections.isEmpty {
                let state = ErrorState(err)
                if state.isTransient {
                    await retryTransientInitialLoad()
                } else {
                    self.error = state
                }
            }
        }

        isLoading = false
        isRefreshing = false
    }

    func dismissContinueWatchingItem(_ item: SectionItem) async {
        guard pendingContinueWatchingDismissals.insert(item.contentId).inserted else {
            return
        }
        defer { pendingContinueWatchingDismissals.remove(item.contentId) }

        actionError = nil
        let progressUpdatedAt = item.progressUpdatedAt
            ?? ISO8601DateFormatter().string(from: Date())

        do {
            try await dismissContinueWatching(item.contentId, progressUpdatedAt)

            // A Home request that started before the dismissal can contain the
            // removed item. Invalidate that generation before committing the
            // authoritative local/cache update so a late response cannot put it
            // back on screen.
            StartupContentPrefetcher.invalidateHomeSectionsInFlight()
            sections = HomeSectionsMutation.removingContinueWatchingItem(
                contentId: item.contentId,
                from: sections
            )
            ResponseCache.shared.update(CacheKey.homeSections, as: SectionsResponse.self) { response in
                response = SectionsResponse(
                    sections: HomeSectionsMutation.removingContinueWatchingItem(
                        contentId: item.contentId,
                        from: response.sections
                    )
                )
            }
        } catch {
            actionError = ErrorState(error)
        }
    }

    /// Updates playback state through the server, then immediately removes a
    /// completed item from membership-driven Home rows. A fresh Home fetch
    /// reconciles replacement Next Up episodes and watched state elsewhere.
    @discardableResult
    func setWatched(_ item: SectionItem, played: Bool) async -> Bool {
        guard pendingWatchedUpdates.insert(item.contentId).inserted else {
            return false
        }
        defer { pendingWatchedUpdates.remove(item.contentId) }

        actionError = nil

        do {
            try await updateWatchedState(item.contentId, played)

            // Never join or apply a Home request that began before this
            // mutation. It can carry the old Next Up membership.
            StartupContentPrefetcher.invalidateHomeSectionsInFlight()

            if played {
                sections = HomeSectionsMutation.removingCompletedItem(
                    contentId: item.contentId,
                    from: sections
                )
                ResponseCache.shared.update(CacheKey.homeSections, as: SectionsResponse.self) { response in
                    response = SectionsResponse(
                        sections: HomeSectionsMutation.removingCompletedItem(
                            contentId: item.contentId,
                            from: response.sections
                        )
                    )
                }
            }

            // The server may advance a series to its following episode. Keep
            // the local removal if this reconciliation cannot be fetched.
            await loadSections()
            return true
        } catch {
            actionError = ErrorState(error)
            return false
        }
    }

    private func fetchAndApplySections() async throws {
        let response = try await fetchHomeSections()
        sections = response.sections.filter { !$0.items.isEmpty }
        error = nil
    }

    private func retryTransientInitialLoad() async {
        try? await Task.sleep(nanoseconds: 750_000_000)
        guard !Task.isCancelled else { return }

        do {
            try await fetchAndApplySections()
        } catch {
            self.error = ErrorState(error)
        }
    }
}
