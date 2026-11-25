import Foundation

/// The acting profile's own Home and Library layouts (`/api/v2/profile/sections*`)
/// and the section recipe gallery (`/api/v2/sections/recipes`).
///
/// Section `config` objects keep the recipe's own keys, so these documents go
/// through plain coders with explicit coding keys, not the shared snake_case
/// decoder.
extension APIv2Client {
    /// `getProfileSectionSettings`: the page's rows in the order the profile
    /// sees them, hidden rows included.
    func profileSectionSettings(
        scope: ProfileSectionsScope = .home,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> [APIv2ProfileSectionSetting] {
        struct Wire: Decodable { let items: [APIv2ProfileSectionSetting] }
        let raw = try await profileSectionsRequest(
            "GET",
            path: "/api/v2/profile/sections/settings",
            query: scope.queryItems,
            body: nil,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        let rows = try JSONDecoder().decode(Wire.self, from: raw.data).items
        guard rows.allSatisfy({ !$0.id.isEmpty }), Set(rows.map(\.id)).count == rows.count else {
            throw APIv2Error.incompleteHomeLayout
        }
        return rows
    }

    /// `listProfileSectionOverrides`: what the profile saved for `scope`.
    func profileSectionOverrides(
        scope: ProfileSectionsScope = .home,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> [APIv2SectionOverride] {
        struct Wire: Decodable { let items: [APIv2SectionOverride] }
        let raw = try await profileSectionsRequest(
            "GET",
            path: "/api/v2/profile/sections",
            query: scope.queryItems,
            body: nil,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try JSONDecoder().decode(Wire.self, from: raw.data).items
    }

    /// `replaceProfileSectionOverrides` (204): `overrides` becomes the
    /// profile's whole override set for `scope`.
    func replaceProfileSectionOverrides(
        _ overrides: [APIv2SectionOverride],
        scope: ProfileSectionsScope = .home,
        auth: CapturedOrdinaryRequestAuth
    ) async throws {
        struct Body: Encodable { let overrides: [APIv2SectionOverride] }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try encoder.encode(Body(overrides: overrides))
        let raw = try await profileSectionsRequest(
            "PUT",
            path: "/api/v2/profile/sections",
            query: scope.queryItems,
            body: body,
            auth: auth
        )
        guard raw.statusCode == 204 || raw.statusCode == 200 else {
            throw APIv2Error.httpStatus(raw.statusCode)
        }
    }

    /// `resetProfileSectionOverrides` (204): deletes all saved overrides for
    /// `scope`, restoring the server's default layout.
    func resetProfileSectionOverrides(
        scope: ProfileSectionsScope = .home,
        auth: CapturedOrdinaryRequestAuth
    ) async throws {
        let raw = try await profileSectionsRequest(
            "DELETE",
            path: "/api/v2/profile/sections",
            query: scope.queryItems,
            body: nil,
            auth: auth
        )
        guard raw.statusCode == 204 || raw.statusCode == 200 else {
            throw APIv2Error.httpStatus(raw.statusCode)
        }
    }

    /// `listSectionRecipes`: available section recipes grouped by category.
    func sectionRecipeCatalog(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2RecipeCatalog {
        let raw = try await profileSectionsRequest(
            "GET",
            path: "/api/v2/sections/recipes",
            query: [:],
            body: nil,
            auth: auth
        )
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return try JSONDecoder().decode(APIv2RecipeCatalog.self, from: raw.data)
    }

    private func profileSectionsRequest(
        _ method: String,
        path: String,
        query: [String: String],
        body: Data?,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> HTTPRawResponse {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        let raw = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(
                    method: method,
                    path: path,
                    query: query,
                    body: body,
                    requestIdentity: identity,
                    expectedAccount: auth.account,
                    expectedAuth: auth
                )
            }
        }
        try Task.checkCancellation()
        return raw
    }
}
