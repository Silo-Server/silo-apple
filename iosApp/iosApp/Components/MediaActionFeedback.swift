import SwiftUI

/// One mutation at a time per card. Keep this on the card, outside the
/// transient context menu, so completion and failures survive menu dismissal.
@Observable
@MainActor
final class MediaActionFeedback {
    private(set) var isUpdating = false
    var updateFailed = false

    func perform(
        reportsFailure: Bool = true,
        _ operation: @escaping @MainActor () async -> Bool
    ) {
        guard !isUpdating else { return }
        isUpdating = true
        Task {
            let succeeded = await operation()
            isUpdating = false
            if reportsFailure && !succeeded {
                updateFailed = true
            }
        }
    }
}

extension View {
    func mediaActionFeedback(_ feedback: MediaActionFeedback) -> some View {
        modifier(MediaActionFeedbackModifier(feedback: feedback))
    }
}

private struct MediaActionFeedbackModifier: ViewModifier {
    @Bindable var feedback: MediaActionFeedback

    func body(content: Content) -> some View {
        content.alert("Couldn't Update Item", isPresented: $feedback.updateFailed) {
            Button("OK", role: .cancel) { }
        } message: {
            Text("Your change wasn't saved. Please try again.")
        }
    }
}
