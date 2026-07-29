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
              "rating_imdb": 8.4,
              "versions": [
                {
                  "file_id": 10,
                  "resolution": "2160p",
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
    }

    private func decodeDetail(_ json: String) throws -> ItemDetail {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data(json.utf8))
    }
}
