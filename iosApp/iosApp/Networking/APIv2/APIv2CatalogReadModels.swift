import Foundation

/// Wire-only catalog reads from the v2 contract. These models deliberately do
/// not share the legacy watch/player ID or marker decoders. Calendar dates stay
/// strings; instants use the common HTTP decoder. Unknown enum values stay strings.
enum APIv2CatalogRead {
    struct CatalogItemDetail: Decodable {
        let advisoryAge: Int64?
        let advisorySource: String?
        let airDate: String?
        let audiobook: AudiobookDetailExtension?
        let backdropThumbhash: String?
        @ArtworkURL var backdropUrl: String?
        let cast: [CastCredit]
        let contentId: String
        let contentRating: String?
        let countries: [String]?
        let credits: Marker?
        let crew: [CrewCredit]
        let effectiveShowForcedSubtitles: Bool?
        let effectiveSubtitleMode: String?
        let effectiveSubtitleTrackSignature: WatchSubtitleSignature?
        let effectiveVersionHdr: Bool?
        let effectiveVersionResolution: String?
        let episodeCount: Int64?
        let episodeNumber: Int64?
        let extras: [ItemExtraInfo]?
        let firstAirDate: String?
        let genres: [String]
        let imdbId: String?
        let intro: Marker?
        let isSpecials: Bool?
        let lastAirDate: String?
        @ArtworkURL var logoUrl: String?
        /// Localized fields ("overview", "tagline") machine-translated by AI.
        let machineTranslatedFields: [String]?
        let networks: [String]?
        let originalLanguage: String?
        let originalTitle: String?
        let overlaySummary: CatalogItemOverlay?
        let overview: String?
        let pendingTranslationLanguage: String?
        let playbackVariants: [PlaybackVariant]?
        let posterThumbhash: String?
        @ArtworkURL var posterUrl: String?
        let ratingImdb: Double?
        let ratingRtAudience: Int64?
        let ratingRtCritic: Int64?
        let ratingTmdb: Double?
        /// The external ratings a title page shows, chosen, ordered and
        /// formatted by the server. Absent from servers that predate it.
        let ratings: [CatalogRating]?
        let releaseDate: String?
        let runtime: Int64?
        let seasonCount: Int64?
        let seasonNumber: Int64?
        let seriesId: String?
        let seriesTitle: String?
        let showStatus: String?
        let sortTitle: String?
        let status: String
        let studios: [String]?
        let subtitles: [SubtitleInfo]
        let tagline: String?
        let title: String
        let tmdbId: String?
        let tvdbId: String?
        let `type`: String
        let userData: WatchRollup?
        let userState: CatalogItemUserState?
        let versions: [FileVersion]
        let videos: [ItemVideoInfo]?
        let year: Int64?
    }

    struct Season: Decodable {
        let airDate: String?
        let contentId: String
        let episodeCount: Int64
        let isSpecials: Bool?
        let machineTranslatedFields: [String]?
        let overview: String?
        let posterThumbhash: String?
        @ArtworkURL var posterUrl: String?
        let seasonNumber: Int64
        let title: String
        let userData: WatchRollup?
    }

    struct Episode: Decodable {
        let airDate: String?
        let contentId: String
        let episodeNumber: Int64
        let files: [EpisodeFile]?
        let imdbId: String?
        let machineTranslatedFields: [String]?
        let overview: String?
        let pendingTranslationLanguage: String?
        let runtime: Int64
        let seasonNumber: Int64
        let stillThumbhash: String?
        @ArtworkURL var stillUrl: String?
        let title: String
        let tmdbId: String?
        let tvdbId: String?
        let userData: WatchRollup?
    }

    struct Person: Decodable {
        let bio: String?
        let birthDate: String?
        let birthplace: String?
        let deathDate: String?
        let id: String
        let imdbId: String?
        let name: String
        let photoThumbhash: String?
        @ArtworkURL var photoUrl: String?
        let tmdbId: String?
        let tvdbId: String?
    }

    struct AudioTrack: Decodable {
        let bitrate: Int64?
        let channels: Int64?
        let codec: String?
        let `default`: Bool
        let embeddedTitle: String?
        let language: String?
        let layout: String?
        let sampleRate: Int64?
        let title: String?
    }

    struct AudiobookDetailExtension: Decodable {
        let authors: [AudiobookPerson]
        let narrators: [AudiobookPerson]
        let otherNarrations: [AudiobookNarration]
        let publisher: String?
        let related: AudiobookRelatedContent
        let series: AudiobookSeriesGroup?
        let totalDurationSeconds: Int64
    }

    struct AudiobookNarration: Decodable {
        let contentId: String
        let narrators: [String]
        let title: String
        let year: Int64?
    }

    struct AudiobookPerson: Decodable {
        let name: String
        let personId: String?
        let photoThumbhash: String?
        @ArtworkURL var photoUrl: String?
    }

    struct AudiobookRelatedContent: Decodable {
        let alsoByAuthor: [AudiobookRelatedItem]
        let similar: [AudiobookRelatedItem]
    }

    struct AudiobookRelatedItem: Decodable {
        let contentId: String
        @ArtworkURL var posterUrl: String?
        let seriesIndex: Int64?
        let title: String
        let year: Int64?
    }

    struct AudiobookSeriesGroup: Decodable {
        let entries: [AudiobookRelatedItem]
        let name: String?
    }

    struct CatalogRating: Decodable {
        let display: String
        let name: String
        let score: Double
        let source: String
    }

    struct CastCredit: Decodable {
        let character: String
        let imdbId: String?
        let name: String
        let order: Int64
        let personId: String?
        let photoThumbhash: String?
        @ArtworkURL var photoUrl: String?
        let tmdbId: String?
        let tvdbId: String?
    }

    struct CatalogItemOverlay: Decodable {
        let aspectRatio: String?
        let audio: String?
        let audioChannels: String?
        let container: String?
        let edition: String?
        let hdr: String?
        let multiAudio: Bool?
        let multiSub: Bool?
        let releaseType: String?
        let resolution: String?
        let videoCodec: String?
    }

    struct CatalogItemUserState: Decodable {
        let inWatchlist: Bool
        let isFavorite: Bool
        let played: Bool
    }

    struct CrewCredit: Decodable {
        let imdbId: String?
        let job: String
        let name: String
        let personId: String?
        let photoThumbhash: String?
        @ArtworkURL var photoUrl: String?
        let tmdbId: String?
        let tvdbId: String?
    }

    struct EpisodeFile: Decodable {
        let audioChannels: Int64?
        let codecVideo: String?
        let container: String?
        let fileId: String
        let fileSize: Int64
        let hdr: Bool
        let resolution: String?
    }

    struct FileVersion: Decodable {
        let addedAt: Date
        let audioTracks: [AudioTrack]?
        let bitrate: Int64
        let chapters: [VersionChapter]?
        let codecAudio: String
        let codecVideo: String
        let container: String
        let credits: Marker?
        let duration: Int64
        let editionKey: String?
        let editionRaw: String?
        let effectiveAudioLanguage: String?
        let effectiveAudioTrackIndex: Int64?
        let fileId: String
        let fileName: String?
        let fileSize: Int64
        let hdr: Bool
        let intro: Marker?
        let presentationGroupKey: String?
        let presentationKind: String?
        let presentationPartIndex: Int64?
        let presentationPartTotal: Int64?
        let resolution: String
        let subtitleTracks: [VersionSubtitleTrack]?
        let videoTracks: [VideoTrack]?
    }

    struct WatchMarker: Decodable {
        let startSeconds: Double
        let endSeconds: Double
    }

    struct WatchFileVersion: Decodable {
        let audioTracks: [AudioTrack]?
        let bitrate: Int64
        let chapters: [VersionChapter]?
        let codecAudio: String
        let codecVideo: String
        let container: String
        let credits: WatchMarker?
        let durationSeconds: Int64
        var duration: Int64 { durationSeconds }
        let editionKey: String?
        let editionRaw: String?
        let effectiveAudioLanguage: String?
        let effectiveAudioTrackIndex: Int64?
        let fileId: String
        let fileName: String?
        let fileSize: Int64
        let hdr: Bool
        let intro: WatchMarker?
        let presentationGroupKey: String?
        let presentationKind: String?
        let presentationPartIndex: Int64?
        let presentationPartTotal: Int64?
        let resolution: String
        let subtitleTracks: [VersionSubtitleTrack]?
        let videoTracks: [VideoTrack]?
    }

    struct WatchDetail: Decodable {
        let contentId: String
        let type: String
        let title: String
        let year: Int?
        let overview: String?
        let versions: [WatchFileVersion]
        let subtitles: [SubtitleInfo]
        let intro: WatchMarker?
        let credits: WatchMarker?
        let userData: WatchRollup?
        let seriesId: String?
        let seriesTitle: String?
        let seasonNumber: Int?
        let episodeNumber: Int?
        let effectiveSubtitleLanguage: String?
        let effectiveSubtitleMode: String?
        let effectiveShowForcedSubtitles: Bool?
        let effectiveSubtitleTrackSignature: WatchSubtitleSignature?
    }

    struct ItemExtraInfo: Decodable {
        let contentId: String
        let durationSeconds: Int64?
        // Current embedded extras schema uses a numeric ID; distinct from FileVersion.
        let fileId: Int64?
        let kind: String
        let title: String?
    }

    struct ItemVideoInfo: Decodable {
        let isOfficial: Bool
        let kind: String
        let language: String?
        let name: String?
        let site: String
        let siteKey: String
    }

    struct Marker: Decodable {
        let end: Double
        let start: Double
    }

    struct PlaybackVariant: Decodable {
        let defaultFileId: String?
        let editionKey: String?
        let editionRaw: String?
        let partCount: Int64
        let parts: [PlaybackVariantPart]
        let presentationGroupKey: String?
        let presentationKind: String?
        let totalDuration: Int64?
        let variantId: String
    }

    struct PlaybackVariantPart: Decodable {
        let defaultFileId: String?
        let partIndex: Int64
        let totalDuration: Int64?
        let versions: [FileVersion]
    }

    struct SubtitleInfo: Decodable {
        let codec: String?
        let forced: Bool
        let language: String
        let source: String
        let title: String?
    }

    struct VersionChapter: Decodable {
        let endSeconds: Double
        let index: Int64
        let source: String
        let startSeconds: Double
        let thumbnailThumbhash: String?
        @ArtworkURL var thumbnailUrl: String?
        let title: String
    }

    struct VersionSubtitleTrack: Decodable {
        let codec: String?
        let `default`: Bool
        let embeddedTitle: String?
        let external: Bool
        let fileName: String?
        let forced: Bool
        let hearingImpaired: Bool
        let index: Int64?
        let language: String?
        let title: String?
    }

    struct VideoTrack: Decodable {
        let bitDepth: Int64?
        let bitrate: Int64?
        let codec: String?
        let colorPrimaries: String?
        let colorRange: String?
        let colorSpace: String?
        let colorTransfer: String?
        let dolbyVision: String?
        let frameRate: String?
        let height: Int64?
        let level: Int64?
        let profile: String?
        let title: String?
        let videoRange: String?
        let width: Int64?
    }

    struct WatchRollup: Decodable {
        let durationSeconds: Double?
        let inProgressCount: Int64
        let isInProgress: Bool?
        let lastFileId: String?
        let lastResolution: String?
        let played: Bool
        let positionSeconds: Double?
        let unplayedCount: Int64
        let watchedCount: Int64
    }

    struct WatchSubtitleSignature: Decodable {
        let codec: String?
        let forced: Bool
        let hearingImpaired: Bool
        let label: String?
        let language: String?
        let source: String?
    }

}

/// Hierarchy and people reads are finite collections, not catalog cursor pages.
struct APIv2CatalogReadCollection<Item: Decodable>: Decodable {
    let items: [Item]
    let page: APIv2Page?

    func completeItems() throws -> [Item] {
        guard page?.hasMore != true, page?.nextCursor?.isEmpty != false else {
            throw APIv2Error.incompleteCatalogRead
        }
        return items
    }
}

/// Viewer configuration projection; IDs remain strings on the wire.
struct APIv2UserLibrary: Decodable {
    let id: String
    let name: String
    let type: String
    let sortOrder: Int
    @ArtworkURL var posterUrl: String?
}

/// Complete Discover rows use the same flat catalog-card fields as section shelves.
struct APIv2DiscoverRow: Decodable {
    let type: String
    let title: String
    let items: [SectionItem]
}

/// In-memory provenance for the existing library section consumers.
struct APIv2LibrarySectionsRead {
    let libraryId: Int
    let auth: CapturedOrdinaryRequestAuth
    let response: SectionsResponse
    var sections: [ResolvedSection] { response.sections }
}
