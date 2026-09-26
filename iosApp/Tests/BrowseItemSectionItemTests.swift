import Foundation
import XCTest
@testable import Silo

/// `BrowseItem(sectionItem:)` lifts a Home row into the catalog shape for
/// Watch Party's picker, and `BrowseItem` decodes through synthesized
/// `Decodable`. Both must keep producing what the catalog decode produces.
final class BrowseItemSectionItemTests: XCTestCase {
    private let decoder = HTTPClient.makeJSONDecoder(artworkServerURL: URL(string: "https://a.example/base"))

    func testSectionItemLiftMatchesCatalogDecodeOfTheSameRow() throws {
        // Every field the two types share, with non-default values. No
        // added_at, release_date or last_air_date: section rows do not carry
        // them, so the catalog decode would differ by design.
        let row = Data(#"""
        {
          "content_id": "movie:heat-1995",
          "type": "movie",
          "title": "Heat",
          "year": 1995,
          "genres": ["Crime", "Thriller"],
          "content_rating": "R",
          "status": "available",
          "rating_imdb": 8.3,
          "rating_tmdb": 7.9,
          "rating_rt_critic": 88,
          "rating_rt_audience": 94,
          "runtime": 170,
          "original_language": "en",
          "studios": ["Warner Bros."],
          "networks": ["HBO"],
          "show_status": "ended",
          "overview": "A thief and a detective.",
          "poster_url": "/art/poster.jpg?sig=a%2Fb",
          "poster_thumbhash": "poster-hash",
          "backdrop_url": "/art/backdrop.jpg",
          "backdrop_thumbhash": "backdrop-hash",
          "user_state": {"played": true, "is_favorite": true, "in_watchlist": true},
          "overlay_summary": {
            "resolution": "4k",
            "hdr": "dolby_vision",
            "audio": "atmos",
            "audio_channels": "7.1",
            "video_codec": "hevc",
            "container": "mkv",
            "aspect_ratio": "2.39",
            "release_type": "bluray",
            "edition": "Director's Cut",
            "multi_audio": true,
            "multi_sub": true
          }
        }
        """#.utf8)

        let section = try decoder.decode(SectionItem.self, from: row)
        let catalog = try decoder.decode(BrowseItem.self, from: row)
        let lifted = BrowseItem(sectionItem: section)

        XCTAssertEqual(lifted, catalog)
        XCTAssertNil(lifted.addedAt)
        XCTAssertNil(lifted.releaseDate)
        XCTAssertNil(lifted.lastAirDate)
        XCTAssertTrue(try XCTUnwrap(lifted.posterUrl).hasPrefix("https://a.example/"))
        XCTAssertTrue(try XCTUnwrap(lifted.backdropUrl).hasPrefix("https://a.example/"))
    }

    func testCatalogRowDecodesWithOnlyRequiredKeysAfterSynthesizedDecoder() throws {
        let item = try decoder.decode(
            BrowseItem.self,
            from: Data(#"{"content_id":"movie:x","type":"movie","title":"X","poster_url":null}"#.utf8)
        )

        XCTAssertEqual(item.contentId, "movie:x")
        XCTAssertEqual(item.type, "movie")
        XCTAssertEqual(item.title, "X")
        XCTAssertNil(item.year)
        XCTAssertNil(item.posterUrl)
        XCTAssertNil(item.backdropUrl)
        XCTAssertNil(item.userState)
        XCTAssertNil(item.overlaySummary)
    }
}
