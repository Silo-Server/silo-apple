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

    // MARK: Phone row

    func testPhoneRowShowsAtMostThreeAndDropsFromTheEnd() {
        let five = [
            DisplayRating(source: "imdb", name: "IMDb", score: 85, display: "8.5"),
            DisplayRating(source: "tmdb", name: "TMDB", score: 82.5, display: "8.3"),
            DisplayRating(source: "rt_critic", name: "RT", score: 93, display: "93%"),
            DisplayRating(source: "rt_audience", name: "RT Audience", score: 95, display: "95%"),
            DisplayRating(source: "metacritic", name: "Metacritic", score: 87, display: "87"),
        ]
        XCTAssertEqual(
            DisplayRating.phoneRowCandidates(five).map { $0.map(\.source) },
            [["imdb", "tmdb", "rt_critic"], ["imdb", "tmdb"], ["imdb"]],
            "the first three in server order, then one fewer from the end"
        )
        XCTAssertEqual(
            DisplayRating.phoneRowCandidates(Array(five.suffix(2))).map { $0.map(\.source) },
            [["rt_audience", "metacritic"], ["rt_audience"]],
            "server order decides, not the source"
        )
        XCTAssertEqual(DisplayRating.phoneRowCandidates([]), [])
    }

    func testTVRowTriesEveryPrefixLongestFirst() {
        let four = ["imdb", "tmdb", "rt_critic", "mdblist"].map {
            DisplayRating(source: $0, name: $0, score: 80, display: "8.0")
        }
        XCTAssertEqual(
            DisplayRating.rowCandidates(four).map { $0.map(\.source) },
            [
                ["imdb", "tmdb", "rt_critic", "mdblist"],
                ["imdb", "tmdb", "rt_critic"],
                ["imdb", "tmdb"],
                ["imdb"],
            ],
            "no limit: the whole list first, then whole entries drop from the end"
        )
        XCTAssertEqual(DisplayRating.rowCandidates([]), [])
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

    func testAdvisoryAgeFlowsFromDetailIntoPosterAndAttributedBadge() throws {
        let detail = try decodeDetail(extraFields: #""advisory_age":13,"advisory_source":"commonsense""#)
        XCTAssertEqual(detail.advisoryAge, 13)
        XCTAssertEqual(detail.advisorySource, "commonsense")

        let data = OverlayData.from(detail)
        let definition = try XCTUnwrap(
            OverlayRegistry.all.first { $0.id == .advisoryAge }
        )
        XCTAssertEqual(definition.getValue(data), "13+")
        XCTAssertEqual(data.advisoryAgeBadgeLabel, "Common Sense 13+")
        XCTAssertFalse(definition.defaultEnabled)
        XCTAssertEqual(definition.defaultPosition, .bottomRight)
        XCTAssertEqual(definition.iconId, .users)
    }

    func testAdvisoryAgeBadgeAttributesMDBListAndRejectsInvalidAges() {
        XCTAssertEqual(
            OverlayData(advisoryAge: 10, advisorySource: "mdblist").advisoryAgeBadgeLabel,
            "MDBList 10+"
        )
        XCTAssertEqual(
            OverlayData(advisoryAge: 8, advisorySource: "future-provider").advisoryAgeBadgeLabel,
            "8+"
        )
        XCTAssertNil(OverlayData(advisoryAge: 0, advisorySource: "commonsense").advisoryAgeBadgeLabel)
        XCTAssertNil(OverlayData(advisoryAge: nil, advisorySource: "commonsense").advisoryAgeBadgeLabel)
    }

    #if os(tvOS)
    // MARK: Focus marquee

    @MainActor
    func testMarqueeTakesTheReloadedTextOfTheShownCard() throws {
        let german = try decodeSectionItem(#""type":"movie","overview":"[German] Text""#)
        let french = try decodeSectionItem(#""type":"movie","overview":"[French] Text""#)
        let model = TVFocusMarqueeModel()
        model.seed(TVMarqueeContent(item: german, rowId: "row", rowTitle: "Movies"))
        model.refreshContent(TVMarqueeContent(item: french, rowId: "row", rowTitle: "Movies"))
        XCTAssertEqual(model.content?.synopsis, "[French] Text")
        // Another row's copy of the card is not the one on show.
        model.refreshContent(TVMarqueeContent(item: german, rowId: "other", rowTitle: "Other"))
        XCTAssertEqual(model.content?.synopsis, "[French] Text")
    }

    func testMarqueeTranslatesOnlyFeaturedCardsOnView() throws {
        let item = try decodeSectionItem(#""type":"movie","pendingTranslationLanguage":"de""#)
        let featured = TVMarqueeContent(item: item, rowTitle: "Featured", isFeatured: true)
        XCTAssertEqual(
            featured.onViewTranslationRequest(pendingLanguage: "de", mode: .auto),
            TVMarqueeTranslationRequest(contentId: item.contentId, language: "de")
        )
        // `button` mode and a landed translation start nothing.
        XCTAssertNil(featured.onViewTranslationRequest(pendingLanguage: "de", mode: .button))
        XCTAssertNil(featured.onViewTranslationRequest(pendingLanguage: nil, mode: .auto))

        // A card in an ordinary row keeps its text and marker but never starts a job.
        let ordinary = TVMarqueeContent(item: item, rowTitle: "Recently Added")
        XCTAssertEqual(ordinary.pendingTranslationLanguage, "de")
        XCTAssertNil(ordinary.onViewTranslationRequest(pendingLanguage: "de", mode: .auto))
    }

    func testMarqueeShowsOneMarkedRatingBeforeTimeLeft() throws {
        let item = try decodeSectionItem(#""type":"movie","ratingImdb":7.8,"ratingTmdb":8.1,"positionSeconds":600,"durationSeconds":3000"#)
        let content = TVMarqueeContent(item: item, rowTitle: "Continue Watching", isContinueWatching: true)
        XCTAssertEqual(content.rating?.accessibilityText, "IMDb 7.8")
        XCTAssertFalse(content.metaParts.contains("7.8"), "no bare score in the text tokens")
        XCTAssertEqual(content.trailingMetaParts, ["40m left"], "time left follows the rating")
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
