import Foundation

// MARK: - Media requests

/// User-facing endpoints of the server's media-request system
/// (`/api/v1/requests/*`, TMDB movies + series). Admin moderation stays on
/// the web — the clients only search, create, track, and cancel.
extension ContinuumAPI {
    /// Feature probe — a 404 on older servers means "disabled".
    func requestsStatus() async throws -> RequestsFeatureStatus {
        try await http.get("/api/v1/requests/status")
    }

    /// TMDB search annotated with availability + per-user request state.
    func requestsSearch(
        query: String,
        mediaType: RequestMediaType = .all,
        page: Int = 1
    ) async throws -> RequestMediaPage {
        try await http.get("/api/v1/requests/search", query: [
            "q": query,
            "media_type": mediaType.rawValue,
            "page": String(page),
        ])
    }

    /// Curated TMDB carousels (trending/popular/upcoming/on-air).
    func requestsDiscover() async throws -> [RequestDiscoverySection] {
        let response: RequestDiscoverResponse = try await http.get("/api/v1/requests/discover")
        return response.sections
    }

    func requestsDetail(mediaType: RequestMediaType, tmdbId: Int) async throws -> RequestMediaDetail {
        try await http.get("/api/v1/requests/detail/\(mediaType.rawValue)/\(tmdbId)")
    }

    func createRequest(_ input: CreateRequestInput) async throws -> MediaRequest {
        try await http.post("/api/v1/requests/", body: input)
    }

    func myRequests(limit: Int = 200, offset: Int = 0) async throws -> [MediaRequest] {
        let response: MediaRequestsResponse = try await http.get("/api/v1/requests/mine", query: [
            "limit": String(limit),
            "offset": String(offset),
        ])
        return response.requests
    }

    /// Owner-cancel; the server only allows this while the request hasn't
    /// been submitted to an integration yet.
    func cancelRequest(id: String, reason: String? = nil) async throws -> MediaRequest {
        try await http.post("/api/v1/requests/\(id)/cancel", body: CancelRequestBody(reason: reason))
    }
}
