import AetherEngine
import XCTest
@testable import Silo

/// The order text subtitles shown together are stacked in, bottom first.
final class SubtitleCueStackTests: XCTestCase {
    private func cue(_ id: Int, _ text: String, _ start: Double, _ end: Double) -> SubtitleCue {
        SubtitleCue(id: id, startTime: start, endTime: end, body: .text(text))
    }

    private func captions(_ cues: [SubtitleCue]) -> [String] {
        cues.compactMap(\.text)
    }

    func testCaptionsShownTogetherGoEarliestAtTheBottom() {
        let stack = SubtitleCueStack()
        // A sidecar can list a later cue first.
        let later = cue(1, "later", 2, 9)
        let earlier = cue(2, "earlier", 1, 9)
        XCTAssertEqual(captions(stack.bottomUp([later, earlier])), ["earlier", "later"])
        XCTAssertEqual(captions(stack.bottomUp([later, earlier])), ["earlier", "later"],
                       "the same captions keep the same order")
    }

    /// A card shown across two lines of dialogue stays above them: the second
    /// line takes the line the first one left.
    func testACaptionThatStaysOnScreenKeepsItsLine() {
        let stack = SubtitleCueStack()
        let firstLine = cue(1, "first line", 0, 3)
        let card = cue(2, "card", 1, 10)
        let secondLine = cue(3, "second line", 3, 6)
        XCTAssertEqual(captions(stack.bottomUp([firstLine, card])), ["first line", "card"])
        XCTAssertEqual(captions(stack.bottomUp([card, secondLine])), ["second line", "card"])
    }

    /// Alone, a caption drops to the bottom and keeps that line when the next
    /// one arrives.
    func testACaptionLeftAloneKeepsTheBottomLine() {
        let stack = SubtitleCueStack()
        let firstLine = cue(1, "first line", 0, 3)
        let card = cue(2, "card", 1, 10)
        let secondLine = cue(3, "second line", 4, 6)
        _ = stack.bottomUp([firstLine, card])
        XCTAssertEqual(captions(stack.bottomUp([card])), ["card"])
        XCTAssertEqual(captions(stack.bottomUp([card, secondLine])), ["card", "second line"])
    }

    func testARepeatedCaptionIsShownOnce() {
        let stack = SubtitleCueStack()
        let shown = stack.bottomUp([cue(1, "Hello", 0, 5), cue(2, "Hello", 1, 4), cue(3, "Bye", 2, 4)])
        XCTAssertEqual(captions(shown), ["Hello", "Bye"])
    }

    func testOnlyTextWithoutAPlacementOfItsOwnIsStacked() {
        XCTAssertTrue(SubtitleCueStack.stacks(cue(1, "dialogue", 0, 1)))
        XCTAssertFalse(SubtitleCueStack.stacks(cue(2, "  \n", 0, 1)), "an empty cue draws nothing")
        let placed = SubtitleCue(id: 3, startTime: 0, endTime: 1, body: .text("sign"),
                                 placement: SubtitleTextPlacement(alignment: 8, position: nil))
        XCTAssertFalse(SubtitleCueStack.stacks(placed), "an authored placement stays where it is")
    }
}
