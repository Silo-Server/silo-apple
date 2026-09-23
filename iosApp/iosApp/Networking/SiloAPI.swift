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

    /// The library's sections as the acting profile sees them. Like Home,
    /// the read carries the owner it was fetched for so a caller can refuse
    /// to cache or show it after a switch.
    func librarySections(libraryId: Int) async throws -> APIv2LibrarySectionsRead {
        let auth = try await detailReadAuth()
        return try await apiV2Client.librarySections(
            id: libraryId, imageSize: await imageSizeQuery["image_size"], auth: auth
        )
    }

    /// Cards the recommendation engine considers similar to `contentId`,
    /// in ranked order. The client's owner fence throws `authorityChanged`
    /// when the acting owner changed while the read was in flight; the
    /// re-check here covers a switch during decoding. Either way a rail
    /// never shows another profile's picks.
    func recommendationsSimilar(contentId: String, limit: Int = 12) async throws -> [BrowseItem] {
        let auth = try await detailReadAuth()
        let cards = try await apiV2Client.similarCards(id: contentId, limit: limit, auth: auth)
        guard await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
        return cards
    }

    func recommendationsDiscover() async throws -> SectionsResponse {
        let rows = try await apiV2Client.discover(auth: try await detailReadAuth())
        let resolved = rows.enumerated().map { index, row -> ResolvedSection in
            ResolvedSection(
                id: "discover_\(index)_\(row.type)",
                sectionType: row.type,
                title: row.title,
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
        let auth = try await detailReadAuth()
        let response = try await apiV2Client.calendar(
            start: start, end: end, filter: filter, timezone: timezone, auth: auth
        )
        // The week is cached per profile; never hand one profile's week to the next.
        guard await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
        return response
    }

    // --- Catalog ---

    /// Every catalog-shaped list (browse, search, history, person credits,
    /// collection items) pages through here. The first page captures the
    /// acting owner and the image size; `nextCatalogPage` reuses both from
    /// the continuation, so every page of one list matches the first. Large
    /// filter sets go through `POST /catalog/query` instead of a GET that
    /// the server would refuse.
    func catalogPage(_ query: APIv2CatalogQuery) async throws -> CatalogListPage {
        var query = query
        if query.imageSize == nil { query.imageSize = await imageSizeQuery["image_size"] }
        let auth = try await detailReadAuth()
        return CatalogListPage(try await apiV2Client.catalogPage(
            query: query, operation: query.preferredOperation, auth: auth
        ))
    }

    /// The page after `continuation`, read for the owner and query of the
    /// first page. A changed owner throws instead of returning their cards.
    /// When the server rejects the cursor because the list changed, this
    /// reads a fresh first page for the same owner and query instead, marked
    /// `startsOver`, so the caller never resends a dead cursor.
    func nextCatalogPage(_ continuation: APIv2CatalogContinuation) async throws -> CatalogListPage {
        do {
            return CatalogListPage(try await apiV2Client.nextCatalogPage(continuation))
        } catch where APIv2Error.isCatalogRestart(error) {
            return CatalogListPage(try await apiV2Client.catalogPage(
                query: continuation.query, operation: continuation.operation, auth: continuation.auth
            ), startsOver: true)
        }
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

    /// Facet vocabulary for one library (or all of them). Without
    /// `includeTechnical` the server skips the file-derived resolution /
    /// audio / subtitle facets. Facets follow the profile's library access,
    /// so the read is refused if the owner changed while it was in flight.
    func catalogFilters(libraryId: Int?, includeTechnical: Bool = true) async throws -> APIv2CatalogFilters {
        let auth = try await detailReadAuth()
        let filters = try await apiV2Client.catalogFilters(
            libraryId: libraryId.map(String.init), includeTechnical: includeTechnical, auth: auth
        )
        guard await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
        return filters
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

    func person(id: String) async throws -> Person {
        let auth = try await detailReadAuth()
        return try Person(catalog: try await apiV2Client.catalogPerson(id: id, auth: auth))
    }

    /// Queue a provider refresh of the person. `non_retryable`: one dispatch,
    /// never replayed; see ``APIv2Client/refreshPerson(id:auth:)``.
    func refreshPerson(id: String) async throws {
        try await apiV2Client.refreshPerson(id: id, auth: try await detailReadAuth())
    }

    /// Ask the server to look for trailers for a movie or series.
    ///
    /// Three expected outcomes, all decoded from a body: `202` +
    /// `{"status":"queued"}` when a refresh started, `200` +
    /// `{"status":"cooldown","next_allowed_at":…}` when the item was checked
    /// too recently, and `200` + `{"status":"disabled"}` when remote videos
    /// are switched off for every library holding the item. Problems (`409`,
    /// `429` rate limit, …) and transport failures throw.
    ///
    /// The route is `non_retryable`: it is dispatched once, never replayed
    /// after a token refresh, and a lost answer is reported rather than retried.
    ///
    /// There is no job id: observe completion by re-fetching item detail
    /// until `videos` / `extras` change — see ``TrailerFetchCoordinator``.
    func requestTrailersRefresh(contentId: String) async throws -> TrailerRefreshResponse {
        try await apiV2Client.refreshTrailers(id: contentId, auth: try await detailReadAuth())
    }

    // --- Libraries ---

    func libraries() async throws -> LibrariesResponse {
        let libs: [Library] = try await http.get("/api/v1/user/libraries")
        return LibrariesResponse(libraries: libs)
    }

    /// The library's Collections tab. Personal collections in it belong to
    /// the acting profile, so a tab read for one profile is never returned
    /// once the session acts as another.
    func libraryCollections(libraryId: Int) async throws -> LibraryCollectionsResponse {
        let auth = try await detailReadAuth()
        let tab = try await apiV2Client.libraryCollectionTab(libraryId: String(libraryId), auth: auth)
        guard await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
        return LibraryCollectionsResponse(tab)
    }

    // --- Personal data ---

    // These build their own query rather than routing through
    // `catalogPage(_:)`, so each merges the image-size entry itself.
    // They back real poster grids on TV.

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
