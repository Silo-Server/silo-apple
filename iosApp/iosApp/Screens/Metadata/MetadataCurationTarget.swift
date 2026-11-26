#if os(iOS)
import Foundation

/// Identifies a catalog item targeted by a metadata management flow (movie,
/// series, season, or episode) and carries any already-loaded context.
struct MetadataCurationTarget: Identifiable, Hashable, Sendable {
    let contentId: String
    /// Canonical server media type: `"movie"`, `"series"`, `"season"`, `"episode"`, etc.
    let mediaType: String
    let title: String
    let year: Int?
    let libraryId: Int?
    let seriesId: String?
    let seasonNumber: Int?
    let episodeNumber: Int?
    let status: String?
    let posterUrl: String?
    let backdropUrl: String?
    let logoUrl: String?
    let folderPaths: [String]
    let fileNames: [String]

    var id: String { contentId }

    var displayTitle: String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        if mediaType == "season", let seasonNumber {
            return seasonNumber == 0
                ? AppLanguage.string(.detailSpecials)
                : AppLanguage.string(.detailSeason(LocaleFormat.integer(seasonNumber)))
        }
        if mediaType == "episode", let seasonNumber, let episodeNumber {
            return EpisodeLabel.code(season: seasonNumber, episode: episodeNumber, style: .dotted)
        }
        return contentId
    }

    var isMatched: Bool {
        status?.lowercased() != "unmatched"
    }

    /// Explicit allow-list so non-video detail fallbacks never show Fix Match.
    var supportsFixMatch: Bool {
        mediaType == "movie" || mediaType == "series"
    }

    var supportsArtwork: Bool {
        !MetadataImageSlot.slots(forMediaType: mediaType).isEmpty
    }

    var supportsEditMetadata: Bool {
        ["movie", "series", "season", "episode"].contains(mediaType)
    }

    var supportsRefresh: Bool {
        supportsEditMetadata
    }

    /// Permitted card-level curation capabilities for the active profile.
    struct CardCapabilities: Equatable, Sendable {
        let canFixMatch: Bool
        let canChooseArtwork: Bool

        var hasAny: Bool { canFixMatch || canChooseArtwork }
    }

    @MainActor
    func cardCapabilities(
        using authority: MetadataCurationAuthorityStore = .shared
    ) -> CardCapabilities {
        CardCapabilities(
            canFixMatch: authority.canCurateMetadata && supportsFixMatch,
            canChooseArtwork: authority.canEditArtwork && supportsArtwork
        )
    }

    // MARK: - Factories

    static func from(detail: ItemDetail, libraryId: Int? = nil) -> MetadataCurationTarget {
        let files = (detail.versions ?? [])
            .compactMap(\.fileName)
            .filter { !$0.isEmpty }
        let normalized = normalizedType(detail.type)
        return MetadataCurationTarget(
            contentId: detail.contentId,
            mediaType: normalized,
            title: detail.title,
            year: detail.year,
            libraryId: libraryId,
            seriesId: detail.seriesId ?? (normalized == "series" ? detail.contentId : nil),
            seasonNumber: detail.seasonNumber,
            episodeNumber: detail.episodeNumber,
            status: detail.status,
            posterUrl: detail.posterUrl,
            backdropUrl: detail.backdropUrl,
            logoUrl: detail.logoUrl,
            folderPaths: detail.folderPaths ?? [],
            fileNames: files
        )
    }

    static func from(
        season: Season,
        seriesDetail: ItemDetail,
        libraryId: Int? = nil,
        locale: Locale = AppLanguage.formattingLocale
    ) -> MetadataCurationTarget {
        MetadataCurationTarget(
            contentId: season.contentId,
            mediaType: "season",
            title: season.displayName(locale: locale),
            year: nil,
            libraryId: libraryId,
            seriesId: seriesDetail.seriesId ?? seriesDetail.contentId,
            seasonNumber: season.seasonNumber,
            episodeNumber: nil,
            status: seriesDetail.status,
            posterUrl: season.posterUrl,
            backdropUrl: seriesDetail.backdropUrl,
            logoUrl: nil,
            folderPaths: [],
            fileNames: []
        )
    }

    static func from(
        episode: EpisodeListItem,
        seriesDetail: ItemDetail,
        libraryId: Int? = nil,
        locale: Locale = AppLanguage.formattingLocale
    ) -> MetadataCurationTarget {
        let code = EpisodeLabel.code(
            season: episode.seasonNumber,
            episode: episode.episodeNumber,
            style: .dotted,
            locale: locale
        )
        let title = (episode.title?.isEmpty == false) ? "\(code) — \(episode.title!)" : code
        return MetadataCurationTarget(
            contentId: episode.contentId,
            mediaType: "episode",
            title: title,
            year: nil,
            libraryId: libraryId,
            seriesId: seriesDetail.seriesId ?? seriesDetail.contentId,
            seasonNumber: episode.seasonNumber,
            episodeNumber: episode.episodeNumber,
            status: seriesDetail.status,
            posterUrl: episode.stillUrl,
            backdropUrl: nil,
            logoUrl: nil,
            folderPaths: [],
            fileNames: []
        )
    }

    static func fromCard(
        contentId: String,
        mediaType: String?,
        title: String,
        year: Int?,
        libraryId: Int?,
        posterUrl: String?
    ) -> MetadataCurationTarget? {
        let resolvedType = normalizedType(mediaType ?? inferredType(from: contentId))
        guard resolvedType == "movie" || resolvedType == "series" else { return nil }
        return MetadataCurationTarget(
            contentId: contentId,
            mediaType: resolvedType,
            title: title,
            year: year,
            libraryId: libraryId,
            seriesId: resolvedType == "series" ? contentId : nil,
            seasonNumber: nil,
            episodeNumber: nil,
            status: nil,
            posterUrl: posterUrl,
            backdropUrl: nil,
            logoUrl: nil,
            folderPaths: [],
            fileNames: []
        )
    }

    static func normalizedType(_ raw: String) -> String {
        let lower = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch lower {
        case "tv", "show", "series": return "series"
        case "film", "movie": return "movie"
        case "season": return "season"
        case "episode": return "episode"
        default: return lower
        }
    }

    private static func inferredType(from contentId: String) -> String {
        if contentId.hasPrefix("movie:") { return "movie" }
        if contentId.hasPrefix("series:") { return "series" }
        if contentId.hasPrefix("season:") { return "season" }
        if contentId.hasPrefix("episode:") { return "episode" }
        return ""
    }
}

/// Active metadata curation sheet presentation.
enum MetadataSheetPresentation: Identifiable, Hashable {
    case fixMatch(MetadataCurationTarget)
    case chooseArtwork(MetadataCurationTarget, initialSlot: MetadataImageSlot = .poster)
    case editMetadata(MetadataCurationTarget)

    var id: String {
        switch self {
        case .fixMatch(let target): return "fixMatch:\(target.contentId)"
        case .chooseArtwork(let target, let slot): return "artwork:\(target.contentId):\(slot.rawValue)"
        case .editMetadata(let target): return "edit:\(target.contentId)"
        }
    }

    var target: MetadataCurationTarget {
        switch self {
        case .fixMatch(let target), .chooseArtwork(let target, _), .editMetadata(let target):
            return target
        }
    }
}
#endif
