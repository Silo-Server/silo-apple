import Foundation
import XCTest
@testable import Silo

/// Search "All" lists episodes on servers that advertise the
/// `video_with_episodes` scope, and episode results are captioned and routed
/// like Home's episode cards (silo-apple#337).
final class SearchEpisodeResultsTests: XCTestCase {
    // MARK: Media scope

    func testAllWithoutAudiobooksIncludesEpisodesOnlyWhenTheServerSupportsIt() {
        XCTAssertEqual(SearchMediaType.all.queryValue(audiobooksEnabled: false, includesEpisodes: true),
                       "video_with_episodes")
        XCTAssertEqual(SearchMediaType.all.queryValue(audiobooksEnabled: false, includesEpisodes: false), "video")
        XCTAssertEqual(SearchMediaType.all.queryValue(audiobooksEnabled: false), "video")
    }

    func testAllWithAudiobooksSearchesEveryType() {
        XCTAssertNil(SearchMediaType.all.queryValue(audiobooksEnabled: true, includesEpisodes: true))
        XCTAssertNil(SearchMediaType.all.queryValue(audiobooksEnabled: true, includesEpisodes: false))
    }

    func testSpecificFiltersIgnoreTheEpisodeScope() {
        for audiobooksEnabled in [false, true] {
            for includesEpisodes in [false, true] {
                XCTAssertEqual(SearchMediaType.movie.queryValue(audiobooksEnabled: audiobooksEnabled,
                                                                includesEpisodes: includesEpisodes), "movie")
                XCTAssertEqual(SearchMediaType.series.queryValue(audiobooksEnabled: audiobooksEnabled,
                                                                 includesEpisodes: includesEpisodes), "series")
                XCTAssertEqual(SearchMediaType.audiobook.queryValue(audiobooksEnabled: audiobooksEnabled,
                                                                    includesEpisodes: includesEpisodes), "audiobook")
            }
        }
    }

    func testSearchFeaturesReadTheCapabilityFlags() throws {
        let decoder = HTTPClient.makeJSONDecoder()
        let current = try decoder.decode(APIv2CatalogSearchCapabilities.self, from: Data("""
        {"revision":"r","state":"available","allowed":true,"people_media_scope":true,"video_with_episodes_scope":true}
        """.utf8))
        XCTAssertEqual(CatalogSearchFeatures(current),
                       CatalogSearchFeatures(peopleMediaScope: true, videoWithEpisodesScope: true))

        // An older server omits the flag: fall back to `video`.
        let older = try decoder.decode(APIv2CatalogSearchCapabilities.self, from: Data("""
        {"revision":"r","state":"available","allowed":true,"people_media_scope":true}
        """.utf8))
        XCTAssertEqual(CatalogSearchFeatures(older),
                       CatalogSearchFeatures(peopleMediaScope: true, videoWithEpisodesScope: false))
    }

    // MARK: Episode rows

    private func page(_ items: String) throws -> APIv2CatalogPage {
        try HTTPClient.makeJSONDecoder().decode(APIv2CatalogPage.self, from: Data("""
        {"items":[\(items)],"page":{"has_more":false},"total":1,"total_exact":true}
        """.utf8))
    }

    private let episodeJSON = """
    {"content_id":"ep-1","type":"episode","title":"Pilot","year":2008,
     "series_id":"series-1","series_title":"Breaking Bad","season_number":1,"episode_number":1}
    """

    private let movieJSON = #"{"content_id":"movie-1","type":"movie","title":"Heat","year":1995}"#

    func testBrowseItemDecodesEpisodeContext() throws {
        let episode = try XCTUnwrap(try page(episodeJSON).items.first)
        XCTAssertEqual(episode.seriesId, "series-1")
        XCTAssertEqual(episode.seriesTitle, "Breaking Bad")
        XCTAssertEqual(episode.seasonNumber, 1)
        XCTAssertEqual(episode.episodeNumber, 1)

        let movie = try XCTUnwrap(try page(movieJSON).items.first)
        XCTAssertNil(movie.seriesId)
        XCTAssertNil(movie.seriesTitle)
        XCTAssertNil(movie.seasonNumber)
        XCTAssertNil(movie.episodeNumber)
    }

    func testEpisodeResultIsCaptionedWithSeriesAndEpisodeCode() throws {
        let episode = try XCTUnwrap(try page(episodeJSON).items.first)
        XCTAssertEqual(EpisodeCardCaption.cardTitle(for: episode), "Breaking Bad")
        XCTAssertEqual(EpisodeCardCaption.line(for: episode), "S01E01 · Pilot")
        XCTAssertEqual(EpisodeCardCaption.accessibilityLabel(for: episode), "Season 1, Episode 1, Pilot")

        // The same caption a Home row gives the episode.
        let homeCard = SectionItem(browseItem: episode)
        XCTAssertEqual(EpisodeCardCaption.cardTitle(for: homeCard), "Breaking Bad")
        XCTAssertEqual(EpisodeCardCaption.line(for: homeCard), "S01E01 · Pilot")
    }

    func testEpisodeWithoutSeriesTitleKeepsItsOwnTitle() throws {
        let episode = try XCTUnwrap(try page(
            #"{"content_id":"ep-2","type":"episode","title":"Pilot","season_number":2,"episode_number":3}"#
        ).items.first)
        XCTAssertEqual(EpisodeCardCaption.cardTitle(for: episode), "Pilot")
        XCTAssertEqual(EpisodeCardCaption.line(for: episode), "S02E03 · Pilot")
    }

    func testMovieResultKeepsTitleAndYear() throws {
        let movie = try XCTUnwrap(try page(movieJSON).items.first)
        XCTAssertEqual(EpisodeCardCaption.cardTitle(for: movie), "Heat")
        XCTAssertNil(EpisodeCardCaption.line(for: movie))
        XCTAssertNil(EpisodeCardCaption.accessibilityLabel(for: movie))
    }

    // MARK: Routing

    func testEpisodeResultOpensItsSeriesOnThatEpisode() throws {
        let episode = try XCTUnwrap(try page(episodeJSON).items.first)
        guard case .itemDetail(let id, _, _, let context) = Route.itemDetail(browseItem: episode) else {
            return XCTFail("Expected item detail")
        }
        XCTAssertEqual(id, "series-1")
        XCTAssertEqual(context, SeriesDetailContext(seriesContentId: "series-1", episodeContentId: "ep-1",
                                                    seasonNumber: 1))
    }

    func testMovieResultOpensItself() throws {
        let movie = try XCTUnwrap(try page(movieJSON).items.first)
        guard case .itemDetail(let id, _, _, let context) = Route.itemDetail(browseItem: movie) else {
            return XCTFail("Expected item detail")
        }
        XCTAssertEqual(id, "movie-1")
        XCTAssertNil(context)
    }
}
