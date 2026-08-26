import Foundation

/// Native Swift facade over the Continuum REST API.
///
/// Supports two interfaces:
/// - **Path-based**: ``get(_:query:)``, ``post(_:body:)``, ``put(_:body:)``,
///   ``delete(_:)``, etc. Legacy call sites use these; each path maps to a
///   specific server endpoint plus any reshape logic (e.g. /discover →
///   SectionsResponse).
/// - **Typed methods**: convenience wrappers for every supported endpoint
///   (e.g. ``homeSections()``, ``itemDetail(contentId:)``). Preferred for
///   new code because they keep types at the call site.
///
/// All HTTP goes through ``HTTPClient/shared``; session state lives in
/// ``TokenStore/shared``. Refer to [HTTPClient](x-source-tag://HTTPClient)
/// for auth header injection and 401 refresh semantics.
actor ContinuumAPI {
    static let shared = ContinuumAPI()

    /// Non-private so endpoint methods declared in extensions (e.g. the
    /// downloads API) can reuse the same injected transport.
    let http: HTTPClient
    private let tokenStore: TokenStore

    init(http: HTTPClient = .shared, tokenStore: TokenStore = .shared) {
        self.http = http
        self.tokenStore = tokenStore
    }

    // MARK: - Session state accessors

    func currentServerUrl() async -> String {
        await tokenStore.getServerUrl()
    }

    func currentAccessToken() async -> String? {
        await tokenStore.getAccessToken()
    }

    /// The profile the session is acting as, or nil before one is selected.
    func currentProfileId() async -> String? {
        await tokenStore.getProfileId()
    }

    // MARK: - Image size selection

    /// Extra query entries asking the server to bake a larger image
    /// variant into every image URL in the response.
    ///
    /// One place decides this for every image-bearing endpoint, so call
    /// sites just merge it in. Empty off tvOS, and empty until (or
    /// unless) the capability probe in ``ImageSizeCapability`` lands —
    /// which makes iOS and macOS requests byte-identical to before.
    private var imageSizeQuery: [String: String] {
        get async {
            // Gate only the artwork request, never launch/profile navigation.
            // Concurrent startup prefetches join one probe, and older or
            // unreachable servers fall back to an empty query.
            await ImageSizeCapability.shared.refresh()
            return ImageSizeCapability.shared.requestQuery
        }
    }

    /// Merge ``imageSizeQuery`` into a caller-built query. Caller-supplied
    /// values win, so an explicit size is never overwritten.
    private func withImageSize(_ query: [String: String]) async -> [String: String] {
        query.merging(await imageSizeQuery) { caller, _ in caller }
    }

    /// `GET /api/v1/images/capability`. Throws `HTTPError.http(404, _)`
    /// on servers that predate image-size selection; the caller treats
    /// that as "feature off".
    func imageSizeCapability() async throws -> ImageSizeCapabilityResponse {
        try await http.get("/api/v1/images/capability")
    }

    // MARK: - Path-based dispatcher (legacy)

    func get<T: Decodable>(_ path: String, query: [String: String] = [:]) async throws -> T {
        let components = pathComponents(path)

        // Home / sections
        if components == ["api", "v1", "home", "sections"] {
            return try cast(try await homeSections())
        }
        if components == ["api", "v1", "recommendations", "discover"] {
            return try cast(try await recommendationsDiscover())
        }

        // Catalog / items
        if components == ["api", "v1", "catalog"] {
            return try cast(try await catalog(query: query))
        }
        if components.count == 5,
           components[0] == "api", components[1] == "v1",
           components[2] == "catalog", components[3] == "items" {
            return try cast(try await itemDetail(contentId: components[4]))
        }
        if components.count == 6,
           components[0] == "api", components[1] == "v1",
           components[2] == "catalog", components[3] == "series",
           components[5] == "seasons" {
            return try cast(try await seasons(seriesId: components[4]))
        }
        if components.count == 8,
           components[0] == "api", components[1] == "v1",
           components[2] == "catalog", components[3] == "series",
           components[5] == "seasons", components[7] == "episodes" {
            guard let seasonNumber = Int(components[6]) else {
                throw APIError.invalidPathParameter(name: "seasonNumber", value: components[6])
            }
            return try cast(try await episodes(seriesId: components[4], seasonNumber: seasonNumber))
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "people" {
            guard let personId = Int(components[3]) else {
                throw APIError.invalidPathParameter(name: "personId", value: components[3])
            }
            return try cast(try await person(id: personId))
        }

        // Personal
        if components == ["api", "v1", "favorites"] {
            return try cast(try await favorites(
                offset: queryInt(query["offset"]) ?? 0,
                limit: queryInt(query["limit"]) ?? 100
            ))
        }
        if components == ["api", "v1", "watchlist"] {
            return try cast(try await watchlist(
                offset: queryInt(query["offset"]) ?? 0,
                limit: queryInt(query["limit"]) ?? 100
            ))
        }
        if components == ["api", "v1", "history"] {
            return try cast(try await history(
                offset: queryInt(query["offset"]) ?? 0,
                limit: queryInt(query["limit"]) ?? 100
            ))
        }

        // Collections
        if components == ["api", "v1", "collections"] {
            return try cast(try await collections())
        }
        if components.count == 5,
           components[0] == "api", components[1] == "v1",
           components[2] == "collections", components[4] == "items" {
            return try cast(try await collectionItems(
                collectionId: components[3],
                offset: queryInt(query["offset"]) ?? 0,
                limit: queryInt(query["limit"]) ?? 200
            ))
        }

        // Libraries
        if components == ["api", "v1", "libraries"] || components == ["api", "v1", "user", "libraries"] {
            return try cast(try await libraries())
        }

        // Library-scoped
        if components.count == 5,
           components[0] == "api", components[1] == "v1",
           components[2] == "library" {
            guard let libraryId = Int(components[3]) else {
                throw APIError.invalidPathParameter(name: "libraryId", value: components[3])
            }
            if components[4] == "sections" {
                return try cast(try await librarySections(libraryId: libraryId))
            }
            if components[4] == "collections" {
                return try cast(try await libraryCollections(libraryId: libraryId))
            }
        }
        if components.count == 7,
           components[0] == "api", components[1] == "v1",
           components[2] == "library", components[4] == "collections",
           components[6] == "items" {
            guard let libraryId = Int(components[3]) else {
                throw APIError.invalidPathParameter(name: "libraryId", value: components[3])
            }
            return try cast(try await libraryCollectionItems(
                libraryId: libraryId,
                collectionId: components[5],
                offset: queryInt(query["offset"]) ?? 0,
                limit: queryInt(query["limit"]) ?? 60,
                snapshot: query["snapshot"],
                includeTotal: query["include_total"] != "false"
            ))
        }
        // Catalog filters
        if components == ["api", "v1", "catalog", "filters"] {
            let libraryId = queryInt(query["library_id"])
            let includeTechnical = query["include_technical"].map { $0 == "true" } ?? true
            return try cast(try await catalogFilters(
                libraryId: libraryId,
                includeTechnical: includeTechnical
            ))
        }

        // Watch detail
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "watch" {
            return try cast(try await watchDetail(contentId: components[3]))
        }

        if components == ["api", "v1", "user", "me"] || components == ["api", "v1", "auth", "me"] {
            return try cast(try await currentUser())
        }

        // Profiles
        if components == ["api", "v1", "profiles"] {
            return try cast(try await listProfiles())
        }

        // Favorite / watchlist check (Bool)
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "favorites" {
            return try cast(try await isFavorite(contentId: components[3]))
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "watchlist" {
            return try cast(try await isInWatchlist(contentId: components[3]))
        }

        throw APIError.unsupportedPath(path)
    }

    func post<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        let components = pathComponents(path)

        if components == ["api", "v1", "playback", "start"] {
            let request = try requireBody(body, as: StartPlaybackRequest.self)
            return try cast(try await startPlayback(request: request))
        }
        if components == ["api", "v1", "playback", "transcode", "start"] {
            let request = try requireBody(body, as: TranscodeStartRequest.self)
            return try cast(try await startTranscode(request: request))
        }
        if components == ["api", "v1", "collections"] {
            let request = try requireBody(body, as: CreateCollectionRequest.self)
            return try cast(try await createCollection(
                name: request.name,
                collectionType: request.collectionType
            ))
        }
        if components == ["api", "v1", "profiles"] {
            let request = try requireBody(body, as: CreateProfileBody.self)
            return try cast(try await createProfile(
                name: request.name,
                avatarEmoji: request.avatarEmoji,
                pin: request.pin,
                isChild: request.isChild
            ))
        }
        if components.count == 5,
           components[0] == "api", components[1] == "v1",
           components[2] == "people", components[4] == "refresh" {
            guard let personId = Int(components[3]) else {
                throw APIError.invalidPathParameter(name: "personId", value: components[3])
            }
            return try cast(try await refreshPerson(id: personId))
        }

        throw APIError.unsupportedPath(path)
    }

    func postVoid(_ path: String, body: (any Encodable)? = nil) async throws {
        let components = pathComponents(path)

        if components.count == 5,
           components[0] == "api", components[1] == "v1",
           components[2] == "playback", components[4] == "progress" {
            let report = try requireBody(body, as: ProgressReport.self)
            try await reportPlaybackProgress(sessionId: components[3], report: report)
            return
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "watched" {
            try await setWatched(contentId: components[3], played: true)
            return
        }

        throw APIError.unsupportedPath(path)
    }

    func put<T: Decodable>(_ path: String, body: (any Encodable)? = nil) async throws -> T {
        throw APIError.unsupportedPath(path)
    }

    func putVoid(_ path: String, body: (any Encodable)? = nil) async throws {
        let components = pathComponents(path)

        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "settings" {
            let request = try requireBody(body, as: SetSettingBody.self)
            try await setSetting(key: components[3], value: request.value)
            return
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "favorites" {
            try await toggleFavorite(contentId: components[3], isFavorite: true)
            return
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "watchlist" {
            try await toggleWatchlist(contentId: components[3], isInWatchlist: true)
            return
        }

        throw APIError.unsupportedPath(path)
    }

    func delete(_ path: String) async throws {
        let components = pathComponents(path)

        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "settings" {
            try await deleteSetting(key: components[3])
            return
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "favorites" {
            try await toggleFavorite(contentId: components[3], isFavorite: false)
            return
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "watchlist" {
            try await toggleWatchlist(contentId: components[3], isInWatchlist: false)
            return
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "collections" {
            try await deleteCollection(id: components[3])
            return
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "playback" {
            try await stopPlayback(sessionId: components[3])
            return
        }
        if components.count == 4,
           components[0] == "api", components[1] == "v1",
           components[2] == "watched" {
            try await setWatched(contentId: components[3], played: false)
            return
        }

        throw APIError.unsupportedPath(path)
    }

    // MARK: - Typed endpoint methods

    // --- Auth ---

    // --- Onboarding tour (profile-scoped) ---

    func onboardingFlow(surface: String) async throws -> OnboardingFlow {
        try await http.get(
            "/api/v1/onboarding/flow",
            query: ["surface": surface]
        )
    }

    func onboardingState() async throws -> OnboardingState {
        try await http.get("/api/v1/onboarding/state")
    }

    func postOnboardingProgress(_ request: OnboardingProgressRequest) async throws {
        try await http.postVoid("/api/v1/onboarding/progress", body: request)
    }

    func currentUser() async throws -> UserInfo {
        let user: AuthUser = try await http.get("/api/v1/auth/me")
        return UserInfo(
            id: String(user.id),
            username: user.username,
            isAdmin: user.role == "admin"
        )
    }

    // --- User settings ---

    func effectiveSettings(keys: [String]) async throws -> [EffectiveSettingResponse] {
        guard !keys.isEmpty else { return [] }
        let response: EffectiveSettingsResponse = try await http.get(
            "/api/v1/settings/effective",
            query: ["keys": keys.joined(separator: ",")]
        )
        return response.settings
    }

    func effectiveSubtitleAppearance() async throws -> EffectiveSubtitleAppearanceResponse {
        try await http.get("/api/v1/settings/subtitle_appearance/effective")
    }

    func getDeviceSetting(key: String) async throws -> SettingEntryResponse {
        try await http.get("/api/v1/settings/device/\(key)")
    }

    func setDeviceSetting(key: String, value: String) async throws {
        try await http.putVoid("/api/v1/settings/device/\(key)", body: SetSettingBody(value: value))
    }

    func deleteDeviceSetting(key: String) async throws {
        try await http.delete("/api/v1/settings/device/\(key)")
    }

    func setDeviceSubtitleAppearanceOverride(_ appearance: SubtitleAppearance) async throws {
        try await setDeviceSetting(key: "subtitle_appearance", value: appearance.jsonString)
    }

    func deleteDeviceSubtitleAppearanceOverride() async throws {
        try await deleteDeviceSetting(key: "subtitle_appearance")
    }

    func setSetting(key: String, value: String) async throws {
        try await http.putVoid("/api/v1/settings/\(key)", body: SetSettingBody(value: value))
    }

    func deleteSetting(key: String) async throws {
        try await http.delete("/api/v1/settings/\(key)")
    }

    /// Read a user-scoped setting (the `setting_user.user_id` partition,
    /// distinct from `/settings/device/{key}` which is device-scoped).
    /// The server returns 404 when the key is unset — callers that want
    /// "default if absent" semantics catch `HTTPError.http(404, _)` and
    /// fall through to their own defaults.
    func getUserSetting(key: String) async throws -> SettingEntryResponse {
        try await http.get("/api/v1/settings/\(key)")
    }

    /// Read the server-wide overlay configuration: the admin kill
    /// switch and the optional baseline `card_overlays` defaults for
    /// users who haven't customized yet. Cached server-side for 60s.
    func overlayConfig() async throws -> OverlayConfigResponse {
        try await http.get("/api/v1/settings/overlay-config")
    }

    // --- Home / sections ---

    func homeSections() async throws -> SectionsResponse {
        try await http.get("/api/v1/home/sections", query: await imageSizeQuery)
    }

    func dismissContinueWatchingItem(contentId: String, progressUpdatedAt: String) async throws {
        try await http.putVoid(
            "/api/v1/home/dismissals/continue_watching/\(contentId)",
            body: HomeDismissalBody(progressUpdatedAt: progressUpdatedAt)
        )
    }

    func undoDismissContinueWatchingItem(contentId: String) async throws {
        try await http.delete("/api/v1/home/dismissals/continue_watching/\(contentId)")
    }

    func librarySections(libraryId: Int) async throws -> SectionsResponse {
        try await http.get("/api/v1/library/\(libraryId)/sections", query: await imageSizeQuery)
    }

    /// Fetch the IDs of items the recommendation engine considers
    /// similar to `contentId`. The server returns scored IDs only —
    /// resolve each into a poster card via `itemDetail` (in parallel).
    func recommendationsSimilar(
        contentId: String,
        limit: Int = 12
    ) async throws -> [ScoredItemRef] {
        let response: ScoredItemsResponse = try await http.get(
            "/api/v1/recommendations/similar/\(contentId)",
            query: ["limit": String(limit)]
        )
        return response.items
    }

    func recommendationsDiscover() async throws -> SectionsResponse {
        let response: DiscoverResponse = try await http.get("/api/v1/recommendations/discover")
        let resolved = response.rows.enumerated().map { index, row -> ResolvedSection in
            ResolvedSection(
                id: "discover_\(index)_\(row.type)",
                sectionType: row.type,
                title: row.label,
                featured: false,
                itemLimit: row.items.count,
                totalCount: row.items.count,
                isCustom: false,
                customized: false,
                items: row.items
            )
        }
        return SectionsResponse(sections: resolved)
    }

    // --- Calendar ---

    /// Upcoming releases/airings grouped by viewer-local day. `start` /
    /// `end` are inclusive "YYYY-MM-DD" bounds (the server caps the
    /// window at 31 days); `timezone` is the viewer's IANA identifier
    /// used for day grouping.
    func calendarEvents(
        start: String,
        end: String,
        filter: String,
        timezone: String
    ) async throws -> CalendarResponse {
        try await http.get("/api/v1/calendar", query: [
            "start": start,
            "end": end,
            "filter": filter,
            "timezone": timezone,
        ])
    }

    // --- Catalog ---

    /// Every catalog-shaped list (browse, search, person credits,
    /// collection items, section paging) funnels through here, so the
    /// image-size entry only has to be merged in once.
    func catalog(query: [String: String]) async throws -> CatalogResponse {
        try await http.get("/api/v1/catalog", query: await withImageSize(query))
    }

    func historyCatalog(
        offset: Int,
        limit: Int,
        snapshot: String? = nil,
        includeTotal: Bool = true
    ) async throws -> CatalogResponse {
        var query: [String: String] = [
            "source": "history",
            "offset": String(offset),
            "limit": String(limit),
        ]
        if let snapshot { query["snapshot"] = snapshot }
        if !includeTotal { query["include_total"] = "false" }
        return try await catalog(query: query)
    }

    func itemDetail(contentId: String) async throws -> ItemDetail {
        try await http.get("/api/v1/catalog/items/\(contentId)", query: await imageSizeQuery)
    }

    func catalogFilters(libraryId: Int?, includeTechnical: Bool = true) async throws -> CatalogFilters {
        var query: [String: String] = [:]
        if let libraryId { query["library_id"] = String(libraryId) }
        // include_technical unlocks the resolution / audio / subtitle facets.
        if includeTechnical { query["include_technical"] = "true" }
        return try await http.get("/api/v1/catalog/filters", query: query)
    }

    func seasons(seriesId: String) async throws -> SeasonsResponse {
        try await http.get(
            "/api/v1/catalog/series/\(seriesId)/seasons",
            query: await imageSizeQuery
        )
    }

    func episodes(seriesId: String, seasonNumber: Int) async throws -> EpisodesResponse {
        try await http.get(
            "/api/v1/catalog/series/\(seriesId)/seasons/\(seasonNumber)/episodes",
            query: await imageSizeQuery
        )
    }

    func watchDetail(contentId: String) async throws -> WatchDetail {
        try await http.get("/api/v1/watch/\(contentId)", query: await imageSizeQuery)
    }

    func person(id: Int) async throws -> Person {
        try await http.get("/api/v1/people/\(id)")
    }

    func refreshPerson(id: Int) async throws -> PersonRefreshQueuedResponse {
        try await http.post("/api/v1/people/\(id)/refresh")
    }

    /// Ask the server to look for trailers for a movie or series.
    ///
    /// Three expected outcomes, all decoded from a body: `202` +
    /// `{"status":"queued"}` when a refresh started, `200` +
    /// `{"status":"cooldown","next_allowed_at":…}` when the item was checked
    /// too recently, and `200` + `{"status":"disabled"}` when remote videos
    /// are switched off for every library holding the item. Only `429`
    /// (per-user rate limit) and the usual transport failures throw.
    ///
    /// There is no job id: observe completion by re-fetching item detail
    /// until `videos` / `extras` change — see ``TrailerFetchCoordinator``.
    func requestTrailersRefresh(contentId: String) async throws -> TrailerRefreshResponse {
        try await http.post("/api/v1/items/\(contentId)/trailers/refresh")
    }

    func personCatalogItems(
        personId: Int,
        type: String?,
        offset: Int,
        limit: Int,
        snapshot: String? = nil
    ) async throws -> CatalogResponse {
        var query: [String: String] = [
            "source": "person",
            "person_id": String(personId),
            "offset": String(offset),
            "limit": String(limit),
            "sort": "year",
            "order": "desc",
        ]
        if let type { query["type"] = type }
        if let snapshot { query["snapshot_at"] = snapshot }
        return try await catalog(query: query)
    }

    // --- Libraries ---

    func libraries() async throws -> LibrariesResponse {
        let libs: [Library] = try await http.get("/api/v1/user/libraries")
        return LibrariesResponse(libraries: libs)
    }

    func libraryCollections(libraryId: Int) async throws -> LibraryCollectionsResponse {
        let wire: LibraryCollectionsWireResponse = try await http.get(
            "/api/v1/library/\(libraryId)/collections"
        )
        return LibraryCollectionsResponse(collections: wire.collections, sections: wire.sections)
    }

    func libraryCollectionItems(
        libraryId: Int,
        collectionId: String,
        offset: Int = 0,
        limit: Int = 60,
        snapshot: String? = nil,
        includeTotal: Bool = false
    ) async throws -> CatalogResponse {
        try await catalogCollectionItems(
            kind: .regular,
            collectionId: collectionId,
            offset: offset,
            limit: limit,
            snapshot: snapshot,
            includeTotal: includeTotal
        )
    }

    /// User-collection items resolved through the unified catalog endpoint.
    /// The raw `/api/v1/collections/{id}/items` route returns un-hydrated
    /// join records; only the catalog resolver re-hydrates them into the
    /// `CatalogResponse` shape that views expect.
    func userCollectionItems(
        collectionId: String,
        offset: Int = 0,
        limit: Int = 60,
        snapshot: String? = nil,
        includeTotal: Bool = false
    ) async throws -> CatalogResponse {
        try await catalogCollectionItems(
            kind: .userCollections,
            collectionId: collectionId,
            offset: offset,
            limit: limit,
            snapshot: snapshot,
            includeTotal: includeTotal
        )
    }

    private func catalogCollectionItems(
        kind: LibraryCollectionKind,
        collectionId: String,
        offset: Int,
        limit: Int,
        snapshot: String?,
        includeTotal: Bool
    ) async throws -> CatalogResponse {
        var query: [String: String] = [
            "source": kind.catalogSource,
            "collection_id": collectionId,
            "offset": String(offset),
            "limit": String(limit),
        ]
        if let snapshot { query["snapshot"] = snapshot }
        if !includeTotal { query["include_total"] = "false" }
        return try await catalog(query: query)
    }

    // --- Playback preferences ---

    /// Fetch all per-library playback preferences for the current
    /// profile. Empty array if the user hasn't set any.
    func libraryPlaybackPrefs() async throws -> [LibraryPlaybackPref] {
        let resp: LibraryPlaybackPrefsResponse = try await http.get(
            "/api/v1/library-playback-prefs"
        )
        return resp.preferences
    }

    /// Set or update the per-library prefs for `libraryId`. Pass nil
    /// for any field to clear it; sending all four nil deletes the row
    /// server-side and the next list will omit it.
    func setLibraryPlaybackPref(
        libraryId: Int,
        audioLanguage: String?,
        subtitleLanguage: String?,
        subtitleMode: String?,
        showForcedSubtitles: Bool?
    ) async throws {
        let body = LibraryPlaybackPrefRequest(
            audioLanguage: audioLanguage,
            subtitleLanguage: subtitleLanguage,
            subtitleMode: subtitleMode,
            showForcedSubtitles: showForcedSubtitles
        )
        try await http.putVoid("/api/v1/library-playback-prefs/\(libraryId)", body: body)
    }

    func deleteLibraryPlaybackPref(libraryId: Int) async throws {
        try await http.delete("/api/v1/library-playback-prefs/\(libraryId)")
    }

    /// Per-series subtitle override. 404 → no override exists; we treat
    /// that as `nil` so callers don't need to special-case it.
    func subtitlePref(seriesId: String) async throws -> SubtitlePref? {
        do {
            let pref: SubtitlePref = try await http.get("/api/v1/subtitle-prefs/\(seriesId)")
            return pref
        } catch HTTPError.http(let code, _) where code == 404 {
            return nil
        }
    }

    func setSubtitlePref(seriesId: String, body: SubtitlePrefRequest) async throws {
        try await http.putVoid("/api/v1/subtitle-prefs/\(seriesId)", body: body)
    }

    func deleteSubtitlePref(seriesId: String) async throws {
        try await http.delete("/api/v1/subtitle-prefs/\(seriesId)")
    }

    func audioPref(seriesId: String) async throws -> AudioPref? {
        do {
            let pref: AudioPref = try await http.get("/api/v1/audio-prefs/\(seriesId)")
            return pref
        } catch HTTPError.http(let code, _) where code == 404 {
            return nil
        }
    }

    func setAudioPref(seriesId: String, body: AudioPrefRequest) async throws {
        try await http.putVoid("/api/v1/audio-prefs/\(seriesId)", body: body)
    }

    func deleteAudioPref(seriesId: String) async throws {
        try await http.delete("/api/v1/audio-prefs/\(seriesId)")
    }

    // --- Personal data ---

    // These three build their own query rather than routing through
    // `catalog(query:)`, so each merges the image-size entry itself.
    // They back real poster grids on TV, and `historyCatalog` — the
    // entry point the history screen actually uses — is already covered
    // by `catalog(query:)`.

    func favorites(offset: Int, limit: Int) async throws -> CatalogResponse {
        try await http.get("/api/v1/favorites", query: await withImageSize([
            "offset": String(offset),
            "limit": String(limit),
        ]))
    }

    func watchlist(offset: Int, limit: Int) async throws -> CatalogResponse {
        try await http.get("/api/v1/watchlist", query: await withImageSize([
            "offset": String(offset),
            "limit": String(limit),
        ]))
    }

    func history(offset: Int, limit: Int) async throws -> CatalogResponse {
        try await http.get("/api/v1/history", query: await withImageSize([
            "offset": String(offset),
            "limit": String(limit),
        ]))
    }

    /// Server returns 204 when the item is a favorite and 404 otherwise.
    /// ``HTTPClient/exists(_:query:)`` translates that into a boolean
    /// without trying to decode the empty response body.
    func isFavorite(contentId: String) async throws -> Bool {
        try await http.exists("/api/v1/favorites/\(contentId)")
    }

    func isInWatchlist(contentId: String) async throws -> Bool {
        try await http.exists("/api/v1/watchlist/\(contentId)")
    }

    func toggleFavorite(contentId: String, isFavorite: Bool) async throws {
        if isFavorite {
            try await http.putVoid("/api/v1/favorites/\(contentId)")
        } else {
            try await http.delete("/api/v1/favorites/\(contentId)")
        }
    }

    func toggleWatchlist(contentId: String, isInWatchlist: Bool) async throws {
        if isInWatchlist {
            try await http.putVoid("/api/v1/watchlist/\(contentId)")
        } else {
            try await http.delete("/api/v1/watchlist/\(contentId)")
        }
    }

    /// Mark a content item (movie / series / season / episode) as watched
    /// or unwatched. Server resolves the leaf targets.
    func setWatched(contentId: String, played: Bool) async throws {
        if played {
            try await http.postVoid("/api/v1/watched/\(contentId)")
        } else {
            try await http.delete("/api/v1/watched/\(contentId)")
        }
    }

    // --- Collections ---

    func collections() async throws -> CollectionsResponse {
        try await http.get("/api/v1/collections")
    }

    func collectionItems(
        collectionId: String,
        offset: Int,
        limit: Int
    ) async throws -> CatalogResponse {
        try await http.get("/api/v1/collections/\(collectionId)/items", query: [
            "offset": String(offset),
            "limit": String(limit),
        ])
    }

    func createCollection(name: String, collectionType: String) async throws -> UserCollection {
        try await http.post(
            "/api/v1/collections",
            body: CreateCollectionRequest(name: name, collectionType: collectionType)
        )
    }

    func deleteCollection(id: String) async throws {
        try await http.delete("/api/v1/collections/\(id)")
    }

    /// Move a personal collection between groups (pass `nil` for
    /// Ungrouped). Returns the updated collection.
    func moveCollectionToGroup(id: String, groupId: String?) async throws -> UserCollection {
        try await http.put(
            "/api/v1/collections/\(id)",
            body: UpdateUserCollectionGroupBody(groupId: groupId)
        )
    }

    // --- Collection groups (personal) ---

    func createCollectionGroup(name: String) async throws -> CollectionGroup {
        try await http.post(
            "/api/v1/collections/groups",
            body: CreateCollectionGroupRequest(name: name, slug: nil)
        )
    }

    func renameCollectionGroup(id: String, name: String) async throws -> CollectionGroup {
        try await http.put(
            "/api/v1/collections/groups/\(id)",
            body: UpdateCollectionGroupRequest(name: name)
        )
    }

    func deleteCollectionGroup(id: String) async throws {
        try await http.delete("/api/v1/collections/groups/\(id)")
    }

    func reorderCollectionGroups(orderedIds: [String]) async throws {
        try await http.putVoid(
            "/api/v1/collections/groups/order",
            body: ReorderCollectionGroupsRequest(orderedIds: orderedIds)
        )
    }

    func reorderCollections(orderedIds: [String], groupId: String?) async throws {
        try await http.putVoid(
            "/api/v1/collections/order",
            body: ReorderCollectionsRequest(orderedIds: orderedIds, groupId: groupId)
        )
    }

    // --- Profiles ---

    func listProfiles() async throws -> [UserProfile] {
        let response: ProfilesResponse = try await http.get("/api/v1/profiles")
        return response.profiles.map(\.asUserProfile)
    }

    /// Verifies a protected profile without mutating process-wide identity.
    /// `AuthService` uses this to finish the network round trip first, then
    /// commit profile ID and proof together behind HTTPClient's transition
    /// barrier.
    func verifyProfileSelection(profileId: String, pin: String?) async throws -> String? {
        // Profiles without a PIN: just record the selection locally; there's
        // nothing to verify and the server's /verify-pin rejects empty PINs
        // with 400. Mirrors `ProfileSelectionViewModel.onProfileTapped` on
        // Android, which skips the verify call when `hasPin` is false.
        if let pin, !pin.isEmpty {
            let response: VerifyPinResponse = try await http.post(
                "/api/v1/profiles/\(profileId)/verify-pin",
                body: VerifyPinRequest(pin: pin)
            )
            guard response.valid else {
                throw APIError.httpError(statusCode: 401)
            }
            return response.profileToken
        }
        return nil
    }

    func createProfile(
        name: String,
        avatarEmoji: String?,
        pin: String?,
        isChild: Bool,
        maxContentRating: String? = nil,
        libraryRestrictionsEnabled: Bool = false,
        allowedLibraryIds: [Int] = []
    ) async throws -> UserProfile {
        let profile: Profile = try await http.post(
            "/api/v1/profiles",
            body: CreateProfileRequestBody(
                name: name,
                avatar: avatarEmoji,
                pin: pin,
                isChild: isChild,
                maxContentRating: maxContentRating,
                libraryRestrictionsEnabled: libraryRestrictionsEnabled,
                allowedLibraryIds: allowedLibraryIds
            )
        )
        return profile.asUserProfile
    }

    /// Patch a profile. Send only the fields you want to change — the
    /// server treats absent fields as untouched. Used by Settings to
    /// persist subtitle prefs.
    func updateProfile(profileId: String, body: UpdateProfileBody) async throws {
        try await http.putVoid("/api/v1/profiles/\(profileId)", body: body)
    }

    // --- Playback ---

    // Session planning can be slow on heavy files (stream probing, transcode
    // spin-up), so both start calls opt out of the fail-fast timeout. A dead
    // server is still caught early: connection-refused fails instantly, and
    // the detail screen's own fetches run on the standard timeout.
    func startPlayback(request: StartPlaybackRequest) async throws -> PlaybackSessionResponse {
        try await http.post("/api/v1/playback/start", body: request, timeout: .extended)
    }

    func playbackV3Capability() async throws -> PlaybackV3CapabilityResponse {
        try await http.get("/api/v1/playback/capability")
    }

    func startPlaybackV3(request: PlaybackV3StartRequest) async throws -> PlaybackV3DecisionResponse {
        try await http.post("/api/v1/playback/start", body: request, timeout: .extended)
    }

    func replanPlaybackV3(
        sessionId: String,
        request: PlaybackV3ReplanRequest
    ) async throws -> PlaybackV3DecisionResponse {
        try await http.post(
            "/api/v1/playback/\(sessionId)/replan",
            body: request,
            timeout: .extended
        )
    }

    func reportPlaybackRouteEventV3(_ event: PlaybackV3RouteEvent) async throws {
        try await http.postVoid("/api/v1/playback/route-events", body: event)
    }

    func startTranscode(request: TranscodeStartRequest) async throws -> TranscodeStartResponse {
        try await http.post("/api/v1/playback/transcode/start", body: request, timeout: .extended)
    }

    func reportPlaybackProgress(sessionId: String, report: ProgressReport) async throws {
        try await http.postVoid(
            "/api/v1/playback/\(sessionId)/progress",
            body: report
        )
    }

    func syncProgress(
        mediaItemId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool = false
    ) async throws {
        try await http.postVoid(
            "/api/v1/sync/progress",
            body: SyncProgressRequest(items: [
                SyncProgressItem(
                    mediaItemId: mediaItemId,
                    position: position,
                    duration: duration,
                    forceOverwrite: forceOverwrite
                )
            ])
        )
    }

    func stopPlayback(sessionId: String) async throws {
        try await http.delete("/api/v1/playback/\(sessionId)")
    }

    // MARK: - Helpers

    private func pathComponents(_ path: String) -> [String] {
        path.split(separator: "/").map(String.init)
    }

    private func queryInt(_ value: String?) -> Int? {
        value.flatMap(Int.init)
    }

    private func cast<T>(_ value: Any) throws -> T {
        guard let typed = value as? T else {
            throw APIError.typeMismatch(
                expected: String(describing: T.self),
                actual: String(describing: Swift.type(of: value))
            )
        }
        return typed
    }

    private func requireBody<B>(_ body: (any Encodable)?, as type: B.Type) throws -> B {
        guard let typed = body as? B else {
            throw APIError.unsupportedBody(expected: String(describing: type))
        }
        return typed
    }
}

// MARK: - Supporting Types

enum APIError: LocalizedError {
    case httpError(statusCode: Int)
    case invalidPathParameter(name: String, value: String)
    case unsupportedPath(String)
    case unsupportedBody(expected: String)
    case typeMismatch(expected: String, actual: String)
    case unsupportedMedia(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "Server returned status \(code)"
        case .invalidPathParameter(let name, let value):
            return "Invalid \(name): \(value)"
        case .unsupportedPath(let path):
            return "Unsupported API path: \(path)"
        case .unsupportedBody(let expected):
            return "Unsupported request body. Expected \(expected)."
        case .typeMismatch(let expected, let actual):
            return "API returned \(actual), expected \(expected)."
        case .unsupportedMedia(let message):
            return message
        }
    }
}

private struct HomeDismissalBody: Encodable {
    let progressUpdatedAt: String
}
