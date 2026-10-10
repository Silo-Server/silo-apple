import Foundation

/// Native Swift facade over the Silo REST API.
///
/// All HTTP goes through ``HTTPClient/shared``; session state lives in
/// ``TokenStore/shared``. See ``HTTPClient`` for auth header injection and
/// 401 refresh semantics.
actor SiloAPI {
    static let shared = SiloAPI()

    /// Non-private so playback can build media requests on the same transport.
    let http: HTTPClient
    private let tokenStore: TokenStore
    /// The one v2 client for this facade, built from the same injected
    /// transport and token store. `nonisolated` so callers outside the
    /// actor can use `SiloAPI.shared.apiV2Client` without a hop.
    nonisolated let apiV2Client: APIv2Client
    /// Test seam: runs inside ``requireCurrentOwner(_:)`` after a read
    /// finishes and before its owner is rechecked, so a test can switch the
    /// profile after the round trip. Production leaves it `nil`.
    private let ownerRecheckBarrier: (@Sendable () async -> Void)?

    init(
        http: HTTPClient = .shared,
        tokenStore: TokenStore = .shared,
        ownerRecheckBarrier: (@Sendable () async -> Void)? = nil
    ) {
        self.http = http
        self.tokenStore = tokenStore
        self.apiV2Client = APIv2Client(http: http, tokenStore: tokenStore)
        self.ownerRecheckBarrier = ownerRecheckBarrier
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
    /// One place decides this for every image-bearing endpoint; call sites
    /// pass `imageSizeQuery["image_size"]` to the `APIv2Client` method.
    /// Always empty off tvOS.
    private var imageSizeQuery: [String: String] {
        get async {
            await ImageSizeCapability.shared.requestQueryForImageRequest()
        }
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
    /// in ranked order. Owner-scoped; see ``requireCurrentOwner(_:)``.
    func recommendationsSimilar(contentId: String, limit: Int = 12) async throws -> [BrowseItem] {
        let auth = try await detailReadAuth()
        let cards = try await apiV2Client.similarCards(id: contentId, limit: limit, auth: auth)
        try await requireCurrentOwner(auth)
        return cards
    }

    func recommendationsDiscover() async throws -> SectionsResponse {
        let auth = try await detailReadAuth()
        let rows = try await apiV2Client.discover(auth: auth)
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
        let response = SectionsResponse(sections: resolved)
        try await requireCurrentOwner(auth)
        return response
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
        try await requireCurrentOwner(auth)
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
        let page = CatalogListPage(try await apiV2Client.catalogPage(
            query: query, operation: query.preferredOperation, auth: auth
        ))
        try await requireCurrentOwner(auth)
        return page
    }

    /// The page after `continuation`, read for the owner and query of the
    /// first page. A changed owner throws instead of returning their cards.
    /// When the server rejects the cursor because the list changed, this
    /// reads a fresh first page for the same owner and query instead, marked
    /// `startsOver`, so the caller never resends a dead cursor.
    func nextCatalogPage(_ continuation: APIv2CatalogContinuation) async throws -> CatalogListPage {
        let page: CatalogListPage
        do {
            page = CatalogListPage(try await apiV2Client.nextCatalogPage(continuation))
        } catch where APIv2Error.isCatalogRestart(error) {
            page = CatalogListPage(try await apiV2Client.catalogPage(
                query: continuation.query, operation: continuation.operation, auth: continuation.auth
            ), startsOver: true)
        }
        try await requireCurrentOwner(continuation.auth)
        return page
    }

    func itemDetail(contentId: String, libraryId: Int? = nil) async throws -> ItemDetail {
        let auth = try await detailReadAuth()
        let item = try await apiV2Client.catalogItem(
            id: contentId, libraryId: libraryId.map(String.init),
            imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        let detail = try ItemDetail(catalog: item)
        try await requireCurrentOwner(auth)
        return detail
    }

    /// The owner a write is sent for. Without one nothing is sent, which the
    /// error says, so the write reads as a definite failure.
    private func mutationAuth() async throws -> CapturedOrdinaryRequestAuth {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else {
            throw APIv2OwnerChangedBeforeDispatch()
        }
        return auth
    }

    private func detailReadAuth() async throws -> CapturedOrdinaryRequestAuth {
        guard let auth = await tokenStore.captureOrdinaryRequestAuth() else {
            throw HTTPError.requestIdentityChanged
        }
        return auth
    }

    /// Refuses a read's result once its owner is no longer the acting one.
    /// The client's owner fence covers the round trip; this covers decoding,
    /// projection and the hop back to this actor.
    private func requireCurrentOwner(_ auth: CapturedOrdinaryRequestAuth) async throws {
        await ownerRecheckBarrier?()
        guard await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
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
        try await requireCurrentOwner(auth)
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
        let response = SeasonsResponse(seasons: try seasons.map { try Season(catalog: $0) })
        try await requireCurrentOwner(auth)
        return response
    }

    func episodes(seriesId: String, seasonNumber: Int, libraryId: Int? = nil) async throws -> EpisodesResponse {
        let auth = try await detailReadAuth()
        let episodes = try await apiV2Client.catalogEpisodes(
            seriesId: seriesId, seasonNumber: seasonNumber, libraryId: libraryId.map(String.init),
            imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        let response = EpisodesResponse(episodes: try episodes.map { try EpisodeListItem(catalog: $0) })
        try await requireCurrentOwner(auth)
        return response
    }

    func watchDetail(contentId: String, libraryId: Int? = nil) async throws -> WatchDetail {
        let auth = try await detailReadAuth()
        let detail = try await apiV2Client.watchDetail(
            id: contentId, libraryId: libraryId.map(String.init),
            imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        try await requireCurrentOwner(auth)
        return detail
    }

    func person(id: String) async throws -> Person {
        let auth = try await detailReadAuth()
        let person = try Person(catalog: try await apiV2Client.catalogPerson(id: id, auth: auth))
        try await requireCurrentOwner(auth)
        return person
    }

    /// The search features this server offers; see ``CatalogSearchFeatures``.
    /// A server without the capabilities read (v1-only, or answering 404)
    /// offers none. Any other failure throws: a server that timed out or
    /// refused the credentials has not said what it supports.
    func catalogSearchFeatures() async throws -> CatalogSearchFeatures {
        let auth = try await detailReadAuth()
        do {
            return CatalogSearchFeatures(try await apiV2Client.catalogSearchCapabilities(auth: auth))
        } catch let error as APIv2Error {
            switch error {
            case .serverUpdateRequired, .httpStatus(404): return CatalogSearchFeatures()
            case .problem(let problem) where problem.status == 404: return CatalogSearchFeatures()
            default: throw error
            }
        }
    }

    /// People matching `query` for the acting profile, exact names first.
    func searchPeople(query: String, mediaScope: String?, limit: Int) async throws -> [Person] {
        let auth = try await detailReadAuth()
        let people = try await apiV2Client.searchPeople(query: query, limit: limit, mediaScope: mediaScope, auth: auth)
        guard await isCurrentOwner(auth) else { throw HTTPError.requestIdentityChanged }
        return try people.map { try Person(catalog: $0) }
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

    /// `GET /api/v2/user/libraries`. The rows keep their numeric app IDs; a
    /// row whose ID is not a canonical positive integer fails the whole read
    /// rather than disappearing from the list.
    func libraries() async throws -> LibrariesResponse {
        let rows = try await apiV2Client.userLibraries()
        return LibrariesResponse(libraries: try rows.map(Library.init(v2:)))
    }

    /// The library's Collections tab. Personal collections in it belong to
    /// the acting profile, so a tab read for one profile is never returned
    /// once the session acts as another.
    func libraryCollections(libraryId: Int) async throws -> LibraryCollectionsResponse {
        let auth = try await detailReadAuth()
        let tab = try await apiV2Client.libraryCollectionTab(libraryId: String(libraryId), auth: auth)
        let response = LibraryCollectionsResponse(tab)
        try await requireCurrentOwner(auth)
        return response
    }

    // --- Personal data ---

    /// The acting profile's whole favorites list, read page by page from
    /// `/api/v2/favorites`. The screens filter it locally by media type.
    func favorites() async throws -> CatalogResponse {
        let auth = try await detailReadAuth()
        let list = try await apiV2Client.personalListItems(
            kind: .favorites, imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        try await requireCurrentOwner(auth)
        return list
    }

    /// The acting profile's whole watchlist from `/api/v2/watchlist`.
    func watchlist() async throws -> CatalogResponse {
        let auth = try await detailReadAuth()
        let list = try await apiV2Client.personalListItems(
            kind: .watchlist, imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        try await requireCurrentOwner(auth)
        return list
    }

    // --- Collections (personal) ---

    /// The acting profile's collections and the account's groups. A list read
    /// for one profile is never returned once the session acts as another.
    func collections() async throws -> CollectionsResponse {
        let auth = try await detailReadAuth()
        let list = try await apiV2Client.personalCollections(auth: auth)
        let response = CollectionsResponse(collections: list.items, groups: list.groups)
        try await requireCurrentOwner(auth)
        return response
    }

    /// Whether the acting account's store supports collection groups.
    func collectionCapabilities() async throws -> APIv2CollectionCapabilities {
        let auth = try await detailReadAuth()
        let capabilities = try await apiV2Client.collectionCapabilities(auth: auth)
        try await requireCurrentOwner(auth)
        return capabilities
    }

    /// Every display card in a personal collection, read as catalog pages.
    func collectionItems(collectionId: String) async throws -> CatalogResponse {
        let auth = try await detailReadAuth()
        let cards = try await apiV2Client.personalCollectionCards(
            id: collectionId, imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        try await requireCurrentOwner(auth)
        return cards
    }

    /// `non_retryable`: dispatched once. A lost answer may still have created
    /// the collection, so the caller re-reads the list instead of resending.
    func createCollection(name: String) async throws -> UserCollection {
        try await apiV2Client.createCollection(name: name, auth: try await mutationAuth())
    }

    /// The canonical collection and the version an edit of it must send.
    func collectionEditor(id: String) async throws -> CollectionEditor<UserCollection> {
        let auth = try await detailReadAuth()
        let editor = try await apiV2Client.collectionEditor(id: id, auth: auth)
        try await requireCurrentOwner(auth)
        return editor
    }

    func deleteCollection(_ version: CollectionEditVersion) async throws {
        try await apiV2Client.deleteCollection(version)
    }

    /// Move a personal collection between groups (pass `nil` for
    /// Ungrouped). Returns the updated collection.
    func moveCollection(_ version: CollectionEditVersion, toGroupId groupId: String?) async throws -> UserCollection {
        try await apiV2Client.moveCollection(version, toGroupId: groupId)
    }

    // --- Shuffle ---

    func shuffleCapability() async throws -> APIv2ShuffleCapability {
        try await apiV2Client.shuffleCapability(auth: try await detailReadAuth())
    }

    /// `non_retryable`: dispatched once. A lost answer leaves an unused
    /// shuffle that the server deletes with other abandoned ones.
    ///
    /// Shuffle answers are owner-scoped like other reads; see
    /// ``requireCurrentOwner(_:)``. One that arrives after a server or
    /// profile switch is refused, so it never opens a player or replaces a
    /// pick for the new owner.
    func createShuffle(scope: ShuffleScopeRequest) async throws -> APIv2Shuffle {
        let auth = try await mutationAuth()
        let shuffle = try await apiV2Client.createShuffle(
            scope: scope, imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        try await requireCurrentOwner(auth)
        return shuffle
    }

    func shuffle(id: String) async throws -> APIv2Shuffle {
        let auth = try await detailReadAuth()
        let shuffle = try await apiV2Client.shuffle(id: id, imageSize: await imageSizeQuery["image_size"], auth: auth)
        try await requireCurrentOwner(auth)
        return shuffle
    }

    func advanceShuffle(id: String, fromContentId: String) async throws -> APIv2Shuffle {
        let auth = try await mutationAuth()
        let shuffle = try await apiV2Client.advanceShuffle(
            id: id, fromContentId: fromContentId,
            imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        try await requireCurrentOwner(auth)
        return shuffle
    }

    func skipShuffleItem(id: String, nextContentId: String) async throws -> APIv2Shuffle {
        let auth = try await mutationAuth()
        let shuffle = try await apiV2Client.skipShuffleItem(
            id: id, nextContentId: nextContentId,
            imageSize: await imageSizeQuery["image_size"], auth: auth
        )
        try await requireCurrentOwner(auth)
        return shuffle
    }

    func deleteShuffle(id: String) async throws {
        try await apiV2Client.deleteShuffle(id: id, auth: try await mutationAuth())
    }

    // --- Collection groups (personal) ---

    /// `non_retryable`, like ``createCollection(name:)``.
    func createCollectionGroup(name: String) async throws -> CollectionGroup {
        try await apiV2Client.createCollectionGroup(name: name, auth: try await mutationAuth())
    }

    func collectionGroupEditor(id: String) async throws -> CollectionEditor<CollectionGroup> {
        let auth = try await detailReadAuth()
        let editor = try await apiV2Client.collectionGroupEditor(id: id, auth: auth)
        try await requireCurrentOwner(auth)
        return editor
    }

    func renameCollectionGroup(_ version: CollectionEditVersion, name: String) async throws -> CollectionGroup {
        try await apiV2Client.renameCollectionGroup(version, name: name)
    }

    func deleteCollectionGroup(_ version: CollectionEditVersion) async throws {
        try await apiV2Client.deleteCollectionGroup(version)
    }

    // --- Profiles ---

    func listProfiles() async throws -> [UserProfile] {
        try await apiV2Client.householdProfiles()
    }

    /// Verifies a protected profile without mutating process-wide identity.
    /// `AuthService` uses this to finish the network round trip first, then
    /// commit profile ID and proof together behind HTTPClient's transition
    /// barrier.
    func verifyProfileSelection(profileId: String, pin: String?) async throws -> String? {
        // No PIN: nothing to verify, and `/verify-pin` rejects an empty PIN
        // with 422.
        if let pin, !pin.isEmpty {
            // A wrong PIN is a 200 with `valid: false`, not an error status.
            let response = try await apiV2Client.verifyHouseholdPIN(id: profileId, pin: pin)
            guard response.valid else {
                throw ProfileTransitionError.incorrectPIN
            }
            return response.profileToken
        }
        return nil
    }

    /// `POST /api/v2/profiles` is `non_retryable`: it is sent once, and a
    /// failure is never replayed here. `CreateProfileFailure` decides what the
    /// form tells the user.
    func createProfile(
        name: String,
        avatarEmoji: String?,
        pin: String?,
        isChild: Bool,
        maxContentRating: String? = nil,
        libraryRestrictionsEnabled: Bool = false,
        allowedLibraryIds: [Int] = []
    ) async throws -> UserProfile {
        try await apiV2Client.createHouseholdProfile(
            CreateProfileRequestBody(
                name: name,
                avatar: avatarEmoji,
                pin: pin,
                isChild: isChild,
                maxContentRating: maxContentRating,
                libraryRestrictionsEnabled: libraryRestrictionsEnabled,
                allowedLibraryIds: allowedLibraryIds
            )
        )
    }

    /// Patch the active profile through `PATCH /api/v2/profiles/{id}`. Only
    /// the set fields are sent; the server leaves the rest untouched. Used by
    /// the onboarding tour's profile-field steps. The write is
    /// `non_retryable` and is sent once.
    func updateProfile(profileId: String, body: UpdateProfileBody) async throws {
        _ = try await apiV2Client.updateProfile(id: profileId, patch: body.asAPIv2Patch)
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
