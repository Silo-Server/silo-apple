#if !os(tvOS)
import SwiftUI

/// What the title page's rating control is showing and what each action
/// saves. The closed chip opens a row with a draft; nothing is written while
/// the row is open, so one visit to the row costs at most one write. Done,
/// a tap outside, starting playback and leaving the page all commit the
/// draft the same way; Escape discards it.
struct PhoneRatingEditor: Equatable {
    /// A write the page should send.
    enum Write: Equatable {
        case set(Int)
        case remove
    }

    /// A removal Undo can still restore. `id` tells one removal's toast from
    /// the next, so an old toast's timer cannot hide a newer one.
    struct Removal: Equatable {
        let id: Int
        let previous: RatingScore
    }

    private(set) var isOpen = false
    /// The rating the open row shows.
    private(set) var draft: RatingScore = .none
    /// The saved rating when the row opened.
    private(set) var original: RatingScore = .none
    /// The latest removal; nil when there is nothing to undo.
    private(set) var removal: Removal?
    /// What the closed chip shows after a write until the page's saved
    /// rating reflects it, so closing the row never flashes the old value.
    private(set) var unsavedShown: RatingScore?
    private var removalCount = 0

    /// The rating the closed chip shows.
    func shown(saved: RatingScore) -> RatingScore {
        unsavedShown ?? saved
    }

    /// The page's saved rating moved: a write landed or a failed one was
    /// put back. The chip follows it from now on.
    mutating func savedRatingChanged() {
        unsavedShown = nil
    }

    /// Opens the row on `saved`. Opening dismisses the removal toast.
    mutating func open(saved: RatingScore) {
        isOpen = true
        draft = saved
        original = saved
        removal = nil
    }

    /// Returns whether the draft changed.
    @discardableResult
    mutating func setDraft(_ score: RatingScore) -> Bool {
        guard isOpen, score != draft else { return false }
        draft = score
        return true
    }

    /// Closes the row and saves the draft: a new rating sets it, no stars
    /// over a saved rating removes it, and an unchanged draft sends nothing.
    mutating func commit() -> Write? {
        guard isOpen else { return nil }
        isOpen = false
        guard draft != original else { return nil }
        guard draft.isRated else { return recordRemoval() }
        unsavedShown = draft
        return .set(draft.value)
    }

    /// Closes the row and removes the saved rating. With none saved there is
    /// nothing to remove, and the draft is dropped.
    mutating func clear() -> Write? {
        guard isOpen else { return nil }
        isOpen = false
        guard original.isRated else { return nil }
        return recordRemoval()
    }

    /// Closes the row and drops the draft.
    mutating func cancel() {
        isOpen = false
    }

    /// Restores the rating the last removal took away.
    mutating func undo() -> Write? {
        guard let removal, !isOpen else { return nil }
        self.removal = nil
        unsavedShown = removal.previous
        return .set(removal.previous.value)
    }

    /// Hides removal `id`'s toast when its time is up. A newer removal stays.
    mutating func dismissRemoval(id: Int) {
        if removal?.id == id { removal = nil }
    }

    private mutating func recordRemoval() -> Write {
        removalCount += 1
        removal = Removal(id: removalCount, previous: original)
        unsavedShown = RatingScore.none
        return .remove
    }
}

/// The page's rating control state, shared by the hero's rating line, the
/// removal toast and the page-level commit triggers (an outside tap,
/// playback, the page leaving). `send` writes a rating; nil removes it.
@Observable
@MainActor
final class PhoneRatingController {
    private(set) var editor = PhoneRatingEditor()
    /// Counts saved changes and removals, so the views can play one haptic
    /// for each.
    private(set) var savedCount = 0
    private(set) var removedCount = 0
    /// The open row's frame in `PhoneRatingController.pageSpace`; a page tap
    /// inside it is the row's own and commits nothing.
    @ObservationIgnored var openRowFrame: CGRect = .null
    @ObservationIgnored var send: (Int?) -> Void = { _ in }

    /// The named coordinate space the page and the open row share.
    static let pageSpace = "phone-rating-page"

    func open(saved: RatingScore) {
        // Unknown until the row lays out; page taps wait for it.
        openRowFrame = .null
        editor.open(saved: saved)
    }

    func savedRatingChanged() {
        editor.savedRatingChanged()
    }

    func setDraft(_ score: RatingScore) {
        editor.setDraft(score)
    }

    func commit() {
        perform(editor.commit())
    }

    func clear() {
        perform(editor.clear())
    }

    func cancel() {
        editor.cancel()
    }

    func undo() {
        perform(editor.undo())
    }

    func dismissRemoval(id: Int) {
        editor.dismissRemoval(id: id)
    }

    /// A tap anywhere on the page. Outside the open row it commits, as Done.
    func pageTapped(at location: CGPoint) {
        // The tap that opened the row arrives before the row has a frame.
        guard editor.isOpen, !openRowFrame.isNull, !openRowFrame.contains(location) else { return }
        commit()
    }

    private func perform(_ write: PhoneRatingEditor.Write?) {
        switch write {
        case .set(let score):
            savedCount += 1
            send(score)
        case .remove:
            removedCount += 1
            send(nil)
        case nil:
            break
        }
    }
}
#endif
