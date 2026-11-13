import Foundation

/// Catalog envelopes are distinct from the legacy offset/snapshot response.
/// Cards retain the shared presentation model used by personal v2 collections.
struct APIv2CatalogPage: Decodable {
    let items: [BrowseItem]
    let page: APIv2Page
    let total: Int
    let totalExact: Bool
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
    /// People search accepts `media_scope` and filters credits by access.
    let peopleMediaScope: Bool?
    /// Person reads accept `prefetch=true` without queueing a refresh.
    let personPrefetch: Bool?
    /// Text search accepts `type=video_with_episodes` (movies, series, and
    /// episodes) on the query source, and people search accepts it as
    /// `media_scope`. Older servers omit it and ignore or reject the value.
    let videoWithEpisodesScope: Bool?
    /// Searching and opening box sets is supported (`searchCatalogBoxSets`,
    /// `getCatalogBoxSet`). Older servers omit it.
    let boxSets: Bool?

    var isAvailable: Bool { allowed && state == "available" }
}

/// What the Search screen may ask of this server, read once from
/// ``APIv2CatalogSearchCapabilities``. An absent flag means unsupported.
struct CatalogSearchFeatures: Equatable {
    /// People search accepts `media_scope` and filters credits by access.
    /// Without it search offers no people at all.
    var peopleMediaScope = false
    /// Search accepts the `video_with_episodes` media scope.
    var videoWithEpisodesScope = false
    /// The server searches box sets. It lists only those of libraries with
    /// box sets in search, so this alone decides whether to ask.
    var boxSets = false

    init(peopleMediaScope: Bool = false, videoWithEpisodesScope: Bool = false, boxSets: Bool = false) {
        self.peopleMediaScope = peopleMediaScope
        self.videoWithEpisodesScope = videoWithEpisodesScope
        self.boxSets = boxSets
    }

    init(_ capabilities: APIv2CatalogSearchCapabilities) {
        self.init(
            peopleMediaScope: capabilities.peopleMediaScope == true,
            videoWithEpisodesScope: capabilities.videoWithEpisodesScope == true,
            boxSets: capabilities.boxSets == true
        )
    }
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
    var skipTotal = false
    /// Reads the page starting at this zero-based list position instead of
    /// the first. A page read this way is used on its own: its continuation
    /// would send the position again and repeat the page.
    var seek: Int?
    /// `image_size` and the per-slot widths, sent as query parameters on both
    /// operations and never in a POST body.
    var artwork: [String: String] = [:]

    enum CodingKeys: String, CodingKey {
        case source, scope, sectionId, collectionId, personId, libraryId, q, type
        case namePrefix, groups, match, sort, order, group, limit, skipTotal, seek
    }

    func getParameters() throws -> [String: String] {
        guard (1...100).contains(limit),
              sort.map({ !$0.hasPrefix("-") && !$0.contains(",") }) ?? true,
              order == "asc" || order == "desc" else { throw APIv2Error.invalidCatalogQuery }
        var query = ["source": source, "limit": String(limit)]
        // Sections own their filters. Even the default match overlay is rejected.
        if source != "section" { query["match"] = match }
        for (key, value) in [
            ("scope", scope), ("section_id", sectionId), ("collection_id", collectionId),
            ("person_id", personId), ("library_id", libraryId), ("q", q), ("type", type),
            ("name_prefix", namePrefix), ("group", group),
        ] {
            if let value { query[key] = value }
        }
        query.merge(artwork) { current, _ in current }
        if let sort { query["sort"] = (order == "desc" ? "-" : "") + sort }
        if skipTotal { query["skip_total"] = "true" }
        if let seek, seek > 0 { query["seek"] = String(seek) }
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
    static func personCredits(personId: String, type: String?, limit: Int) -> APIv2CatalogQuery {
        var query = APIv2CatalogQuery()
        query.source = "person"
        query.personId = personId
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

    /// The cards of one Home or library row, in the row's order.
    static func sectionItems(_ target: SectionCatalogTarget, limit: Int) -> APIv2CatalogQuery {
        var query = APIv2CatalogQuery()
        query.source = "section"
        query.sectionId = target.sectionId
        switch target.scope {
        case .home:
            query.scope = "home"
        case .library(let libraryId):
            query.scope = "library"
            query.libraryId = String(libraryId)
        }
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

/// `POST /api/v2/catalog/letters`: the scope and rules of a title-ordered
/// query-source browse, as on the catalog query.
struct APIv2CatalogLettersQuery: Encodable, Equatable {
    var libraryId: String?
    var type: String?
    var match: String
    var groups: [APIv2CatalogGroup]
    var order: String

    /// The letter index of the list `query` pages, which must be a
    /// query-source browse in title order.
    init(_ query: APIv2CatalogQuery) {
        libraryId = query.libraryId
        type = query.type
        match = query.match
        groups = query.groups
        order = query.order
    }
}

/// Where each letter's titles sit in a title-ordered browse, for jumping to a
/// letter. Positions are zero-based and count in the browse's order.
struct APIv2CatalogLetters: Decodable, Equatable {
    struct Letter: Decodable, Equatable {
        /// A to Z, or # for titles that start with a digit, a symbol or a
        /// non-Latin letter.
        let letter: String
        let count: Int
        /// The letter's first title.
        let position: Int
    }

    /// A block of consecutive titles under one letter.
    struct Run: Decodable, Equatable {
        let letter: String
        let position: Int
    }

    let total: Int
    /// Letters with at least one title, in list order.
    let letters: [Letter]
    /// Blocks covering the whole list, in list order. A collation can sort
    /// some of a letter's titles apart from the rest, so a position's letter
    /// comes from these rather than from `letters`.
    let runs: [Run]

    /// The letter whose titles the list shows at `position`.
    func letter(at position: Int) -> String? {
        var current: String?
        for run in runs {
            if run.position > position { break }
            current = run.letter
        }
        return current
    }

    /// The first position of `letter`, or nil when no title files under it.
    func position(of letter: String) -> Int? {
        letters.first { $0.letter == letter }?.position
    }
}

/// One page of a catalog list for a screen: the cards and totals it shows,
/// plus the continuation for the next page (`nil` on the last one). The
/// continuation keeps the original query and owner, so a screen pages by
/// handing it back rather than rebuilding the request.
struct CatalogListPage {
    let auth: CapturedOrdinaryRequestAuth
    let response: CatalogResponse
    let continuation: APIv2CatalogContinuation?
    /// This is a fresh first page read in place of a rejected cursor, so the
    /// caller replaces its list instead of appending.
    let startsOver: Bool

    init(_ result: APIv2CatalogResult, startsOver: Bool = false) {
        auth = result.auth
        response = CatalogResponse(catalogPage: result.value)
        continuation = result.continuation
        self.startsOver = startsOver
    }
}

extension APIv2Error {
    /// The cursor can never succeed again: the server rejected it because the
    /// list changed since the first page (`invalid_cursor`: a collection edit,
    /// a library scan, a changed access policy), or the server's cursor chain
    /// repeated or dropped a cursor. The list has to start over from page 1.
    static func isCatalogRestart(_ error: Error) -> Bool {
        switch error {
        case APIv2Error.invalidCatalogContinuation:
            return true
        case APIv2Error.problem(let problem):
            return problem.identifier == "invalid_cursor"
        default:
            return false
        }
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
    let title: String
    let collectionType: String
    @RequiredArtworkURL var posterUrl: String
    let posterThumbhash: String?
    let itemCount: Int
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
    let sortOrder: Int
    let collections: [APIv2LibraryCollectionCard]
}
struct APIv2LibraryCollectionUngrouped: Decodable {
    let sortOrder: Int
    let collections: [APIv2LibraryCollectionCard]
}
