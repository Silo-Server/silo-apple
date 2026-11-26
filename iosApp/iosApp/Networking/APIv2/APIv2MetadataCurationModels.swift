import Foundation

// MARK: - Field Locks

/// Server `MetadataField` enum values matching `internal/metadata/types.go`.
enum MetadataFieldLock: Int, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case name = 0
    case overview = 1
    case genres = 2
    case studios = 3
    case rating = 6
    case runtime = 7
    case tags = 8
    case contentRating = 9
    case images = 10
    case airSchedule = 11
    case releaseDates = 13

    var id: Int { rawValue }

    /// Lockable field groups for a given item type, matching `EditMetadataDialog`.
    static func supportedLocks(for mediaType: String) -> [MetadataFieldLock] {
        switch mediaType {
        case "movie":
            return [.name, .overview, .contentRating, .runtime, .releaseDates, .rating, .genres, .studios, .tags, .images]
        case "series":
            return [.name, .overview, .contentRating, .releaseDates, .airSchedule, .rating, .genres, .studios, .tags, .images]
        case "season":
            return [.name, .overview, .releaseDates]
        case "episode":
            return [.name, .overview, .runtime, .releaseDates]
        default:
            return []
        }
    }

    static func lock(forFieldKey field: String, mediaType: String) -> MetadataFieldLock? {
        switch mediaType {
        case "season":
            switch field {
            case "title": return .name
            case "overview": return .overview
            case "air_date": return .releaseDates
            default: return nil
            }
        case "episode":
            switch field {
            case "title": return .name
            case "overview": return .overview
            case "air_date": return .releaseDates
            case "runtime": return .runtime
            default: return nil
            }
        case "movie", "series":
            switch field {
            case "title", "sort_title", "original_title": return .name
            case "overview", "tagline": return .overview
            case "genres": return .genres
            case "studios", "networks": return .studios
            case "countries": return .tags
            case "rating_imdb", "rating_tmdb", "rating_rt_critic", "rating_rt_audience": return .rating
            case "runtime": return .runtime
            case "content_rating": return .contentRating
            case "air_time", "air_timezone": return .airSchedule
            case "year", "release_date", "first_air_date", "last_air_date": return .releaseDates
            default: return nil
            }
        default:
            return nil
        }
    }
}

// MARK: - Nullable JSON Patch Wrapper

/// Tri-state field value for PATCH bodies: omit unchanged fields, send explicit
/// JSON `null` to clear a nullable field, or encode a new value.
enum NullablePatch<Value: Encodable & Equatable & Sendable>: Equatable, Sendable {
    case unchanged
    case clear
    case set(Value)

    var isChanged: Bool {
        if case .unchanged = self { return false }
        return true
    }
}

// MARK: - Edit Metadata PATCH

struct AdminItemMetadataPatch: Encodable, Equatable, Sendable {
    var title: String?
    var sortTitle: String?
    var originalTitle: String?
    var overview: String?
    var tagline: String?
    var contentRating: String?
    var year: Int?
    var runtime: Int?
    var genres: [String]?
    var studios: [String]?
    var networks: [String]?
    var countries: [String]?
    var releaseDate: NullablePatch<String> = .unchanged
    var firstAirDate: NullablePatch<String> = .unchanged
    var lastAirDate: NullablePatch<String> = .unchanged
    var airTime: NullablePatch<String> = .unchanged
    var airTimezone: NullablePatch<String> = .unchanged
    var airDate: NullablePatch<String> = .unchanged
    var ratingImdb: NullablePatch<Double> = .unchanged
    var ratingTmdb: NullablePatch<Double> = .unchanged
    var ratingRtCritic: NullablePatch<Int> = .unchanged
    var ratingRtAudience: NullablePatch<Int> = .unchanged
    var imdbId: String?
    var tmdbId: String?
    var tvdbId: String?
    var seasonNumber: Int?
    var episodeNumber: Int?
    var lockedFields: [Int]?

    var isEmpty: Bool {
        title == nil && sortTitle == nil && originalTitle == nil &&
        overview == nil && tagline == nil && contentRating == nil &&
        year == nil && runtime == nil && genres == nil &&
        studios == nil && networks == nil && countries == nil &&
        !releaseDate.isChanged && !firstAirDate.isChanged && !lastAirDate.isChanged &&
        !airTime.isChanged && !airTimezone.isChanged && !airDate.isChanged &&
        !ratingImdb.isChanged && !ratingTmdb.isChanged &&
        !ratingRtCritic.isChanged && !ratingRtAudience.isChanged &&
        imdbId == nil && tmdbId == nil && tvdbId == nil &&
        seasonNumber == nil && episodeNumber == nil && lockedFields == nil
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case sortTitle = "sort_title"
        case originalTitle = "original_title"
        case overview
        case tagline
        case contentRating = "content_rating"
        case year
        case runtime
        case genres
        case studios
        case networks
        case countries
        case releaseDate = "release_date"
        case firstAirDate = "first_air_date"
        case lastAirDate = "last_air_date"
        case airTime = "air_time"
        case airTimezone = "air_timezone"
        case airDate = "air_date"
        case ratingImdb = "rating_imdb"
        case ratingTmdb = "rating_tmdb"
        case ratingRtCritic = "rating_rt_critic"
        case ratingRtAudience = "rating_rt_audience"
        case imdbId = "imdb_id"
        case tmdbId = "tmdb_id"
        case tvdbId = "tvdb_id"
        case seasonNumber = "season_number"
        case episodeNumber = "episode_number"
        case lockedFields = "locked_fields"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(sortTitle, forKey: .sortTitle)
        try c.encodeIfPresent(originalTitle, forKey: .originalTitle)
        try c.encodeIfPresent(overview, forKey: .overview)
        try c.encodeIfPresent(tagline, forKey: .tagline)
        try c.encodeIfPresent(contentRating, forKey: .contentRating)
        try c.encodeIfPresent(year, forKey: .year)
        try c.encodeIfPresent(runtime, forKey: .runtime)
        try c.encodeIfPresent(genres, forKey: .genres)
        try c.encodeIfPresent(studios, forKey: .studios)
        try c.encodeIfPresent(networks, forKey: .networks)
        try c.encodeIfPresent(countries, forKey: .countries)
        try encodeNullable(releaseDate, forKey: .releaseDate, in: &c)
        try encodeNullable(firstAirDate, forKey: .firstAirDate, in: &c)
        try encodeNullable(lastAirDate, forKey: .lastAirDate, in: &c)
        try encodeNullable(airTime, forKey: .airTime, in: &c)
        try encodeNullable(airTimezone, forKey: .airTimezone, in: &c)
        try encodeNullable(airDate, forKey: .airDate, in: &c)
        try encodeNullable(ratingImdb, forKey: .ratingImdb, in: &c)
        try encodeNullable(ratingTmdb, forKey: .ratingTmdb, in: &c)
        try encodeNullable(ratingRtCritic, forKey: .ratingRtCritic, in: &c)
        try encodeNullable(ratingRtAudience, forKey: .ratingRtAudience, in: &c)
        try c.encodeIfPresent(imdbId, forKey: .imdbId)
        try c.encodeIfPresent(tmdbId, forKey: .tmdbId)
        try c.encodeIfPresent(tvdbId, forKey: .tvdbId)
        try c.encodeIfPresent(seasonNumber, forKey: .seasonNumber)
        try c.encodeIfPresent(episodeNumber, forKey: .episodeNumber)
        try c.encodeIfPresent(lockedFields, forKey: .lockedFields)
    }

    private func encodeNullable<T: Encodable>(
        _ field: NullablePatch<T>,
        forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        switch field {
        case .unchanged:
            break
        case .clear:
            try container.encodeNil(forKey: key)
        case .set(let value):
            try container.encode(value, forKey: key)
        }
    }
}

// MARK: - Fix Match

struct AdminMatchHints: Decodable, Equatable, Sendable {
    let title: String
    let year: Int
    let providerIds: [String: String]
}

struct AdminMatchSearchRequest: Encodable, Equatable, Sendable {
    var title: String?
    var year: Int?
    var imdbId: String?
    var tmdbId: String?
    var tvdbId: String?
    var providerIds: [String: String]?
    var libraryId: String?
    var limit: Int = 500
}

struct AdminMatchCandidate: Decodable, Equatable, Hashable, Sendable, Identifiable {
    let title: String
    let originalTitle: String?
    let matchedTitle: String?
    let titleIsFallback: Bool?
    let titleLanguage: String?
    let year: Int
    let contentType: String
    let overview: String?
    @ArtworkURL var imageUrl: String?
    let matchScore: Double?
    let matchReasons: [String]?
    let sources: [String]
    let agreementHints: [String]?
    let providerIds: [String: String]

    var id: String {
        let keys = providerIds.keys.sorted().map { "\($0)=\(providerIds[$0] ?? "")" }.joined(separator: "&")
        return "\(contentType):\(title):\(year):\(keys)"
    }

    var displayTitle: String {
        if titleIsFallback == true, let matchedTitle, !matchedTitle.isEmpty, matchedTitle != title {
            return matchedTitle
        }
        return title
    }

    var secondaryTitle: String? {
        if titleIsFallback == true, let matchedTitle, !matchedTitle.isEmpty, matchedTitle != title {
            return title
        }
        if let originalTitle, !originalTitle.isEmpty, originalTitle != title {
            return originalTitle
        }
        if let matchedTitle, !matchedTitle.isEmpty, matchedTitle != title, matchedTitle != originalTitle {
            return matchedTitle
        }
        return nil
    }

    /// Formats `matchScore` (already on a 0...100 server scale) as a rounded percentage badge.
    var formattedMatchScore: String? {
        guard let score = matchScore, score.isFinite else { return nil }
        return "\(Int(score.rounded()))%"
    }

    /// Converts snake_case server reason tokens (`exact_title`, `provider_sources`)
    /// into readable labels.
    var formattedMatchReasons: [String] {
        (matchReasons ?? [])
            .map { raw in
                raw.split(separator: "_")
                    .map { word in
                        let lower = word.lowercased()
                        switch lower {
                        case "id": return "ID"
                        case "imdb": return "IMDb"
                        case "tmdb": return "TMDB"
                        case "tvdb": return "TVDB"
                        default: return lower.capitalized
                        }
                    }
                    .joined(separator: " ")
            }
            .filter { !$0.isEmpty }
    }
}

struct AdminMatchSearchResponse: Decodable, Equatable, Sendable {
    let candidates: [AdminMatchCandidate]
    let truncated: Bool
}

struct AdminMatchApplyRequest: Encodable, Equatable, Sendable {
    let providerIds: [String: String]
    var libraryId: String?
}

struct AdminMatchApplyResponse: Decodable, Equatable, Sendable {
    let contentId: String
    let updated: Bool
}

// MARK: - Smart Query Detection for Fix Match

struct DetectedMatchQuery: Equatable, Sendable {
    var title: String?
    var imdbId: String?
    var tmdbId: String?
    var tvdbId: String?

    /// Parses a free-form search string so pasting `tt15239678`, an IMDb URL,
    /// a TMDB URL, or a TVDB URL directly into the search bar routes straight
    /// to external ID lookup without opening the ID disclosure.
    static func parse(_ raw: String) -> DetectedMatchQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return DetectedMatchQuery() }

        // Direct IMDb ID: tt1234567
        if let match = trimmed.range(of: #"^tt\d{5,10}$"#, options: [.regularExpression, .caseInsensitive]) {
            return DetectedMatchQuery(imdbId: String(trimmed[match]).lowercased())
        }

        // IMDb URL: https://www.imdb.com/title/tt15239678/...
        if trimmed.lowercased().contains("imdb.com"),
           let match = trimmed.range(of: #"tt\d{5,10}"#, options: [.regularExpression, .caseInsensitive]) {
            return DetectedMatchQuery(imdbId: String(trimmed[match]).lowercased())
        }

        // TMDB URL: https://www.themoviedb.org/movie/693134-dune-part-two or /tv/95396-severance
        if trimmed.lowercased().contains("themoviedb.org"),
           let regex = try? NSRegularExpression(pattern: #"/(?:movie|tv)/(\d+)"#, options: .caseInsensitive),
           let result = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(result.range(at: 1), in: trimmed) {
            return DetectedMatchQuery(tmdbId: String(trimmed[range]))
        }

        // TVDB URL: https://thetvdb.com/dereferrer/series/371980 or ?id=371980
        if trimmed.lowercased().contains("thetvdb.com"),
           let regex = try? NSRegularExpression(pattern: #"(?:series|movies|id=)/?(\d+)"#, options: .caseInsensitive),
           let result = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let range = Range(result.range(at: 1), in: trimmed) {
            return DetectedMatchQuery(tvdbId: String(trimmed[range]))
        }

        return DetectedMatchQuery(title: trimmed)
    }
}

// MARK: - Artwork / Images

enum MetadataImageSlot: String, CaseIterable, Codable, Hashable, Sendable, Identifiable {
    case poster
    case backdrop
    case logo

    var id: String { rawValue }

    /// Seasons support posters and backdrops; the server rejects logos for them.
    static func slots(forMediaType type: String) -> [MetadataImageSlot] {
        switch type {
        case "season":
            return [.poster, .backdrop]
        case "movie", "series":
            return [.poster, .backdrop, .logo]
        default:
            return []
        }
    }

    var aspectRatio: Double {
        switch self {
        case .poster: return 2.0 / 3.0
        case .backdrop, .logo: return 16.0 / 9.0
        }
    }
}

struct AdminItemImage: Decodable, Equatable, Hashable, Sendable, Identifiable {
    let type: String
    @ArtworkURL var url: String?
    let originalUrl: String
    let providerId: String
    let language: String
    let width: Int
    let height: Int
    let rating: Double

    var id: String { "\(type):\(providerId):\(originalUrl)" }

    var isUploaded: Bool { originalUrl.hasPrefix("upload://") }

    var isTextless: Bool {
        let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty || trimmed == "xx"
    }

    var resolutionText: String? {
        guard width > 0, height > 0 else { return nil }
        return "\(width) × \(height)"
    }

    var displayProvider: String { providerId.uppercased() }
}

struct AdminCurrentImages: Decodable, Equatable, Sendable {
    let posterUrl: String?
    let backdropUrl: String?
    let logoUrl: String?

    func storedPath(for slot: MetadataImageSlot) -> String? {
        switch slot {
        case .poster: return posterUrl
        case .backdrop: return backdropUrl
        case .logo: return logoUrl
        }
    }
}

struct AdminImagesPageWire: Decodable, Sendable {
    let items: [AdminItemImage]
    let current: AdminCurrentImages
    let page: APIv2Page
    let providerErrors: [String: String]?
}

struct AdminItemImagesResponse: Equatable, Sendable {
    let images: [AdminItemImage]
    let current: AdminCurrentImages
    let providerErrors: [String: String]
}

struct AdminImageApplyRequest: Encodable, Equatable, Sendable {
    let originalUrl: String
    let type: String
    let providerId: String?
}

struct AdminImageApplyResponse: Decodable, Equatable, Sendable {
    let contentId: String
    @ArtworkURL var imageUrl: String?
    let revision: String?
    let storedPath: String
    let thumbhash: String
}

// MARK: - On-Device Image Upload Validation

struct ValidatedUploadImage: Equatable, Sendable {
    let data: Data
    let mimeType: String
    let fileExtension: String
}

enum ImageUploadValidationError: LocalizedError, Equatable, Sendable {
    case empty
    case tooLarge(maxBytes: Int)
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case .empty:
            return "The selected image file is empty."
        case .tooLarge:
            return "Image exceeds the 10 MB upload limit."
        case .unsupportedFormat:
            return "Only JPEG, PNG, and WebP images are supported."
        }
    }
}

enum ImageUploadValidator {
    static let maxBytes = 10 * 1024 * 1024

    /// Validates bytes against JPEG, PNG, and WebP magic headers and the
    /// server's 10 MiB cap before starting a network upload.
    static func validate(_ data: Data) throws -> ValidatedUploadImage {
        guard !data.isEmpty else { throw ImageUploadValidationError.empty }
        guard data.count <= maxBytes else { throw ImageUploadValidationError.tooLarge(maxBytes: maxBytes) }

        let bytes = [UInt8](data.prefix(12))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return ValidatedUploadImage(data: data, mimeType: "image/jpeg", fileExtension: "jpg")
        }
        if bytes.count >= 8,
           bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47,
           bytes[4] == 0x0D, bytes[5] == 0x0A, bytes[6] == 0x1A, bytes[7] == 0x0A {
            return ValidatedUploadImage(data: data, mimeType: "image/png", fileExtension: "png")
        }
        if bytes.count >= 12,
           bytes[0] == 0x52, bytes[1] == 0x49, bytes[2] == 0x46, bytes[3] == 0x46,
           bytes[8] == 0x57, bytes[9] == 0x45, bytes[10] == 0x42, bytes[11] == 0x50 {
            return ValidatedUploadImage(data: data, mimeType: "image/webp", fileExtension: "webp")
        }
        throw ImageUploadValidationError.unsupportedFormat
    }
}

// MARK: - Refresh Metadata & Jobs

enum MetadataRefreshMode: String, Codable, Hashable, Sendable {
    case quick
    case complete
}

struct AdminRefreshItemMetadataRequest: Encodable, Sendable {
    let mode: MetadataRefreshMode
}

struct AdminTaskJobItemResult: Decodable, Equatable, Sendable {
    let requestedContentId: String?
    let refreshContentId: String?
    let detailContentId: String?
    let matchedFiles: Int?
    let newFiles: Int?
    let artworkCacheIncomplete: Bool?
}

struct AdminTaskJobFailure: Decodable, Equatable, Sendable {
    let type: String?
    let title: String?
    let detail: String?
    let retryable: Bool?

    var displayMessage: String? {
        if let detail, !detail.isEmpty { return detail }
        if let title, !title.isEmpty { return title }
        return nil
    }
}

struct AdminTaskJob: Decodable, Equatable, Sendable {
    let id: String
    let kind: String
    let state: String
    let terminal: Bool
    let itemResult: AdminTaskJobItemResult?
    let failure: AdminTaskJobFailure?

    var isTerminal: Bool {
        if terminal { return true }
        switch state {
        case "completed", "succeeded", "failed", "canceled", "cancelled", "interrupted":
            return true
        default:
            return false
        }
    }

    var isSuccess: Bool {
        state == "completed" || state == "succeeded"
    }
}

// MARK: - Item Files (for Multi-Library Match Scoping)

struct AdminItemFile: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let libraryId: String
    let filePath: String
    let observedRootPath: String
    let seasonNumber: Int?
    let episodeNumber: Int?
}

struct AdminItemFilesPageWire: Decodable, Sendable {
    let items: [AdminItemFile]
    let page: APIv2Page?
}

// MARK: - Admin Metadata AI Translation

struct AdminTranslateMetadataRequest: Encodable, Sendable {
    let targetLanguage: String
    let includeChildren: Bool
    let force: Bool
}

struct AdminMetadataTranslationJob: Decodable, Equatable, Sendable, Identifiable {
    let id: String
    let targetKind: String
    let contentId: String
    let targetLanguage: String
    let status: String
    let fieldsDone: Int?
    let fieldsTotal: Int?
    let progressMessage: String?
    let errorMessage: String?

    var isActive: Bool {
        status == "pending" || status == "running"
    }
}

struct AdminMetadataTranslationJobsResponse: Decodable, Equatable, Sendable {
    let jobs: [AdminMetadataTranslationJob]
}
