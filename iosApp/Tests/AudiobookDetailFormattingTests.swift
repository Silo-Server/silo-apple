import XCTest
@testable import Silo

final class AudiobookDetailFormattingTests: XCTestCase {

    // MARK: - Title cleanup

    func testStripsSeriesPrefixAndTrailingVolume() {
        let title = AudiobookDetailFormatting.cleanTitle(
            "Stormlight Archive 5 - Wind and Truth (5 of 5)",
            seriesName: "The Stormlight Archive"
        )
        XCTAssertEqual(title, "Wind and Truth")
    }

    func testLeavesStandaloneTitleUntouched() {
        XCTAssertEqual(
            AudiobookDetailFormatting.cleanTitle("Project Hail Mary", seriesName: nil),
            "Project Hail Mary"
        )
    }

    func testTitleNotMangledWhenItDoesNotStartWithSeries() {
        // Book 1's title doesn't repeat the series name, so nothing should
        // be stripped from it even though series data is present.
        XCTAssertEqual(
            AudiobookDetailFormatting.cleanTitle("The Way of Kings", seriesName: "The Stormlight Archive"),
            "The Way of Kings"
        )
    }

    func testTrailingVolumeStrippedWithoutSeries() {
        XCTAssertEqual(
            AudiobookDetailFormatting.cleanTitle("Some Story (2 of 3)", seriesName: nil),
            "Some Story"
        )
    }

    // MARK: - Volume locator

    func testVolumeLocatorParsesIndexAndTotal() {
        let volume = AudiobookDetailFormatting.volume(in: "Stormlight Archive 5 - Wind and Truth (5 of 5)")
        XCTAssertEqual(volume.index, 5)
        XCTAssertEqual(volume.total, 5)
    }

    func testVolumeLocatorAbsentReturnsNils() {
        let volume = AudiobookDetailFormatting.volume(in: "Project Hail Mary")
        XCTAssertNil(volume.index)
        XCTAssertNil(volume.total)
    }

    // MARK: - Series line

    func testSeriesLineUsesParsedTotalNotEntryCount() {
        // Regression: the series grouping reported 19 entries (alternate
        // editions), but the book is 5 of 5.
        XCTAssertEqual(
            AudiobookDetailFormatting.seriesLine(name: "The Stormlight Archive", index: 5, total: 5),
            "The Stormlight Archive · Book 5 of 5"
        )
    }

    func testSeriesLineFallsBackToNameOnlyWithoutIndex() {
        XCTAssertEqual(
            AudiobookDetailFormatting.seriesLine(name: "Mistborn", index: nil, total: nil),
            "Mistborn"
        )
        XCTAssertEqual(
            AudiobookDetailFormatting.seriesLine(name: "Mistborn", index: 2, total: nil),
            "Mistborn · Book 2"
        )
    }

    // MARK: - Credit summaries

    func testNarratorSummaryRollsUpDiscretePeople() {
        let summary = AudiobookDetailFormatting.peopleSummary(
            ["Danny Montooth", "James Konicek", "Drew Kopas", "Andy Clemence", "Bradley Foster Smith"],
            visible: 2
        )
        XCTAssertEqual(summary, "Danny Montooth, James Konicek & 3 more")
    }

    func testNarratorSummaryRollsUpCombinedString() {
        // Regression: the server delivers the whole cast as one comma-joined
        // string, which must still summarise rather than wrap to many lines.
        let summary = AudiobookDetailFormatting.peopleSummary(
            ["Danny Montooth, James Konicek, Drew Kopas, Andy Clemence, Bradley Foster Smith"],
            visible: 2
        )
        XCTAssertEqual(summary, "Danny Montooth, James Konicek & 3 more")
    }

    func testSmallCreditListsJoinNaturally() {
        XCTAssertEqual(AudiobookDetailFormatting.peopleSummary(["Brandon Sanderson"]), "Brandon Sanderson")
        XCTAssertEqual(AudiobookDetailFormatting.peopleSummary(["A", "B"]), "A & B")
        XCTAssertEqual(AudiobookDetailFormatting.peopleSummary(["A", "B", "C"]), "A, B & C")
    }

    func testEmptyCreditListIsNil() {
        XCTAssertNil(AudiobookDetailFormatting.peopleSummary([]))
        XCTAssertNil(AudiobookDetailFormatting.peopleSummary(["", "  "]))
    }

    func testSeriesNameOnlyStripsAtAWordBoundary() {
        XCTAssertEqual(
            AudiobookDetailFormatting.cleanTitle("American Gods", seriesName: "A"),
            "American Gods"
        )
        XCTAssertEqual(
            AudiobookDetailFormatting.cleanTitle("Dunes of Arrakis", seriesName: "Dune"),
            "Dunes of Arrakis"
        )
        XCTAssertEqual(
            AudiobookDetailFormatting.cleanTitle("Dune Saga 12 - Dune Messiah", seriesName: "Dune Saga"),
            "Dune Messiah"
        )
    }
}
