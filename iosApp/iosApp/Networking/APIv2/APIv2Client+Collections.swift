import Foundation

/// Personal collections and their groups. Every call runs for the profile in
/// `auth` and is refused once that owner is no longer current.
///
/// Edits follow the v2 editor contract (`docs/collections-api-v2.md`): read
/// the canonical collection or group, keep its strong `ETag`, and send it
/// back as `If-Match`. A 412 `stale_version` means the item changed since the
/// read; a 428 means the tag was missing, which is a client bug. Neither is
/// retried here. Creates and edits are `non_retryable`: each is dispatched
/// once and never replayed.
extension APIv2Client {
    /// The collection features the acting account's store supports.
    func collectionCapabilities(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2CollectionCapabilities {
        let raw = try await collectionRequest("GET", path: "/api/v2/collections/capabilities", status: 200, auth: auth)
        return try HTTPClient.makeJSONDecoder().decode(APIv2CollectionCapabilities.self, from: raw.data)
    }

    /// The acting profile's collections and the account's groups.
    func personalCollections(auth: CapturedOrdinaryRequestAuth) async throws -> APIv2PersonalCollections {
        let raw = try await collectionRequest("GET", path: "/api/v2/collections", status: 200, auth: auth)
        let list = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(APIv2PersonalCollections.self, from: raw.data)
        guard list.page?.hasMore != true else { throw APIv2Error.incompleteCollection }
        return list
    }

    /// `201` with the new collection. A lost answer may still have created it.
    func createCollection(name: String, auth: CapturedOrdinaryRequestAuth) async throws -> UserCollection {
        let body = try Self.collectionEncoder.encode(CreateCollectionRequest(name: name, collectionType: "manual"))
        let raw = try await collectionRequest("POST", path: "/api/v2/collections", body: body, status: 201, auth: auth)
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(UserCollection.self, from: raw.data)
    }

    /// `201` with the new group. A lost answer may still have created it.
    func createCollectionGroup(name: String, auth: CapturedOrdinaryRequestAuth) async throws -> CollectionGroup {
        let body = try Self.collectionEncoder.encode(CreateCollectionGroupRequest(name: name))
        let raw = try await collectionRequest("POST", path: "/api/v2/collections/groups", body: body, status: 201, auth: auth)
        return try HTTPClient.makeJSONDecoder().decode(CollectionGroup.self, from: raw.data)
    }

    func collectionEditor(id: String, auth: CapturedOrdinaryRequestAuth) async throws -> CollectionEditor<UserCollection> {
        try await editorRead(id: id, under: "/api/v2/collections/", auth: auth)
    }

    func collectionGroupEditor(id: String, auth: CapturedOrdinaryRequestAuth) async throws -> CollectionEditor<CollectionGroup> {
        try await editorRead(id: id, under: "/api/v2/collections/groups/", auth: auth)
    }

    /// Moves the collection into `groupId`, or out of any group for `nil`
    /// (sent as an explicit JSON `null`; an omitted member means "unchanged").
    func moveCollection(_ version: CollectionEditVersion, toGroupId groupId: String?) async throws -> UserCollection {
        let body = try Self.collectionEncoder.encode(UpdateUserCollectionGroupBody(groupId: groupId))
        let raw = try await collectionRequest("PATCH", path: version.path, body: body, ifMatch: version.etag,
                                              status: 200, auth: version.auth)
        return try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(UserCollection.self, from: raw.data)
    }

    func renameCollectionGroup(_ version: CollectionEditVersion, name: String) async throws -> CollectionGroup {
        let body = try Self.collectionEncoder.encode(UpdateCollectionGroupRequest(name: name))
        let raw = try await collectionRequest("PATCH", path: version.path, body: body, ifMatch: version.etag,
                                              status: 200, auth: version.auth)
        return try HTTPClient.makeJSONDecoder().decode(CollectionGroup.self, from: raw.data)
    }

    /// `204`. `version` comes from ``collectionEditor(id:auth:)``.
    func deleteCollection(_ version: CollectionEditVersion) async throws {
        _ = try await collectionRequest("DELETE", path: version.path, ifMatch: version.etag, status: 204, auth: version.auth)
    }

    /// `204`; the group's collections become ungrouped on the server.
    /// `version` comes from ``collectionGroupEditor(id:auth:)``.
    func deleteCollectionGroup(_ version: CollectionEditVersion) async throws {
        _ = try await collectionRequest("DELETE", path: version.path, ifMatch: version.etag, status: 204, auth: version.auth)
    }

    /// The display cards of a personal collection, read as catalog pages
    /// (`source=user_collection`). All pages keep the first page's owner and
    /// query; a partial list is never published as a complete collection.
    func personalCollectionCards(id: String, imageSize: String? = nil,
                                 auth: CapturedOrdinaryRequestAuth) async throws -> CatalogResponse {
        var query = APIv2CatalogQuery()
        query.source = "user_collection"
        query.collectionId = id
        query.imageSize = imageSize
        var result = try await catalogPage(query: query, auth: auth)
        var items = result.value.items
        for pageNumber in 1...100 {
            guard let continuation = result.continuation else {
                return CatalogResponse(collectionCards: items)
            }
            guard pageNumber < 100 else { throw APIv2Error.incompleteCollection }
            result = try await nextCatalogPage(continuation)
            items.append(contentsOf: result.value.items)
        }
        throw APIv2Error.incompleteCollection
    }

    /// The canonical read of item `id` under `prefix`, refused unless it
    /// answers for that same item.
    private func editorRead<Value: Decodable & Identifiable>(
        id: String, under prefix: String, auth: CapturedOrdinaryRequestAuth
    ) async throws -> CollectionEditor<Value> where Value.ID == String {
        let path = prefix + (try Self.collectionSegment(id))
        let raw = try await collectionRequest("GET", path: path, status: 200, auth: auth)
        let tag = try Self.entityTag(raw.header("ETag"))
        let value = try HTTPClient.makeJSONDecoder(artworkServerURL: raw.url).decode(Value.self, from: raw.data)
        guard value.id == id else { throw APIv2Error.incompleteCollection }
        return CollectionEditor(value: value, version: CollectionEditVersion(path: path, etag: tag, auth: auth))
    }

    private static func collectionSegment(_ id: String) throws -> String {
        guard let segment = CatalogPathSegment.encode(id) else { throw APIv2Error.invalidCatalogQuery }
        return segment
    }

    private static var collectionEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }
}

extension CatalogResponse {
    /// A complete personal-collection card list assembled from v2 catalog
    /// pages. There is no further page by construction.
    init(collectionCards: [BrowseItem]) {
        self.init(items: collectionCards, total: collectionCards.count, totalExact: true, hasMore: false)
    }
}
