import Foundation

/// Presentation models for the redesigned Downloads screen. These are
/// derived synchronously from the flat `[DownloadRecord]` registry by
/// `DownloadManager` (see its "Grouped surface" section) so SwiftUI bodies
/// never group/aggregate inline.

/// One season's worth of downloaded leaves within a series.
struct DownloadSeasonGroup: Identifiable, Hashable, Sendable {
    /// Season number; `0` (or negative) represents Specials.
    let seasonNumber: Int
    /// Completed/revoked episode records, sorted by episode number.
    let records: [DownloadRecord]
    let totalBytes: Int64
    let watchedCount: Int

    var id: Int { seasonNumber }
    var episodeCount: Int { records.count }
    var isSpecials: Bool { seasonNumber <= 0 }
    var allWatched: Bool { !records.isEmpty && watchedCount == records.count }
}

/// All downloaded episodes for one series, grouped by season.
struct DownloadSeriesGroup: Identifiable, Hashable, Sendable {
    let seriesId: String
    let title: String
    let posterThumbhash: String?
    /// Seasons newest-first, Specials last.
    let seasons: [DownloadSeasonGroup]
    let totalBytes: Int64
    let episodeCount: Int
    let watchedCount: Int
    let isMonitored: Bool
    /// Newest registration in the group — drives "recently added" sort.
    let latestRegisteredAt: Date

    var id: String { seriesId }
    var seasonCount: Int { seasons.count }
    var allRecords: [DownloadRecord] { seasons.flatMap(\.records) }
    var allWatched: Bool { episodeCount > 0 && watchedCount == episodeCount }
}

/// Storage split for the Downloads storage hero bar.
struct DownloadStorageBreakdown: Hashable, Sendable {
    let series: Int64
    let movies: Int64
    /// Artwork, manifests, subtitles, and in-flight partials — the
    /// remainder of true on-disk usage beyond completed media.
    let other: Int64

    var total: Int64 { series + movies + other }
}

/// A single row in the Manager list: either a whole series (collapsed to
/// one expandable card) or a standalone movie.
enum DownloadListItem: Identifiable, Hashable {
    case series(DownloadSeriesGroup)
    case movie(DownloadRecord)

    var id: String {
        switch self {
        case .series(let group): return "series:" + group.seriesId
        case .movie(let record): return "movie:" + record.id
        }
    }

    var totalBytes: Int64 {
        switch self {
        case .series(let group): return group.totalBytes
        case .movie(let record): return record.fileSize
        }
    }

    var latestRegisteredAt: Date {
        switch self {
        case .series(let group): return group.latestRegisteredAt
        case .movie(let record): return record.registeredAt
        }
    }

    var sortTitle: String {
        switch self {
        case .series(let group): return group.title
        case .movie(let record): return record.title ?? record.contentId
        }
    }

    /// All download ids this row represents (a series contributes every
    /// episode id) — used by batch delete and select-mode tallies.
    var downloadIds: [String] {
        switch self {
        case .series(let group): return group.allRecords.map(\.id)
        case .movie(let record): return [record.id]
        }
    }
}

/// Pure grouping/sorting for the Downloads Manager. Kept free of
/// `DownloadManager` state (watched/title/monitored are injected as
/// closures) so the ordering rules are unit-testable in isolation.
enum DownloadGroupBuilder {
    /// Group episode records (those with a `seriesId`) into per-series,
    /// per-season cards. Records without a `seriesId` (movies) are ignored.
    static func seriesGroups(
        from records: [DownloadRecord],
        isWatched: (DownloadRecord) -> Bool,
        seriesTitle: (String) -> String?,
        isMonitored: (String) -> Bool
    ) -> [DownloadSeriesGroup] {
        let episodes = records.filter { $0.seriesId != nil }
        return Dictionary(grouping: episodes) { $0.seriesId! }
            .map { seriesId, recs in
                makeSeriesGroup(
                    seriesId: seriesId,
                    records: recs,
                    isWatched: isWatched,
                    seriesTitle: seriesTitle(seriesId),
                    isMonitored: isMonitored(seriesId)
                )
            }
    }

    static func makeSeriesGroup(
        seriesId: String,
        records: [DownloadRecord],
        isWatched: (DownloadRecord) -> Bool,
        seriesTitle: String?,
        isMonitored: Bool
    ) -> DownloadSeriesGroup {
        let seasons = Dictionary(grouping: records) { $0.seasonNumber ?? 0 }
            .map { season, recs -> DownloadSeasonGroup in
                let sorted = recs.sorted { ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0) }
                return DownloadSeasonGroup(
                    seasonNumber: season,
                    records: sorted,
                    totalBytes: sorted.reduce(0) { $0 + $1.fileSize },
                    watchedCount: sorted.filter(isWatched).count
                )
            }
            .sorted { lhs, rhs in
                // Real seasons newest-first; Specials (<= 0) always last.
                if (lhs.seasonNumber <= 0) != (rhs.seasonNumber <= 0) {
                    return rhs.seasonNumber <= 0
                }
                return lhs.seasonNumber > rhs.seasonNumber
            }

        let title = records.compactMap(\.seriesTitle).first
            ?? seriesTitle
            ?? records.first?.title
            ?? seriesId

        return DownloadSeriesGroup(
            seriesId: seriesId,
            title: title,
            posterThumbhash: records.compactMap(\.posterThumbhash).first,
            seasons: seasons,
            totalBytes: records.reduce(0) { $0 + $1.fileSize },
            episodeCount: records.count,
            watchedCount: records.filter(isWatched).count,
            isMonitored: isMonitored,
            latestRegisteredAt: records.map(\.registeredAt).max() ?? .distantPast
        )
    }

    /// Order the unified list of series groups + movies.
    static func sorted(_ items: [DownloadListItem], by option: DownloadSortOption) -> [DownloadListItem] {
        items.sorted { lhs, rhs in
            switch option {
            case .largestFirst:
                return lhs.totalBytes > rhs.totalBytes
            case .recentlyAdded:
                return lhs.latestRegisteredAt > rhs.latestRegisteredAt
            case .alphabetical:
                return lhs.sortTitle.localizedCaseInsensitiveCompare(rhs.sortTitle) == .orderedAscending
            }
        }
    }
}

/// How the Downloads Manager list is ordered. Persisted in `DownloadSettings`.
enum DownloadSortOption: String, CaseIterable, Identifiable, Sendable {
    case largestFirst
    case recentlyAdded
    case alphabetical

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .largestFirst: return "Largest first"
        case .recentlyAdded: return "Recently added"
        case .alphabetical: return "Name (A–Z)"
        }
    }

    var systemImage: String {
        switch self {
        case .largestFirst: return "arrow.down.to.line"
        case .recentlyAdded: return "clock"
        case .alphabetical: return "textformat"
        }
    }
}
