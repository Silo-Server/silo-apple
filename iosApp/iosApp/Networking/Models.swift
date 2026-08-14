import Foundation

// MARK: - Browse / Catalog

struct BrowseItem: Codable, Identifiable, Hashable {
    let contentId: String
    let type: String
    let title: String
    let year: Int?
    let genres: [String]?
    let contentRating: String?
    let status: String?
    let ratingImdb: Double?
    let ratingTmdb: Double?
    let ratingRtCritic: Int?
    let ratingRtAudience: Int?
    let runtime: Int?
    let originalLanguage: String?
    let studios: [String]?
    let networks: [String]?
    let showStatus: String?
    let overview: String?
    let posterUrl: String?
    let posterThumbhash: String?
    let backdropUrl: String?
    let backdropThumbhash: String?
    let addedAt: String?
    let releaseDate: String?
    let lastAirDate: String?
    let userState: MediaItemUserState?
    let overlaySummary: OverlaySummary?
    var id: String { contentId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try c.decode(String.self, forKey: .contentId)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        ratingImdb = try c.decodeIfPresent(Double.self, forKey: .ratingImdb)
        ratingTmdb = try c.decodeIfPresent(Double.self, forKey: .ratingTmdb)
        ratingRtCritic = try c.decodeIfPresent(Int.self, forKey: .ratingRtCritic)
        ratingRtAudience = try c.decodeIfPresent(Int.self, forKey: .ratingRtAudience)
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime)
        originalLanguage = try c.decodeIfPresent(String.self, forKey: .originalLanguage)
        studios = try c.decodeIfPresent([String].self, forKey: .studios)
        networks = try c.decodeIfPresent([String].self, forKey: .networks)
        showStatus = try c.decodeIfPresent(String.self, forKey: .showStatus)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        posterUrl = try c.decodeIfPresent(String.self, forKey: .posterUrl)
        posterThumbhash = try c.decodeIfPresent(String.self, forKey: .posterThumbhash)
        backdropUrl = try c.decodeIfPresent(String.self, forKey: .backdropUrl)
        backdropThumbhash = try c.decodeIfPresent(String.self, forKey: .backdropThumbhash)
        addedAt = try c.decodeIfPresent(String.self, forKey: .addedAt)
        releaseDate = try c.decodeIfPresent(String.self, forKey: .releaseDate)
        lastAirDate = try c.decodeIfPresent(String.self, forKey: .lastAirDate)
        userState = try c.decodeIfPresent(MediaItemUserState.self, forKey: .userState)
        overlaySummary = try c.decodeIfPresent(OverlaySummary.self, forKey: .overlaySummary)
    }
}

/// Tech-level overlay data derived server-side from the best-ranked file's
/// media metadata. Mirrors `internal/overlays/summary.go` →
/// `OverlaySummary` on the Go side. Ratings, metadata, and ribbon overlays
/// pull their values from item-level fields (ratingImdb, year, …), not this
/// struct.
struct OverlaySummary: Codable, Hashable {
    let resolution: String?
    let hdr: String?
    let audio: String?
    let audioChannels: String?
    let videoCodec: String?
    let container: String?
    let aspectRatio: String?
    let releaseType: String?
    let edition: String?
    let multiAudio: Bool?
    let multiSub: Bool?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution)
        hdr = try c.decodeIfPresent(String.self, forKey: .hdr)
        audio = try c.decodeIfPresent(String.self, forKey: .audio)
        audioChannels = try c.decodeIfPresent(String.self, forKey: .audioChannels)
        videoCodec = try c.decodeIfPresent(String.self, forKey: .videoCodec)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        aspectRatio = try c.decodeIfPresent(String.self, forKey: .aspectRatio)
        releaseType = try c.decodeIfPresent(String.self, forKey: .releaseType)
        edition = try c.decodeIfPresent(String.self, forKey: .edition)
        multiAudio = try c.decodeIfPresent(Bool.self, forKey: .multiAudio)
        multiSub = try c.decodeIfPresent(Bool.self, forKey: .multiSub)
    }
}

struct MediaItemUserState: Codable, Hashable {
    let played: Bool
    let isFavorite: Bool
    let inWatchlist: Bool

    init(played: Bool = false, isFavorite: Bool = false, inWatchlist: Bool = false) {
        self.played = played
        self.isFavorite = isFavorite
        self.inWatchlist = inWatchlist
    }
}

/// Distinct filter values for a library. Returned by `/api/v1/catalog/filters`.
/// The server does NOT return counts — consumers render plain labels.
struct CatalogFilters: Codable, Hashable {
    let genres: [String]
    let studios: [String]
    let networks: [String]
    let countries: [String]
    let contentRatings: [String]
    let resolutions: [String]?
    let audioLanguages: [String]?
    let subtitleLanguages: [String]?
    let originalLanguages: [String]?
    /// Audiobook-native facets. Always returned by the server; optional here
    /// so older servers still decode.
    let authors: [String]?
    let narrators: [String]?
    let series: [String]?
}

struct CatalogResponse: Codable {
    let total: Int?
    let totalExact: Bool?
    let hasMore: Bool?
    let items: [BrowseItem]
    let source: String?
    let title: String?
    let snapshot: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        total = try c.decodeIfPresent(Int.self, forKey: .total)
        totalExact = try c.decodeIfPresent(Bool.self, forKey: .totalExact)
        hasMore = try c.decodeIfPresent(Bool.self, forKey: .hasMore)
        items = try c.decodeIfPresent([BrowseItem].self, forKey: .items) ?? []
        source = try c.decodeIfPresent(String.self, forKey: .source)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        snapshot = try c.decodeIfPresent(String.self, forKey: .snapshot)
    }
}

// MARK: - Home Sections

struct SectionItem: Codable, Identifiable, Hashable {
    let contentId: String
    let type: String
    let title: String
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let year: Int?
    let genres: [String]?
    let status: String?
    let ratingImdb: Double?
    let ratingTmdb: Double?
    let ratingRtCritic: Int?
    let ratingRtAudience: Int?
    let contentRating: String?
    let runtime: Int?
    let originalLanguage: String?
    let studios: [String]?
    let networks: [String]?
    let showStatus: String?
    let overview: String?
    let itemSource: String?
    let positionSeconds: Double?
    let durationSeconds: Double?
    let progressUpdatedAt: String?
    let posterUrl: String?
    let posterThumbhash: String?
    let backdropUrl: String?
    let backdropThumbhash: String?
    let logoUrl: String?
    let userState: MediaItemUserState?
    let overlaySummary: OverlaySummary?
    var id: String { contentId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try c.decode(String.self, forKey: .contentId)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        seriesTitle = try c.decodeIfPresent(String.self, forKey: .seriesTitle)
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        genres = try c.decodeIfPresent([String].self, forKey: .genres)
        status = try c.decodeIfPresent(String.self, forKey: .status)
        ratingImdb = try c.decodeIfPresent(Double.self, forKey: .ratingImdb)
        ratingTmdb = try c.decodeIfPresent(Double.self, forKey: .ratingTmdb)
        ratingRtCritic = try c.decodeIfPresent(Int.self, forKey: .ratingRtCritic)
        ratingRtAudience = try c.decodeIfPresent(Int.self, forKey: .ratingRtAudience)
        contentRating = try c.decodeIfPresent(String.self, forKey: .contentRating)
        runtime = try c.decodeIfPresent(Int.self, forKey: .runtime)
        originalLanguage = try c.decodeIfPresent(String.self, forKey: .originalLanguage)
        studios = try c.decodeIfPresent([String].self, forKey: .studios)
        networks = try c.decodeIfPresent([String].self, forKey: .networks)
        showStatus = try c.decodeIfPresent(String.self, forKey: .showStatus)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        itemSource = try c.decodeIfPresent(String.self, forKey: .itemSource)
        positionSeconds = try c.decodeIfPresent(Double.self, forKey: .positionSeconds)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        progressUpdatedAt = try c.decodeIfPresent(String.self, forKey: .progressUpdatedAt)
        posterUrl = try c.decodeIfPresent(String.self, forKey: .posterUrl)
        posterThumbhash = try c.decodeIfPresent(String.self, forKey: .posterThumbhash)
        backdropUrl = try c.decodeIfPresent(String.self, forKey: .backdropUrl)
        backdropThumbhash = try c.decodeIfPresent(String.self, forKey: .backdropThumbhash)
        logoUrl = try c.decodeIfPresent(String.self, forKey: .logoUrl)
        userState = try c.decodeIfPresent(MediaItemUserState.self, forKey: .userState)
        overlaySummary = try c.decodeIfPresent(OverlaySummary.self, forKey: .overlaySummary)
    }
}

enum SiloMediaType {
    private static func normalized(_ type: String) -> String {
        type.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    static func isAudiobook(_ type: String) -> Bool {
        switch normalized(type) {
        case "audiobook", "audiobooks", "book", "books":
            return true
        default:
            return false
        }
    }

    static func isSeries(_ type: String) -> Bool {
        switch normalized(type) {
        case "series", "show", "shows", "tv", "tvshows":
            return true
        default:
            return false
        }
    }

    static func isMovieLibrary(_ type: String) -> Bool {
        switch normalized(type) {
        case "movie", "movies":
            return true
        default:
            return false
        }
    }

    /// Leaf media that can be handed directly to the player. Container
    /// types such as series and seasons still open their detail screen.
    static func isDirectlyPlayable(_ type: String) -> Bool {
        isMovieLibrary(type)
            || isAudiobook(type)
            || normalized(type) == "episode"
    }

    static func isAudiobookLibrary(_ type: String) -> Bool {
        switch normalized(type) {
        case "audiobook", "audiobooks":
            return true
        default:
            return false
        }
    }

    /// A "mixed" library holds movies and series in one folder; each item
    /// still carries its own concrete `type`, so it browses as one library.
    static func isMixedLibrary(_ type: String) -> Bool {
        normalized(type) == "mixed"
    }

    static func isSupportedLibrary(_ type: String) -> Bool {
        isMovieLibrary(type) || isSeries(type) || isAudiobookLibrary(type) || isMixedLibrary(type)
    }

    /// Section items are kept only when their type maps to a library type
    /// the Apple clients support (see ``isSupportedLibrary``). The server
    /// builds Home sections for every library type, so items from hidden
    /// libraries (ebook, manga, comics, music, …) must be stripped
    /// client-side or those libraries leak rows into Home.
    static func isSupportedSectionItem(_ type: String) -> Bool {
        if isMovieLibrary(type) || isSeries(type) || isAudiobook(type) {
            return true
        }
        switch normalized(type) {
        case "episode", "episodes":
            return true
        default:
            return false
        }
    }
}

extension BrowseItem {
    var isAudiobook: Bool { SiloMediaType.isAudiobook(type) }
}

extension SectionItem {
    var isAudiobook: Bool { SiloMediaType.isAudiobook(type) }
}

struct ResolvedSection: Codable, Identifiable {
    let id: String
    let sectionType: String
    let title: String
    let featured: Bool?
    let itemLimit: Int?
    let totalCount: Int?
    let isCustom: Bool?
    let customized: Bool?
    let items: [SectionItem]

    /// Whether this section is featured (defaults to false if nil).
    var isFeatured: Bool { featured ?? false }

    init(
        id: String,
        sectionType: String,
        title: String,
        featured: Bool?,
        itemLimit: Int?,
        totalCount: Int?,
        isCustom: Bool?,
        customized: Bool?,
        items: [SectionItem]
    ) {
        self.id = id
        self.sectionType = sectionType
        self.title = title
        self.featured = featured
        self.itemLimit = itemLimit
        self.totalCount = totalCount
        self.isCustom = isCustom
        self.customized = customized
        self.items = items
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        sectionType = try c.decode(String.self, forKey: .sectionType)
        title = try c.decode(String.self, forKey: .title)
        featured = try c.decodeIfPresent(Bool.self, forKey: .featured)
        itemLimit = try c.decodeIfPresent(Int.self, forKey: .itemLimit)
        totalCount = try c.decodeIfPresent(Int.self, forKey: .totalCount)
        isCustom = try c.decodeIfPresent(Bool.self, forKey: .isCustom)
        customized = try c.decodeIfPresent(Bool.self, forKey: .customized)
        items = try c.decodeIfPresent([SectionItem].self, forKey: .items) ?? []
    }
}

struct SectionsResponse: Codable {
    let sections: [ResolvedSection]

    init(sections: [ResolvedSection]) {
        self.sections = Self.strippingUnsupportedItems(sections)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let decoded = try c.decodeIfPresent([ResolvedSection].self, forKey: .sections) ?? []
        sections = Self.strippingUnsupportedItems(decoded)
    }

    /// Mirror of `LibrariesResponse` gating: unsupported library types are
    /// hidden from the library list, so their items must not surface through
    /// server-built sections either. Sections emptied by the strip are kept —
    /// every consumer already drops empty sections before rendering.
    private static func strippingUnsupportedItems(
        _ sections: [ResolvedSection]
    ) -> [ResolvedSection] {
        sections.map { section in
            let kept = section.items.filter {
                SiloMediaType.isSupportedSectionItem($0.type)
            }
            guard kept.count != section.items.count else { return section }
            return ResolvedSection(
                id: section.id,
                sectionType: section.sectionType,
                title: section.title,
                featured: section.featured,
                itemLimit: section.itemLimit,
                totalCount: section.totalCount,
                isCustom: section.isCustom,
                customized: section.customized,
                items: kept
            )
        }
    }
}

// MARK: - Item Detail

struct ItemDetail: Codable {
    let contentId: String
    let type: String
    let status: String?
    let title: String
    let sortTitle: String?
    let originalTitle: String?
    let originalLanguage: String?
    let showStatus: String?
    let year: Int?
    let overview: String?
    let tagline: String?
    let runtime: Int?
    let contentRating: String?
    let genres: [String]?
    let ratingImdb: Double?
    let ratingTmdb: Double?
    let ratingRtCritic: Int?
    let ratingRtAudience: Int?
    let imdbId: String?
    let tmdbId: String?
    let tvdbId: String?
    let cast: [CastMember]?
    let crew: [CrewMember]?
    let studios: [String]?
    let networks: [String]?
    let countries: [String]?
    let releaseDate: String?
    let firstAirDate: String?
    let lastAirDate: String?
    let posterUrl: String?
    let posterThumbhash: String?
    let backdropUrl: String?
    let backdropThumbhash: String?
    let logoUrl: String?
    let seasonCount: Int?
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let episodeCount: Int?
    let airDate: String?
    let isSpecials: Bool?
    let userData: LeafItemUserData?
    let versions: [FileVersion]?
    let subtitles: [SubtitleInfoBasic]?
    let intro: TimeRange?
    let credits: TimeRange?
    /// Server-resolved subtitle policy, folded in from the watch detail
    /// during playback enrichment (absent on the raw catalog payload).
    /// The signature is only present when an explicit per-series /
    /// per-movie subtitle override is stored, so it doubles as the
    /// "user picked a track" marker for selector seeding.
    let effectiveSubtitleMode: String?
    let effectiveShowForcedSubtitles: Bool?
    let effectiveSubtitleTrackSignature: SubtitleTrackSignature?
    let overlaySummary: OverlaySummary?
    let audiobook: AudiobookDetail?
    /// Set by the server (omitted when empty) when a description exists
    /// but is not yet available in the viewer's resolved metadata
    /// language. Drives the on-view "translate this description"
    /// affordance; clears once the localized overview lands.
    let pendingTranslationLanguage: String?
    /// Remote provider videos (YouTube trailers, teasers, …) for movies and
    /// series, pre-ordered by the server (trailers first, official first).
    /// Never populated for episodes.
    ///
    /// `var` with a default (rather than `let`) purely so the synthesized
    /// memberwise initializer keeps a default for this parameter: the
    /// detail views rebuild an `ItemDetail` field-by-field when folding in
    /// watch metadata, and those call sites must keep compiling. Optional
    /// `var`s are still decoded normally (unlike `let`s with an initial
    /// value, which Codable skips).
    var videos: [ItemVideo]? = nil
    /// Local extras discovered by the scanner. Each carries its own
    /// `contentId`, playable through the normal `/watch` flow.
    var extras: [ItemExtra]? = nil
}

extension ItemDetail {
    var isAudiobook: Bool {
        audiobook != nil || SiloMediaType.isAudiobook(type)
    }
}

/// A remote provider video reference (server `ItemVideoInfo`). The site
/// reference (`site` + `siteKey`) is all a client needs to build thumbnail,
/// watch, and embed URLs — see ``TrailerRail``.
struct ItemVideo: Codable, Hashable {
    let kind: String
    let site: String
    let siteKey: String
    let name: String?
    let language: String?
    let isOfficial: Bool

    init(
        kind: String,
        site: String,
        siteKey: String,
        name: String? = nil,
        language: String? = nil,
        isOfficial: Bool = false
    ) {
        self.kind = kind
        self.site = site
        self.siteKey = siteKey
        self.name = name
        self.language = language
        self.isOfficial = isOfficial
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        kind = try c.decode(String.self, forKey: .kind)
        site = try c.decode(String.self, forKey: .site)
        siteKey = try c.decode(String.self, forKey: .siteKey)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        language = try c.decodeIfPresent(String.self, forKey: .language)
        // Defensive: a missing `is_official` must not fail the whole item
        // detail decode.
        isOfficial = try c.decodeIfPresent(Bool.self, forKey: .isOfficial) ?? false
    }
}

/// A local extras file (server `ItemExtraInfo`). `contentId` is a playable
/// watch target like any other item; `fileId` backs direct-stream affordances.
struct ItemExtra: Codable, Hashable, Identifiable {
    let contentId: String
    let kind: String
    let title: String?
    let durationSeconds: Int?
    let fileId: Int?
    var id: String { contentId }

    init(
        contentId: String,
        kind: String,
        title: String? = nil,
        durationSeconds: Int? = nil,
        fileId: Int? = nil
    ) {
        self.contentId = contentId
        self.kind = kind
        self.title = title
        self.durationSeconds = durationSeconds
        self.fileId = fileId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try c.decode(String.self, forKey: .contentId)
        kind = try c.decode(String.self, forKey: .kind)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        // Both are `omitempty` server-side, so they are simply absent at zero.
        durationSeconds = try c.decodeIfPresent(Int.self, forKey: .durationSeconds)
        fileId = try c.decodeIfPresent(Int.self, forKey: .fileId)
    }
}

/// Outcome of `POST /api/v1/items/{id}/trailers/refresh`.
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

struct AudiobookDetail: Codable, Hashable {
    let authors: [AudiobookPerson]
    let narrators: [AudiobookPerson]
    let publisher: String?
    let totalDurationSeconds: Int?
    let series: AudiobookSeriesGroup?
    let otherNarrations: [AudiobookNarration]
    let related: AudiobookRelatedContent?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        authors = try c.decodeIfPresent([AudiobookPerson].self, forKey: .authors) ?? []
        narrators = try c.decodeIfPresent([AudiobookPerson].self, forKey: .narrators) ?? []
        publisher = try c.decodeIfPresent(String.self, forKey: .publisher)
        totalDurationSeconds = try c.decodeIfPresent(Int.self, forKey: .totalDurationSeconds)
        series = try c.decodeIfPresent(AudiobookSeriesGroup.self, forKey: .series)
        otherNarrations = try c.decodeIfPresent([AudiobookNarration].self, forKey: .otherNarrations) ?? []
        related = try c.decodeIfPresent(AudiobookRelatedContent.self, forKey: .related)
    }
}

struct AudiobookPerson: Codable, Identifiable, Hashable {
    let personId: String?
    let name: String
    let photoUrl: String?
    let photoThumbhash: String?
    var id: String { personId ?? name }
}

struct AudiobookSeriesGroup: Codable, Hashable {
    let name: String?
    let entries: [AudiobookRelatedItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        entries = try c.decodeIfPresent([AudiobookRelatedItem].self, forKey: .entries) ?? []
    }
}

struct AudiobookRelatedContent: Codable, Hashable {
    let alsoByAuthor: [AudiobookRelatedItem]
    let similar: [AudiobookRelatedItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        alsoByAuthor = try c.decodeIfPresent([AudiobookRelatedItem].self, forKey: .alsoByAuthor) ?? []
        similar = try c.decodeIfPresent([AudiobookRelatedItem].self, forKey: .similar) ?? []
    }
}

struct AudiobookRelatedItem: Codable, Identifiable, Hashable {
    let contentId: String
    let title: String
    let year: Int?
    let posterUrl: String?
    let seriesIndex: Int?
    var id: String { contentId }
}

struct AudiobookNarration: Codable, Identifiable, Hashable {
    let contentId: String
    let title: String
    let year: Int?
    let narrators: [String]
    var id: String { contentId }
}

struct CastMember: Codable, Identifiable, Hashable {
    let name: String
    let character: String?
    let order: Int?
    let personId: String?
    let tmdbId: String?
    let tvdbId: String?
    let imdbId: String?
    let photoUrl: String?
    let photoThumbhash: String?
    var id: String { personId ?? "\(name)-\(character ?? "")" }
}

struct CrewMember: Codable, Identifiable, Hashable {
    let name: String
    let job: String?
    let personId: String?
    let tmdbId: String?
    let tvdbId: String?
    let imdbId: String?
    let photoUrl: String?
    let photoThumbhash: String?
    var id: String { "\(personId ?? name)-\(job ?? "")" }
}

struct Person: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let bio: String?
    let birthDate: String?
    let deathDate: String?
    let birthplace: String?
    let homepage: String?
    let photoUrl: String?
    let photoThumbhash: String?
    let tmdbId: String?
    let imdbId: String?
    let tvdbId: String?
    let plexGuid: String?
}

struct PersonRefreshQueuedResponse: Codable, Hashable {
    let status: String
    let personId: Int
}

struct Season: Codable, Identifiable, Hashable {
    let contentId: String
    let seasonNumber: Int
    let isSpecials: Bool?
    let title: String?
    let overview: String?
    let airDate: String?
    let episodeCount: Int
    let posterUrl: String?
    let posterThumbhash: String?
    let userData: SeasonUserData?
    var id: String { contentId }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try c.decode(String.self, forKey: .contentId)
        seasonNumber = try c.decode(Int.self, forKey: .seasonNumber)
        isSpecials = try c.decodeIfPresent(Bool.self, forKey: .isSpecials)
        title = try c.decodeIfPresent(String.self, forKey: .title)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        airDate = try c.decodeIfPresent(String.self, forKey: .airDate)
        episodeCount = try c.decodeIfPresent(Int.self, forKey: .episodeCount) ?? 0
        posterUrl = try c.decodeIfPresent(String.self, forKey: .posterUrl)
        posterThumbhash = try c.decodeIfPresent(String.self, forKey: .posterThumbhash)
        userData = try c.decodeIfPresent(SeasonUserData.self, forKey: .userData)
    }
}

extension Array where Element == Season {
    func sortedForDisplay() -> [Season] {
        sorted { lhs, rhs in
            let lhsSpecials = lhs.isSpecials == true || lhs.seasonNumber == 0
            let rhsSpecials = rhs.isSpecials == true || rhs.seasonNumber == 0
            if lhsSpecials != rhsSpecials { return !lhsSpecials }
            if lhs.seasonNumber != rhs.seasonNumber { return lhs.seasonNumber < rhs.seasonNumber }
            if (lhs.title ?? "") != (rhs.title ?? "") { return (lhs.title ?? "") < (rhs.title ?? "") }
            return lhs.contentId < rhs.contentId
        }
    }
}

struct SeasonUserData: Codable, Hashable {
    let played: Bool
    let watchedCount: Int?
    let unplayedCount: Int?
    let inProgressCount: Int?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        played = try c.decodeIfPresent(Bool.self, forKey: .played) ?? false
        watchedCount = try c.decodeIfPresent(Int.self, forKey: .watchedCount)
        unplayedCount = try c.decodeIfPresent(Int.self, forKey: .unplayedCount)
        inProgressCount = try c.decodeIfPresent(Int.self, forKey: .inProgressCount)
    }
}

struct EpisodeListItem: Codable, Identifiable, Hashable {
    let contentId: String
    let seasonNumber: Int
    let episodeNumber: Int
    let title: String?
    let overview: String?
    let airDate: String?
    let runtime: Int?
    let imdbId: String?
    let tmdbId: String?
    let tvdbId: String?
    let stillUrl: String?
    let stillThumbhash: String?
    let userData: LeafItemUserData?
    let files: [EpisodeFile]?
    var id: String { contentId }
}

struct EpisodeFile: Codable, Hashable {
    let fileId: Int
    let resolution: String?
    let codecVideo: String?
    let hdr: Bool?
    let audioChannels: Int?
    let container: String?
    let fileSize: Int64?
}

struct FileVersion: Codable, Identifiable, Hashable {
    let fileId: Int
    let fileName: String?
    let resolution: String?
    let codecVideo: String?
    let codecAudio: String?
    let hdr: Bool?
    let container: String?
    let fileSize: Int64?
    let duration: Double?
    let bitrate: Int?
    let videoTracks: [VideoTrack]?
    let audioTracks: [AudioTrack]?
    let subtitleTracks: [SubtitleTrack]?
    let chapters: [VersionChapter]?
    let intro: TimeRange?
    let credits: TimeRange?
    let presentationKind: String?
    let presentationGroupKey: String?
    let presentationPartIndex: Int?
    let presentationPartTotal: Int?
    /// Server-current edition fields. `editionRaw` is the display label,
    /// while `editionKey` is the stable grouping key.
    let editionRaw: String?
    let editionKey: String?
    /// Legacy pre-`edition_raw` label kept as a decode fallback.
    let edition: String?
    /// Server-resolved default audio track ordinal for this version.
    let effectiveAudioTrackIndex: Int?
    let effectiveAudioLanguage: String?
    var id: Int { fileId }
    var editionDisplayLabel: String {
        Self.normalizedEditionLabel(Self.firstNonEmpty(editionRaw, edition))
    }

    init(
        fileId: Int,
        fileName: String?,
        resolution: String?,
        codecVideo: String?,
        codecAudio: String?,
        hdr: Bool?,
        container: String?,
        fileSize: Int64?,
        duration: Double?,
        bitrate: Int?,
        videoTracks: [VideoTrack]?,
        audioTracks: [AudioTrack]?,
        subtitleTracks: [SubtitleTrack]?,
        chapters: [VersionChapter]?,
        intro: TimeRange? = nil,
        credits: TimeRange? = nil,
        presentationKind: String? = nil,
        presentationGroupKey: String? = nil,
        presentationPartIndex: Int? = nil,
        presentationPartTotal: Int? = nil,
        editionRaw: String? = nil,
        editionKey: String? = nil,
        edition: String? = nil,
        effectiveAudioTrackIndex: Int? = nil,
        effectiveAudioLanguage: String? = nil
    ) {
        self.fileId = fileId
        self.fileName = fileName
        self.resolution = resolution
        self.codecVideo = codecVideo
        self.codecAudio = codecAudio
        self.hdr = hdr
        self.container = container
        self.fileSize = fileSize
        self.duration = duration
        self.bitrate = bitrate
        self.videoTracks = videoTracks
        self.audioTracks = audioTracks
        self.subtitleTracks = subtitleTracks
        self.chapters = chapters
        self.intro = intro
        self.credits = credits
        self.presentationKind = presentationKind
        self.presentationGroupKey = presentationGroupKey
        self.presentationPartIndex = presentationPartIndex
        self.presentationPartTotal = presentationPartTotal
        self.editionRaw = editionRaw
        self.editionKey = editionKey
        self.edition = edition
        self.effectiveAudioTrackIndex = effectiveAudioTrackIndex
        self.effectiveAudioLanguage = effectiveAudioLanguage
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        fileId = try c.decode(Int.self, forKey: .fileId)
        fileName = try c.decodeIfPresent(String.self, forKey: .fileName)
        resolution = try c.decodeIfPresent(String.self, forKey: .resolution)
        codecVideo = try c.decodeIfPresent(String.self, forKey: .codecVideo)
        codecAudio = try c.decodeIfPresent(String.self, forKey: .codecAudio)
        hdr = try c.decodeIfPresent(Bool.self, forKey: .hdr)
        container = try c.decodeIfPresent(String.self, forKey: .container)
        fileSize = try c.decodeIfPresent(Int64.self, forKey: .fileSize)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration)
        bitrate = try c.decodeIfPresent(Int.self, forKey: .bitrate)
        videoTracks = try c.decodeIfPresent([VideoTrack].self, forKey: .videoTracks)
        audioTracks = try c.decodeIfPresent([AudioTrack].self, forKey: .audioTracks)
        subtitleTracks = try c.decodeIfPresent([SubtitleTrack].self, forKey: .subtitleTracks)
        chapters = try c.decodeIfPresent([VersionChapter].self, forKey: .chapters)
        intro = try c.decodeIfPresent(TimeRange.self, forKey: .intro)
        credits = try c.decodeIfPresent(TimeRange.self, forKey: .credits)
        presentationKind = try c.decodeIfPresent(String.self, forKey: .presentationKind)
        presentationGroupKey = try c.decodeIfPresent(String.self, forKey: .presentationGroupKey)
        presentationPartIndex = try c.decodeIfPresent(Int.self, forKey: .presentationPartIndex)
        presentationPartTotal = try c.decodeIfPresent(Int.self, forKey: .presentationPartTotal)
        editionRaw = try c.decodeIfPresent(String.self, forKey: .editionRaw)
        editionKey = try c.decodeIfPresent(String.self, forKey: .editionKey)
        edition = try c.decodeIfPresent(String.self, forKey: .edition)
        effectiveAudioTrackIndex = try c.decodeIfPresent(Int.self, forKey: .effectiveAudioTrackIndex)
        effectiveAudioLanguage = try c.decodeIfPresent(String.self, forKey: .effectiveAudioLanguage)
    }

    private static func normalizedEditionLabel(_ raw: String?) -> String {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "Standard" : trimmed
    }

    private static func firstNonEmpty(_ values: String?...) -> String? {
        values.first { value in
            guard let value else { return false }
            return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        } ?? nil
    }
}

struct VersionChapter: Codable, Hashable {
    let index: Int
    let title: String?
    let startSeconds: Double
    let endSeconds: Double?
    let source: String?
    let thumbnailUrl: String?
    let thumbnailThumbhash: String?
}

struct VideoTrack: Codable, Identifiable, Hashable {
    let index: Int?
    let codec: String?
    let width: Int?
    let height: Int?
    /// Server emits this as a string (e.g. "23.976"), not a number.
    let frameRate: String?
    let bitrate: Int?
    let profile: String?
    let level: Int?
    let bitDepth: Int?
    let colorRange: String?
    let colorSpace: String?
    let colorPrimaries: String?
    let colorTransfer: String?
    let videoRange: String?
    let dolbyVision: String?
    let title: String?
    let language: String?
    var id: Int { index ?? 0 }
}

struct AudioTrack: Codable, Identifiable, Hashable {
    let index: Int?
    let codec: String?
    let channels: Int?
    /// Server field is `layout`, not `channel_layout`.
    let channelLayout: String?
    let bitrate: Int?
    let sampleRate: Int?
    let language: String?
    let title: String?
    /// Raw stream title as probed, distinct from the cleaned `title`.
    /// The server's audio-pref signature match compares both fields
    /// separately, so persisted track choices must echo each back.
    let embeddedTitle: String?
    /// Server field is the reserved word `default`.
    let isDefault: Bool?
    var id: Int { index ?? 0 }

    enum CodingKeys: String, CodingKey {
        case index
        case codec
        case channels
        case channelLayout = "layout"
        case bitrate
        case sampleRate
        case language
        case title
        case embeddedTitle
        case isDefault = "default"
    }
}

struct SubtitleTrack: Codable, Identifiable, Hashable {
    /// Optional because the server emits `"index,omitempty"` — a subtitle with
    /// stream index 0, or an external sub that has no ffmpeg stream index,
    /// arrives without the field.
    let index: Int?
    let codec: String?
    let language: String?
    let title: String?
    /// Raw stream title as probed, distinct from the cleaned `title`.
    let embeddedTitle: String?
    let forced: Bool?
    /// SDH flag — carried into persisted subtitle-pref signatures.
    let hearingImpaired: Bool?
    /// Server field is the reserved word `default`.
    let isDefault: Bool?
    let external: Bool?
    let externalPath: String?
    var id: String { "\(index ?? -1)|\(externalPath ?? "")" }

    enum CodingKeys: String, CodingKey {
        case index
        case codec
        case language
        case title
        case embeddedTitle
        case forced
        case hearingImpaired
        case isDefault = "default"
        case external
        // The API decoder runs `.convertFromSnakeCase`, which rewrites the wire
        // key `file_name` to `fileName` *before* matching CodingKeys — so the
        // raw value must be the converted camelCase form. With the old
        // `"file_name"` raw value this field never decoded, collapsing every
        // external subtitle's `id` to `"-1|"` (a collision).
        case externalPath = "fileName"
    }
}

struct SubtitleInfoBasic: Codable, Hashable {
    let source: String?
    let language: String?
    let codec: String?
    let forced: Bool?
    let title: String?
}

struct TimeRange: Codable, Hashable {
    let start: Double
    let end: Double
}

struct LeafItemUserData: Codable, Hashable {
    let played: Bool
    let isInProgress: Bool?
    let positionSeconds: Double?
    let durationSeconds: Double?
    let lastFileId: Int?
    let lastResolution: String?
    let lastHdr: Bool?
    let lastCodecVideo: String?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        played = try c.decodeIfPresent(Bool.self, forKey: .played) ?? false
        isInProgress = try c.decodeIfPresent(Bool.self, forKey: .isInProgress)
        positionSeconds = try c.decodeIfPresent(Double.self, forKey: .positionSeconds)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        lastFileId = try c.decodeIfPresent(Int.self, forKey: .lastFileId)
        lastResolution = try c.decodeIfPresent(String.self, forKey: .lastResolution)
        lastHdr = try c.decodeIfPresent(Bool.self, forKey: .lastHdr)
        lastCodecVideo = try c.decodeIfPresent(String.self, forKey: .lastCodecVideo)
    }
}

// MARK: - Playback

struct PlaybackSessionResponse: Codable {
    let sessionId: String
    let userId: Int?
    let profileId: String?
    let mediaFileId: Int?
    let playMethod: String
    /// Mutable so the session bridge can overwrite the server-returned
    /// resume point when the caller forces "Start Over" without
    /// reconstructing the whole struct.
    var position: Double
    let isPaused: Bool?
    let streamUrl: String
    let audioTrackIndex: Int?
    let durationSeconds: Double?
    var timelineOffsetSeconds: Double
    let subtitleUrls: [SubtitleUrl]?
    let playbackInfo: PlaybackInfo?

    init(
        sessionId: String,
        userId: Int?,
        profileId: String?,
        mediaFileId: Int?,
        playMethod: String,
        position: Double,
        isPaused: Bool?,
        streamUrl: String,
        audioTrackIndex: Int?,
        durationSeconds: Double?,
        timelineOffsetSeconds: Double = 0,
        subtitleUrls: [SubtitleUrl]?,
        playbackInfo: PlaybackInfo?
    ) {
        self.sessionId = sessionId
        self.userId = userId
        self.profileId = profileId
        self.mediaFileId = mediaFileId
        self.playMethod = playMethod
        self.position = position
        self.isPaused = isPaused
        self.streamUrl = streamUrl
        self.audioTrackIndex = audioTrackIndex
        self.durationSeconds = durationSeconds
        self.timelineOffsetSeconds = timelineOffsetSeconds
        self.subtitleUrls = subtitleUrls
        self.playbackInfo = playbackInfo
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sessionId = try c.decode(String.self, forKey: .sessionId)
        userId = try c.decodeIfPresent(Int.self, forKey: .userId)
        profileId = try c.decodeIfPresent(String.self, forKey: .profileId)
        mediaFileId = try c.decodeIfPresent(Int.self, forKey: .mediaFileId)
        playMethod = try c.decode(String.self, forKey: .playMethod)
        position = try c.decodeIfPresent(Double.self, forKey: .position) ?? 0
        isPaused = try c.decodeIfPresent(Bool.self, forKey: .isPaused)
        streamUrl = try c.decode(String.self, forKey: .streamUrl)
        audioTrackIndex = try c.decodeIfPresent(Int.self, forKey: .audioTrackIndex)
        durationSeconds = try c.decodeIfPresent(Double.self, forKey: .durationSeconds)
        timelineOffsetSeconds = try c.decodeIfPresent(Double.self, forKey: .timelineOffsetSeconds) ?? 0
        subtitleUrls = try c.decodeIfPresent([SubtitleUrl].self, forKey: .subtitleUrls)
        playbackInfo = try c.decodeIfPresent(PlaybackInfo.self, forKey: .playbackInfo)
    }
}

struct PlaybackInfo: Codable, Hashable {
    let streamType: String?
    let transcodeAudio: Bool?
    let videoCodec: String?
    let audioCodec: String?
}

struct SubtitleUrl: Codable, Identifiable, Hashable {
    let index: Int
    let language: String?
    let codec: String?
    let label: String?
    let source: String?
    let forced: Bool?
    let `default`: Bool?
    let hearingImpaired: Bool?
    let fontBundleUrl: String?
    let url: String
    var id: Int { index }

    init(
        index: Int,
        language: String?,
        codec: String?,
        label: String?,
        source: String?,
        forced: Bool?,
        `default`: Bool? = nil,
        hearingImpaired: Bool? = nil,
        fontBundleUrl: String? = nil,
        url: String
    ) {
        self.index = index
        self.language = language
        self.codec = codec
        self.label = label
        self.source = source
        self.forced = forced
        self.default = `default`
        self.hearingImpaired = hearingImpaired
        self.fontBundleUrl = fontBundleUrl
        self.url = url
    }
}

// MARK: - Transcode Start Response

struct TranscodeStartResponse: Codable {
    let sessionId: String
    let status: String
    let switchedFileId: Int?
    let manifestUrl: String
    let durationSeconds: Double?
    let playerStartSeconds: Double
    let timelineOffsetSeconds: Double
    let canSeekAnywhere: Bool
}

// MARK: - Watch Detail

struct WatchDetail: Codable {
    let contentId: String
    let type: String
    let title: String
    let year: Int?
    let overview: String?
    let versions: [FileVersion]
    let subtitles: [SubtitleInfoBasic]?
    let intro: TimeRange?
    let credits: TimeRange?
    let userData: LeafItemUserData?
    let seriesId: String?
    let seriesTitle: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    /// Server-resolved subtitle policy for this content. Computed from
    /// per-series → library → profile prefs cascade. Absent when the
    /// user hasn't configured anything that applies. Consumed by the
    /// player at track-discovery time to auto-pick the right track.
    let effectiveSubtitleLanguage: String?
    let effectiveSubtitleMode: String?
    let effectiveShowForcedSubtitles: Bool?
    let effectiveSubtitleTrackSignature: SubtitleTrackSignature?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        contentId = try c.decode(String.self, forKey: .contentId)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        year = try c.decodeIfPresent(Int.self, forKey: .year)
        overview = try c.decodeIfPresent(String.self, forKey: .overview)
        versions = try c.decodeIfPresent([FileVersion].self, forKey: .versions) ?? []
        subtitles = try c.decodeIfPresent([SubtitleInfoBasic].self, forKey: .subtitles)
        intro = try c.decodeIfPresent(TimeRange.self, forKey: .intro)
        credits = try c.decodeIfPresent(TimeRange.self, forKey: .credits)
        userData = try c.decodeIfPresent(LeafItemUserData.self, forKey: .userData)
        seriesId = try c.decodeIfPresent(String.self, forKey: .seriesId)
        seriesTitle = try c.decodeIfPresent(String.self, forKey: .seriesTitle)
        seasonNumber = try c.decodeIfPresent(Int.self, forKey: .seasonNumber)
        episodeNumber = try c.decodeIfPresent(Int.self, forKey: .episodeNumber)
        effectiveSubtitleLanguage = try c.decodeIfPresent(String.self, forKey: .effectiveSubtitleLanguage)
        effectiveSubtitleMode = try c.decodeIfPresent(String.self, forKey: .effectiveSubtitleMode)
        effectiveShowForcedSubtitles = try c.decodeIfPresent(Bool.self, forKey: .effectiveShowForcedSubtitles)
        effectiveSubtitleTrackSignature = try c.decodeIfPresent(SubtitleTrackSignature.self, forKey: .effectiveSubtitleTrackSignature)
    }
}

// MARK: - Collections

struct UserCollection: Codable, Identifiable {
    let id: String
    let name: String
    let collectionType: String?
    let createdAt: String?
    let description: String?
    let groupId: String?
    let sortOrder: Int?
    let itemCount: Int?
    let posterUrl: String?
    let posterThumbhash: String?
    let includeInServerCollections: Bool?
}

/// A user-defined grouping bucket for personal collections. Matches the
/// server's `/api/v1/collections` `groups[*]` shape.
struct CollectionGroup: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let slug: String?
    let defaultSortMode: String?
    let sortOrder: Int?
}

struct CollectionItemsResponse: Codable {
    let items: [BrowseItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        items = try c.decodeIfPresent([BrowseItem].self, forKey: .items) ?? []
    }
}

// MARK: - Search (uses CatalogResponse)

// MARK: - Libraries

struct Library: Codable, Identifiable, Hashable {
    let id: Int
    let name: String
    let type: String
    let sortOrder: Int?
    let posterUrl: String?

    var isMovieLibrary: Bool { SiloMediaType.isMovieLibrary(type) }
    var isAudiobookLibrary: Bool { SiloMediaType.isAudiobookLibrary(type) }
    var isSeriesLibrary: Bool { SiloMediaType.isSeries(type) }
    var isMixedLibrary: Bool { SiloMediaType.isMixedLibrary(type) }
    var isSupportedLibrary: Bool { SiloMediaType.isSupportedLibrary(type) }

    var navigationIcon: String {
        isMixedLibrary ? "square.stack.3d.up" : "rectangle.stack"
    }

    var selectedNavigationIcon: String {
        isMixedLibrary ? "square.stack.3d.up.fill" : "rectangle.stack.fill"
    }
}

struct LibrariesResponse: Codable {
    let libraries: [Library]

    init(libraries: [Library]) {
        self.libraries = libraries.filter(\.isSupportedLibrary)
    }

    init(from decoder: Decoder) throws {
        if let list = try? [Library](from: decoder) {
            libraries = list.filter(\.isSupportedLibrary)
            return
        }

        let c = try decoder.container(keyedBy: CodingKeys.self)
        libraries = try c.decodeIfPresent([Library].self, forKey: .libraries)?
            .filter(\.isSupportedLibrary) ?? []
    }
}

/// Type of a library collection. Wire values are the plural forms
/// (`regular`, `user_collections`); the catalog endpoint's `source`
/// query parameter uses the singular forms — see [catalogSource].
enum LibraryCollectionKind: String, Codable, Hashable {
    case regular
    case userCollections = "user_collections"

    /// Value to pass as the `source` query parameter when resolving
    /// collection items through the unified `/api/v1/catalog` endpoint.
    var catalogSource: String {
        switch self {
        case .regular: return "library_collection"
        case .userCollections: return "user_collection"
        }
    }
}

struct LibraryCollection: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let collectionType: String?
    let itemCount: Int?
    let posterUrl: String?
    let posterThumbhash: String?
    /// Populated when the collection was decoded inside a
    /// `LibraryTabGroup`. Flat-response cards leave this nil; treat as
    /// regular.
    let kind: LibraryCollectionKind?
    /// Creator profile id, populated only for [LibraryCollectionKind.userCollections].
    let creatorProfileId: String?

    /// Server emits `title`, not `name`. All other fields go through the
    /// shared `.convertFromSnakeCase` strategy — camelCase raw values
    /// match the strategy-converted wire keys.
    enum CodingKeys: String, CodingKey {
        case id
        case name = "title"
        case collectionType
        case itemCount
        case posterUrl
        case posterThumbhash
        case kind
        case creatorProfileId
    }

    /// Convenience initializer for code that constructs from a wire
    /// payload (e.g. flat fallback path) without round-tripping JSON.
    init(
        id: String,
        name: String,
        collectionType: String? = nil,
        itemCount: Int? = nil,
        posterUrl: String? = nil,
        posterThumbhash: String? = nil,
        kind: LibraryCollectionKind? = nil,
        creatorProfileId: String? = nil
    ) {
        self.id = id
        self.name = name
        self.collectionType = collectionType
        self.itemCount = itemCount
        self.posterUrl = posterUrl
        self.posterThumbhash = posterThumbhash
        self.kind = kind
        self.creatorProfileId = creatorProfileId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        collectionType = try c.decodeIfPresent(String.self, forKey: .collectionType)
        itemCount = try c.decodeIfPresent(Int.self, forKey: .itemCount)
        posterUrl = try c.decodeIfPresent(String.self, forKey: .posterUrl)
        posterThumbhash = try c.decodeIfPresent(String.self, forKey: .posterThumbhash)
        // Tolerate unknown raw values by decoding through String first —
        // unrecognized kinds become nil rather than aborting the whole
        // collection decode.
        if let raw = try c.decodeIfPresent(String.self, forKey: .kind) {
            kind = LibraryCollectionKind(rawValue: raw)
        } else {
            kind = nil
        }
        creatorProfileId = try c.decodeIfPresent(String.self, forKey: .creatorProfileId)
    }
}

/// Runtime-synthesized response from `ContinuumAPI.libraryCollections`.
/// Not decoded from wire JSON directly — `LibraryCollectionsWireResponse`
/// handles that and is mapped into this shape at the API boundary.
struct LibraryCollectionsResponse {
    let collections: [LibraryCollection]
    /// Ordered render sections. Empty when the server returned a flat
    /// response — use [resolvedSections] to get a render-ready list that
    /// transparently wraps the flat case.
    let sections: [LibraryCollectionSection]

    /// Render-ready sections: server-provided groups when present,
    /// otherwise a single anonymous section wrapping the flat list.
    var resolvedSections: [LibraryCollectionSection] {
        if !sections.isEmpty { return sections }
        if collections.isEmpty { return [] }
        return [LibraryCollectionSection(
            id: "__flat__",
            name: "",
            kind: .regular,
            collections: collections
        )]
    }
}

// MARK: - Seasons / Episodes

struct SeasonsResponse: Codable {
    let seasons: [Season]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        seasons = try c.decodeIfPresent([Season].self, forKey: .seasons) ?? []
    }
}

struct EpisodesResponse: Codable {
    let episodes: [EpisodeListItem]

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        episodes = try c.decodeIfPresent([EpisodeListItem].self, forKey: .episodes) ?? []
    }
}

// MARK: - Progress Report (sent to server)

struct ProgressReport: Codable {
    let position: Double
    let isPaused: Bool
}

struct SyncProgressRequest: Codable {
    let items: [SyncProgressItem]
}

struct SyncProgressItem: Codable {
    let mediaItemId: String
    let position: Double
    let duration: Double
    let forceOverwrite: Bool
    /// Client **event** time for offline-queued items (RFC3339). Present →
    /// last-write-wins merge on the bounded event time; absent → server
    /// uses `now()`. See §5.1 of `docs/download-api.md`.
    let updatedAt: Date?

    init(
        mediaItemId: String,
        position: Double,
        duration: Double,
        forceOverwrite: Bool,
        updatedAt: Date? = nil
    ) {
        self.mediaItemId = mediaItemId
        self.position = position
        self.duration = duration
        self.forceOverwrite = forceOverwrite
        self.updatedAt = updatedAt
    }
}

// MARK: - Playback Start Request (sent to server)

/// Body for POST /api/v1/playback/start.
///
/// Server shape is **flat** — there is no `client_capabilities` wrapper
/// (see `Continuum/internal/api/handlers/playback.go::startPlaybackRequest`).
/// Apple normally requests the selected original file (`playMethod == direct`)
/// and performs route selection locally. `preserveDirectAudioSelection` tells
/// the server not to remux solely to map a selected embedded audio track.
struct StartPlaybackRequest: Codable {
    let fileId: Int
    let profileId: String?
    let playMethod: String?
    let startPosition: Double?
    let audioTrackIndex: Int?
    let preserveDirectAudioSelection: Bool
    let codecsVideo: [String]
    let codecsAudio: [String]
    let containers: [String]
    let maxResolution: String?
    let hdr: Bool
    /// Audiobooks only: the session's file-local position must not overwrite
    /// the book-level resume point, which the client reports separately via
    /// `/api/v1/sync/progress` on the whole-book timeline.
    var disableProgressPersistence: Bool?
}

struct TranscodeStartRequest: Codable {
    let sessionId: String
    let seekSeconds: Double
    let targetResolution: String?
    let targetCodecVideo: String?
    let targetCodecAudio: String?
    let targetBitrateKbps: Int
    let segmentDuration: Int
    let subtitleTrackIndex: Int
    let subtitleBurnIn: Bool
}

// MARK: - Collection Create

struct CreateCollectionRequest: Codable {
    let name: String
    let collectionType: String
}

// MARK: - User Info

struct UserInfo: Codable {
    let id: String?
    let username: String
    let isAdmin: Bool?
}

// MARK: - Collections Response (array wrapper)

/// Server payload for `GET /api/v1/collections`. The server emits both
/// `collections` and `groups` arrays alongside each other; the latter is
/// optional for backward compatibility with older deployments.
struct CollectionsResponse: Codable {
    let collections: [UserCollection]?
    let groups: [CollectionGroup]?

    init(collections: [UserCollection]?, groups: [CollectionGroup]?) {
        self.collections = collections
        self.groups = groups
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        collections = try c.decodeIfPresent([UserCollection].self, forKey: .collections)
        groups = try c.decodeIfPresent([CollectionGroup].self, forKey: .groups)
    }
}

// MARK: - Collection group requests

struct CreateCollectionGroupRequest: Codable {
    let name: String
    let slug: String?
}

struct UpdateCollectionGroupRequest: Codable {
    let name: String?
}

/// Move-to-group payload. Always serializes `group_id`, including the
/// JSON `null` literal when [groupId] is nil — the server needs to
/// distinguish "clear group" from "don't change group", and the default
/// synthesized `encode(to:)` would otherwise drop the nil via
/// `encodeIfPresent`.
struct UpdateUserCollectionGroupBody: Encodable {
    let groupId: String?

    enum CodingKeys: String, CodingKey {
        case groupId
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let groupId {
            try c.encode(groupId, forKey: .groupId)
        } else {
            try c.encodeNil(forKey: .groupId)
        }
    }
}

struct ReorderCollectionsRequest: Codable {
    let orderedIds: [String]
    let groupId: String?
}

struct ReorderCollectionGroupsRequest: Codable {
    let orderedIds: [String]
}

// MARK: - Settings (generic key/value)

/// Generic user-setting envelope returned by `GET /api/v1/settings/{key}`.
struct SettingEntryResponse: Codable {
    let key: String
    let value: String
}

/// PUT body for `/api/v1/settings/{key}` and `/api/v1/settings/device/{key}`.
struct SetSettingBody: Codable {
    let value: String
}

/// Server-wide overlay configuration. `defaults` is a JSON-stringified
/// `CardOverlayPrefs` document the admin set as the baseline for users
/// who haven't customized; absent when no baseline is configured.
struct OverlayConfigResponse: Codable {
    let enabled: Bool
    let defaults: String?
}
