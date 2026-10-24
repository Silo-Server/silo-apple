import Foundation

/// The acting profile's own Home layout (`profile_sections`, Home scope only).
/// Every call is profile-scoped: it carries the captured owner's profile,
/// refuses to start once the session acts as someone else, and discards a
/// response whose owner changed while it was in flight.
///
/// Section `config` objects keep the recipe's own keys, so these documents go
/// through plain coders with explicit coding keys, not the shared snake_case
/// decoder.
extension APIv2Client {
    private static let homeScope = ["scope": "home"]

    /// `getProfileSectionSettings`: the Home rows in the order the profile
    /// sees them, hidden rows included.
    func profileHomeSectionSettings(auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2ProfileSectionSetting] {
        struct Wire: Decodable { let items: [APIv2ProfileSectionSetting] }
        let raw = try await profileSectionsRequest("GET", path: "/api/v2/profile/sections/settings", body: nil, auth: auth)
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let rows = try JSONDecoder().decode(Wire.self, from: raw.data).items
        guard rows.allSatisfy({ !$0.id.isEmpty }), Set(rows.map(\.id)).count == rows.count else {
            throw APIv2Error.incompleteHomeLayout
        }
        return rows
    }

    /// `listProfileSectionOverrides`: what the profile saved for Home.
    func profileHomeSectionOverrides(auth: CapturedOrdinaryRequestAuth) async throws -> [APIv2SectionOverride] {
        struct Wire: Decodable { let items: [APIv2SectionOverride] }
        let raw = try await profileSectionsRequest("GET", path: "/api/v2/profile/sections", body: nil, auth: auth)
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try JSONDecoder().decode(Wire.self, from: raw.data).items
    }

    /// `replaceProfileSectionOverrides` (204): `overrides` becomes the
    /// profile's whole Home override set.
    func replaceProfileHomeSectionOverrides(_ overrides: [APIv2SectionOverride],
                                            auth: CapturedOrdinaryRequestAuth) async throws {
        struct Body: Encodable { let overrides: [APIv2SectionOverride] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(Body(overrides: overrides))
        let raw = try await profileSectionsRequest("PUT", path: "/api/v2/profile/sections", body: body, auth: auth)
        guard raw.statusCode == 204 else { throw APIv2Error.httpStatus(raw.statusCode) }
    }

    private func profileSectionsRequest(_ method: String, path: String, body: Data?,
                                        auth: CapturedOrdinaryRequestAuth) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: method, path: path, query: Self.homeScope, body: body,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        return raw
    }
}
