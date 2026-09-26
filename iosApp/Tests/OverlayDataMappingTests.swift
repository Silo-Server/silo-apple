import XCTest
@testable import Silo

/// `OverlayData.from` is one mapper for the three item shapes that carry
/// overlay fields (F126). The same payload must give the same badges whether
/// it arrives as a catalog item, a Home row item or an item detail.
final class OverlayDataMappingTests: XCTestCase {
    private let payload = #"""
    {
      "contentId": "movie:1", "type": "movie", "title": "Synthetic",
      "year": 2024, "runtime": 128, "contentRating": "PG-13", "originalLanguage": "ja",
      "ratingImdb": 7.9, "ratingTmdb": 8.1, "ratingRtCritic": 91, "ratingRtAudience": 84,
      "studios": ["", "Studio A", "Studio B"], "networks": [], "showStatus": "Ended",
      "overlaySummary": {
        "resolution": "2160p", "hdr": "DV", "audio": "TrueHD", "audioChannels": "7.1",
        "videoCodec": "hevc", "container": "mkv", "aspectRatio": "2.39:1",
        "releaseType": "bluray", "edition": "Director's Cut", "multiAudio": true, "multiSub": false
      }
    }
    """#

    private var expected: OverlayData {
        var data = OverlayData()
        data.resolution = "2160p"
        data.hdr = "DV"
        data.audio = "TrueHD"
        data.audioChannels = "7.1"
        data.videoCodec = "hevc"
        data.container = "mkv"
        data.aspectRatio = "2.39:1"
        data.releaseType = "bluray"
        data.edition = "Director's Cut"
        data.multiAudio = true
        data.multiSub = false
        data.ratingImdb = 7.9
        data.ratingTmdb = 8.1
        data.ratingRtCritic = 91
        data.ratingRtAudience = 84
        data.contentRating = "PG-13"
        data.year = 2024
        data.runtime = 128
        data.originalLanguage = "ja"
        // The first non-empty studio; an empty network list has none.
        data.studio = "Studio A"
        data.network = nil
        data.showStatus = "Ended"
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(type, from: Data(json.utf8))
    }

    func testEveryItemShapeMapsTheSameOverlayFields() throws {
        XCTAssertEqual(OverlayData.from(try decode(BrowseItem.self, payload)), expected)
        XCTAssertEqual(OverlayData.from(try decode(SectionItem.self, payload)), expected)
        XCTAssertEqual(OverlayData.from(try decode(ItemDetail.self, payload)), expected)
    }

    func testMissingFieldsStayEmpty() throws {
        let bare = #"{"contentId":"movie:2","type":"movie","title":"Bare"}"#
        XCTAssertEqual(OverlayData.from(try decode(BrowseItem.self, bare)), OverlayData())
        XCTAssertEqual(OverlayData.from(try decode(SectionItem.self, bare)), OverlayData())
        XCTAssertEqual(OverlayData.from(try decode(ItemDetail.self, bare)), OverlayData())
    }
}
