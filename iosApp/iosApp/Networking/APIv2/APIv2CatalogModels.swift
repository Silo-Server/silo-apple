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

struct APIv2CatalogSearchCapabilities: Decodable {
    let revision: String
    let state: String
    let allowed: Bool?
    let provider: String
    let resultWindowLimit: Int?
    let sessionTtlSeconds: Int?
    let maxSessionsPerAccount: Int?
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

struct APIv2CatalogContinuation {
    let query: APIv2CatalogQuery
    let operation: APIv2CatalogOperation
    let cursor: String
    let seen: Set<String>
    let identity: HTTPRequestIdentity
    let account: RefreshAccountIdentity
}

struct APIv2CatalogResult {
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

struct APIv2CatalogFilters: Decodable {
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
struct APIv2CatalogTechnicalFilters: Decodable {
    let resolutions: [String]
    let audioLanguages: [String]
    let subtitleLanguages: [String]
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
    let posterUrl: String
    let posterThumbhash: String?
    let itemCount: Int
    let sortOrder: Int
    let createdAt: Date
    let updatedAt: Date
}
struct APIv2LibraryCollectionCard: Decodable {
    let id: String
    let title: String
    let posterUrl: String
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
