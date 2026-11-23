#if os(tvOS)
import Foundation

/// What the detail page's star button does with each remote press, kept apart
/// from the view so the rules can be tested without one.
///
/// Idle, Select opens editing with a draft: the current rating, or three
/// stars when there is none. Editing, Left and Right move the draft half a
/// star between none and five, Select saves it, and Back or losing focus
/// throws it away. Holding Select on an idle, rated button removes the rating.
/// A save or removal leaves a short message that the view clears after a few
/// seconds, or sooner if the server turns the change down.
struct TVRatingEditor: Equatable {
    enum Phase: Equatable {
        case idle
        case editing(draft: RatingScore)
    }

    /// A draft step. `up` is toward five stars, whichever way the layout runs.
    enum Step: Equatable {
        case up
        case down
    }

    /// The change to send. Nil from an input means nothing to send.
    enum Write: Equatable {
        /// 1 to 10.
        case set(Int)
        case remove
    }

    enum Message: Equatable {
        case saved(RatingScore)
        case removed
    }

    /// The line under the action row.
    enum Hint: Equatable {
        case editing(isSeries: Bool)
        /// Editing with the draft at no stars.
        case editingNone
        case saved(isSeries: Bool)
        case removed
    }

    private(set) var phase: Phase = .idle
    private(set) var message: Message?
    /// Changes each time a message is shown, so a timer for an older message
    /// cannot clear a newer one.
    private(set) var messageGeneration = 0

    var isEditing: Bool {
        if case .editing = phase { return true }
        return false
    }

    var draft: RatingScore? {
        if case .editing(let draft) = phase { return draft }
        return nil
    }

    /// Select: opens editing when idle, saves when editing.
    mutating func select(current: RatingScore) -> Write? {
        guard let draft else {
            phase = .editing(draft: current.isRated ? current : .unratedDraft)
            message = nil
            return nil
        }
        phase = .idle
        if draft.isRated {
            show(.saved(draft))
            return draft == current ? nil : .set(draft.value)
        }
        guard current.isRated else { return nil }
        show(.removed)
        return .remove
    }

    /// Left or Right while editing; ignored when idle.
    mutating func step(_ step: Step) {
        guard let draft else { return }
        phase = .editing(draft: step == .up ? draft.steppedUp : draft.steppedDown)
    }

    /// Back. Returns whether the press was used, so an idle Back can pop the page.
    @discardableResult
    mutating func cancel() -> Bool {
        guard isEditing else { return false }
        phase = .idle
        return true
    }

    /// Select held on the idle button: removes an existing rating.
    mutating func hold(current: RatingScore) -> Write? {
        guard !isEditing, current.isRated else { return nil }
        show(.removed)
        return .remove
    }

    /// Focus left the button for any reason: an open edit is cancelled.
    mutating func focusLost() {
        cancel()
    }

    /// The message timer ran out.
    mutating func expireMessage(generation: Int) {
        guard generation == messageGeneration else { return }
        message = nil
    }

    /// The page's rating changed. A message that no longer matches it was
    /// for a change the server turned down, so it goes.
    mutating func ratingChanged(to current: RatingScore) {
        switch message {
        case .saved(let saved) where saved != current:
            message = nil
        case .removed where current.isRated:
            message = nil
        default:
            break
        }
    }

    /// The hint for the current state. Nil leaves the line empty: the idle
    /// button explains itself, so only editing and its outcome show one.
    func hint(isSeries: Bool) -> Hint? {
        if let draft {
            return draft.isRated ? .editing(isSeries: isSeries) : .editingNone
        }
        switch message {
        case .saved: return .saved(isSeries: isSeries)
        case .removed: return .removed
        case nil: return nil
        }
    }

    private mutating func show(_ message: Message) {
        self.message = message
        messageGeneration &+= 1
    }
}
#endif
