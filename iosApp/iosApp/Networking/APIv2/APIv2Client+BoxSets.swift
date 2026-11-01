import Foundation

/// Movie box set reads (`docs/catalog-api.md`, "Movie box sets"). Both run for
/// the profile in `auth` and are refused once that owner is no longer current.
/// A server without box sets answers 404; callers only ask a server whose
/// libraries report `box_sets_enabled`.
extension APIv2Client {
    /// `getCatalogBoxSet`: the box set's movies in `libraryId` that the viewer
    /// can see, in release order. 404 when the library has box sets off or the
    /// viewer can see too few of its movies.
    func catalogBoxSet(id: String, libraryId: String, artwork: [String: String],
                       auth: CapturedOrdinaryRequestAuth) async throws -> CatalogBoxSetDetail {
        var query = artwork
        query["library_id"] = libraryId
        let raw = try await boxSetRead(path: "/api/v2/catalog/box-sets/\(try catalogPathSegment(id))",
                                       query: query, auth: auth)
        let detail = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
            .decode(CatalogBoxSetDetail.self, from: raw.data)
        guard detail.boxSet.id == id else { throw APIv2Error.incompleteCatalogRead }
        return detail
    }

    /// `getCatalogItemBoxSet`: the box set the movie `id` belongs to, with its
    /// movies the viewer can see in release order, or nil when it is in none
    /// the viewer sees. `libraryId` is the library the movie was opened from.
    func catalogItemBoxSet(id: String, libraryId: String?, artwork: [String: String],
                           auth: CapturedOrdinaryRequestAuth) async throws -> CatalogBoxSetDetail? {
        var query = artwork
        if let libraryId { query["library_id"] = libraryId }
        let raw = try await boxSetRead(path: "/api/v2/catalog/items/\(try catalogPathSegment(id))/box-set",
                                       query: query, auth: auth)
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
            .decode(CatalogItemBoxSet.self, from: raw.data).boxSet
    }

    /// `searchCatalogBoxSets`: box sets whose name, or two or more of whose
    /// movies' titles, match `query`, best match first.
    func searchCatalogBoxSets(query: String, limit: Int,
                              auth: CapturedOrdinaryRequestAuth) async throws -> [CatalogBoxSet] {
        let raw = try await boxSetRead(path: "/api/v2/catalog/box-sets",
                                       query: ["q": query, "limit": String(limit)], auth: auth)
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
            .decode(CatalogBoxSetList.self, from: raw.data).items
    }

    private func boxSetRead(path: String, query: [String: String],
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
                try await http.requestData(method: "GET", path: path, query: query,
                    requestIdentity: identity, expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard raw.statusCode == 200 else { throw APIv2Error.httpStatus(raw.statusCode) }
        return raw
    }
}
