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

    /// The `/api/v2` pilot operations, on the same transport. v2 has no v1
    /// fallback: a pilot call that fails stays failed.
    let v2: APIv2Client

    init(http: HTTPClient = .shared, tokenStore: TokenStore = .shared, v2: APIv2Client? = nil) {
        self.http = http
        self.tokenStore = tokenStore
        self.v2 = v2 ?? APIv2Client(http: http, tokenStore: tokenStore)
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

    /// `GET /api/v2/images/capabilities`. Unavailable
    /// on servers that predate image-size selection; the caller treats
    /// that as "feature off".
    func imageSizeCapability() async throws -> ImageSizeCapabilityResponse {
        try await v2.requestGet("/api/v2/images/capabilities")
    }

    // MARK: - Typed endpoint methods

    // --- Auth ---

    // --- Onboarding tour (profile-scoped) ---

    private var onboardingWriter: APIv2OnboardingSession?
    private var onboardingBusy = false

    func onboardingFlow(surface: String) async throws -> OnboardingFlow {
        guard !onboardingBusy else { throw HTTPError.requestIdentityChanged }
        onboardingBusy = true
        onboardingWriter = nil
        defer { onboardingBusy = false }
        let session = try await v2.onboardingRead(surface: surface)
        guard var flow = session.flow else { throw APIv2Error.incompleteCollection }
        onboardingWriter = session
        flow.writerID = session.id
        flow.acknowledgedState = session.state
        return flow
    }

    func onboardingState() async throws -> OnboardingState {
        try await v2.onboardingRead().state
    }

    func postOnboardingProgress(_ request: OnboardingProgressRequest) async throws {
        guard !onboardingBusy, let session = onboardingWriter, request.writerID == session.id else {
            throw APIv2Error.incompleteCollection
        }
        onboardingBusy = true
        onboardingWriter = nil
        defer { onboardingBusy = false }
        // Consume before dispatch. Failure/412/uncertainty requires a fresh read,
        // and can never replay the old operation under a newer validator.
        onboardingWriter = try await v2.onboardingWrite(request, session: session)
    }

    func currentUser() async throws -> UserInfo {
        let account = try await v2.currentUser()
        return UserInfo(
            id: account.id,
            username: account.username,
            isAdmin: account.role == .admin
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

    func setDeviceSetting(key: String, value: String) async throws {
        try await http.putVoid("/api/v1/settings/device/\(key)", body: SetSettingBody(value: value))
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

    /// Next Up episodes carry no progress row, so the server keys their
    /// dismissal on the parent series instead of `progress_updated_at`.
    func dismissNextUpItem(contentId: String, seriesId: String) async throws {
        try await http.putVoid(
            "/api/v1/home/dismissals/next_up/\(contentId)",
            body: NextUpDismissalBody(seriesId: seriesId)
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

    func catalogPage(query: APIv2CatalogQuery, operation: APIv2CatalogOperation = .get) async throws -> APIv2CatalogResult {
        var query = query
        if query.imageSize == nil { query.imageSize = await imageSizeQuery["image_size"] }
        return try await v2.catalogPage(query: query, operation: operation)
    }

    func itemDetail(contentId: String) async throws -> ItemDetail {
        let value = try await v2.catalogItem(id: contentId, imageSize: await imageSizeQuery["image_size"])
        return try ItemDetail(catalog: value)
    }

    func seasons(seriesId: String) async throws -> SeasonsResponse {
        let items = try await v2.catalogSeasons(seriesId: seriesId, imageSize: await imageSizeQuery["image_size"])
        return try SeasonsResponse(catalog: items)
    }

    func episodes(seriesId: String, seasonNumber: Int) async throws -> EpisodesResponse {
        let items = try await v2.catalogEpisodes(seriesId: seriesId, seasonNumber: seasonNumber,
                                                 imageSize: await imageSizeQuery["image_size"])
        return try EpisodesResponse(catalog: items)
    }

    func watchDetail(contentId: String) async throws -> WatchDetail {
        try await http.get("/api/v1/watch/\(contentId)", query: await imageSizeQuery)
    }

    func person(id: Int) async throws -> Person {
        try await Person(catalog: v2.catalogPerson(id: String(id)))
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

    // --- Libraries ---

    func libraries() async throws -> LibrariesResponse {
        let libs = try await v2.userLibraries().map { try Library(v2: $0) }
        return LibrariesResponse(libraries: libs)
    }

    func libraryCollections(libraryId: Int) async throws -> LibraryCollectionsResponse {
        let wire = try await v2.libraryCollectionTab(libraryId: String(libraryId))
        let flat = wire.collections.map {
            LibraryCollection(id: $0.id, name: $0.title, collectionType: $0.collectionType,
                              itemCount: $0.itemCount, posterUrl: $0.posterUrl, posterThumbhash: $0.posterThumbhash, kind: .regular)
        }
        func cards(_ values: [APIv2LibraryCollectionCard], kind: LibraryCollectionKind) -> [LibraryCollection] {
            values.map { LibraryCollection(id: $0.id, name: $0.title, itemCount: $0.itemCount,
                posterUrl: $0.posterUrl, posterThumbhash: $0.posterThumbhash, kind: kind, creatorProfileId: $0.creatorProfileId) }
        }
        var sections = wire.groups.compactMap { group -> LibraryCollectionSection? in
            let kind: LibraryCollectionKind
            switch group.kind {
            case "admin": kind = .regular
            case "user_collections": kind = .userCollections
            default: return nil
            }
            return LibraryCollectionSection(id: group.id, name: group.name, kind: kind, collections: cards(group.collections, kind: kind))
        }
        if let ungrouped = wire.ungrouped, !ungrouped.collections.isEmpty {
            let section = LibraryCollectionSection(id: "__ungrouped__", name: "", kind: .regular,
                                                   collections: cards(ungrouped.collections, kind: .regular))
            let position = wire.groups.filter { $0.sortOrder <= ungrouped.sortOrder }.count
            sections.insert(section, at: min(position, sections.count))
        }
        return LibraryCollectionsResponse(collections: flat, sections: sections)
    }

    /// Fully hydrated personal collection cards, using bounded v2 cursor pages.
    func userCollectionItems(collectionId: String) async throws -> CatalogResponse {
        try await v2.personalCollectionCards(id: collectionId)
    }

    // --- Playback preferences ---

    func setSubtitlePref(seriesId: String, body: SubtitlePrefRequest) async throws {
        try await http.putVoid("/api/v1/subtitle-prefs/\(seriesId)", body: body)
    }

    func deleteSubtitlePref(seriesId: String) async throws {
        try await http.delete("/api/v1/subtitle-prefs/\(seriesId)")
    }

    func setAudioPref(seriesId: String, body: AudioPrefRequest) async throws {
        try await http.putVoid("/api/v1/audio-prefs/\(seriesId)", body: body)
    }

    func deleteAudioPref(seriesId: String) async throws {
        try await http.delete("/api/v1/audio-prefs/\(seriesId)")
    }

    // --- Personal data ---

    // Standalone personal-list transports remain outside catalog browsing.

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
        let response: PersonalCollectionsV2 = try await v2.requestGet("/api/v2/collections")
        return CollectionsResponse(collections: response.items, groups: response.groups)
    }

    func collectionItems(collectionId: String) async throws -> CatalogResponse {
        try await userCollectionItems(collectionId: collectionId)
    }

    func createCollection(name: String, collectionType: String) async throws -> UserCollection {
        try await v2.requestPost(
            "/api/v2/collections",
            body: CreateCollectionRequest(name: name, collectionType: collectionType)
        )
    }

    func collectionCapabilities() async throws -> CollectionCapabilitiesV2 {
        try await v2.requestGet("/api/v2/collections/capabilities")
    }

    func collectionEditor(id: String) async throws -> CollectionEditor<UserCollection> {
        try await v2.collectionEditor("/api/v2/collections/\(id)")
    }

    func collectionGroupEditor(id: String) async throws -> CollectionEditor<CollectionGroup> {
        try await v2.collectionEditor("/api/v2/collections/groups/\(id)")
    }

    func deleteCollection(version: CollectionEditVersion) async throws {
        try await v2.deleteCollection(version: version)
    }

    func moveCollectionToGroup(version: CollectionEditVersion, groupId: String?) async throws -> UserCollection {
        try await v2.mutateCollection(method: "PATCH", version: version,
            body: UpdateUserCollectionGroupBody(groupId: groupId))
    }

    // --- Collection groups (personal) ---

    func createCollectionGroup(name: String) async throws -> CollectionGroup {
        try await v2.requestPost(
            "/api/v2/collections/groups",
            body: CreateCollectionGroupRequest(name: name, slug: nil)
        )
    }

    func renameCollectionGroup(version: CollectionEditVersion, name: String) async throws -> CollectionGroup {
        try await v2.mutateCollection(method: "PATCH", version: version,
            body: UpdateCollectionGroupRequest(name: name))
    }

    func deleteCollectionGroup(version: CollectionEditVersion) async throws {
        try await v2.deleteCollection(version: version)
    }

    // --- Profiles ---

    func listProfiles() async throws -> [UserProfile] {
        try await v2.householdProfiles()
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
            let response = try await v2.verifyHouseholdPIN(id: profileId, pin: pin)
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
        return try await v2.createHouseholdProfile(
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

    /// Patch a profile. Send only the fields you want to change — the
    /// server treats absent fields as untouched. Used by Settings to
    /// persist subtitle prefs.
    func updateProfile(profileId: String, body: UpdateProfileBody) async throws {
        _ = try await v2.updateProfile(id: profileId, patch: body.asAPIv2Patch)
    }

    // --- Playback ---

    func playbackV3Capability() async throws -> PlaybackV3CapabilityResponse {
        try await http.get("/api/v1/playback/capability")
    }

    // Stream probing and transcode startup can exceed the standard request timeout.
    func startPlaybackV3(request: PlaybackV3StartRequest, auth: CapturedOrdinaryRequestAuth? = nil) async throws -> PlaybackV3DecisionResponse {
        guard let auth else { return try await http.post("/api/v1/playback/start", body: request, timeout: .extended) }
        guard let profile = auth.profileId, request.profileId == profile else { throw HTTPError.requestIdentityChanged }
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let identity = HTTPRequestIdentity(serverId: auth.account.serverId, serverURL: auth.account.serverURL,
            profileId: profile, clientFamily: AppleDeviceIdentity.current.clientFamily)
        let response = try await http.requestData(method: "POST", path: "/api/v1/playback/start",
            body: encoder.encode(request), timeout: .extended, requestIdentity: identity, expectedAccount: auth.account)
        return try HTTPClient.makeJSONDecoder().decode(PlaybackV3DecisionResponse.self, from: response.data)
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

private struct HomeDismissalBody: Encodable {
    let progressUpdatedAt: String
}

private struct NextUpDismissalBody: Encodable {
    let seriesId: String
}
