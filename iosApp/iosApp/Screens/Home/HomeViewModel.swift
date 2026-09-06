import Foundation

/// Device-local, per-server/profile Home row visibility and order. The server
/// remains authoritative for which rows exist and what they contain; this
/// projection only arranges the rows it returns. Unknown/new server rows append
/// in server order and remain visible until the user chooses otherwise.
@Observable
@MainActor
final class HomeSectionPreferences {
    static let shared = HomeSectionPreferences()

    private(set) var orderedSectionIds: [String] = []
    private(set) var hiddenSectionIds = Set<String>()
    /// Changes only for explicit preference/layout transitions—not ordinary
    /// Home data refreshes—so Home can reset its row band and marquee once.
    private(set) var layoutRevision = 0

    @ObservationIgnored private let defaults: SharedDefaults
    @ObservationIgnored private let storageKey: @MainActor () -> String?
    @ObservationIgnored private var loadedStorageKey: String?

    private struct StoredLayout: Codable {
        var orderedSectionIds: [String]
        var hiddenSectionIds: Set<String>
    }

    init(
        defaults: SharedDefaults = .shared,
        storageKey: @escaping @MainActor () -> String? = HomeSectionPreferences.activeStorageKey
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        refresh()
    }

    func refresh() {
        let key = storageKey()
        guard key != loadedStorageKey else { return }
        loadedStorageKey = key

        guard let key,
              let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredLayout.self, from: data) else {
            orderedSectionIds = []
            hiddenSectionIds = []
            layoutRevision &+= 1
            return
        }

        orderedSectionIds = Self.unique(stored.orderedSectionIds)
        hiddenSectionIds = stored.hiddenSectionIds
        layoutRevision &+= 1
    }

    func isVisible(_ sectionId: String) -> Bool {
        !hiddenSectionIds.contains(sectionId)
    }

    func setVisible(_ visible: Bool, sectionId: String) {
        let wasVisible = isVisible(sectionId)
        guard wasVisible != visible else { return }
        if visible {
            hiddenSectionIds.remove(sectionId)
        } else {
            hiddenSectionIds.insert(sectionId)
        }
        layoutRevision &+= 1
        persist()
    }

    /// Replace the order of currently-known rows while retaining remembered
    /// identities that are temporarily absent (for example an empty Continue
    /// Watching row). If they return later, they recover their saved position.
    func setOrder(_ sectionIds: [String]) {
        let currentOrder = Self.unique(sectionIds)
        let currentSet = Set(currentOrder)
        let updatedOrder = currentOrder + orderedSectionIds.filter {
            !currentSet.contains($0)
        }
        guard updatedOrder != orderedSectionIds else { return }
        orderedSectionIds = updatedOrder
        layoutRevision &+= 1
        persist()
    }

    /// Hidden rows are removed before the Skyline feed receives this array.
    /// Consequently the next visible row occupies the same fixed row slot;
    /// no placeholder or vertical gap can enter the Home layout.
    func arrangedSections(
        _ sections: [ResolvedSection],
        includingHidden: Bool = false
    ) -> [ResolvedSection] {
        let nonEmpty = sections.filter { !$0.items.isEmpty }
        let rank = Dictionary(
            uniqueKeysWithValues: orderedSectionIds.enumerated().map { ($0.element, $0.offset) }
        )

        let arranged = nonEmpty.enumerated().sorted { lhs, rhs in
            let lhsRank = rank[lhs.element.id]
            let rhsRank = rank[rhs.element.id]
            switch (lhsRank, rhsRank) {
            case let (.some(left), .some(right)):
                return left < right
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return lhs.offset < rhs.offset
            }
        }.map(\.element)

        guard !includingHidden else { return arranged }
        return arranged.filter { !hiddenSectionIds.contains($0.id) }
    }

    private func persist() {
        guard let key = storageKey() else { return }
        loadedStorageKey = key
        let stored = StoredLayout(
            orderedSectionIds: orderedSectionIds,
            hiddenSectionIds: hiddenSectionIds
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        defaults.set(data, forKey: key)
    }

    private static func unique(_ ids: [String]) -> [String] {
        var seen = Set<String>()
        return ids.filter { seen.insert($0).inserted }
    }

    private static func activeStorageKey() -> String? {
        guard let profileId = AuthService.shared.profileId, !profileId.isEmpty else {
            return nil
        }
        let serverId = ServerRegistry.shared.activeServerId ?? "default"
        return "\(platformStoragePrefix).\(serverId).\(profileId)"
    }

    private static var platformStoragePrefix: String {
        #if os(tvOS)
        "tvos.homeSections.v1"
        #elseif os(iOS)
        "ios.homeSections.v1"
        #elseif os(macOS)
        "mac.homeSections.v1"
        #else
        "apple.homeSections.v1"
        #endif
    }
}

@Observable
@MainActor
class HomeViewModel {
    typealias DismissContinueWatching = (
        _ contentId: String,
        _ progressUpdatedAt: String,
        _ auth: CapturedOrdinaryRequestAuth?
    ) async throws -> Void
    typealias DismissNextUp = (_ contentId: String, _ seriesId: String, _ auth: CapturedOrdinaryRequestAuth?) async throws -> Void
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
    private let dismissNextUp: DismissNextUp
    private let updateWatchedState: SetWatched
    private let fetchHomeSections: FetchHomeSections
    private let responseIsCurrent: (SectionsResponse) async -> Bool
    private var loadGeneration = 0
    private var displayedHomeResponse: SectionsResponse?
    var personalListAuth: CapturedOrdinaryRequestAuth? { displayedHomeResponse?.homeReadAuth }

    var isShowingActionError: Bool {
        get { actionError != nil }
        set {
            if !newValue {
                actionError = nil
            }
        }
    }

    /// Sections for Home in server order, filtered to non-empty rows.
    /// `featured` sections render as ordinary rows in their server position —
    /// Apple Home has no separate hero surface.
    var regularSections: [ResolvedSection] {
        sections.filter { !$0.items.isEmpty }
    }

    init(
        dismissContinueWatching: @escaping DismissContinueWatching = { contentId, progressUpdatedAt, auth in
            try await SiloAPI.shared.dismissContinueWatchingItem(
                contentId: contentId,
                progressUpdatedAt: progressUpdatedAt, auth: auth
            )
        },
        dismissNextUp: @escaping DismissNextUp = { contentId, seriesId, auth in
            try await SiloAPI.shared.dismissNextUpItem(
                contentId: contentId,
                seriesId: seriesId, auth: auth
            )
        },
        setWatched: @escaping SetWatched = { contentId, played in
            try await SiloAPI.shared.setWatched(contentId: contentId, played: played)
        },
        fetchHomeSections: @escaping FetchHomeSections = {
            try await StartupContentPrefetcher.fetchHomeSections()
        },
        responseIsCurrent: @escaping (SectionsResponse) async -> Bool = {
            await StartupContentPrefetcher.homeResponseIsCurrent($0)
        }
    ) {
        self.dismissContinueWatching = dismissContinueWatching
        self.dismissNextUp = dismissNextUp
        self.updateWatchedState = setWatched
        self.fetchHomeSections = fetchHomeSections
        self.responseIsCurrent = responseIsCurrent
    }

    func loadSections() async {
        loadGeneration += 1
        let generation = loadGeneration
        if let displayedHomeResponse {
            let current = await responseIsCurrent(displayedHomeResponse)
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if !current { sections = []; self.displayedHomeResponse = nil }
        }
        if let cached = await StartupContentPrefetcher.cachedHomeSections() {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            sections = cached.sections.filter { !$0.items.isEmpty }
            displayedHomeResponse = cached
        }
        guard generation == loadGeneration, !Task.isCancelled else { return }
        isLoading = sections.isEmpty
        isRefreshing = !sections.isEmpty
        error = nil
        defer {
            if generation == loadGeneration { isLoading = false; isRefreshing = false }
        }
        do {
            try await fetchAndApplySections(generation: generation)
        } catch let err {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            if sections.isEmpty {
                let state = ErrorState(err)
                if state.isTransient {
                    await retryTransientInitialLoad(generation: generation)
                } else { self.error = state }
            }
        }
    }

    /// The Continue Watching row mixes two kinds of cards, and the server keys
    /// their dismissals differently. In-progress items are dismissed against
    /// their exact `progress_updated_at`, so resuming playback re-surfaces
    /// them. Next Up episodes have no progress row; they are dismissed on the
    /// `next_up` surface keyed by series. Sending a fabricated timestamp for
    /// a Next Up card is accepted by the server but never matches anything,
    /// so the card returns on the next fresh fetch.
    func dismissContinueWatchingItem(_ item: SectionItem) async {
        let observation = displayedHomeResponse
        let auth = observation?.homeReadAuth
        let generation = loadGeneration
        let removal: (
            request: () async throws -> Void,
            mutate: (_ sections: [ResolvedSection]) -> [ResolvedSection]
        )
        if let progressUpdatedAt = item.progressUpdatedAt {
            removal = (
                request: { [dismissContinueWatching] in
                    try await dismissContinueWatching(item.contentId, progressUpdatedAt, auth)
                },
                mutate: { sections in
                    HomeSectionsMutation.removingContinueWatchingItem(
                        contentId: item.contentId,
                        from: sections
                    )
                }
            )
        } else if let seriesId = item.seriesId, !seriesId.isEmpty {
            removal = (
                request: { [dismissNextUp] in
                    try await dismissNextUp(item.contentId, seriesId, auth)
                },
                mutate: { sections in
                    HomeSectionsMutation.removingNextUpItem(
                        contentId: item.contentId,
                        from: sections
                    )
                }
            )
        } else {
            // Neither surface can represent this card. Leave it in place rather
            // than hide it locally and have it reappear after relaunch.
            return
        }

        guard pendingContinueWatchingDismissals.insert(item.contentId).inserted else {
            return
        }
        defer { pendingContinueWatchingDismissals.remove(item.contentId) }

        actionError = nil

        do {
            if let observation {
                let current = await responseIsCurrent(observation)
                guard current, generation == loadGeneration, !Task.isCancelled else { return }
            }
            guard containsDismissalAnchor(item), !Task.isCancelled else { return }
            try await removal.request()
            if let observation {
                let current = await responseIsCurrent(observation)
                guard current, generation == loadGeneration, !Task.isCancelled else { return }
            }
            guard containsDismissalAnchor(item), !Task.isCancelled else { return }

            // A Home request that started before the dismissal can contain the
            // removed item. Invalidate that generation before committing the
            // authoritative local/cache update so a late response cannot put it
            // back on screen.
            loadGeneration += 1
            isLoading = false
            isRefreshing = false
            StartupContentPrefetcher.invalidateHomeSectionsInFlight()
            sections = removal.mutate(sections)
            ResponseCache.shared.update(CacheKey.homeSections, as: SectionsResponse.self) { response in
                if let auth {
                    guard let owner = response.homeReadAuth,
                          StartupContentPrefetcher.sameRecommendationOwner(owner, auth) else { return }
                }
                guard containsDismissalAnchor(item, in: response.sections) else { return }
                response = SectionsResponse(sections: removal.mutate(response.sections))
            }
        } catch {
            if let observation {
                let current = await responseIsCurrent(observation)
                guard current, generation == loadGeneration, !Task.isCancelled else { return }
            }
            actionError = ErrorState(error)
        }
    }

    private func containsDismissalAnchor(_ item: SectionItem, in observedSections: [ResolvedSection]? = nil) -> Bool {
        (observedSections ?? sections).contains { section in
            ["continue_watching", "in_progress", "next_up"].contains(section.sectionType) &&
                section.items.contains { $0.contentId == item.contentId &&
                    $0.progressUpdatedAt == item.progressUpdatedAt && $0.seriesId == item.seriesId }
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
            loadGeneration += 1
            isLoading = false
            isRefreshing = false
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

    private func fetchAndApplySections(generation: Int) async throws {
        let response = try await fetchHomeSections()
        let current = await responseIsCurrent(response)
        guard generation == loadGeneration, !Task.isCancelled else { throw CancellationError() }
        guard current else { sections = []; throw HTTPError.requestIdentityChanged }
        sections = response.sections.filter { !$0.items.isEmpty }
        displayedHomeResponse = response
        error = nil
    }

    private func retryTransientInitialLoad(generation: Int) async {
        try? await Task.sleep(nanoseconds: 750_000_000)
        guard generation == loadGeneration, !Task.isCancelled else { return }

        do {
            try await fetchAndApplySections(generation: generation)
        } catch {
            guard generation == loadGeneration, !Task.isCancelled else { return }
            self.error = ErrorState(error)
        }
    }
}
