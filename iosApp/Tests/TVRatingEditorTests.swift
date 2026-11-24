#if os(tvOS)
import XCTest
@testable import Silo

final class TVRatingEditorTests: XCTestCase {
    func testSelectOnUnratedStartsTheDraftAtThreeStarsAndSendsNothing() {
        var editor = TVRatingEditor()
        XCTAssertNil(editor.select(current: .none))
        XCTAssertEqual(editor.draft, RatingScore(6))
    }

    func testSelectOnRatedStartsTheDraftAtTheRating() {
        var editor = TVRatingEditor()
        _ = editor.select(current: RatingScore(9))
        XCTAssertEqual(editor.draft, RatingScore(9))
    }

    func testStepsMoveHalfAStarAndStopAtBothEnds() {
        var editor = TVRatingEditor()
        _ = editor.select(current: RatingScore(9))
        editor.step(.up)
        editor.step(.up)
        XCTAssertEqual(editor.draft, RatingScore(10))
        for _ in 0..<12 { editor.step(.down) }
        XCTAssertEqual(editor.draft, RatingScore.none)
    }

    func testStepsAreIgnoredWhenIdle() {
        var editor = TVRatingEditor()
        editor.step(.up)
        XCTAssertEqual(editor.phase, .idle)
    }

    func testSavingAChangedDraftSendsItAndShowsSaved() {
        var editor = TVRatingEditor()
        _ = editor.select(current: RatingScore(6))
        editor.step(.up)
        XCTAssertEqual(editor.select(current: RatingScore(6)), .set(7))
        XCTAssertFalse(editor.isEditing)
        XCTAssertEqual(editor.message, .saved(RatingScore(7)))
    }

    func testSavingAnUnchangedDraftSendsNothing() {
        var editor = TVRatingEditor()
        _ = editor.select(current: RatingScore(8))
        XCTAssertNil(editor.select(current: RatingScore(8)))
        XCTAssertEqual(editor.message, .saved(RatingScore(8)))
    }

    func testSavingNoStarsRemovesAnExistingRating() {
        var editor = TVRatingEditor()
        _ = editor.select(current: RatingScore(1))
        editor.step(.down)
        XCTAssertEqual(editor.select(current: RatingScore(1)), .remove)
        XCTAssertEqual(editor.message, .removed)
    }

    func testSavingNoStarsWithoutARatingDoesNothing() {
        var editor = TVRatingEditor()
        _ = editor.select(current: .none)
        for _ in 0..<6 { editor.step(.down) }
        XCTAssertNil(editor.select(current: .none))
        XCTAssertNil(editor.message)
        XCTAssertEqual(editor.phase, .idle)
    }

    func testCancelDiscardsTheDraftAndOnlyConsumesBackWhileEditing() {
        var editor = TVRatingEditor()
        XCTAssertFalse(editor.cancel(), "an idle Back must reach the page")
        _ = editor.select(current: RatingScore(4))
        editor.step(.up)
        XCTAssertTrue(editor.cancel())
        XCTAssertEqual(editor.phase, .idle)
        XCTAssertNil(editor.message)
        // The next edit starts from the rating again, not the old draft.
        _ = editor.select(current: RatingScore(4))
        XCTAssertEqual(editor.draft, RatingScore(4))
    }

    func testLosingFocusCancelsAnEdit() {
        var editor = TVRatingEditor()
        _ = editor.select(current: RatingScore(4))
        editor.focusLost()
        XCTAssertEqual(editor.phase, .idle)
    }

    func testHoldRemovesOnlyAnExistingRatingWhileIdle() {
        var editor = TVRatingEditor()
        XCTAssertNil(editor.hold(current: .none))
        XCTAssertEqual(editor.hold(current: RatingScore(7)), .remove)
        XCTAssertEqual(editor.message, .removed)

        var editing = TVRatingEditor()
        _ = editing.select(current: RatingScore(7))
        XCTAssertNil(editing.hold(current: RatingScore(7)))
        XCTAssertTrue(editing.isEditing)
    }

    func testOpeningAnEditClearsTheLastMessage() {
        var editor = TVRatingEditor()
        _ = editor.hold(current: RatingScore(7))
        _ = editor.select(current: .none)
        XCTAssertNil(editor.message)
    }

    func testAnOlderTimerCannotClearANewerMessage() {
        var editor = TVRatingEditor()
        _ = editor.hold(current: RatingScore(7))
        let first = editor.messageGeneration
        _ = editor.select(current: .none)
        _ = editor.select(current: .none)
        XCTAssertEqual(editor.message, .saved(RatingScore(6)))
        editor.expireMessage(generation: first)
        XCTAssertEqual(editor.message, .saved(RatingScore(6)))
        editor.expireMessage(generation: editor.messageGeneration)
        XCTAssertNil(editor.message)
    }

    func testARevertedSaveDropsItsMessage() {
        var editor = TVRatingEditor()
        _ = editor.select(current: RatingScore(4))
        editor.step(.up)
        _ = editor.select(current: RatingScore(4))
        editor.ratingChanged(to: RatingScore(5))
        XCTAssertEqual(editor.message, .saved(RatingScore(5)), "the optimistic value matches")
        editor.ratingChanged(to: RatingScore(4))
        XCTAssertNil(editor.message, "the server refused it")
    }

    func testARevertedRemovalDropsItsMessage() {
        var editor = TVRatingEditor()
        _ = editor.hold(current: RatingScore(4))
        editor.ratingChanged(to: .none)
        XCTAssertEqual(editor.message, .removed)
        editor.ratingChanged(to: RatingScore(4))
        XCTAssertNil(editor.message)
    }

    func testHintShowsOnlyWhileEditingAndAfterAnOutcome() {
        var editor = TVRatingEditor()
        // The idle button carries no hint, focused or not, rated or not.
        XCTAssertNil(editor.hint(isSeries: false))

        _ = editor.select(current: RatingScore(1))
        XCTAssertEqual(editor.hint(isSeries: true), .editing(isSeries: true))
        editor.step(.down)
        XCTAssertEqual(editor.hint(isSeries: true), .editingNone)

        _ = editor.select(current: RatingScore(1))
        XCTAssertEqual(editor.hint(isSeries: false), .removed)
    }
}
#endif
