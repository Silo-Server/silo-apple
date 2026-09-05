import Foundation

// MARK: - Media requests

/// User-facing endpoints of the server's media-request system
/// (`/api/v2/requests/*`, TMDB movies + series). Admin moderation stays on
/// the web — the clients only search, create, track, and cancel.
extension SiloAPI {
    /// Profile-scoped v2 capability probe.
    func requestsStatus() async throws -> RequestsFeatureStatus {
        try await v2.requestGet("/api/v2/requests/status")
    }

    /// TMDB search annotated with availability + per-user request state.
    func requestsSearch(
        query: String,
        mediaType: RequestMediaType = .all,
        page: Int = 1
    ) async throws -> RequestMediaPage {
        try await v2.requestGet("/api/v2/requests/search", query: [
            "q": query,
            "media_type": mediaType.rawValue,
            "page": String(page),
        ])
    }

    /// Curated TMDB carousels (trending/popular/upcoming/on-air).
    func requestsDiscover() async throws -> [RequestDiscoverySection] {
        let response: RequestDiscoverResponse = try await v2.requestGet("/api/v2/requests/discover")
        return response.items
    }

    func requestsDetail(mediaType: RequestMediaType, tmdbId: Int) async throws -> RequestMediaDetail {
        try await v2.requestGet("/api/v2/requests/detail/\(mediaType.rawValue)/\(tmdbId)")
    }

    func createRequest(_ input: CreateRequestInput) async throws -> MediaRequest {
        try await v2.requestPost("/api/v2/requests", body: input)
    }

    func myRequests() async throws -> [MediaRequest] {
        try await v2.myRequests()
    }

    /// Owner-cancel; the server only allows this while the request hasn't
    /// been submitted to an integration yet.
    func cancelRequest(id: String, reason: String? = nil) async throws -> MediaRequest {
        try await v2.requestPost("/api/v2/requests/\(id)/cancel", body: CancelRequestBody(reason: reason))
    }
}
