#if os(iOS)
import XCTest
@testable import Silo

/// A download notification names a date-labeled game (sports) by its date and
/// matchup, so two games of one league on one day stay apart.
@MainActor
final class DownloadNotificationNameTests: XCTestCase {
    private func game(title: String) -> DownloadRecord {
        var record = DownloadRecord(
            id: "d1", contentId: "nba", episodeId: "game-1", batchId: nil, mediaFileId: "7",
            format: "original", serverStatus: "ready", localStatus: .completed, fileSize: 1, bytesDownloaded: 1,
            mediaFilename: nil, manifestFilename: nil, posterFilename: nil,
            backdropFilename: nil, logoFilename: nil, subtitleFilenames: [:], title: title,
            subtitle: nil, type: "episode", seriesId: "nba", posterThumbhash: nil,
            container: "mp4", stableIdentity: nil, registeredAt: Date(), downloadedAt: nil, lastError: nil,
            retryCount: 0, taskIdentifier: nil
        )
        record.seriesTitle = "NBA"
        record.seasonNumber = 2026
        record.episodeNumber = 296
        record.episodeLabels = "air_date"
        record.airDate = "2026-11-20"
        return record
    }

    func testDateLabeledGameIsNamedByDateAndMatchup() throws {
        let date = try XCTUnwrap(DetailDateFormatting.abbreviatedDate("2026-11-20"))
        XCTAssertEqual(
            DownloadNotifier.displayName(for: game(title: "Los Angeles Lakers vs Sacramento Kings")),
            "\(date) · Los Angeles Lakers vs Sacramento Kings"
        )
    }

    /// An untitled game was stored as "Episode 296"; the league names it.
    func testUntitledGameFallsBackToTheSeries() throws {
        let date = try XCTUnwrap(DetailDateFormatting.abbreviatedDate("2026-11-20"))
        XCTAssertEqual(
            DownloadNotifier.displayName(for: game(title: DownloadRecord.storedEpisodeName(296))),
            "\(date) · NBA"
        )
    }
}
#endif
