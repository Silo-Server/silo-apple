import Foundation

@Observable
@MainActor
class HomeViewModel {
    typealias DismissContinueWatching = (
        _ contentId: String,
        _ progressUpdatedAt: String
    ) async throws -> Void
    typealias DismissNextUp = (_ contentId: String, _ seriesId: String) async throws -> Void
    typealias SetWatched = (_ contentId: String, _ played: Bool) async throws -> Void
    typealias FetchHomeSections = () async throws -> SectionsResponse

    /// Non-empty rows in server order; featured rows render as ordinary rows.
    var sections: [ResolvedSection] = []
    /// True only while loading with nothing cached to show.
    var isLoading = false
    var error: ErrorState?
    /// Whether the app is in the background, kept by `HomeView` from the
    /// scene phase.
    var isInBackground = false {
        didSet {
            if isInBackground, isLoadInFlight { loadCrossedBackground = true }
        }
    }
    /// A load failed, or its retry was put off, while the app was in the
    /// background: Home kept its placeholder and loads again when the app
    /// returns.
    private var reloadsOnReturn = false
    /// Numbers each load. A newer load replaces one still in flight, whose
    /// late result or failure is then ignored.
    private var loadGeneration = 0
    private var isLoadInFlight = false
    /// The load in flight started or ran while the app was in the
    /// background, so suspension may have cut its request off.
    private var loadCrossedBackground = false
    private(set) var actionError: ErrorState?
    /// An unconfirmed watched change, offered for discard. Never re-sent.
    var personalStateNotice: PersonalStateNotice?
    private var pendingContinueWatchingDismissals = Set<String>()
    private var pendingWatchedUpdates = Set<String>()
    private let dismissContinueWatching: DismissContinueWatching
    private let dismissNextUp: DismissNextUp
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

    init(
        dismissContinueWatching: @escaping DismissContinueWatching = { contentId, progressUpdatedAt in
            try await SiloAPI.shared.dismissContinueWatchingItem(
                contentId: contentId,
                progressUpdatedAt: progressUpdatedAt
            )
        },
        dismissNextUp: @escaping DismissNextUp = { contentId, seriesId in
            try await SiloAPI.shared.dismissNextUpItem(
                contentId: contentId,
                seriesId: seriesId
            )
        },
        setWatched: @escaping SetWatched = { contentId, played in
            try await PersonalStateSync.set(.watched, contentId: contentId, to: played)
        },
        fetchHomeSections: @escaping FetchHomeSections = {
            try await StartupContentPrefetcher.fetchHomeSections()
        }
    ) {
        self.dismissContinueWatching = dismissContinueWatching
        self.dismissNextUp = dismissNextUp
        self.updateWatchedState = setWatched
        self.fetchHomeSections = fetchHomeSections

        // Hydrate from the shared cache so the first render after a
        // navigation paints last-known data without any network wait.
        if let cached: SectionsResponse = ResponseCache.shared.get(CacheKey.homeSections) {
            sections = cached.sections.filter { !$0.items.isEmpty }
        }
    }

    func loadSections() async {
        // A load that crossed into the background may be waiting on a request
        // that suspension cut off. Start a new request instead of joining it.
        if isLoadInFlight, loadCrossedBackground {
            StartupContentPrefetcher.invalidateHomeSectionsInFlight()
        }
        loadGeneration += 1
        let generation = loadGeneration
        isLoadInFlight = true
        loadCrossedBackground = isInBackground
        isLoading = sections.isEmpty
        error = nil
        reloadsOnReturn = false

        do {
            try await fetchAndApplySections(generation)
        } catch let err {
            // Don't blow away painted content on a transient failure —
            // surface the error only when there's nothing to show.
            if generation == loadGeneration, sections.isEmpty {
                let state = ErrorState(err)
                if state.isTransient, !isInBackground {
                    await retryTransientInitialLoad(generation)
                } else {
                    showFailure(state)
                }
            }
        }

        guard generation == loadGeneration else { return }
        isLoadInFlight = false
        // A load put off until the app returns keeps the placeholder up.
        isLoading = reloadsOnReturn
    }

    /// Loads again as the app returns when the last load failed, was put off
    /// in the background, or is still waiting on a request that crossed into
    /// the background: suspension may have cut that request off, and its
    /// failure would arrive only now. The new load replaces it. `HomeView`
    /// calls this as the app becomes active: Home stays mounted while the
    /// app is away, so its appear task does not run again.
    func reloadIfInterrupted() async {
        let isWaitingOnCutOffLoad = isLoadInFlight && loadCrossedBackground
        guard isWaitingOnCutOffLoad || error != nil || reloadsOnReturn else { return }
        await loadSections()
    }

    /// The Continue Watching row mixes two kinds of cards, and the server keys
    /// their dismissals differently. In-progress items are dismissed against
    /// their exact `progress_updated_at`, so resuming playback re-surfaces
    /// them. Next Up episodes have no progress row; they are dismissed on the
    /// `next_up` surface keyed by series. Sending a fabricated timestamp for
    /// a Next Up card is accepted by the server but never matches anything,
    /// so the card returns on the next fresh fetch.
    func dismissContinueWatchingItem(_ item: SectionItem) async {
        let removal: (
            request: () async throws -> Void,
            mutate: (_ sections: [ResolvedSection]) -> [ResolvedSection]
        )
        if let progressUpdatedAt = item.progressUpdatedAt {
            removal = (
                request: { [dismissContinueWatching] in
                    try await dismissContinueWatching(item.contentId, progressUpdatedAt)
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
                    try await dismissNextUp(item.contentId, seriesId)
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
            try await removal.request()

            // A Home request that started before the dismissal can contain the
            // removed item. Invalidate that generation before committing the
            // authoritative local/cache update so a late response cannot put it
            // back on screen.
            StartupContentPrefetcher.invalidateHomeSectionsInFlight()
            // Dismissing a row's last card removes the row.
            sections = removal.mutate(sections).filter { !$0.items.isEmpty }
            ResponseCache.shared.update(CacheKey.homeSections, as: SectionsResponse.self) { response in
                response = SectionsResponse(sections: removal.mutate(response.sections))
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
                ).filter { !$0.items.isEmpty }
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
            switch PersonalStateSync.outcome(for: error) {
            case .held(let change): personalStateNotice = .held(change)
            case .skipped: break
            case .applied, .failed: actionError = ErrorState(error)
            }
            return false
        }
    }

    /// Applies the rows only while `generation` is the latest load, so an
    /// older load finishing late cannot replace newer rows.
    private func fetchAndApplySections(_ generation: Int) async throws {
        let response = try await fetchHomeSections()
        guard generation == loadGeneration else { return }
        sections = response.sections.filter { !$0.items.isEmpty }
        error = nil
    }

    private func retryTransientInitialLoad(_ generation: Int) async {
        try? await Task.sleep(nanoseconds: 750_000_000)
        guard !Task.isCancelled, generation == loadGeneration else { return }
        // The app may have left during the wait; a request now would risk
        // being cut off, so load again on return instead.
        guard !isInBackground else {
            reloadsOnReturn = true
            return
        }

        do {
            try await fetchAndApplySections(generation)
        } catch {
            if generation == loadGeneration { showFailure(ErrorState(error)) }
        }
    }

    /// A failure in the background (a request cut off when the app was
    /// suspended, or no network while a push woke it) says nothing about
    /// what the person will find on return, so it is not shown; Home loads
    /// again then.
    private func showFailure(_ state: ErrorState) {
        if isInBackground {
            reloadsOnReturn = true
        } else {
            error = state
        }
    }
}
