@testable import Silo
import XCTest

/// The years line under a series card, read through a Home card's caption
/// from rows decoded the way the server sends them.
final class CardYearsTests: XCTestCase {
    private let english = Locale(identifier: "en_US")
    /// Apple's plain `ar` writes Latin digits; Egypt uses Arabic-Indic ones.
    private let arabic = Locale(identifier: "ar_EG")

    func testAnEndedSeriesShowsTheYearsItRan() throws {
        let ended = try sectionItem(#""type":"series","year":2019,"show_status":"ended","last_air_date":"2023-05-28""#)
        XCTAssertEqual(caption(ended), "2019 – 2023")

        let cancelled = try sectionItem(#""type":"series","year":2014,"show_status":"cancelled","last_air_date":"2015-03-01""#)
        XCTAssertEqual(caption(cancelled), "2014 – 2015")
    }

    func testARunningSeriesRunsToPresent() throws {
        let running = try sectionItem(#""type":"series","year":2021,"show_status":"returning","last_air_date":"2025-12-28""#)
        XCTAssertEqual(caption(running), "2021 – Present")

        let noLastDate = try sectionItem(#""type":"series","year":2021,"show_status":"returning""#)
        XCTAssertEqual(caption(noLastDate), "2021 – Present")
    }

    func testASeriesThatStartedAndEndedInOneYearShowsThatYear() throws {
        let item = try sectionItem(#""type":"series","year":2022,"show_status":"ended","last_air_date":"2022-05-04""#)
        XCTAssertEqual(caption(item), "2022")
    }

    func testASeriesWithoutAStatusOrAnEndShowsItsFirstYear() throws {
        for fields in [
            #""year":2019,"show_status":"ended""#,
            #""year":2019,"last_air_date":"2023-05-28""#,
            #""year":2019,"show_status":"ended","last_air_date":"2018-01-01""#,
            #""year":2019,"show_status":"in_production","last_air_date":"2023-05-28""#,
            #""year":2019,"show_status":"upcoming""#,
        ] {
            XCTAssertEqual(caption(try sectionItem(#""type":"series",\#(fields)"#)), "2019", fields)
        }
        XCTAssertNil(caption(try sectionItem(#""type":"series","show_status":"returning""#)))
    }

    /// A film or a season keeps its year, whatever else its row carries.
    func testOnlyASeriesShowsARange() throws {
        let film = try sectionItem(#""type":"movie","year":1995,"show_status":"ended","last_air_date":"1999-01-01""#)
        XCTAssertEqual(caption(film), "1995")

        let season = try sectionItem(#""type":"season","year":2021,"show_status":"returning""#)
        XCTAssertEqual(caption(season), "2021")
    }

    /// Asserts the digits, not the translated wording around them.
    func testTheYearsUseTheLanguagesDigits() throws {
        let item = try sectionItem(#""type":"series","year":2019,"show_status":"ended","last_air_date":"2023-05-28""#)
        let text = try XCTUnwrap(HomeFeedMeta.cardSecondLine(for: item, locale: arabic))
        XCTAssertTrue(text.contains("٢٠١٩"), text)
        XCTAssertTrue(text.contains("٢٠٢٣"), text)
        XCTAssertNil(text.rangeOfCharacter(from: CharacterSet(charactersIn: "0123456789")), text)
    }

    /// A library page rebuilds its rows from catalog cards.
    func testARowBuiltFromACatalogCardKeepsTheYears() throws {
        let card = try HTTPClient.makeJSONDecoder().decode(BrowseItem.self, from: Data(
            #"{"content_id":"series:years","type":"series","title":"Synthetic","year":2019,"show_status":"ended","last_air_date":"2023-05-28"}"#.utf8))
        XCTAssertEqual(caption(SectionItem(browseItem: card)), "2019 – 2023")
    }

    // MARK: Helpers

    private func caption(_ item: SectionItem) -> String? {
        HomeFeedMeta.cardSecondLine(for: item, locale: english)
    }

    /// A section card as `/api/v2/home/sections` sends it, with `fields` spliced in.
    private func sectionItem(_ fields: String) throws -> SectionItem {
        try HTTPClient.makeJSONDecoder().decode(SectionItem.self, from: Data(
            #"{"content_id":"series:years","title":"Synthetic",\#(fields)}"#.utf8))
    }
}
