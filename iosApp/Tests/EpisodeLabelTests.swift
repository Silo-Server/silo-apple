import XCTest
@testable import Silo

/// A series the server marks `episode_labels: "air_date"` (a sports league
/// Sportarr numbers S2026E296) names each episode by its air date; every
/// other episode, and an undated one, keeps its season and episode code.
final class EpisodeLabelTests: XCTestCase {
    private let locale = Locale(identifier: "en_US")

    func testDateLabeledEpisodeShowsItsAirDate() {
        XCTAssertEqual(
            EpisodeLabel.text(season: 2026, episode: 296, labels: "air_date", airDate: "2026-11-20", locale: locale),
            "Nov 20, 2026"
        )
    }

    func testNumberedEpisodeShowsItsCode() {
        XCTAssertEqual(
            EpisodeLabel.text(season: 1, episode: 2, labels: nil, airDate: "2026-11-20", locale: locale),
            "S01E02"
        )
    }

    func testUndatedEpisodeOfDateLabeledSeriesKeepsItsCode() {
        XCTAssertEqual(
            EpisodeLabel.text(season: 2026, episode: 296, labels: "air_date", airDate: nil, locale: locale),
            "S2026E296"
        )
    }
}
