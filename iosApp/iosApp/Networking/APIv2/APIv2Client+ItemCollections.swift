import Foundation

extension APIv2Client {
    /// `listCatalogItemCollections`: the collections holding the movie or
    /// series `id` that the profile in `auth` may see, with a few titles of
    /// the one collection when only one does. `libraryId` is the library the
    /// page was opened from. A server without the read answers 404.
    func catalogItemCollections(id: String, libraryId: String?, artwork: [String: String],
                                auth: CapturedOrdinaryRequestAuth) async throws -> CatalogItemCollections {
        var query = artwork
        if let libraryId { query["library_id"] = libraryId }
        let raw = try await profileCatalogRead(
            path: "/api/v2/catalog/items/\(try catalogPathSegment(id))/collections",
            query: query, auth: auth
        )
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url)
            .decode(CatalogItemCollections.self, from: raw.data)
    }
}
