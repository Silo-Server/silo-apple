import Foundation

/// `GET /api/v2/capabilities/ratings`: the rating sources the server shows
/// (`imdb`, `tmdb`, and any source a metadata plugin declares and an
/// administrator turned on, such as `rt_critic`).
private struct APIv2RatingsCapability: Decodable {
    struct Source: Decodable {
        let source: String
    }

    let state: String
    let sources: [Source]?
}

extension APIv2Client {
    /// The shown rating sources; empty when the capability is not available.
    func shownRatingSources(auth: CapturedOrdinaryRequestAuth) async throws -> Set<String> {
        let raw = try await collectionRequest("GET", path: "/api/v2/capabilities/ratings", status: 200, auth: auth)
        let capability = try HTTPClient.makeJSONDecoder().decode(APIv2RatingsCapability.self, from: raw.data)
        guard capability.state == "available" else { return [] }
        return Set((capability.sources ?? []).map(\.source))
    }
}
