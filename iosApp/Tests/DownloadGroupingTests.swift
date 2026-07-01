import XCTest
import Foundation
@testable import Silo

/// Pure-logic coverage for the Downloads redesign grouping/sorting rules
/// (`DownloadGroupBuilder`). These are the highest-risk new behaviors:
/// season ordering (newest-first, specials last), episode ordering, watched
/// counts, title resolution, and list sort options.
final class DownloadGroupingTests: XCTestCase {

    // MARK: - Factories

    private func episode(
        _ id: String,
        series: String,
        season: Int,
        number: Int,
        bytes: Int64,
        title: String? = nil,
        seriesTitle: String? = nil,
        status: LocalDownloadStatus = .completed
    ) -> DownloadRecord {
        DownloadRecord(
            id: id,
            contentId: series,
            episodeId: "\(id)-leaf",
            batchId: nil,
            mediaFileId: 0,
            format: "original",
            serverStatus: "ready",
            localStatus: status,
            fileSize: bytes,
            bytesDownloaded: bytes,
            mediaFilename: "media.mp4",
            manifestFilename: "manifest.json",
            posterFilename: nil,
            backdropFilename: nil,
            logoFilename: nil,
            subtitleFilenames: [:],
            title: title ?? "Episode \(number)",
            subtitle: "S\(season) · E\(number)",
            type: "episode",
            seriesId: series,
            seriesTitle: seriesTitle,
            seasonNumber: season,
            episodeNumber: number,
            posterThumbhash: nil,
            container: "mp4",
            stableIdentity: nil,
            registeredAt: Date(timeIntervalSince1970: 1_000_000 + Double(season * 100 + number)),
            downloadedAt: nil,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

    private func movie(_ id: String, bytes: Int64, title: String) -> DownloadRecord {
        DownloadRecord(
            id: id,
            contentId: id,
            episodeId: nil,
            batchId: nil,
            mediaFileId: 0,
            format: "original",
            serverStatus: "ready",
            localStatus: .completed,
            fileSize: bytes,
            bytesDownloaded: bytes,
            mediaFilename: "media.mp4",
            manifestFilename: "manifest.json",
            posterFilename: nil,
            backdropFilename: nil,
            logoFilename: nil,
            subtitleFilenames: [:],
            title: title,
            subtitle: "2024",
            type: "movie",
            seriesId: nil,
            seriesTitle: nil,
            seasonNumber: nil,
            episodeNumber: nil,
            posterThumbhash: nil,
            container: "mp4",
            stableIdentity: nil,
            registeredAt: Date(timeIntervalSince1970: 1_000_000),
            downloadedAt: nil,
            lastError: nil,
            retryCount: 0,
            taskIdentifier: nil
        )
    }

    private func groups(
        _ records: [DownloadRecord],
        watched: Set<String> = [],
        seriesTitle: @escaping (String) -> String? = { _ in nil },
        monitored: Set<String> = []
    ) -> [DownloadSeriesGroup] {
        DownloadGroupBuilder.seriesGroups(
            from: records,
            isWatched: { watched.contains($0.leafMediaItemId) },
            seriesTitle: seriesTitle,
            isMonitored: { monitored.contains($0) }
        )
    }

    // MARK: - Grouping

    func testGroupsEpisodesBySeriesAndExcludesMovies() {
        let records = [
            episode("a", series: "show", season: 1, number: 1, bytes: 100),
            episode("b", series: "show", season: 1, number: 2, bytes: 200),
            movie("m", bytes: 999, title: "A Movie"),
        ]
        let result = groups(records)
        XCTAssertEqual(result.count, 1, "movies must not produce a series group")
        XCTAssertEqual(result.first?.seriesId, "show")
        XCTAssertEqual(result.first?.episodeCount, 2)
        XCTAssertEqual(result.first?.totalBytes, 300)
    }

    func testSeasonsAreNewestFirstWithSpecialsLast() {
        let records = [
            episode("a", series: "s", season: 1, number: 1, bytes: 1),
            episode("b", series: "s", season: 2, number: 1, bytes: 1),
            episode("c", series: "s", season: 0, number: 1, bytes: 1),
        ]
        let group = groups(records).first
        XCTAssertEqual(group?.seasons.map(\.seasonNumber), [2, 1, 0])
    }

    func testEpisodesWithinSeasonSortedByNumber() {
        let records = [
            episode("a", series: "s", season: 1, number: 3, bytes: 1),
            episode("b", series: "s", season: 1, number: 1, bytes: 1),
            episode("c", series: "s", season: 1, number: 2, bytes: 1),
        ]
        let season = groups(records).first?.seasons.first
        XCTAssertEqual(season?.records.map { $0.episodeNumber }, [1, 2, 3])
    }

    func testWatchedCountsAndAllWatched() {
        let records = [
            episode("a", series: "s", season: 1, number: 1, bytes: 1),
            episode("b", series: "s", season: 1, number: 2, bytes: 1),
        ]
        let partial = groups(records, watched: ["a-leaf"]).first
        XCTAssertEqual(partial?.watchedCount, 1)
        XCTAssertFalse(partial?.allWatched ?? true)

        let all = groups(records, watched: ["a-leaf", "b-leaf"]).first
        XCTAssertTrue(all?.allWatched ?? false)
    }

    func testPerSeasonTotalsAndCounts() {
        let records = [
            episode("a", series: "s", season: 2, number: 1, bytes: 100),
            episode("b", series: "s", season: 2, number: 2, bytes: 150),
            episode("c", series: "s", season: 1, number: 1, bytes: 300),
        ]
        let group = groups(records).first
        XCTAssertEqual(group?.totalBytes, 550)
        XCTAssertEqual(group?.seasons.first?.seasonNumber, 2)
        XCTAssertEqual(group?.seasons.first?.totalBytes, 250)
        XCTAssertEqual(group?.seasons.first?.episodeCount, 2)
    }

    // MARK: - Title resolution

    func testTitlePrefersRecordSeriesTitleThenSubscription() {
        let withRecordTitle = [episode("a", series: "sid", season: 1, number: 1, bytes: 1, seriesTitle: "The Show")]
        XCTAssertEqual(groups(withRecordTitle, seriesTitle: { _ in "Fallback" }).first?.title, "The Show")

        let withoutRecordTitle = [episode("a", series: "sid", season: 1, number: 1, bytes: 1)]
        XCTAssertEqual(groups(withoutRecordTitle, seriesTitle: { _ in "Sub Title" }).first?.title, "Sub Title")
    }

    func testMonitoredFlagThreadedThrough() {
        let records = [episode("a", series: "sid", season: 1, number: 1, bytes: 1)]
        XCTAssertTrue(groups(records, monitored: ["sid"]).first?.isMonitored ?? false)
        XCTAssertFalse(groups(records).first?.isMonitored ?? true)
    }

    // MARK: - List sorting

    func testSortLargestFirst() {
        let items: [DownloadListItem] = [
            .movie(movie("a", bytes: 100, title: "A")),
            .movie(movie("b", bytes: 300, title: "B")),
            .movie(movie("c", bytes: 200, title: "C")),
        ]
        XCTAssertEqual(
            DownloadGroupBuilder.sorted(items, by: .largestFirst).map(\.totalBytes),
            [300, 200, 100]
        )
    }

    func testSortAlphabeticalIsCaseInsensitive() {
        let items: [DownloadListItem] = [
            .movie(movie("a", bytes: 1, title: "Zodiac")),
            .movie(movie("b", bytes: 1, title: "arrival")),
            .movie(movie("c", bytes: 1, title: "Dune")),
        ]
        XCTAssertEqual(
            DownloadGroupBuilder.sorted(items, by: .alphabetical).map(\.sortTitle),
            ["arrival", "Dune", "Zodiac"]
        )
    }
}
