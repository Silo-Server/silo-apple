import Foundation

extension Notification.Name {
    static let userLibrariesDidRefresh = Notification.Name("userLibrariesDidRefresh")
}

@MainActor
enum StartupContentPrefetcher {
    // tvOS paints a full-width first row plus the focus marquee's logo and
    // backdrop on entry, so it needs a deeper artwork warmup than the
    // phone-sized first screen.
    #if os(tvOS)
    private static let maxHomeArtworkURLs = 28
    #else
    private static let maxHomeArtworkURLs = 12
    #endif
    private static let maxSectionArtworkURLs = 12
    /// For You shows two eight-card rows in its initial viewport. Logos are
    /// tiny compared with backdrops, so warm exactly those visible candidates
    /// rather than waiting for each focus rest to begin its own request.
    #if os(tvOS)
    private static let maxRecommendationLogoURLs = 16
    #endif
    private static let maxBrowseArtworkURLs = 12
    private static let maxProfileArtworkURLs = 8
    private static let browsePageSize = 60
    private static let selectedLibraryDefaultsKey = "librariesTabSelectedLibraryId"
    private static let episodeSectionTypes: Set<String> = [
        "continue_watching",
        "in_progress",
        "next_up",
    ]

    private static var profilesTask: Task<[UserProfile], Error>?
    private static var homeSectionsTask: Task<SectionsResponse, Error>?
    private static var recommendationsTask: Task<SectionsResponse, Error>?
    private static var userLibrariesTask: Task<LibrariesResponse, Error>?
    private static var librarySectionsTasks: [Int: Task<SectionsResponse, Error>] = [:]
    private static var browseFirstPageTasks: [String: Task<CatalogResponse, Error>] = [:]
    private static var profileScopedGeneration = 0
    private static var homeSectionsGeneration = 0
    private static var profilesGeneration = 0

    static func resetProfileScopedPrefetches() {
        profileScopedGeneration += 1

        homeSectionsTask?.cancel()
        recommendationsTask?.cancel()
        userLibrariesTask?.cancel()
        librarySectionsTasks.values.forEach { $0.cancel() }
        browseFirstPageTasks.values.forEach { $0.cancel() }

        homeSectionsTask = nil
        recommendationsTask = nil
        userLibrariesTask = nil
        librarySectionsTasks.removeAll()
        browseFirstPageTasks.removeAll()
    }

    static func resetAllPrefetches() {
        profilesGeneration += 1
        profilesTask?.cancel()
        profilesTask = nil
        resetProfileScopedPrefetches()
    }

    static func prefetchProfiles() {
        Task {
            _ = try? await fetchProfiles()
        }
    }

    static func fetchProfiles() async throws -> [UserProfile] {
        let generation = profilesGeneration
        // Read the single-flight slot before it is filled below: after the
        // assignment there is no way to tell an originator from a waiter.
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin("profiles", isOriginator: profilesTask == nil)
        #endif
        let task: Task<[UserProfile], Error>
        if let profilesTask {
            task = profilesTask
        } else {
            task = Task {
                try await AuthService.shared.getProfiles()
            }
            profilesTask = task
        }

        do {
            let profiles = try await task.value
            try validateProfilesGeneration(generation)
            if profilesGeneration == generation {
                profilesTask = nil
            }
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(profiles, for: CacheKey.profiles)
            await AuthService.shared.reconcileAvailableProfiles(profiles)
            prefetchProfileArtwork(for: profiles)
            return profiles
        } catch {
            if profilesGeneration == generation {
                profilesTask = nil
            }
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
        homeSectionsTask?.cancel()
        homeSectionsTask = nil
    }

    static func fetchHomeSections() async throws -> SectionsResponse {
        let profileGeneration = profileScopedGeneration
        let homeGeneration = homeSectionsGeneration
        let requestProfileID = AuthService.shared.profileId
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin("home_sections", isOriginator: homeSectionsTask == nil)
        #endif
        let task: Task<SectionsResponse, Error>
        if let homeSectionsTask {
            task = homeSectionsTask
        } else {
            task = Task {
                try await ContinuumAPI.shared.homeSections()
            }
            homeSectionsTask = task
        }

        do {
            let response = try await task.value
            try validateProfileScopedGeneration(profileGeneration)
            try validateHomeSectionsGeneration(homeGeneration)
            if profileScopedGeneration == profileGeneration,
               homeSectionsGeneration == homeGeneration {
                homeSectionsTask = nil
            }
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(response, for: CacheKey.homeSections)
            prefetchHomeArtwork(for: response)
            return response
        } catch {
            if profileScopedGeneration == profileGeneration,
               homeSectionsGeneration == homeGeneration {
                homeSectionsTask = nil
            }
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
        guard let error = error as? HTTPError else { return false }
        return ["profile_unverified", "profile_not_found"].contains(error.serverErrorCode)
    }

    #if os(iOS) || os(tvOS)
    // MARK: - Diagnostics

    /// Classifies a prefetch failure into a small, stable set of tokens for the
    /// `reason` attribute.
    ///
    /// The vocabulary is deliberately coarse. `reason` is what a reader groups
    /// on across reports, so it has to mean the same thing in every build; a
    /// pass-through of the error's own text would be neither stable nor
    /// necessarily free of server-authored detail. Anything not recognised here
    /// becomes `other` rather than leaking a description.
    ///
    /// `invalid_profile` is called out because it is the one classification
    /// that already drives recovery (`recoverFromInvalidProfile`): a user who
    /// reports "it bounced me to Who's Watching on launch" is looking at that
    /// token, and it is otherwise indistinguishable from a plain HTTP failure.
    /// `nonisolated` because `PrefetchProbe` is a nested type and so does not
    /// inherit this enum's `@MainActor`; its `finish` calls this from whatever
    /// context the failing fetch unwound on. The classification is a pure
    /// function of the error value and touches no actor state, so there is
    /// nothing to hop for.
    ///
    /// Cancellation arrives in three shapes and all three mean the same thing,
    /// so the check is factored out rather than repeated per branch — see
    /// `indicatesCancellation`.
    nonisolated static func prefetchFailureReason(_ error: Error) -> String {
        if indicatesCancellation(error) { return "cancelled" }
        guard let httpError = error as? HTTPError else {
            // URLSession surfaces transport failures as NSError before
            // HTTPClient wraps them; the cancelled case was already claimed
            // above, so anything left in this domain is a real transport
            // failure.
            let nsError = error as NSError
            if nsError.domain == NSURLErrorDomain { return "network" }
            return "other"
        }
        if indicatesInvalidProfile(httpError) { return "invalid_profile" }
        switch httpError {
        case .serverUrlNotConfigured:
            return "no_server"
        case .requestIdentityChanged:
            return "identity_changed"
        case .network(let underlying):
            // A cancellation reaches here wrapped: `HTTPClient.perform` catches
            // the transport error and rethrows it as `.network(underlying:)`
            // regardless of cause, so the outer case says only "the transport
            // threw", not what it threw. Unwrapping it is the same distinction
            // `HTTPClient.noteServerUnreachable` already makes when it refuses
            // to feed a cancelled request into reachability — "cancellation
            // says nothing about reachability" — and for the same reason: a
            // server or profile switch cancelling its own in-flight prefetches
            // is the routine path, and classifying it as `network` would put a
            // warning-level phantom connectivity failure in every report that
            // contains an identity transition.
            return indicatesCancellation(underlying) ? "cancelled" : "network"
        case .decodingFailed:
            return "decode_failed"
        case .http(let statusCode, _):
            // Bucketed, not verbatim: the status class is what distinguishes
            // "the server rejected us" from "the server is broken", and the
            // exact code adds cardinality without adding meaning here.
            if statusCode == 401 || statusCode == 403 { return "unauthorized" }
            if (500..<600).contains(statusCode) { return "server_error" }
            return "http_\(statusCode / 100)xx"
        case .invalidURL, .invalidResponse, .encodingFailed:
            return "other"
        }
    }

    /// True for every shape a cancelled prefetch can take.
    ///
    /// There are three, because a prefetch can be torn down at three different
    /// depths and each layer reports in its own vocabulary:
    ///
    /// 1. `CancellationError` — the prefetcher's own generation guards, thrown
    ///    when a `resetProfileScopedPrefetches` bumped the generation while the
    ///    fetch was awaiting.
    /// 2. A bare `URLError.cancelled` — URLSession tearing the request down,
    ///    reaching a caller that did not route through `HTTPClient.perform`.
    /// 3. That same `URLError.cancelled` wrapped in `HTTPError.network` —
    ///    the common case, because `perform` rethrows *every* transport error
    ///    as `.network(underlying:)` and the cause survives only in the payload.
    ///
    /// Matching on `NSURLErrorDomain`/`NSURLErrorCancelled` rather than
    /// `URLError` alone so a bridged `NSError` — which is what a cancellation
    /// looks like once it has crossed an `Error` existential more than once —
    /// is caught by the same test.
    nonisolated static func indicatesCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        let nsError = error as NSError
        return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
    }

    /// One line per prefetch, essential tier.
    ///
    /// These fetches are the launch path's only network work, and a cold launch
    /// that lands on an empty Home or bounces to profile selection is explained
    /// entirely by their outcomes. `phase` is the fetch name, so they form a
    /// readable startup block; nothing about the response contents (item
    /// counts, titles, library names) is recorded — the outcome and its
    /// classification are the whole diagnostic value.
    ///
    /// Every fetch here is single-flight, so only the caller that *started* the
    /// request reports. Waiters that join an in-flight task would otherwise
    /// emit a duplicate line per screen that asked, padding the launch block
    /// with joins rather than work. `begin` captures that decision at the one
    /// point where it is knowable — before the task is stored — and carries it
    /// to the `finish` in both exit paths.
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
        let probe = PrefetchProbe.begin("recommendations", isOriginator: recommendationsTask == nil)
        #endif
        let task: Task<SectionsResponse, Error>
        if let recommendationsTask {
            task = recommendationsTask
        } else {
            task = Task {
                try await ContinuumAPI.shared.recommendationsDiscover()
            }
            recommendationsTask = task
        }

        do {
            let response = try await task.value
            try validateProfileScopedGeneration(generation)
            if profileScopedGeneration == generation {
                recommendationsTask = nil
            }
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
            if profileScopedGeneration == generation {
                recommendationsTask = nil
            }
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            throw error
        }
    }

    static func prefetchUserLibraries() {
        Task {
            _ = try? await fetchUserLibraries()
        }
    }

    static func fetchUserLibraries() async throws -> LibrariesResponse {
        let generation = profileScopedGeneration
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin("user_libraries", isOriginator: userLibrariesTask == nil)
        #endif
        let task: Task<LibrariesResponse, Error>
        if let userLibrariesTask {
            task = userLibrariesTask
        } else {
            task = Task {
                try await ContinuumAPI.shared.libraries()
            }
            userLibrariesTask = task
        }

        do {
            let response = try await task.value
            try validateProfileScopedGeneration(generation)
            if profileScopedGeneration == generation {
                userLibrariesTask = nil
            }
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(response, for: CacheKey.userLibraries)
            NotificationCenter.default.post(
                name: .userLibrariesDidRefresh,
                object: response
            )
            return response
        } catch {
            if profileScopedGeneration == generation {
                userLibrariesTask = nil
            }
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            throw error
        }
    }

    static func prefetchLibraryLanding(libraryId: Int) {
        prefetchLibrarySections(libraryId: libraryId)
        prefetchBrowseFirstPage(libraryId: libraryId)
    }

    static func prefetchLibrarySections(libraryId: Int) {
        Task {
            _ = try? await fetchLibrarySections(libraryId: libraryId)
        }
    }

    static func fetchLibrarySections(libraryId: Int) async throws -> SectionsResponse {
        let generation = profileScopedGeneration
        // Verbose: these two run once per library on the landing prefetch and
        // again on every browse navigation, so at essential tier a session's
        // worth of them would crowd out the launch chain. The library id is
        // deliberately not recorded — there is no registered key for it, and
        // it identifies the user's own content.
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin(
            "library_sections",
            verbosity: .verbose,
            isOriginator: librarySectionsTasks[libraryId] == nil
        )
        #endif
        let task: Task<SectionsResponse, Error>
        if let existing = librarySectionsTasks[libraryId] {
            task = existing
        } else {
            task = Task {
                try await ContinuumAPI.shared.librarySections(libraryId: libraryId)
            }
            librarySectionsTasks[libraryId] = task
        }

        do {
            let response = try await task.value
            try validateProfileScopedGeneration(generation)
            if profileScopedGeneration == generation {
                librarySectionsTasks[libraryId] = nil
            }
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(response, for: CacheKey.librarySections(libraryId))
            prefetchSectionArtwork(for: response, maxCount: maxSectionArtworkURLs)
            return response
        } catch {
            if profileScopedGeneration == generation {
                librarySectionsTasks[libraryId] = nil
            }
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

    static func fetchBrowseFirstPage(
        libraryId: Int?,
        state: CatalogFilterState = .none
    ) async throws -> CatalogResponse {
        let generation = profileScopedGeneration
        let key = CacheKey.browse(libraryId: libraryId, filterKey: state.cacheKeyFragment)
        // Verbose for the same reason as `library_sections`, and the cache key
        // (library id plus the user's filter selections) is never logged.
        #if os(iOS) || os(tvOS)
        let probe = PrefetchProbe.begin(
            "browse_first_page",
            verbosity: .verbose,
            isOriginator: browseFirstPageTasks[key] == nil
        )
        #endif
        let task: Task<CatalogResponse, Error>
        if let existing = browseFirstPageTasks[key] {
            task = existing
        } else {
            task = Task {
                // iOS omits `type` (library_id already scopes the page); the
                // builder is the single source of the wire format shared with
                // BrowseViewModel so prefetch and live fetch hit the same key.
                let query = CatalogQueryBuilder.build(
                    state,
                    libraryId: libraryId,
                    mediaType: .movie,
                    offset: 0,
                    limit: browsePageSize,
                    includeType: false
                )
                return try await ContinuumAPI.shared.catalog(query: query)
            }
            browseFirstPageTasks[key] = task
        }

        do {
            let response = try await task.value
            try validateProfileScopedGeneration(generation)
            if profileScopedGeneration == generation {
                browseFirstPageTasks[key] = nil
            }
            #if os(iOS) || os(tvOS)
            probe.finish(error: nil)
            #endif
            ResponseCache.shared.set(response, for: key)
            prefetchBrowseArtwork(for: response)
            return response
        } catch {
            if profileScopedGeneration == generation {
                browseFirstPageTasks[key] = nil
            }
            #if os(iOS) || os(tvOS)
            probe.finish(error: error)
            #endif
            throw error
        }
    }

    static func prefetchAuthenticatedContent() {
        prefetchHomeSections()
        prefetchRecommendations()
        prefetchActiveLibraryLanding()
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
        case .loading, .needsServerSetup, .needsLogin:
            break
        }
    }

    private static func prefetchActiveLibraryLanding() {
        Task {
            guard let response = try? await fetchUserLibraries(),
                  let library = preferredLibrary(from: response.libraries) else {
                return
            }
            prefetchLibraryLanding(libraryId: library.id)
        }
    }

    private static func preferredLibrary(from libraries: [Library]) -> Library? {
        AppNavPreferences.shared.refresh()
        let visibleLibraries = libraries
            .filter {
                AppNavPreferences.shared.showAudiobooks || !$0.isAudiobookLibrary
            }
            .sorted {
                ($0.sortOrder ?? Int.max, $0.id) < ($1.sortOrder ?? Int.max, $1.id)
            }
        let storedId = UserDefaults.standard.integer(forKey: selectedLibraryDefaultsKey)
        if storedId != 0,
           let stored = visibleLibraries.first(where: { $0.id == storedId }) {
            return stored
        }
        return visibleLibraries.first
    }

    private static func prefetchHomeArtwork(for response: SectionsResponse) {
        var urls: [URL] = []
        var seen = Set<String>()

        func append(_ urlString: String?) {
            guard urls.count < maxHomeArtworkURLs,
                  let url = normalizedURL(from: urlString) else {
                return
            }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return }
            urls.append(url)
        }

        // No client renders a featured hero anymore — featured sections show
        // as ordinary rows. Entry lands on the first card of the first content
        // row. Warm that row's logo + art first (so a cold start paints a
        // finished first row), then the rest. (The first row's logo + backdrop
        // are sized for the tvOS focus marquee; on other platforms only
        // posters/episode stills render, so those two are speculative but
        // harmless.)
        let contentSections = response.sections.filter { !$0.items.isEmpty }
        if let firstRow = contentSections.first {
            append(firstRow.items.first?.logoUrl)
            for item in firstRow.items {
                if episodeSectionTypes.contains(firstRow.sectionType) {
                    // Episode thumbs already render the backdrop, so the card
                    // art and the first-row art are one fetch.
                    append(item.backdropUrl ?? item.posterUrl)
                } else {
                    append(item.posterUrl)
                    append(item.backdropUrl)
                }
                if urls.count >= maxHomeArtworkURLs { break }
            }
        }
        for section in contentSections.dropFirst() {
            for item in section.items {
                if episodeSectionTypes.contains(section.sectionType) {
                    append(item.backdropUrl ?? item.posterUrl)
                } else {
                    append(item.posterUrl)
                }
                if urls.count >= maxHomeArtworkURLs { break }
            }
            if urls.count >= maxHomeArtworkURLs { break }
        }

        guard !urls.isEmpty else { return }
        PosterImageCache.prefetcher.startPrefetching(with: urls)

        // Warm the marquee's initial tint: tvOS seeds the marquee with the
        // first row's first item on cold entry, and a cached sample lets the
        // tint wash paint on the same frame as the backdrop instead of
        // fading up from the black background once sampling finishes. Other
        // platforms render no marquee, so skip the fetch + sampling there.
        #if os(tvOS)
        if let firstBackdrop = normalizedURL(from: contentSections.first?.items.first?.backdropUrl) {
            Task { _ = await HeroBackdropPalette.tintColor(for: firstBackdrop) }
        }
        #endif
    }

    private static func prefetchSectionArtwork(for response: SectionsResponse, maxCount: Int) {
        var urls: [URL] = []
        var seen = Set<String>()

        func append(_ urlString: String?) {
            guard urls.count < maxCount,
                  let url = normalizedURL(from: urlString) else {
                return
            }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { return }
            urls.append(url)
        }

        for section in response.sections where !section.isFeatured && !section.items.isEmpty {
            for item in section.items {
                if episodeSectionTypes.contains(section.sectionType) {
                    append(item.backdropUrl ?? item.posterUrl)
                } else {
                    append(item.posterUrl)
                }
                if urls.count >= maxCount { break }
            }
            if urls.count >= maxCount { break }
        }

        guard !urls.isEmpty else { return }
        PosterImageCache.prefetcher.startPrefetching(with: urls)
    }

    #if os(tvOS)
    /// Match `RecommendationsViewModel` ordering so the first two rows the
    /// user can actually focus are the ones whose logo art is ready first.
    private static func prefetchRecommendationLogos(for response: SectionsResponse) {
        let nonEmpty = response.sections.filter { !$0.items.isEmpty }
        let forYou = nonEmpty.filter { $0.title.lowercased() == "for you" }
        let others = nonEmpty.filter { $0.title.lowercased() != "for you" }
        let initialRows = (forYou + others).prefix(2)

        var urls: [URL] = []
        var seen = Set<String>()
        for section in initialRows {
            for item in section.items.prefix(8) {
                guard urls.count < maxRecommendationLogoURLs,
                      let url = normalizedURL(from: item.logoUrl),
                      seen.insert(url.absoluteString).inserted else { continue }
                urls.append(url)
            }
        }

        guard !urls.isEmpty else { return }
        PosterImageCache.prefetcher.startPrefetching(with: urls)
    }
    #endif

    private static func prefetchBrowseArtwork(for response: CatalogResponse) {
        var urls: [URL] = []
        var seen = Set<String>()

        for item in response.items {
            guard urls.count < maxBrowseArtworkURLs,
                  let url = normalizedURL(from: item.posterUrl) else {
                continue
            }
            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }

        guard !urls.isEmpty else { return }
        PosterImageCache.prefetcher.startPrefetching(with: urls)
    }

    private static func prefetchProfileArtwork(for profiles: [UserProfile]) {
        var urls: [URL] = []
        var seen = Set<String>()

        for profile in profiles {
            guard urls.count < maxProfileArtworkURLs else { continue }

            // Mirror the view-side precedence: server-resolved `avatar_url`
            // first, then the client-side resolution of the raw ref.
            let resolved: String?
            if let serverURL = ProfileAvatarResolver.serverResolvedImageURL(profile.avatarImageUrl) {
                resolved = serverURL
            } else if let avatar = profile.avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines),
                      ProfileAvatarResolver.isImage(avatar) {
                resolved = ProfileAvatarResolver.imageURL(for: avatar)
            } else {
                resolved = nil
            }

            guard let urlString = resolved,
                  let url = normalizedURL(from: urlString) else {
                continue
            }

            let key = url.absoluteString
            guard seen.insert(key).inserted else { continue }
            urls.append(url)
        }

        guard !urls.isEmpty else { return }
        PosterImageCache.prefetcher.startPrefetching(with: urls)
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
