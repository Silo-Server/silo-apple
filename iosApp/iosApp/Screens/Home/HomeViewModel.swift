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

    /// Sections for Home in server order, filtered to non-empty rows.
    /// `featured` sections render as ordinary rows in their server position —
    /// Apple Home has no separate hero surface.
    var regularSections: [ResolvedSection] {
        sections.filter { !$0.items.isEmpty }
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
