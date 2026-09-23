import Foundation

/// Catalog envelopes are distinct from the legacy offset/snapshot response.
/// Cards retain the shared presentation model used by personal v2 collections.
struct APIv2CatalogPage: Decodable {
    let items: [BrowseItem]
    let page: APIv2Page
    let total: Int
    let totalExact: Bool
    let windowCursor: String
    let effectiveSort: APIv2CatalogEffectiveSort?
    let searchDiagnostics: APIv2CatalogSearchDiagnostics?
}

struct APIv2CatalogEffectiveSort: Decodable, Hashable {
    let field: String
    let order: String
}

struct APIv2CatalogSearchDiagnostics: Decodable {
    let provider: String
    let mode: String
    let semanticUsed: Bool
    let fallbackReason: String?
    let indexPendingUpdates: Int?
    let resultWindowLimit: Int?
    let sessionExpiresAt: Date?
}

/// `GET /api/v2/catalog/search/capabilities`. Only `revision`, `state` and
/// `allowed` are required; the provider and its limits are absent when search
/// is not configured.
struct APIv2CatalogSearchCapabilities: Decodable {
    let revision: String
    let state: String
    let allowed: Bool
    let provider: String?
    let resultWindowLimit: Int?
    let sessionTtlSeconds: Int?
    let maxSessionsPerAccount: Int?
    /// People search accepts `media_scope` and filters credits by access.
    let peopleMediaScope: Bool?
    /// Person reads accept `prefetch=true` without queueing a refresh.
    let personPrefetch: Bool?

    var isAvailable: Bool { allowed && state == "available" }
}

enum APIv2CatalogRuleValue: Encodable, Hashable {
    case string(String)
    case strings([String])
    case number(Double)
    case numbers([Double])
    case bool(Bool)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .strings(let values): try container.encode(values)
        case .number(let value): try container.encode(value)
        case .numbers(let values): try container.encode(values)
        case .bool(let value): try container.encode(value)
        }
    }
}

struct APIv2CatalogRule: Encodable, Hashable {
    let field: String
    let op: String
    let value: APIv2CatalogRuleValue
}
struct APIv2CatalogGroup: Encodable, Hashable {
    let match: String
    let rules: [APIv2CatalogRule]
}

/// Query scope is copied into the continuation so page size, filters, operation,
/// artwork variant, and source cannot change while consuming an opaque cursor.
struct APIv2CatalogQuery: Encodable, Hashable {
    var source = "query"
    var scope: String?
    var sectionId: String?
    var collectionId: String?
    var personId: String?
    var libraryId: String?
    var q: String?
    var type: String?
    var namePrefix: String?
    var groups: [APIv2CatalogGroup] = []
    var match = "all"
    /// An unsigned field; GET adds the descending prefix, POST sends order.
    var sort: String?
    var order = "asc"
    var group: String?
    var limit = 50
    var queryLimit: Int?
    var skipTotal = false
    var imageSize: String?

    enum CodingKeys: String, CodingKey {
        case source, scope, sectionId, collectionId, personId, libraryId, q, type
        case namePrefix, groups, match, sort, order, group, limit, queryLimit, skipTotal
    }

    func getParameters() throws -> [String: String] {
        guard (1...100).contains(limit), queryLimit.map({ $0 >= 0 }) ?? true,
              sort.map({ !$0.hasPrefix("-") && !$0.contains(",") }) ?? true,
              order == "asc" || order == "desc" else { throw APIv2Error.invalidCatalogQuery }
        var query = ["source": source, "limit": String(limit), "match": match]
        for (key, value) in [
            ("scope", scope), ("section_id", sectionId), ("collection_id", collectionId),
            ("person_id", personId), ("library_id", libraryId), ("q", q), ("type", type),
            ("name_prefix", namePrefix), ("group", group), ("image_size", imageSize),
        ] {
            if let value { query[key] = value }
        }
        if let sort { query["sort"] = (order == "desc" ? "-" : "") + sort }
        if let queryLimit { query["query_limit"] = String(queryLimit) }
        if skipTotal { query["skip_total"] = "true" }
        if !groups.isEmpty {
            let encoder = JSONEncoder()
            encoder.outputFormatting = .sortedKeys
            query["groups"] = String(decoding: try encoder.encode(groups), as: UTF8.self)
        }
        return query
    }
}

enum APIv2CatalogOperation: String {
    case get
    case query
}

extension APIv2CatalogQuery {
    /// `GET /api/v2/catalog` caps the `groups` parameter at this many
    /// characters; a larger filter set goes in a `POST /catalog/query` body.
    static let maxGetGroupsLength = 32768

    /// GET while the encoded groups fit the query-string limit, POST above it.
    /// An invalid query stays on GET so the request itself reports the error.
    var preferredOperation: APIv2CatalogOperation {
        let groupsLength = (try? getParameters())?["groups"]?.utf8.count ?? 0
        return groupsLength > Self.maxGetGroupsLength ? .query : .get
    }

    /// The watch history, most recent first.
    static func history(limit: Int) -> APIv2CatalogQuery {
        var query = APIv2CatalogQuery()
        query.source = "history"
        query.limit = limit
        return query
    }

    /// A person's credits, newest first, optionally narrowed to one media type.
    static func personCredits(personId: Int, type: String?, limit: Int) -> APIv2CatalogQuery {
        var query = APIv2CatalogQuery()
        query.source = "person"
        query.personId = String(personId)
        query.type = type
        query.sort = "year"
        query.order = "desc"
        query.limit = limit
        return query
    }

    /// The items of a curated library collection or a user collection.
    static func collectionItems(kind: LibraryCollectionKind, collectionId: String, limit: Int) -> APIv2CatalogQuery {
        var query = APIv2CatalogQuery()
        query.source = kind.catalogSource
        query.collectionId = collectionId
        query.limit = limit
        return query
    }

    /// Free-text search across the catalog, optionally narrowed to one media type.
    static func search(_ text: String, type: String?, limit: Int) -> APIv2CatalogQuery {
        var query = APIv2CatalogQuery()
        query.q = text
        query.type = type
        query.limit = limit
        return query
    }
}

/// One page of a catalog list for a screen: the cards and totals it shows,
/// plus the continuation for the next page (`nil` on the last one). The
/// continuation keeps the original query and owner, so a screen pages by
/// handing it back rather than rebuilding the request.
struct CatalogListPage {
    let response: CatalogResponse
    let continuation: APIv2CatalogContinuation?

    init(_ result: APIv2CatalogResult) {
        response = CatalogResponse(catalogPage: result.value)
        continuation = result.continuation
    }
}

struct APIv2CatalogContinuation {
    let query: APIv2CatalogQuery
    let operation: APIv2CatalogOperation
    let cursor: String
    let seen: Set<String>
    let identity: HTTPRequestIdentity
    let auth: CapturedOrdinaryRequestAuth
}

struct APIv2CatalogResult {
    let auth: CapturedOrdinaryRequestAuth
    let value: APIv2CatalogPage
    let continuation: APIv2CatalogContinuation?
}

struct APIv2CatalogQueryBody: Encodable {
    let query: APIv2CatalogQuery
    let cursor: String?
    enum CodingKeys: String, CodingKey { case cursor }
    func encode(to encoder: Encoder) throws {
        try query.encode(to: encoder)
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(cursor, forKey: .cursor)
    }
}

struct APIv2CatalogFilters: Codable {
    let genres: [String]
    let studios: [String]
    let networks: [String]
    let countries: [String]
    let contentRatings: [String]
    let originalLanguages: [String]
    let authors: [String]
    let narrators: [String]
    let series: [String]
    let technical: APIv2CatalogTechnicalFilters?
}
struct APIv2CatalogTechnicalFilters: Codable {
    let resolutions: [String]
    let audioLanguages: [String]
    let subtitleLanguages: [String]
}

/// Outcome of `POST /api/v2/catalog/items/{id}/trailers/refresh`.
///
/// `status` is `queued` (HTTP 202 — a refresh started), `cooldown` (200 — the
/// item was checked recently, `nextAllowedAt` says when it can be retried),
/// or `disabled` (200 — every library containing the item has remote videos
/// turned off). Only `queued` is worth polling for; the other two are
/// rendered states rather than errors.
struct TrailerRefreshResponse: Codable, Hashable {
    let status: String
    /// RFC-3339 on the wire; parsed by the shared decoder's custom ISO-8601
    /// strategy (fractional seconds tolerated).
    let nextAllowedAt: Date?
}

/// Strict library-tab shape. IDs stay strings; unknown group kinds are retained
/// for the consumer to handle explicitly rather than treating them as personal.
struct APIv2LibraryCollectionTab: Decodable {
    let libraryId: String
    let collections: [APIv2CuratedCollection]
    let groups: [APIv2LibraryCollectionGroup]
    let ungrouped: APIv2LibraryCollectionUngrouped?
}
struct APIv2CuratedCollection: Decodable {
    let id: String
    let libraryId: String
    let libraryIds: [String]
    let title: String
    let collectionType: String
    @RequiredArtworkURL var posterUrl: String
    let posterThumbhash: String?
    let itemCount: Int
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date
}
struct APIv2LibraryCollectionCard: Decodable {
    let id: String
    let title: String
    @RequiredArtworkURL var posterUrl: String
    let posterThumbhash: String?
    let itemCount: Int
    let creatorProfileId: String?
}
struct APIv2LibraryCollectionGroup: Decodable {
    let id: String
    let name: String
    let kind: String
    let sortMode: String
    let sortOrder: Int
    let collections: [APIv2LibraryCollectionCard]
}
struct APIv2LibraryCollectionUngrouped: Decodable {
    let sortOrder: Int
    let collections: [APIv2LibraryCollectionCard]
}
