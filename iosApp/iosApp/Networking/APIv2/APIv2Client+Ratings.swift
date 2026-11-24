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

    /// `PUT /api/v2/ratings/{item_id}`: sets the acting profile's rating of
    /// the item, 1 to 10 (stars times two), replacing any earlier one.
    /// `non_retryable`: sent once, never replayed after a refresh, and
    /// applied only under `auth`. Anything but 204 throws.
    func setRating(id: String, score: Int, auth: CapturedOrdinaryRequestAuth) async throws {
        guard (1...10).contains(score) else { throw APIv2Error.unsupportedCatalogReadValue }
        let body = try JSONEncoder().encode(APIv2RatingSet(rating: score))
        try await mutateRating(method: "PUT", id: id, body: body, auth: auth)
    }

    /// `DELETE /api/v2/ratings/{item_id}`: removes the acting profile's
    /// rating; 204 also when there was none. `non_retryable`, as `setRating`.
    func deleteRating(id: String, auth: CapturedOrdinaryRequestAuth) async throws {
        try await mutateRating(method: "DELETE", id: id, body: nil, auth: auth)
    }

    private func mutateRating(method: String, id: String, body: Data?,
                              auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let path = "/api/v2/ratings/\(try catalogPathSegment(id))"
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, body: body,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }
}

/// The `setRating` body; the contract schema is closed.
private struct APIv2RatingSet: Encodable {
    let rating: Int
}
