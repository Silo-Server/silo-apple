import Foundation

// MARK: - Media requests

/// User-facing endpoints of the server's media-request system
/// (`/api/v2/requests`, TMDB movies + series). Admin moderation stays on
/// the web — the clients only search, create, track, and cancel.
extension SiloAPI {
    /// Profile-scoped capability probe. Entry points gate on
    /// `RequestsFeatureStatus.isAvailable`.
    func requestsStatus() async throws -> RequestsFeatureStatus {
        try await apiV2Client.requestsStatus()
    }

    /// TMDB search annotated with availability + per-user request state.
    func requestsSearch(
        query: String,
        mediaType: RequestMediaType = .all,
        page: Int = 1
    ) async throws -> RequestMediaPage {
        try await apiV2Client.searchRequestMedia(query: query, mediaType: mediaType, page: page)
    }

    /// Curated TMDB carousels (trending/popular/upcoming/on-air).
    func requestsDiscover() async throws -> [RequestDiscoverySection] {
        try await apiV2Client.requestDiscoverSections()
    }

    func requestsDetail(mediaType: RequestMediaType, tmdbId: Int) async throws -> RequestMediaDetail {
        try await apiV2Client.requestMediaDetail(mediaType: mediaType, tmdbId: tmdbId)
    }

    func createRequest(_ input: CreateRequestInput) async throws -> MediaRequest {
        try await apiV2Client.createRequest(input)
    }

    /// Every request the profile can see, newest first, loaded completely or
    /// not at all.
    func myRequests() async throws -> [MediaRequest] {
        try await apiV2Client.myRequests()
    }

    /// Owner-cancel; the server only allows this while the request hasn't
    /// been submitted to an integration yet.
    func cancelRequest(id: String, reason: String? = nil) async throws -> MediaRequest {
        try await apiV2Client.cancelRequest(id: id, reason: reason)
    }
}
