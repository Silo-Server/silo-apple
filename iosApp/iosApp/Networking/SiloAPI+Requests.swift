import Foundation

// MARK: - Media requests

/// User-facing endpoints of the server's media-request system
/// (`/api/v2/requests`, TMDB movies + series): search, create, track, and
/// cancel. Request administration (approve, decline, retry, limits) is
/// web-admin only and has no client here.
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
        try await reprobingWhenRequestsAreOff {
            try await apiV2Client.searchRequestMedia(query: query, mediaType: mediaType, page: page)
        }
    }

    /// Curated TMDB carousels (trending/popular/upcoming/on-air).
    func requestsDiscover() async throws -> [RequestDiscoverySection] {
        try await reprobingWhenRequestsAreOff {
            try await apiV2Client.requestDiscoverSections()
        }
    }

    func requestsDetail(mediaType: RequestMediaType, tmdbId: Int) async throws -> RequestMediaDetail {
        try await reprobingWhenRequestsAreOff {
            try await apiV2Client.requestMediaDetail(mediaType: mediaType, tmdbId: tmdbId)
        }
    }

    func createRequest(_ input: CreateRequestInput) async throws -> MediaRequest {
        try await reprobingWhenRequestsAreOff {
            try await apiV2Client.createRequest(input)
        }
    }

    /// Every request the profile can see, newest first, loaded completely or
    /// not at all.
    func myRequests() async throws -> [MediaRequest] {
        try await reprobingWhenRequestsAreOff {
            try await apiV2Client.myRequests()
        }
    }

    /// Owner-cancel; the server only allows this while the request hasn't
    /// been submitted to an integration yet.
    func cancelRequest(id: String, reason: String? = nil) async throws -> MediaRequest {
        try await reprobingWhenRequestsAreOff {
            try await apiV2Client.cancelRequest(id: id, reason: reason)
        }
    }

    /// A requests call refused because the capability is off means the
    /// cached flag is stale: re-probe so entry points hide and an open
    /// Requests screen closes (see `RequestsFeatureStore.isKnownUnavailable`).
    private func reprobingWhenRequestsAreOff<T>(_ call: () async throws -> T) async throws -> T {
        do {
            return try await call()
        } catch {
            if RequestsFeatureStore.isCapabilityOff(error) {
                Task { @MainActor in await RequestsFeatureStore.shared.refresh() }
            }
            throw error
        }
    }

    /// Notify the viewer when a title someone else requested lands.
    func followRequestMedia(mediaType: RequestMediaType, tmdbId: Int) async throws -> RequestState {
        try await reprobingWhenRequestsAreOff {
            try await apiV2Client.followRequestMedia(mediaType: mediaType, tmdbId: tmdbId)
        }
    }

    func unfollowRequestMedia(mediaType: RequestMediaType, tmdbId: Int) async throws {
        try await reprobingWhenRequestsAreOff {
            try await apiV2Client.unfollowRequestMedia(mediaType: mediaType, tmdbId: tmdbId)
        }
    }
}
