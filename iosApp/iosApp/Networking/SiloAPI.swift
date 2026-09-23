import Foundation

/// Native Swift facade over the Silo REST API.
///
/// All HTTP goes through ``HTTPClient/shared``; session state lives in
/// ``TokenStore/shared``. Refer to [HTTPClient](x-source-tag://HTTPClient)
/// for auth header injection and 401 refresh semantics.
actor SiloAPI {
    static let shared = SiloAPI()

    /// Non-private so endpoint methods declared in extensions (e.g. the
    /// downloads API) can reuse the same injected transport.
    let http: HTTPClient
    private let tokenStore: TokenStore
    /// The one v2 client for this facade, built from the same injected
    /// transport and token store. `nonisolated` so callers outside the
    /// actor can use `SiloAPI.shared.apiV2Client` without a hop.
    nonisolated let apiV2Client: APIv2Client

    init(http: HTTPClient = .shared, tokenStore: TokenStore = .shared) {
        self.http = http
        self.tokenStore = tokenStore
        self.apiV2Client = APIv2Client(http: http, tokenStore: tokenStore)
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
            await ImageSizeCapability.shared.refresh(retryFailed: false)
            return ImageSizeCapability.shared.requestQuery
        }
    }

    /// Merge ``imageSizeQuery`` into a caller-built query. Caller-supplied
    /// values win, so an explicit size is never overwritten.
    private func withImageSize(_ query: [String: String]) async -> [String: String] {
        query.merging(await imageSizeQuery) { caller, _ in caller }
    }

    /// `GET /api/v2/images/capabilities`. Throws `HTTPError.http(404, _)`
    /// on servers that predate image-size selection; the caller treats
    /// that as "feature off".
    func imageSizeCapability() async throws -> ImageSizeCapabilityResponse {
        try await http.get("/api/v2/images/capabilities")
    }

    // MARK: - Typed endpoint methods

    // --- Auth ---

    /// `GET /api/v2/account/me`. The v2 read also binds the verified account
    /// ID to a session installed without one (`APIv2Client.currentUser`).
    func currentUser() async throws -> UserInfo {
        let account = try await apiV2Client.currentUser()
        return UserInfo(
            id: account.id,
            username: account.username,
            isAdmin: account.role == .admin
        )
    }

    // --- Home / sections ---

    /// The acting profile's Home rows. The read carries the owner it was
    /// fetched for so a caller can refuse to apply it after a switch.
    func homeSections() async throws -> APIv2HomeSectionsRead {
        let auth = try await detailReadAuth()
        return try await apiV2Client.homeSections(imageSize: await imageSizeQuery["image_size"], auth: auth)
    }

    /// True while `auth` still names the active server, account and profile.
    func isCurrentOwner(_ auth: CapturedOrdinaryRequestAuth) async -> Bool {
        await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil
    }

    /// Hide an in-progress card until it is played again. The server keys
    /// the dismissal on the card's exact `progress_updated_at`.
    func dismissContinueWatchingItem(contentId: String, progressUpdatedAt: String) async throws {
        try await apiV2Client.dismissHomeItem(
            id: contentId, progressUpdatedAt: progressUpdatedAt, seriesId: nil,
            auth: await tokenStore.captureOrdinaryRequestAuth()
        )
    }

    /// Next Up episodes carry no progress row, so the server keys their
    /// dismissal on the parent series instead of `progress_updated_at`.
    func dismissNextUpItem(contentId: String, seriesId: String) async throws {
        try await apiV2Client.dismissHomeItem(
            id: contentId, progressUpdatedAt: nil, seriesId: seriesId,
            auth: await tokenStore.captureOrdinaryRequestAuth()
        )
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

    func itemDetail(contentId: String, libraryId: Int? = nil) async throws -> ItemDetail {
        let auth = try await detailReadAuth()
        let item = try await apiV2Client.catalogItem(
            id: contentId, libraryId: libraryId.map(String.init),
            imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        return try ItemDetail(catalog: item)
    }

    private func detailReadAuth() async throws -> CapturedOrdinaryRequestAuth {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else {
            throw HTTPError.requestIdentityChanged
        }
        return auth
    }

    func catalogFilters(libraryId: Int?, includeTechnical: Bool = true) async throws -> CatalogFilters {
        var query: [String: String] = [:]
        if let libraryId { query["library_id"] = String(libraryId) }
        // include_technical unlocks the resolution / audio / subtitle facets.
        if includeTechnical { query["include_technical"] = "true" }
        return try await http.get("/api/v1/catalog/filters", query: query)
    }

    func seasons(seriesId: String, libraryId: Int? = nil) async throws -> SeasonsResponse {
        let auth = try await detailReadAuth()
        #if os(tvOS)
        let includeArtwork: Bool? = false
        #else
        let includeArtwork: Bool? = nil
        #endif
        let seasons = try await apiV2Client.catalogSeasons(
            seriesId: seriesId, libraryId: libraryId.map(String.init),
            imageSize: await imageSizeQuery["image_size"], includeArtwork: includeArtwork, auth: auth
        )
        return SeasonsResponse(seasons: try seasons.map { try Season(catalog: $0) })
    }

    func episodes(seriesId: String, seasonNumber: Int, libraryId: Int? = nil) async throws -> EpisodesResponse {
        let auth = try await detailReadAuth()
        let episodes = try await apiV2Client.catalogEpisodes(
            seriesId: seriesId, seasonNumber: seasonNumber, libraryId: libraryId.map(String.init),
            imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        return EpisodesResponse(episodes: try episodes.map { try EpisodeListItem(catalog: $0) })
    }

    func watchDetail(contentId: String, libraryId: Int? = nil) async throws -> WatchDetail {
        let auth = try await detailReadAuth()
        return try await apiV2Client.watchDetail(
            id: contentId, libraryId: libraryId.map(String.init),
            imageSize: await imageSizeQuery["image_size"], auth: auth
        )
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
}

// MARK: - Supporting Types

enum APIError: LocalizedError {
    case httpError(statusCode: Int)
    case unsupportedMedia(String)

    var errorDescription: String? {
        switch self {
        case .httpError(let code):
            return "Server returned status \(code)"
        case .unsupportedMedia(let message):
            return message
        }
    }
}
