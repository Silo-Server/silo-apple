import Foundation

extension APIv2Client {
    /// Record the acting profile's rating of an item, replacing any earlier
    /// one. `stars` is 1 to 5; the server rejects anything else.
    func setRating(id: String, stars: Int, auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let body = try JSONEncoder().encode(["rating": stars])
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "PUT", path: "/api/v2/ratings/\(try catalogPathSegment(id))",
                    body: body,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }

    /// Remove the acting profile's rating of an item. An item that was never
    /// rated succeeds too, so this doubles as "undo my last star".
    func clearRating(id: String, auth: CapturedOrdinaryRequestAuth) async throws {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "DELETE", path: "/api/v2/ratings/\(try catalogPathSegment(id))",
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }
}
