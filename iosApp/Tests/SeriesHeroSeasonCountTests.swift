import XCTest
@testable import Silo

/// The hero counts the seasons the library holds, not the provider's
/// `season_count`, so it agrees with the season chips below it.
final class SeriesHeroSeasonCountTests: XCTestCase {
    func testLibrarySeasonCountSkipsSpecials() throws {
        let seasons = try [season(0, isSpecials: true), season(1), season(2)]
        XCTAssertEqual(seasons.librarySeasonCount, 2)
        XCTAssertEqual(try [season(0)].librarySeasonCount, 0)
    }

#if !os(tvOS)
    func testPhoneFactsLineUsesLibrarySeasonsOverProviderTotal() throws {
        let detail = try seriesDetail(seasonCount: 5)
        let seasons = try [season(0, isSpecials: true), season(1), season(2)]
        XCTAssertEqual(
            PhoneHeroMetadata.seriesFactsLine(from: detail, seasons: seasons),
            [.text("2008"), .text("2 Seasons")]
        )
        XCTAssertEqual(
            PhoneHeroMetadata.seriesFactsLine(from: detail, seasons: try [season(1)]),
            [.text("2008"), .text("1 Season")]
        )
    }

    func testPhoneFactsLineOmitsCountUntilSeasonsLoad() throws {
        let detail = try seriesDetail(seasonCount: 5)
        XCTAssertEqual(PhoneHeroMetadata.seriesFactsLine(from: detail, seasons: []), [.text("2008")])
    }

#else
    func testTVFactsLineUsesLibrarySeasonsOverProviderTotal() throws {
        let detail = try seriesDetail(seasonCount: 5)
        let seasons = try [season(0, isSpecials: true), season(1), season(2)]
        XCTAssertEqual(
            TVHeroMetadata.seriesFactsLine(from: detail, seasons: seasons),
            [.text("2008"), .text("2 Seasons")]
        )
    }

#endif

    /// Builds a season the way the seasons read does: the server's
    /// snake_case JSON through the production decoder and projection.
    private func season(_ number: Int, isSpecials: Bool? = nil) throws -> Season {
        var object: [String: Any] = [
            "content_id": "season-\(number)", "season_number": number,
            "title": "Season \(number)", "episode_count": 8,
        ]
        if let isSpecials { object["is_specials"] = isSpecials }
        let data = try JSONSerialization.data(withJSONObject: object)
        return try Season(catalog: HTTPClient.makeJSONDecoder().decode(APIv2CatalogRead.Season.self, from: data))
    }

    private func seriesDetail(seasonCount: Int) throws -> ItemDetail {
        let json = """
        {"content_id":"series","type":"series","title":"Show","year":2008,"season_count":\(seasonCount),"versions":[]}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data(json.utf8))
    }
}
