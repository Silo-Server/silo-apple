#if !os(tvOS)
import XCTest
@testable import Silo

/// The title page rating control's commit rules: one write per visit to the
/// row, removal through Done or Clear, Undo, and the open row's fit.
final class PhoneRatingEditorTests: XCTestCase {
    private func opened(on saved: Int) -> PhoneRatingEditor {
        var editor = PhoneRatingEditor()
        editor.open(saved: RatingScore(saved))
        return editor
    }

    func testDoneSendsOnlyAChangedValue() {
        var unchanged = opened(on: 8)
        unchanged.setDraft(RatingScore(9))
        unchanged.setDraft(RatingScore(8))
        XCTAssertNil(unchanged.commit(), "back where it started sends nothing")
        XCTAssertFalse(unchanged.isOpen)

        var changed = opened(on: 8)
        changed.setDraft(RatingScore(5))
        changed.setDraft(RatingScore(7))
        XCTAssertEqual(changed.commit(), .set(7), "one write with the last draft")
        XCTAssertNil(changed.commit(), "a closed row commits nothing more")
    }

    func testDoneAtNoStarsRemovesASavedRatingAndOffersUndo() {
        var editor = opened(on: 9)
        editor.setDraft(.none)
        XCTAssertEqual(editor.commit(), .remove)
        XCTAssertEqual(editor.removal?.previous, RatingScore(9))
        XCTAssertEqual(editor.undo(), .set(9))
        XCTAssertNil(editor.removal)
        XCTAssertNil(editor.undo(), "Undo restores once")
    }

    func testDoneAtNoStarsOnAnUnratedTitleSendsNothing() {
        var editor = opened(on: 0)
        editor.setDraft(RatingScore(6))
        editor.setDraft(.none)
        XCTAssertNil(editor.commit())
        XCTAssertNil(editor.removal)
    }

    func testClearRemovesTheSavedRatingNotTheDraft() {
        var editor = opened(on: 4)
        editor.setDraft(RatingScore(10))
        XCTAssertEqual(editor.clear(), .remove)
        XCTAssertFalse(editor.isOpen)
        XCTAssertEqual(editor.undo(), .set(4), "Undo brings back what was saved")
    }

    func testClearOnAnUnratedTitleOnlyDropsTheDraft() {
        var editor = opened(on: 0)
        editor.setDraft(RatingScore(3))
        XCTAssertNil(editor.clear())
        XCTAssertFalse(editor.isOpen)
        XCTAssertNil(editor.removal)
    }

    func testEscapeDropsTheDraft() {
        var editor = opened(on: 6)
        editor.setDraft(RatingScore(2))
        editor.cancel()
        XCTAssertFalse(editor.isOpen)
        XCTAssertNil(editor.commit())
        XCTAssertEqual(editor.shown(saved: RatingScore(6)), RatingScore(6))
    }

    func testReopeningOrANewerRemovalRetiresTheToast() throws {
        var editor = opened(on: 7)
        editor.setDraft(.none)
        _ = editor.commit()
        let first = try XCTUnwrap(editor.removal)

        editor.open(saved: .none)
        XCTAssertNil(editor.removal, "opening the row dismisses the toast")
        editor.setDraft(RatingScore(5))
        _ = editor.commit()
        editor.open(saved: RatingScore(5))
        _ = editor.clear()
        let second = try XCTUnwrap(editor.removal)

        editor.dismissRemoval(id: first.id)
        XCTAssertEqual(editor.removal, second, "an older toast's timer leaves the newer one")
        editor.dismissRemoval(id: second.id)
        XCTAssertNil(editor.removal)
    }

    func testTheChipShowsAWriteUntilTheSavedRatingMoves() {
        var editor = opened(on: 4)
        editor.setDraft(RatingScore(9))
        _ = editor.commit()
        XCTAssertEqual(editor.shown(saved: RatingScore(4)), RatingScore(9), "no flash of the old value")

        editor.savedRatingChanged()
        XCTAssertEqual(
            editor.shown(saved: RatingScore(4)), RatingScore(4),
            "a refused write that put the old value back shows it"
        )
    }

    func testTheRowShrinksItsStarsBeforeDroppingTheReadout() {
        let full = PhoneRatingRowFit(width: 358)
        XCTAssertEqual(full.cell, 36)
        XCTAssertTrue(full.showsReadout)

        let narrow = PhoneRatingRowFit(width: 300)
        XCTAssertEqual(narrow.cell, 29.6, accuracy: 0.01)
        XCTAssertTrue(narrow.showsReadout)

        let narrower = PhoneRatingRowFit(width: 280)
        XCTAssertFalse(narrower.showsReadout, "below 28pt cells the readout goes")
        XCTAssertLessThanOrEqual(narrower.cell, 36)
        XCTAssertGreaterThanOrEqual(narrower.cell, 28)
    }
}
#endif
