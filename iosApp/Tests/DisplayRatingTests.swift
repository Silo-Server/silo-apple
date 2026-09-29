import XCTest
@testable import Silo

/// External ratings: the server's `ratings` row on item detail, the IMDb/TMDB
/// fallback for older servers, the one-rating card summary, and the poster
/// badge labels.
final class DisplayRatingTests: XCTestCase {

    // MARK: Fallback row (older servers)

    func testFallbackIsIMDbThenTMDB() {
        let row = DisplayRating.fallback(imdb: 8.5, tmdb: 8.25)
        XCTAssertEqual(row.map(\.source), ["imdb", "tmdb"])
        XCTAssertEqual(row.map(\.name), ["IMDb", "TMDB"])
        XCTAssertEqual(row.map(\.display), ["8.5", "8.3"])
        XCTAssertEqual(row.map(\.score), [85, 82.5])
        XCTAssertEqual(row.map(\.accessibilityText), ["IMDb 8.5", "TMDB 8.3"])
    }

    func testFallbackDropsMissingAndOutOfRangeScores() {
        XCTAssertEqual(DisplayRating.fallback(imdb: nil, tmdb: 7.6).map(\.source), ["tmdb"])
        XCTAssertEqual(DisplayRating.fallback(imdb: 7.3, tmdb: nil).map(\.source), ["imdb"])
        XCTAssertEqual(DisplayRating.fallback(imdb: nil, tmdb: nil), [])
        for unusable in [0, -1, 10.01, 85, .nan, .infinity] as [Double] {
            XCTAssertNil(DisplayRating.imdb(unusable), "\(unusable)")
            XCTAssertNil(DisplayRating.tmdb(unusable), "\(unusable)")
        }
        XCTAssertEqual(DisplayRating.imdb(10)?.display, "10.0")
    }

    func testFallbackNeverShowsRottenTomatoes() throws {
        // Item detail keeps stored RT scores for metadata editors even when
        // an administrator has RT off, so an older server's row leaves them out.
        let detail = try decodeDetail(extraFields: #""rating_imdb":8.5,"rating_tmdb":8.3,"rating_rt_critic":93,"rating_rt_audience":95"#)
        XCTAssertNil(detail.ratings)
        XCTAssertEqual(detail.displayRatings.map(\.name), ["IMDb", "TMDB"])
        XCTAssertEqual(detail.displayRatings.map(\.display), ["8.5", "8.3"])
    }

    // MARK: Server row

    func testServerRowIsShownVerbatimInServerOrder() throws {
        let detail = try decodeDetail(extraFields: """
            "rating_imdb":8.5,"rating_tmdb":8.3,"rating_rt_critic":93,
            "ratings":[
              {"source":"rt_critic","name":"RT","score":93,"display":"93%"},
              {"source":"imdb","name":"IMDb","score":85,"display":"8.5"},
              {"source":"letterboxd","name":"Letterboxd","score":84,"display":"4.2"},
              {"source":"tmdb","name":"TMDB","score":82.5,"display":"8.3"}
            ]
            """)
        let row = detail.displayRatings
        XCTAssertEqual(row.map(\.source), ["rt_critic", "imdb", "letterboxd", "tmdb"])
        XCTAssertEqual(row.map(\.name), ["RT", "IMDb", "Letterboxd", "TMDB"])
        XCTAssertEqual(row.map(\.display), ["93%", "8.5", "4.2", "8.3"])
        XCTAssertEqual(row.map(\.score), [93, 85, 84, 82.5])
        XCTAssertEqual(row.map(\.isTMDB), [false, false, false, true])
        XCTAssertEqual(row[2].accessibilityText, "Letterboxd 4.2")
    }

    func testEmptyServerRowShowsNothing() throws {
        // An empty list is the server saying there is nothing to show, not an
        // older server: the detail's own scores must not come back.
        let detail = try decodeDetail(extraFields: #""rating_imdb":8.5,"ratings":[]"#)
        XCTAssertEqual(detail.ratings, [])
        XCTAssertEqual(detail.displayRatings, [])
    }

    func testServerRowSurvivesTheDetailCache() throws {
        let detail = try decodeDetail(extraFields: #""ratings":[{"source":"tmdb","name":"TMDB","score":82,"display":"8.2"}]"#)
        let cached = try JSONDecoder().decode(ItemDetail.self, from: JSONEncoder().encode(detail))
        XCTAssertEqual(cached.ratings, detail.ratings)
    }

    // MARK: Card summary

    func testPrimaryCardIsIMDbElseTMDB() {
        XCTAssertEqual(DisplayRating.primaryCard(imdb: 7.8, tmdb: 8.1)?.accessibilityText, "IMDb 7.8")
        XCTAssertEqual(DisplayRating.primaryCard(imdb: nil, tmdb: 8.15)?.accessibilityText, "TMDB 8.2")
        XCTAssertEqual(DisplayRating.primaryCard(imdb: 0, tmdb: 6.4)?.source, "tmdb")
        XCTAssertNil(DisplayRating.primaryCard(imdb: nil, tmdb: nil))
    }

    // MARK: Formatting

    func testOneDecimalIgnoresTheDeviceLocale() {
        let german = String(format: "%.1f", locale: Locale(identifier: "de_DE"), 8.3)
        XCTAssertEqual(german, "8,3", "precondition: the German locale uses a decimal comma")
        // 8.25 is exact in binary; printf alone would round the half to even ("8.2").
        XCTAssertEqual(DisplayRating.oneDecimal(8.25), "8.3")
        XCTAssertEqual(DisplayRating.oneDecimal(8.24), "8.2")
        XCTAssertEqual(DisplayRating.oneDecimal(7), "7.0")
    }

    // MARK: Poster badges

    func testRatingBadgesCarryTheirMarkAndNoIcon() throws {
        let data = OverlayData(ratingImdb: 8.5, ratingTmdb: 8.25, ratingRtCritic: 93, ratingRtAudience: 95)
        let expected: [(OverlayId, String)] = [
            (.ratingImdb, "IMDb 8.5"),
            (.ratingTmdb, "TMDB 8.3"),
            (.ratingRt, "RT 93%"),
            (.ratingRtAudience, "RT Audience 95%"),
        ]
        for (id, label) in expected {
            let def = try XCTUnwrap(OverlayRegistry.all.first { $0.id == id }, id.rawValue)
            XCTAssertEqual(def.getValue(data), label, id.rawValue)
            XCTAssertNil(def.iconId, id.rawValue)
            XCTAssertFalse(def.iconCapable, id.rawValue)
            XCTAssertFalse(def.defaultEnabled, id.rawValue)
            XCTAssertNil(def.getValue(OverlayData()), "no score, no badge: \(id.rawValue)")
        }
    }

    #if os(tvOS)
    // MARK: Focus marquee

    func testMarqueeShowsOneMarkedRatingBeforeTimeLeft() throws {
        let item = try decodeSectionItem(#""type":"movie","ratingImdb":7.8,"ratingTmdb":8.1,"positionSeconds":600,"durationSeconds":3000"#)
        let content = TVMarqueeContent(item: item, rowTitle: "Continue Watching", isContinueWatching: true)
        XCTAssertEqual(content.rating?.accessibilityText, "IMDb 7.8")
        XCTAssertFalse(content.metaParts.contains("7.8"), "no bare score in the text tokens")
        XCTAssertEqual(content.trailingMetaParts, ["40 min left"], "time left follows the rating")
    }

    func testMarqueeFallsBackToTMDBAndSkipsEpisodes() throws {
        let movie = try decodeSectionItem(#""type":"movie","ratingTmdb":8.2"#)
        XCTAssertEqual(TVMarqueeContent(item: movie, rowTitle: "Movies").rating?.accessibilityText, "TMDB 8.2")

        let episode = try decodeSectionItem(#""type":"episode","ratingImdb":9.1"#)
        XCTAssertNil(TVMarqueeContent(item: episode, rowTitle: "Next Up").rating)
    }

    private func decodeSectionItem(_ fields: String) throws -> SectionItem {
        try JSONDecoder().decode(SectionItem.self, from: Data(
            #"{"contentId":"marquee-rating","title":"Synthetic",\#(fields)}"#.utf8))
    }
    #endif

    // MARK: Helpers

    /// A minimal v2 item detail with `extraFields` spliced in.
    private func decodeDetail(extraFields: String) throws -> ItemDetail {
        let body = #"{"content_id":"movie:ratings","type":"movie","title":"Ratings","status":"available","genres":[],"keywords":[],"cast":[],"crew":[],"versions":[],"subtitles":[],\#(extraFields)}"#
        let wire = try HTTPClient.makeJSONDecoder().decode(
            APIv2CatalogRead.CatalogItemDetail.self, from: Data(body.utf8))
        return try ItemDetail(catalog: wire)
    }
}
