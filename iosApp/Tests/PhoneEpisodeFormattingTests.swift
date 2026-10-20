#if !os(tvOS)
import XCTest
@testable import Silo

final class PhoneEpisodeFormattingTests: XCTestCase {
    func testTitleLeadsWithSeasonAndEpisodeCode() {
        XCTAssertEqual(
            EpisodeCardCaption.railTitle(for: episode(season: 1, number: 2, title: "Pilot")),
            "S01E02 · Pilot"
        )
    }

    func testSpecialsKeepSeasonZeroCode() {
        XCTAssertEqual(
            EpisodeCardCaption.railTitle(for: episode(season: 0, number: 1, title: "Behind the Scenes")),
            "S00E01 · Behind the Scenes"
        )
    }

    func testUntitledEpisodeShowsOnlyCode() {
        XCTAssertEqual(EpisodeCardCaption.railTitle(for: episode(season: 2, number: 10, title: nil)), "S02E10")
        XCTAssertEqual(EpisodeCardCaption.railTitle(for: episode(season: 2, number: 10, title: "  ")), "S02E10")
    }

    private func episode(season: Int, number: Int, title: String?) -> EpisodeListItem {
        EpisodeListItem(
            contentId: "episode-\(season)-\(number)",
            seasonNumber: season,
            episodeNumber: number,
            title: title,
            overview: nil,
            airDate: nil,
            runtime: nil,
            imdbId: nil,
            tmdbId: nil,
            tvdbId: nil,
            stillUrl: nil,
            stillThumbhash: nil,
            userData: nil,
            files: nil
        )
    }
}
#endif
