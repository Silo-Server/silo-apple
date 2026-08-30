import Foundation
import XCTest
@testable import Silo

final class HeroEditorialMetadataTests: XCTestCase {
    func testMovieFactsExcludeTechnicalFileMetadata() throws {
        let detail = try decodeDetail(
            """
            {
              "content_id": "movie-1",
              "type": "movie",
              "title": "Editorial Movie",
              "year": 2026,
              "runtime": 125,
              "content_rating": "  R  ",
              "genres": [" Drama ", "drama", "", "Unknown", " Sci-Fi ", "Comedy"],
              "rating_imdb": 8.4,
              "versions": [
                {
                  "file_id": 10,
                  "resolution": "2160p",
                  "codec_video": "hevc",
                  "codec_audio": "truehd",
                  "hdr": true,
                  "video_tracks": [
                    { "index": 0, "dolby_vision": "Profile 8.1" }
                  ],
                  "audio_tracks": [
                    { "index": 1, "layout": "7.1 Atmos", "default": true }
                  ],
                  "subtitle_tracks": [
                    { "index": 2, "codec": "srt", "language": "eng" }
                  ]
                }
              ]
            }
            """
        )

        XCTAssertEqual(
            PhoneHeroMetadata.movieFactsLine(from: detail),
            [.text("2026"), .text("2h 5m"), .text("★ 8.4")]
        )
        XCTAssertEqual(PhoneHeroMetadata.movieSourceTokens(from: detail), ["Movie", "Drama", "Sci-Fi"])
        XCTAssertEqual(PhoneHeroMetadata.contentRatingChip(from: detail), "R")

        let version = try XCTUnwrap(detail.versions?.first)
        XCTAssertEqual(
            DetailPlaybackFormatting.versionShortLabel(version),
            "2160p · HEVC · DV · TrueHD"
        )
    }

    func testSeriesFactsExcludeTechnicalFileMetadata() throws {
        let detail = try decodeDetail(
            """
            {
              "content_id": "series-1",
              "type": "series",
              "title": "Editorial Series",
              "year": 2024,
              "season_count": 3,
              "genres": [" Drama ", "DRAMA", "Unknown", " Mystery "],
              "content_rating": " Unknown ",
              "rating_imdb": 9.1,
              "versions": [
                {
                  "file_id": 20,
                  "resolution": "1080p",
                  "hdr": true,
                  "audio_tracks": [
                    { "index": 1, "layout": "5.1", "default": true }
                  ],
                  "subtitle_tracks": [
                    { "index": 2, "codec": "srt", "language": "eng" }
                  ]
                }
              ]
            }
            """
        )

        XCTAssertEqual(
            PhoneHeroMetadata.seriesFactsLine(from: detail),
            [.text("2024"), .text("3 Seasons"), .text("★ 9.1")]
        )
        XCTAssertEqual(PhoneHeroMetadata.seriesSourceTokens(from: detail), ["TV Show", "Drama", "Mystery"])
        XCTAssertNil(PhoneHeroMetadata.contentRatingChip(from: detail))
    }

    func testEpisodeFactsRetainEditorialOrderAndNormalizedIdentity() throws {
        let detail = try decodeDetail(
            """
            {
              "content_id": "episode-1",
              "type": "episode",
              "title": "The Episode",
              "series_title": "  The Series  ",
              "season_number": 2,
              "episode_number": 7,
              "air_date": "2026-07-29T12:00:00Z",
              "runtime": 47,
              "rating_imdb": 7.5,
              "genres": [" Drama ", "drama", " Mystery "]
            }
            """
        )

        XCTAssertEqual(
            PhoneHeroMetadata.movieSourceTokens(from: detail),
            ["Season 2 · Episode 7", "Drama"]
        )
        XCTAssertEqual(PhoneHeroMetadata.eyebrow(from: detail), "The Series")
        let facts = PhoneHeroMetadata.movieFactsLine(from: detail)
        guard let firstFact = facts.first, case let .text(airDate) = firstFact else {
            return XCTFail("Expected the air date to be the first episode fact")
        }
        XCTAssertFalse(airDate.isEmpty)
        XCTAssertEqual(Array(facts.dropFirst()), [.text("47 min"), .text("★ 7.5")])
    }

    func testInvalidIMDbRatingsAndRuntimesAreOmitted() throws {
        let zeroDetail = try decodeDetail(
            """
            {
              "content_id": "movie-zero",
              "type": "movie",
              "title": "Zero",
              "year": 2026,
              "runtime": 0,
              "rating_imdb": 0
            }
            """
        )
        let highDetail = try decodeDetail(
            """
            {
              "content_id": "movie-high",
              "type": "movie",
              "title": "High",
              "runtime": -5,
              "rating_imdb": 10.1
            }
            """
        )

        XCTAssertEqual(PhoneHeroMetadata.movieFactsLine(from: zeroDetail), [.text("2026")])
        XCTAssertEqual(PhoneHeroMetadata.movieFactsLine(from: highDetail), [])
        XCTAssertNil(HeroEditorialMetadata.imdbRatingText(-1))
        XCTAssertNil(HeroEditorialMetadata.imdbRatingText(.nan))
        XCTAssertNil(HeroEditorialMetadata.imdbRatingText(.infinity))
        XCTAssertEqual(HeroEditorialMetadata.imdbRatingText(10), "10.0")
    }

    func testSharedNormalizationTrimsDeduplicatesFiltersAndCapsGenres() {
        XCTAssertEqual(
            HeroEditorialMetadata.normalizedGenres(
                [" Drama ", "drama", "", " Unknown ", "\nSci-Fi\t", "Comedy"],
                limit: 2
            ),
            ["Drama", "Sci-Fi"]
        )
        XCTAssertEqual(HeroEditorialMetadata.normalizedGenres(["Drama"], limit: 0), [])
        XCTAssertNil(HeroEditorialMetadata.normalizedValue(" \n "))
        XCTAssertNil(HeroEditorialMetadata.normalizedValue(" unknown "))
        XCTAssertEqual(HeroEditorialMetadata.normalizedValue(" TV-MA "), "TV-MA")
    }

    func testBrowseMetadataUsesEditorialPriorityAndTwoNormalizedGenres() {
        XCTAssertEqual(
            HeroEditorialMetadata.browseMetadataParts(
                year: 2026,
                runtime: "2h 5m",
                imdbRating: 8.4,
                genres: [" Drama ", "drama", "Sci-Fi", "Comedy"]
            ),
            ["2026", "2h 5m", "8.4", "Drama", "Sci-Fi"]
        )
    }

    func testEpisodeIdentityRejectsInvalidNumbersAndHandlesSpecials() {
        XCTAssertEqual(
            HeroEditorialMetadata.episodeIdentity(season: 0, episode: 5, style: .detail),
            "Specials · Episode 5"
        )
        XCTAssertEqual(
            HeroEditorialMetadata.episodeIdentity(season: 2, episode: 7, style: .compact),
            "S2 E7"
        )
        XCTAssertNil(
            HeroEditorialMetadata.episodeIdentity(season: -1, episode: 0, style: .detail)
        )
    }

    private func decodeDetail(_ json: String) throws -> ItemDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data(json.utf8))
    }
}
