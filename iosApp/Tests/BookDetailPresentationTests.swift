import XCTest
@testable import Silo

final class BookDetailPresentationTests: XCTestCase {

    // MARK: - Hero metadata

    func testSeriesBookLeadsSourceTokensWithItsSeriesPosition() throws {
        let detail = try audiobook(
            title: "Stormlight Archive 5 - Wind and Truth (5 of 5)",
            extra: #""genres":["Fantasy","Epic"],"year":2024,"#,
            audiobook: #""series":{"name":"Stormlight Archive","entries":[{"content_id":"book","title":"Wind and Truth","series_index":5}]},"total_duration_seconds":162000"#
        )
        let presentation = BookDetailPresentation(detail: detail, isMarkedFinished: false)

        XCTAssertEqual(presentation.title, "Wind and Truth")
        XCTAssertEqual(presentation.sourceTokens, ["Stormlight Archive · Book 5 of 5"])
        XCTAssertEqual(presentation.factsTokens, ["2024", "45h"])
    }

    func testStandaloneBookShowsItsLeadGenre() throws {
        let presentation = BookDetailPresentation(
            detail: try audiobook(title: "Project Hail Mary", extra: #""genres":["Science Fiction","Adventure"],"#),
            isMarkedFinished: false
        )

        XCTAssertEqual(presentation.sourceTokens, ["Science Fiction"])
    }

    func testStandaloneBookWithoutGenresHasNoSourceTokens() throws {
        let presentation = BookDetailPresentation(
            detail: try audiobook(title: "Project Hail Mary"),
            isMarkedFinished: false
        )

        XCTAssertEqual(presentation.sourceTokens, [])
        XCTAssertEqual(presentation.factsTokens, [])
    }

    func testCreditTextNamesAuthorsThenNarrators() throws {
        let detail = try audiobook(
            title: "Wind and Truth",
            audiobook: #""authors":[{"name":"Brandon Sanderson"}],"narrators":[{"name":"Michael Kramer"},{"name":"Kate Reading"}]"#
        )
        let presentation = BookDetailPresentation(detail: detail, isMarkedFinished: false)

        XCTAssertEqual(presentation.creditText, "By Brandon Sanderson · Narrated by Michael Kramer & Kate Reading")
    }

    func testCreditTextIsNilWithoutPeople() throws {
        let presentation = BookDetailPresentation(
            detail: try audiobook(title: "Anonymous"),
            isMarkedFinished: false
        )

        XCTAssertNil(presentation.creditText)
    }

    // MARK: - Primary action

    func testInProgressBookResumesWithTimeLeftAndProgress() throws {
        let detail = try audiobook(
            title: "Book",
            extra: #""user_data":{"played":false,"position_seconds":3600},"#,
            audiobook: #""total_duration_seconds":14400"#
        )
        let presentation = BookDetailPresentation(detail: detail, isMarkedFinished: false)

        XCTAssertEqual(presentation.primaryAction, .resume(at: 3600))
        XCTAssertEqual(presentation.primaryLabel, "Resume · 3h left")
        XCTAssertEqual(presentation.primaryIcon, "play.fill")
        XCTAssertEqual(try XCTUnwrap(presentation.resumeFraction), 0.25, accuracy: 0.0001)
    }

    func testMarkingFinishedTurnsPlayIntoPlayAgainBeforeReload() throws {
        // The payload still says unplayed; the live Finished toggle wins.
        let detail = try audiobook(
            title: "Book",
            extra: #""user_data":{"played":false},"#,
            audiobook: #""total_duration_seconds":14400"#
        )

        let unfinished = BookDetailPresentation(detail: detail, isMarkedFinished: false)
        XCTAssertEqual(unfinished.primaryAction, .play)
        XCTAssertEqual(unfinished.primaryLabel, "Play")
        XCTAssertNil(unfinished.resumeFraction)

        let finished = BookDetailPresentation(detail: detail, isMarkedFinished: true)
        XCTAssertEqual(finished.primaryAction, .playAgain)
        XCTAssertEqual(finished.primaryLabel, "Play Again")
        XCTAssertEqual(finished.primaryIcon, "arrow.counterclockwise")
    }

    func testPositionAtTheEndCountsAsFinished() throws {
        let detail = try audiobook(
            title: "Book",
            extra: #""user_data":{"played":false,"position_seconds":14398},"#,
            audiobook: #""total_duration_seconds":14400"#
        )
        let presentation = BookDetailPresentation(detail: detail, isMarkedFinished: false)

        XCTAssertEqual(presentation.primaryAction, .playAgain)
    }

    // MARK: - Details facts

    func testAudiobookFactsReplaceFilmCredits() throws {
        let detail = try audiobook(
            title: "Book",
            extra: #""year":2021,"studios":["Should Not Appear"],"crew":[{"name":"Nobody","job":"Director"}],"versions":[{"file_id":1,"duration":3600,"codec_audio":"aac","container":"m4b"},{"file_id":2,"duration":3600,"codec_audio":"aac","container":"m4b"}],"#,
            audiobook: #""authors":[{"name":"Andy Weir"}],"narrators":[{"name":"Ray Porter, Someone Else"}],"publisher":"Audible Studios""#
        )

        let facts = DetailFacts(detail: detail).assembleFacts()

        XCTAssertEqual(facts.map(\.label), ["Author", "Narrators", "Publisher", "Released", "Length", "Format"])
        XCTAssertEqual(facts.map(\.value), [
            "Andy Weir",
            "Ray Porter & Someone Else",
            "Audible Studios",
            "2021",
            "2h",
            "AAC · M4B · 2 parts",
        ])
    }

    func testAudiobookFactsSkipMissingFields() throws {
        let facts = DetailFacts(detail: try audiobook(title: "Book")).assembleFacts()

        XCTAssertTrue(facts.isEmpty)
    }

    // MARK: - Fixtures

    private func audiobook(title: String, extra: String = "", audiobook: String = "") throws -> ItemDetail {
        let json = """
        {\(extra)"content_id":"book","type":"audiobook","title":"\(title)","audiobook":{\(audiobook)}}
        """
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ItemDetail.self, from: Data(json.utf8))
    }
}
