import Foundation

@MainActor
enum StartupContentPrefetcher {
    private static let maxHomeArtworkURLs = 12
    private static let maxSectionArtworkURLs = 12
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
            ResponseCache.shared.set(profiles, for: CacheKey.profiles)
            prefetchProfileArtwork(for: profiles)
            return profiles
        } catch {
            if profilesGeneration == generation {
                profilesTask = nil
            }
            throw error
        }
    }

    static func prefetchHomeSections() {
        Task {
            _ = try? await fetchHomeSections()
        }
    }

    static func fetchHomeSections() async throws -> SectionsResponse {
        let generation = profileScopedGeneration
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
            try validateProfileScopedGeneration(generation)
            if profileScopedGeneration == generation {
                homeSectionsTask = nil
            }
            ResponseCache.shared.set(response, for: CacheKey.homeSections)
            prefetchHomeArtwork(for: response)
            return response
        } catch {
            if profileScopedGeneration == generation {
                homeSectionsTask = nil
            }
            throw error
        }
    }

    static func prefetchRecommendations() {
        Task {
            _ = try? await fetchRecommendations()
        }
    }

    static func fetchRecommendations() async throws -> SectionsResponse {
        let generation = profileScopedGeneration
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
            ResponseCache.shared.set(response, for: CacheKey.recommendations)
            prefetchSectionArtwork(for: response, maxCount: maxSectionArtworkURLs)
            return response
        } catch {
            if profileScopedGeneration == generation {
                recommendationsTask = nil
            }
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
            ResponseCache.shared.set(response, for: CacheKey.userLibraries)
            return response
        } catch {
            if profileScopedGeneration == generation {
                userLibrariesTask = nil
            }
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
            ResponseCache.shared.set(response, for: CacheKey.librarySections(libraryId))
            prefetchSectionArtwork(for: response, maxCount: maxSectionArtworkURLs)
            return response
        } catch {
            if profileScopedGeneration == generation {
                librarySectionsTasks[libraryId] = nil
            }
            throw error
        }
    }

    static func prefetchBrowseFirstPage(libraryId: Int?, genre: String? = nil, sort: String = "title") {
        Task {
            _ = try? await fetchBrowseFirstPage(libraryId: libraryId, genre: genre, sort: sort)
        }
    }

    static func fetchBrowseFirstPage(
        libraryId: Int?,
        genre: String? = nil,
        sort: String = "title"
    ) async throws -> CatalogResponse {
        let generation = profileScopedGeneration
        let key = CacheKey.browse(libraryId: libraryId, genre: genre, sort: sort)
        let task: Task<CatalogResponse, Error>
        if let existing = browseFirstPageTasks[key] {
            task = existing
        } else {
            task = Task {
                var query: [String: String] = [
                    "offset": "0",
                    "limit": String(browsePageSize),
                    "sort": sort,
                ]
                if let libraryId {
                    query["library_id"] = String(libraryId)
                }
                if let genre {
                    query["genre"] = genre
                }

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
            ResponseCache.shared.set(response, for: key)
            prefetchBrowseArtwork(for: response)
            return response
        } catch {
            if profileScopedGeneration == generation {
                browseFirstPageTasks[key] = nil
            }
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

    static func prefetchForInitialRoute(_ state: AppRouter.AuthState) {
        switch state {
        case .authenticated:
            prefetchAuthenticatedContent()
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

        // No client renders a featured hero anymore: entry lands on the first
        // card of the first content row. Warm that row's logo + art first (so a
        // cold start paints a finished first row), then the rest. (The first
        // row's logo + backdrop are sized for the tvOS focus marquee; on other
        // platforms only posters/episode stills render, so those two are
        // speculative but harmless.)
        let contentSections = response.sections.filter { !$0.isFeatured && !$0.items.isEmpty }
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
            guard urls.count < maxProfileArtworkURLs,
                  let avatar = profile.avatarEmoji?.trimmingCharacters(in: .whitespacesAndNewlines),
                  ProfileAvatarResolver.isImage(avatar),
                  let urlString = ProfileAvatarResolver.imageURL(for: avatar),
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
