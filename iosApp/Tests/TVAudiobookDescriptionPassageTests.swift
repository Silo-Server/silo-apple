#if os(tvOS)
import XCTest
@testable import Silo

/// The full-description screen scrolls passage by passage, so every passage
/// must fit on screen and together they must keep all of the text.
final class TVAudiobookDescriptionPassageTests: XCTestCase {
    func testShortParagraphsStayWhole() {
        let passages = DescriptionPassage.split("First paragraph.\n\nSecond paragraph.")

        XCTAssertEqual(passages.map(\.text), ["First paragraph.", "Second paragraph."])
        XCTAssertEqual(passages.map(\.startsParagraph), [true, true])
    }

    func testLongParagraphSplitsAtSentencesAndKeepsAllText() {
        let sentence = "This sentence is about sixty characters long, give or take. "
        let paragraph = String(repeating: sentence, count: 20).trimmingCharacters(in: .whitespaces)

        let passages = DescriptionPassage.split(paragraph)

        XCTAssertGreaterThan(passages.count, 1)
        XCTAssertEqual(passages.map(\.startsParagraph), [true] + Array(repeating: false, count: passages.count - 1))
        for passage in passages {
            XCTAssertLessThanOrEqual(passage.text.count, DescriptionPassage.targetLength)
            XCTAssertTrue(passage.text.hasSuffix("."), passage.text)
        }
        XCTAssertEqual(
            passages.map(\.text).joined(separator: " ").filter { !$0.isWhitespace },
            paragraph.filter { !$0.isWhitespace }
        )
    }

    func testLongTextWithoutSentenceBreaksSplitsAtWords() {
        let paragraph = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)

        let passages = DescriptionPassage.split(paragraph)

        XCTAssertGreaterThan(passages.count, 1)
        XCTAssertTrue(passages.allSatisfy { $0.text.count <= DescriptionPassage.targetLength })
        XCTAssertTrue(passages.allSatisfy { $0.text.hasPrefix("word") && $0.text.hasSuffix("word") })
        XCTAssertEqual(passages.map(\.text).joined(separator: " "), paragraph)
    }

    func testOversizedSentenceAmongShortOnesSplitsAtWords() {
        let long = String(repeating: "and then ", count: 80) + "it ended."
        let paragraph = "It began. \(long) After that, quiet."

        let passages = DescriptionPassage.split(paragraph)

        XCTAssertTrue(passages.allSatisfy { $0.text.count <= DescriptionPassage.targetLength })
        XCTAssertEqual(
            passages.map(\.text).joined(separator: " ").filter { !$0.isWhitespace },
            paragraph.filter { !$0.isWhitespace }
        )
    }

    func testUnbrokenRunLongerThanAPassageIsCut() {
        let run = String(repeating: "x", count: DescriptionPassage.targetLength * 2 + 10)

        let passages = DescriptionPassage.split(run)

        XCTAssertEqual(passages.count, 3)
        XCTAssertTrue(passages.allSatisfy { $0.text.count <= DescriptionPassage.targetLength })
        XCTAssertEqual(passages.map(\.text).joined(), run)
    }

    func testIdsAreSequentialAcrossParagraphs() {
        let long = String(repeating: "A short sentence here. ", count: 40)
        let passages = DescriptionPassage.split("\(long)\nTail.")

        XCTAssertEqual(passages.map(\.id), Array(0..<passages.count))
        XCTAssertEqual(passages.last?.text, "Tail.")
        XCTAssertEqual(passages.last?.startsParagraph, true)
    }
}
#endif
