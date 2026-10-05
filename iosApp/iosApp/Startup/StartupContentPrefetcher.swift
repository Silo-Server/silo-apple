import Foundation

extension Notification.Name {
    static let userLibrariesDidRefresh = Notification.Name("userLibrariesDidRefresh")
}

@MainActor
enum StartupContentPrefetcher {
    /// Home rows' artwork bytes warmed past what Home itself shows.
    private static let maxHomeArtworkURLs = 40
    private static let maxSectionArtworkURLs = 12
    /// For You shows two eight-card rows in its initial viewport. Logos are
    /// tiny compared with backdrops, so warm exactly those visible candidates
    /// rather than waiting for each focus rest to begin its own request.
    #if os(tvOS)
    private static let maxRecommendationLogoURLs = 16
    #endif
    private static let maxBrowseArtworkURLs = 12
    #if os(tvOS)
    /// About the first three rows of the library grid.
    private static let maxGridArtworkURLs = 18
    #endif
    private static let maxProfileArtworkURLs = 8
    private static let browsePageSize = 60

    private static let profiles = SharedFetch<[UserProfile]>()
    private static let homeSections = SharedFetch<APIv2HomeSectionsRead>()
    private static let recommendations = SharedFetch<SectionsResponse>()
    /// Most screens read the library list as they appear; reuse a result this
    /// fresh instead of repeating the request at launch.
    private static let userLibraries = SharedFetch<LibrariesResponse>(reuseWindow: .seconds(15))
    private static var librarySections: [Int: SharedFetch<APIv2LibrarySectionsRead>] = [:]
    private static var browseFirstPages: [String: SharedFetch<CatalogListPage>] = [:]
    #if os(tvOS)
    /// One bounded cold-start warmup for the Series library the top-level tab
    /// will actually open: its landing payload plus the first Series hero, so
    /// Select never paints a loading action pill before the detail screen.
    private static var tvSeriesLandingTasks: [Int: Task<Void, Never>] = [:]
    #endif
    private static var profileScopedGeneration = 0
    private static var homeSectionsGeneration = 0
    private static var profilesGeneration = 0

    static func resetProfileScopedPrefetches() {
        profileScopedGeneration += 1
        homeSections.reset()
        recommendations.reset()
        userLibraries.reset()
        librarySections.values.forEach { $0.reset() }
        librarySections.removeAll()
        browseFirstPages.values.forEach { $0.reset() }
        browseFirstPages.removeAll()
        #if os(tvOS)
        tvSeriesLandingTasks.values.forEach { $0.cancel() }
        tvSeriesLandingTasks.removeAll()
        #endif
    }

    static func resetAllPrefetches() {
        profilesGeneration += 1
        profiles.reset()
        resetProfileScopedPrefetches()
    }

    static func prefetchProfiles() {
        Task {
            _ = try? await fetchProfiles()
        }
    }

    static func fetchProfiles() async throws -> [UserProfile] {
        let generation = profilesGeneration
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin("profiles", isOriginator: !profiles.isInFlight)
        #endif
        let task = profiles.join { try await AuthService.shared.getProfiles() }
        do {
            let result = try await task.value
            try validateProfilesGeneration(generation)
            profiles.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(result, for: CacheKey.profiles)
            await AuthService.shared.reconcileAvailableProfiles(result)
            prefetchProfileArtwork(for: result)
            return result
        } catch {
            profiles.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            throw error
        }
    }

    static func prefetchHomeSections() {
        Task {
            _ = try? await fetchHomeSections()
        }
    }

    /// Cancels only Home's current single-flight request and prevents any
    /// waiter on that generation from applying its stale response. The shared
    /// response cache is intentionally left intact for the caller to update.
    static func invalidateHomeSectionsInFlight() {
        homeSectionsGeneration += 1
        homeSections.reset()
    }

    /// Capture the active profile/server generation when a player is created.
    /// Call only AFTER its progress write completes. A late previous-profile
    /// player must never invalidate or refresh the new profile's Home cache.
    static func homeRefreshAfterPlaybackWrite() -> @MainActor () -> Void {
        let generation = profileScopedGeneration
        return {
            guard generation == profileScopedGeneration else { return }
            invalidateHomeSectionsInFlight()
            ResponseCache.shared.remove(CacheKey.homeSections)
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        }
    }

    static func fetchHomeSections() async throws -> SectionsResponse {
        let profileGeneration = profileScopedGeneration
        let homeGeneration = homeSectionsGeneration
        let requestProfileID = AuthService.shared.profileId
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin("home_sections", isOriginator: !homeSections.isInFlight)
        #endif
        let task = homeSections.join { try await SiloAPI.shared.homeSections() }
        do {
            let read = try await task.value
            // The rows belong to the profile they were fetched for. Never
            // cache or show them once the session acts as someone else.
            let isCurrentOwner = await SiloAPI.shared.isCurrentOwner(read.auth)
            try validateProfileScopedGeneration(profileGeneration)
            try validateHomeSectionsGeneration(homeGeneration)
            guard isCurrentOwner else { throw HTTPError.requestIdentityChanged }
            homeSections.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(read.response, for: CacheKey.homeSections)
            prefetchHomeArtwork(for: read.response)
            return read.response
        } catch {
            homeSections.finish(task, value: nil)
            // Emitted before the recovery call: `recoverFromInvalidProfile`
            // tears the session down to profile selection, and the breadcrumb
            // explaining why must precede the transition it causes.
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            if let requestProfileID,
               Self.indicatesInvalidProfile(error) {
                await AuthService.shared.recoverFromInvalidProfile(
                    expectedProfileID: requestProfileID
                )
            }
            throw error
        }
    }

    nonisolated static func indicatesInvalidProfile(_ error: Error) -> Bool {
        // v2 names a locked profile without a valid X-Profile-Token this way.
        // A missing profile is a plain `not_found`, which v2 does not tell
        // apart from any other missing resource.
        guard case .problem(let problem) = error as? APIv2Error else { return false }
        return problem.identifier == "profile_verification_required"
    }

    #if os(iOS) || os(tvOS)
    // MARK: - Diagnostics

    /// Stable, coarse reason token for the breadcrumb `reason`; anything
    /// unrecognized is `other`, so no server text leaks. `invalid_profile` is
    /// separate because it triggers profile recovery. Nonisolated: pure, and
    /// called from `PrefetchProbe.finish`.
    nonisolated static func prefetchFailureReason(_ error: Error) -> String {
        if indicatesCancellation(error) { return "cancelled" }
        if let apiError = error as? APIv2Error {
            if indicatesInvalidProfile(apiError) { return "invalid_profile" }
            switch apiError {
            case .serverUpdateRequired:
                return "server_update_required"
            case .problem(let problem):
                return statusReason(problem.status)
            case .httpStatus(let statusCode):
                return statusReason(statusCode)
            default:
                return "decode_failed"
            }
        }
        // v2 reads decode their 2xx bodies outside `mapErrors`, so a
        // malformed body arrives as a bare `DecodingError`, not as
        // `HTTPError.decodingFailed`.
        if error is DecodingError { return "decode_failed" }
        guard let httpError = error as? HTTPError else {
            // URLSession surfaces transport failures as NSError before
            // HTTPClient wraps them; the cancelled case was already claimed
            // above, so anything left in this domain is a real transport
            // failure.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { return "network" }
            return "other"
        }
        switch httpError {
        case .serverUrlNotConfigured:
            return "no_server"
        case .requestIdentityChanged, .authorityChanged:
            return "identity_changed"
        case .network(let underlying):
            // HTTPClient wraps every transport error, cancellation included,
            // in `.network`; cancellation is not a connectivity failure.
            return indicatesCancellation(underlying) ? "cancelled" : "network"
        case .decodingFailed:
            return "decode_failed"
        case .http(let statusCode, _):
            return statusReason(statusCode)
        case .invalidURL, .invalidResponse:
            return "other"
        }
    }

    /// Bucketed, not verbatim: the status class is what distinguishes "the
    /// server rejected us" from "the server is broken", and the exact code
    /// adds cardinality without adding meaning here.
    nonisolated private static func statusReason(_ statusCode: Int) -> String {
        if statusCode == 401 || statusCode == 403 { return "unauthorized" }
        if (500..<600).contains(statusCode) { return "server_error" }
        return "http_\(statusCode / 100)xx"
    }

    /// `CancellationError`, or `NSURLErrorCancelled` bare or bridged through
    /// `NSError` (often wrapped in `HTTPError.network`).
    nonisolated static func indicatesCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// One breadcrumb per prefetch outcome, reported only by the caller that
    /// started the shared request, never by waiters that joined it. Records
    /// the outcome, never response contents.
    struct PrefetchProbe {
        let phase: String
        let verbosity: DiagnosticsVerbosity
        let isOriginator: Bool
        let mark: DispatchTime

        static func begin(
            _ phase: String,
            verbosity: DiagnosticsVerbosity = .essential,
            isOriginator: Bool
        ) -> PrefetchProbe {
            PrefetchProbe(
                phase: phase,
                verbosity: verbosity,
                isOriginator: isOriginator,
                mark: LaunchTimeline.mark()
            )
        }

        /// A cancellation is a generation bump (profile switch, sign-out,
        /// server change), not a failure, so it stays at info level: seeing it
        /// is useful, but it must not read as an error in a report.
        func finish(error: Error?) {
            guard isOriginator else { return }
            let reason = error.map(StartupContentPrefetcher.prefetchFailureReason(_:))
            let cancelled = reason == "cancelled"
            var attrs: [String: DiagLogAttributeValue] = [
                "phase": .string(phase),
                "duration_ms": .int(LaunchTimeline.milliseconds(since: mark)),
                "outcome": .string(reason == nil ? "success" : (cancelled ? "cancelled" : "failure")),
            ]
            if let reason {
                attrs["reason"] = .string(reason)
            }
            DiagTrace.breadcrumb(
                verbosity,
                level: (reason == nil || cancelled) ? .info : .warning,
                category: .lifecycle,
                tag: "Startup",
                message: "prefetch finished",
                attrs: attrs
            )
        }
    }
    #endif

    static func prefetchRecommendations() {
        Task {
            _ = try? await fetchRecommendations()
        }
    }

    static func fetchRecommendations() async throws -> SectionsResponse {
        let generation = profileScopedGeneration
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin("recommendations", isOriginator: !recommendations.isInFlight)
        #endif
        let task = recommendations.join { try await SiloAPI.shared.recommendationsDiscover() }
        do {
            let response = try await task.value
            try validateProfileScopedGeneration(generation)
            recommendations.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(response, for: CacheKey.recommendations)
            prefetchSectionArtwork(for: response, maxCount: maxSectionArtworkURLs)
            #if os(tvOS)
            prefetchRecommendationLogos(for: response)
            #endif
            return response
        } catch {
            recommendations.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            throw error
        }
    }

    /// `reusingRecent: false` is for an explicit refresh by the user.
    static func fetchUserLibraries(reusingRecent: Bool = true) async throws -> LibrariesResponse {
        if reusingRecent, let recent = userLibraries.recentValue() { return recent }
        let generation = profileScopedGeneration
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin("user_libraries", isOriginator: !userLibraries.isInFlight)
        #endif
        let task = userLibraries.join { try await SiloAPI.shared.libraries() }
        do {
            let response = try await task.value
            try validateProfileScopedGeneration(generation)
            // Only the first caller to resume announces the refresh; waiters
            // that joined the same request would repeat it.
            let isFirstToLand = userLibraries.finish(task, value: response)
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(response, for: CacheKey.userLibraries)
            if isFirstToLand {
                NotificationCenter.default.post(name: .userLibrariesDidRefresh, object: response)
            }
            return response
        } catch {
            userLibraries.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            throw error
        }
    }

    /// The landing rows plus the first grid page with the library's saved
    /// filter, which is the query the Library tab sends.
    static func prefetchLibraryLanding(libraryId: Int) {
        prefetchLibrarySections(libraryId: libraryId)
        prefetchBrowseFirstPage(
            libraryId: libraryId,
            state: BrowsePrefsStore.shared.savedState(libraryId: libraryId) ?? .none
        )
    }

    static func prefetchLibrarySections(libraryId: Int) {
        Task {
            _ = try? await fetchLibrarySections(libraryId: libraryId)
        }
    }

    #if os(tvOS)
    /// Warm the exact cold path used by a Series root tab: its section payload
    /// plus one initial Series detail. The work is deliberately limited to a
    /// single card and does not fetch cast portraits; Series cast sits below
    /// the first viewport and keeps its existing lazy path.
    static func prefetchTVSeriesLanding(libraryId: Int) {
        guard tvSeriesLandingTasks[libraryId] == nil else { return }
        let generation = profileScopedGeneration

        tvSeriesLandingTasks[libraryId] = Task(priority: .userInitiated) {
            defer {
                // A task from the prior profile must never clear a replacement
                // registered for the same numeric library id.
                if profileScopedGeneration == generation {
                    tvSeriesLandingTasks[libraryId] = nil
                }
            }

            guard let response = try? await fetchLibrarySections(libraryId: libraryId),
                  !Task.isCancelled,
                  profileScopedGeneration == generation,
                  let item = firstSeriesItem(in: response) else { return }

            let key = CacheKey.itemDetail(item.contentId)
            if let _: ItemDetail = ResponseCache.shared.get(key) { return }

            guard let detail = try? await MetadataRequestPool.shared.itemDetail(
                contentId: item.contentId
            ),
            !Task.isCancelled,
            profileScopedGeneration == generation else { return }

            ResponseCache.shared.set(detail, for: key)
        }
    }

    /// Page 1 of the library's Browse grid with its saved filter, cached
    /// under the key the grid hydrates from, and its first posters as bytes.
    /// Bytes only: decoding a grid's worth of 4K posters for a screen the
    /// user may never open would crowd Home out of the decoded-image budget.
    private static func prefetchTVLibraryGrid(_ library: Library) {
        let generation = profileScopedGeneration
        let filter = TVLibraryGridViewModel.savedFilter(libraryId: library.id)
        let query = TVLibraryGridViewModel.firstPageQuery(
            libraryId: library.id,
            libraryType: library.type,
            filter: filter
        )
        Task {
            guard let page = try? await SiloAPI.shared.catalogPage(query),
                  profileScopedGeneration == generation else { return }
            ResponseCache.shared.set(
                page.response,
                for: CacheKey.tvLibrary(libraryId: library.id, filterKey: filter.cacheKeyFragment)
            )
            PosterImageCache.prefetchArtworkData(
                uniqueURLs(page.response.items.map(\.posterUrl), limit: maxGridArtworkURLs)
            )
        }
    }

    private static func firstSeriesItem(in response: SectionsResponse) -> SectionItem? {
        for section in response.sections where !section.isFeatured && !section.items.isEmpty {
            if let item = section.items.first(where: { SiloMediaType.isSeries($0.type) }) {
                return item
            }
        }
        return nil
    }
    #endif

    static func fetchLibrarySections(libraryId: Int) async throws -> SectionsResponse {
        let generation = profileScopedGeneration
        let flight = librarySections[libraryId] ?? {
            let flight = SharedFetch<APIv2LibrarySectionsRead>()
            librarySections[libraryId] = flight
            return flight
        }()
        // Verbose: this runs on the landing prefetch and again on every browse
        // navigation. The library id is not recorded; it identifies the
        // user's own content.
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin(
            "library_sections",
            verbosity: .verbose,
            isOriginator: !flight.isInFlight
        )
        #endif
        let task = flight.join { try await SiloAPI.shared.librarySections(libraryId: libraryId) }
        do {
            let read = try await task.value
            // Sections belong to the profile they were fetched for. Never
            // cache or show them once the session acts as someone else.
            let isCurrentOwner = await SiloAPI.shared.isCurrentOwner(read.auth)
            try validateProfileScopedGeneration(generation)
            guard isCurrentOwner else { throw HTTPError.requestIdentityChanged }
            flight.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(read.response, for: CacheKey.librarySections(libraryId))
            prefetchSectionArtwork(for: read.response, maxCount: maxSectionArtworkURLs)
            return read.response
        } catch {
            flight.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            throw error
        }
    }

    static func prefetchBrowseFirstPage(libraryId: Int?, state: CatalogFilterState = .none) {
        Task {
            _ = try? await fetchBrowseFirstPage(libraryId: libraryId, state: state)
        }
    }

    /// Page 1 of a browse grid. The page carries the continuation the grid
    /// uses for page 2, so the prefetch and the live grid share one query.
    static func fetchBrowseFirstPage(
        libraryId: Int?,
        state: CatalogFilterState = .none
    ) async throws -> CatalogListPage {
        let generation = profileScopedGeneration
        let key = CacheKey.browse(libraryId: libraryId, filterKey: state.cacheKeyFragment)
        let flight = browseFirstPages[key] ?? {
            let flight = SharedFetch<CatalogListPage>()
            browseFirstPages[key] = flight
            return flight
        }()
        // Verbose for the same reason as `library_sections`; the cache key
        // (library id plus the user's filter selections) is never logged.
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin(
            "browse_first_page",
            verbosity: .verbose,
            isOriginator: !flight.isInFlight
        )
        #endif
        let task = flight.join {
            // iOS omits `type` (library_id already scopes the page); later
            // pages follow this page's continuation.
            let query = CatalogQueryBuilder.build(
                state,
                libraryId: libraryId,
                mediaType: .movie,
                limit: browsePageSize,
                includeType: false
            )
            return try await SiloAPI.shared.catalogPage(query)
        }
        do {
            let page = try await task.value
            try validateProfileScopedGeneration(generation)
            flight.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(page.response, for: key)
            prefetchBrowseArtwork(for: page.response)
            return page
        } catch {
            flight.finish(task, value: nil)
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            throw error
        }
    }

    static func prefetchAuthenticatedContent() {
        ResponseCache.shared.seedFromSnapshots()
        prefetchHomeSections()
        prefetchRecommendations()
        prefetchLibraryTabLandings()
        Task {
            await OverlayPrefsStore.shared.hydrateIfNeeded()
        }
    }

    /// Opens the startup prefetch block. The individual fetches below report
    /// their own outcomes but complete out of order and off the launch chain,
    /// so without this line a reader cannot tell whether a missing outcome
    /// means the fetch failed silently or was never started for this route.
    static func prefetchForInitialRoute(_ state: AppRouter.AuthState) {
        #if os(iOS) || os(tvOS)
        DiagTrace.breadcrumb(
            .essential,
            category: .lifecycle,
            tag: "Startup",
            message: "route prefetch started",
            attrs: [
                "phase": .string("prefetch"),
                "state": .string(state.diagnosticsState),
            ]
        )
        #endif
        switch state {
        case .authenticated:
            prefetchAuthenticatedContent()
            // The root top bar renders the active profile's avatar right
            // after launch. Warm the list here (cold launch only) so it
            // doesn't fill in late; sign-in / profile-selection flows have
            // just fetched profiles, so they don't need this.
            prefetchProfiles()
        case .needsProfile:
            prefetchProfiles()
        case .loading, .needsServerSetup, .needsLogin, .serverRecovery:
            break
        }
    }

    /// Warm the landing of each library tab, for the library that tab opens
    /// on, resolved the way the tab itself resolves it.
    private static func prefetchLibraryTabLandings() {
        Task {
            guard let response = try? await fetchUserLibraries() else { return }
            #if os(tvOS)
            var gridLibraryIds = Set<Int>()
            for type in [TVLibraryTabType.movies, .series] {
                let candidates = response.libraries
                    .filter { type.matches($0) }
                    .sorted { ($0.sortOrder ?? Int.max, $0.id) < ($1.sortOrder ?? Int.max, $1.id) }
                guard let library = TVLibraryScopeStore.shared.resolvedLibrary(for: type, in: candidates) else {
                    continue
                }
                if type == .series {
                    prefetchTVSeriesLanding(libraryId: library.id)
                } else {
                    prefetchLibrarySections(libraryId: library.id)
                }
                // A mixed library sits under both tabs; warm its grid once.
                if gridLibraryIds.insert(library.id).inserted {
                    prefetchTVLibraryGrid(library)
                }
            }
            #else
            let registry = ServerRegistry.shared
            let authority = MainTabLibraryAuthority(
                serverId: registry.activeServerId,
                profileId: registry.activeProfileId
            )
            for category in [PrimaryMenuBuiltin.movies, .series] {
                let storageKey = librarySelectionStorageKey(
                    category: category,
                    fixedLibraryId: nil,
                    authority: authority
                )
                guard let libraryId = resolvedLibraryIdForRoot(
                    response.libraries,
                    category: category,
                    fixedLibraryId: nil,
                    showAudiobooks: AppNavPreferences.shared.showAudiobooks,
                    storedLibraryId: storedLibrarySelectionId(for: storageKey)
                ) else { continue }
                prefetchLibraryLanding(libraryId: libraryId)
            }
            #endif
        }
    }

    /// Home renders under the startup splash and loads what it shows. Warm
    /// the bytes of the rest of its rows, and the first card's marquee logo,
    /// so scrolling and focus moves paint from local data.
    private static func prefetchHomeArtwork(for response: SectionsResponse) {
        let sections = response.sections.filter { !$0.items.isEmpty }
        let cards = sections.lazy.flatMap { section in
            section.items.lazy.map { rowCardArtwork(for: $0, in: section, onHome: true)?.url }
        }
        PosterImageCache.prefetchArtworkData(uniqueURLs(cards, limit: maxHomeArtworkURLs))
        #if os(tvOS)
        if let logo = normalizedURL(from: sections.first?.items.first?.logoUrl) {
            PosterImageCache.prefetchOriginalArtwork([logo])
        }
        #endif
    }

    /// Landing rows of a tab the user has not opened yet: decode their first
    /// posters at the size the row cards draw them, and warm episode stills
    /// as bytes.
    private static func prefetchSectionArtwork(for response: SectionsResponse, maxCount: Int) {
        var posters: [CardArtwork] = []
        var stills: [String?] = []
        for section in response.sections where !section.isFeatured && !section.items.isEmpty {
            let showsStills = SectionRow.layout(for: section) == .thumbnail
            for item in section.items {
                guard let card = rowCardArtwork(for: item, in: section, onHome: false) else { continue }
                if showsStills {
                    stills.append(card.url)
                } else {
                    posters.append(card)
                }
            }
        }
        var seen = Set<String>()
        PosterImageCache.prefetchArtwork(Array(posters.filter { !$0.url.isEmpty && seen.insert($0.url).inserted }.prefix(maxCount)))
        PosterImageCache.prefetchArtworkData(uniqueURLs(stills, limit: maxCount))
    }

    /// The artwork a card in `section`'s row draws, by the rules that row
    /// uses: Skyline rows on tvOS, Home's rows or `SectionRow` elsewhere.
    private static func rowCardArtwork(for item: SectionItem, in section: ResolvedSection, onHome: Bool) -> CardArtwork? {
        #if os(tvOS)
        return MediaRow.cardArtwork(for: item, layout: SectionRow.layout(for: section), cardWidth: SiloTheme.Skyline.densePosterCardWidth)
        #else
        if onHome {
            return HomeFeedRow.cardArtwork(for: item, in: section)
        }
        return MediaRow.cardArtwork(for: item, layout: SectionRow.layout(for: section), cardWidth: nil)
        #endif
    }

    #if os(tvOS)
    /// Match `RecommendationsViewModel` ordering so the first two rows the
    /// user can actually focus are the ones whose logo art is ready first.
    private static func prefetchRecommendationLogos(for response: SectionsResponse) {
        let nonEmpty = response.sections.filter { !$0.items.isEmpty }
        let forYou = nonEmpty.filter { $0.title.lowercased() == "for you" }
        let others = nonEmpty.filter { $0.title.lowercased() != "for you" }
        let logos = (forYou + others).prefix(2).flatMap { $0.items.prefix(8).map(\.logoUrl) }
        PosterImageCache.prefetchOriginalArtwork(uniqueURLs(logos, limit: maxRecommendationLogoURLs))
    }
    #endif

    /// `CatalogGrid` draws audiobook covers square.
    private static func prefetchBrowseArtwork(for response: CatalogResponse) {
        var seen = Set<String>()
        let cards = response.items.compactMap { item -> CardArtwork? in
            guard let url = item.posterUrl, !url.isEmpty, seen.insert(url).inserted else { return nil }
            return CardArtwork(
                url: url,
                pointSize: MediaCard.artworkSize(cardWidthOverride: nil, aspect: item.isAudiobook ? .square : .poster)
            )
        }
        PosterImageCache.prefetchArtwork(Array(cards.prefix(maxBrowseArtworkURLs)))
    }

    private static func prefetchProfileArtwork(for profiles: [UserProfile]) {
        // Same precedence as the avatar view: the server-resolved URL first,
        // then the client-side resolution of the raw ref.
        let avatars = profiles.map { profile -> String? in
            if let serverURL = ProfileAvatarResolver.serverResolvedImageURL(profile.avatarImageUrl) {
                return serverURL
            }
            guard let avatar = profile.avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ProfileAvatarResolver.isImage(avatar) else { return nil }
            return ProfileAvatarResolver.imageURL(for: avatar)
        }
        PosterImageCache.prefetchArtworkData(uniqueURLs(avatars, limit: maxProfileArtworkURLs))
    }

    /// Up to `limit` distinct, valid absolute URLs, in order.
    private static func uniqueURLs(_ strings: some Sequence<String?>, limit: Int) -> [URL] {
        var urls: [URL] = []
        var seen = Set<URL>()
        for string in strings {
            guard let url = normalizedURL(from: string), seen.insert(url).inserted else { continue }
            urls.append(url)
            if urls.count >= limit { break }
        }
        return urls
    }

    private static func validateProfileScopedGeneration(_ generation: Int) throws {
        guard profileScopedGeneration == generation else {
            throw CancellationError()
        }
    }

    private static func validateHomeSectionsGeneration(_ generation: Int) throws {
        guard homeSectionsGeneration == generation else {
            throw CancellationError()
        }
    }

    private static func validateProfilesGeneration(_ generation: Int) throws {
        guard profilesGeneration == generation else {
            throw CancellationError()
        }
    }

    private static func normalizedURL(from urlString: String?) -> URL? {
        guard let trimmed = urlString?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty,
              let url = URL(string: trimmed),
              url.scheme != nil else {
            return nil
        }
        return url
    }
}

/// One request shared by every concurrent caller, and optionally reused for a
/// short window after it lands. Callers validate their own generation after
/// awaiting and report back through `finish`.
@MainActor
final class SharedFetch<Value> {
    private var task: Task<Value, Error>?
    private var landed: (value: Value, at: ContinuousClock.Instant)?
    private let reuseWindow: Duration

    init(reuseWindow: Duration = .zero) {
        self.reuseWindow = reuseWindow
    }

    var isInFlight: Bool { task != nil }

    func recentValue() -> Value? {
        guard let landed, ContinuousClock.now - landed.at < reuseWindow else { return nil }
        return landed.value
    }

    func join(_ start: @escaping @MainActor () async throws -> Value) -> Task<Value, Error> {
        if let task { return task }
        let task = Task { try await start() }
        self.task = task
        return task
    }

    /// Clears the slot if `task` still owns it and remembers a successful
    /// `value` for reuse. Returns whether this call cleared the slot, which is
    /// true only for the first caller to resume.
    @discardableResult
    func finish(_ task: Task<Value, Error>, value: Value?) -> Bool {
        guard self.task == task else { return false }
        self.task = nil
        if let value, reuseWindow > .zero {
            landed = (value, .now)
        }
        return true
    }

    func reset() {
        task?.cancel()
        task = nil
        landed = nil
    }
}
