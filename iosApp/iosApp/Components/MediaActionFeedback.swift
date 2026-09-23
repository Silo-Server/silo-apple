import SwiftUI

/// One mutation at a time per card. Keep this on the card, outside the
/// transient context menu, so completion and failures survive menu dismissal.
@Observable
@MainActor
final class MediaActionFeedback {
    private(set) var isUpdating = false
    var notice: PersonalStateNotice?

    func perform(
        reportsFailure: Bool = true,
        _ operation: @escaping @MainActor () async -> PersonalStateOutcome
    ) {
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            let outcome = await operation()
            isUpdating = false
            report(outcome, reportsFailure: reportsFailure)
        }
    }

    /// A caller that surfaces its own definite failures passes
    /// `reportsFailure: false`; a held change is always offered for discard.
    func report(_ outcome: PersonalStateOutcome, reportsFailure: Bool = true) {
        switch outcome {
        case .applied, .skipped: break
        case .failed: if reportsFailure { notice = .failed }
        case .held(let change): notice = .held(change)
        }
    }
}

/// What a personal-state control tells the viewer after a change did not land.
enum PersonalStateNotice: Equatable {
    case failed
    case held(PersonalStateHeldChange)

    init?(_ outcome: PersonalStateOutcome) {
        switch outcome {
        case .applied, .skipped: return nil
        case .failed: self = .failed
        case .held(let change): self = .held(change)
        }
    }

    static let heldMessage = "Silo sent this change but the server didn't answer, so it won't be sent again. "
        + "Discard the held change to reload this item and try again."

    var title: String {
        switch self {
        case .failed: return "Couldn't Update Item"
        case .held: return "Change Not Confirmed"
        }
    }

    var message: String {
        switch self {
        case .failed: return "Your change wasn't saved. Please try again."
        case .held: return Self.heldMessage
        }
    }
}

extension View {
    func mediaActionFeedback(_ feedback: MediaActionFeedback) -> some View {
        modifier(MediaActionFeedbackModifier(feedback: feedback))
    }

    /// Presents a failed or held personal-state change. A held change offers
    /// "Discard Held Change", which releases the hold and drops the item's
    /// cached state; nothing is ever re-sent from here.
    func personalStateNoticeAlert(_ notice: Binding<PersonalStateNotice?>) -> some View {
        modifier(PersonalStateNoticeAlert(notice: notice))
    }
}

private struct MediaActionFeedbackModifier: ViewModifier {
    @Bindable var feedback: MediaActionFeedback

    func body(content: Content) -> some View {
        content.personalStateNoticeAlert($feedback.notice)
    }
}

private struct PersonalStateNoticeAlert: ViewModifier {
    @Binding var notice: PersonalStateNotice?

    func body(content: Content) -> some View {
        content.alert(
            notice?.title ?? "",
            isPresented: Binding(
                get: { notice != nil },
                set: { if !$0 { notice = nil } }
            ),
            presenting: notice
        ) { presented in
            if case .held(let change) = presented {
                Button("Discard Held Change", role: .destructive) {
                    PersonalStateHolds.shared.discard(change)
                }
            }
            Button("OK", role: .cancel) { }
        } message: { presented in
            Text(presented.message)
        }
    }
}
