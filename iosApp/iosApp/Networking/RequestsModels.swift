import Foundation

// MARK: - Wire enums

/// Media type for the requests domain (TMDB-shaped: movies + series only).
/// `.all` exists solely as a search-filter query value; the server never
/// returns it on a result. Unrecognized values decode as `.unknown` so a
/// future server addition can't fail the whole payload.
enum RequestMediaType: String, Codable, Hashable, CaseIterable, Identifiable {
    case movie
    case series
    case all
    case unknown

    var id: Self { self }

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RequestMediaType(rawValue: raw) ?? .unknown
    }

    var displayName: String {
        switch self {
        case .movie: "Movie"
        case .series: "Series"
        case .all: "All"
        case .unknown: "Title"
        }
    }
}

/// Lifecycle status of a request (or of one fulfillment target). `failed`
/// only appears on targets; requests express failure via `outcome`.
enum RequestStatus: String, Codable, Hashable {
    case pending
    case approved
    case queued
    case downloading
    case completed
    case failed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RequestStatus(rawValue: raw) ?? .unknown
    }
}

/// Terminal-vs-active axis, orthogonal to `RequestStatus`: a declined or
/// cancelled request keeps its last status but flips its outcome.
enum RequestOutcome: String, Codable, Hashable {
    case active
    case declined
    case cancelled
    case failed
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RequestOutcome(rawValue: raw) ?? .unknown
    }
}

enum RequestAvailability: String, Codable, Hashable {
    case missing
    case available
    case unknown

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = RequestAvailability(rawValue: raw) ?? .unknown
    }
}

// MARK: - Feature status

/// `GET /requests/status` — drives every entry point's visibility.
struct RequestsFeatureStatus: Codable {
    let requestsEnabled: Bool
}

// MARK: - Search / discover results

/// The compact per-item request state embedded on every search/discover/
/// detail result, computed server-side for the signed-in user — the client
/// never has to reason about duplicates or quotas itself.
struct RequestState: Codable, Hashable {
    let status: RequestStatus?
    let requestable: Bool
    /// Raw server token (`already_requested`, `quota_exceeded`, …) when not
    /// requestable. Translated to copy via `RequestErrorCopy` — never
    /// rendered verbatim.
    let reason: String?
    let requestId: String?
}

/// One TMDB search/discover result annotated with this server's
/// availability + request state.
struct RequestMediaResult: Codable, Identifiable, Hashable {
    let mediaType: RequestMediaType
    let tmdbId: Int
    let title: String
    let year: Int?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let voteAverage: Double?
    let availability: RequestAvailability
    let libraryContentId: String?
    let request: RequestState

    var id: String { "\(mediaType.rawValue):\(tmdbId)" }
}

struct RequestMediaPage: Codable {
    let page: Int
    let totalPages: Int
    let totalResults: Int
    let results: [RequestMediaResult]
}

/// One curated TMDB carousel from `GET /requests/discover`. Keys are
/// server-fixed (`trending_movies`, `popular_series`, …).
struct RequestDiscoverySection: Codable, Identifiable {
    let key: String
    let title: String
    let page: Int
    let totalPages: Int
    let totalResults: Int
    let results: [RequestMediaResult]

    var id: String { key }
}

struct RequestDiscoverResponse: Codable {
    let sections: [RequestDiscoverySection]
}

// MARK: - Detail

/// Full TMDB detail for a requestable title, annotated like `RequestMediaResult`.
/// The wire payload also carries a `cast` array — not modeled until a
/// requests surface renders it.
struct RequestMediaDetail: Codable {
    let mediaType: RequestMediaType
    let tmdbId: Int
    let imdbId: String?
    let tvdbId: Int?
    let title: String
    let tagline: String?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let releaseDate: String?
    let year: Int?
    let runtime: Int?
    let genres: [String]?
    let voteAverage: Double?
    let contentRating: String?
    let numberOfSeasons: Int?
    let networks: [String]?
    let director: String?
    let creators: [String]?
    let recommendations: [RequestMediaResult]?
    let availability: RequestAvailability
    let libraryContentId: String?
    let request: RequestState
}

// MARK: - Request records

/// One fulfillment of a request against a single integration at a single
/// quality; a request fans out to one target per resolved quality.
struct RequestTarget: Codable, Hashable {
    let quality: String?
    let status: RequestStatus
    let lastError: String?
}

/// Full request record from `/requests/mine`, `/requests/{id}`, and the
/// create/cancel responses.
struct MediaRequest: Codable, Identifiable, Hashable {
    let id: String
    let mediaType: RequestMediaType
    let tmdbId: Int
    let title: String
    let year: Int?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
    let status: RequestStatus
    let outcome: RequestOutcome
    let targets: [RequestTarget]?
    let libraryContentId: String?
    let lastError: String?
    let createdAt: Date
    let updatedAt: Date
    let completedAt: Date?
}

struct MediaRequestsResponse: Codable {
    let requests: [MediaRequest]
}

// MARK: - Mutations

struct CreateRequestInput: Encodable {
    let mediaType: RequestMediaType
    let tmdbId: Int
    let tvdbId: Int?
    let imdbId: String?
    let title: String
    let year: Int?
    let overview: String?
    let posterPath: String?
    let backdropPath: String?
}

struct CancelRequestBody: Encodable {
    let reason: String?
}
