import Foundation

extension APIv2Client {
    /// Every item on the acting profile's favorites or watchlist, newest
    /// first. All pages keep the first page's owner; a list longer than the
    /// page budget throws rather than showing a truncated list as complete.
    func personalListItems(kind: APIv2PersonalListKind, imageSize: String?,
                           auth: CapturedOrdinaryRequestAuth) async throws -> CatalogResponse {
        var items: [BrowseItem] = []
        var cursor: String?
        var seen = Set<String>()
        for _ in 1...100 {
            let page = try await personalListPage(kind: kind, imageSize: imageSize, cursor: cursor, auth: auth)
            items.append(contentsOf: page.items)
            guard page.page.hasMore else {
                guard page.page.nextCursor?.isEmpty != false else { throw APIv2Error.invalidPersonalListContinuation }
                return CatalogResponse(completeItems: items)
            }
            // Empty or duplicate-only pages still advance through the raw list.
            guard let next = page.page.nextCursor, !next.isEmpty, seen.insert(next).inserted else {
                throw APIv2Error.invalidPersonalListContinuation
            }
            cursor = next
        }
        throw APIv2Error.incompletePersonalList
    }

    private func personalListPage(kind: APIv2PersonalListKind, imageSize: String?, cursor: String?,
                                  auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PersonalListPage {
        try await gate()
        guard let profile = auth.profileId, !profile.isEmpty,
              await tokenStore.currentOrdinaryRequestAuth(matchingIdentityOf: auth) != nil else {
            throw HTTPError.requestIdentityChanged
        }
        try Task.checkCancellation()
        let identity = Self.requestIdentity(auth, profile: profile)
        var query = ["limit": "200"]
        if let imageSize { query["image_size"] = imageSize }
        if let cursor { query["cursor"] = cursor }
        let path = "/api/v2/\(kind.rawValue)"
        let requestQuery = query
        let response = try await tokenStore.withOwnerFence(auth) {
            try await mapErrors {
                try await http.requestData(method: "GET", path: path, query: requestQuery, requestIdentity: identity,
                    expectedAccount: auth.account, expectedAuth: auth)
            }
        }
        try Task.checkCancellation()
        guard response.statusCode == 200 else { throw APIv2Error.httpStatus(response.statusCode) }
        return try HTTPClient.makeJSONDecoder(artworkServerURL: response.url).decode(APIv2PersonalListPage.self, from: response.data)
    }
}
