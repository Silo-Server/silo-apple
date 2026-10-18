#if !os(tvOS)
import SwiftUI

/// The questions a sign-in raises (spec §5.4.1) and the sign-out and removal
/// confirmations (spec §5.6, plan G10), as alerts on iPhone, iPad, and Mac.
/// The copy comes from `SignOutConfirmationCopy`; Sign out also offers Sign
/// Out & Remove Server.
struct SignInPromptAlert: View {
    var router: AppRouter

    /// The prompt whose button was tapped. The coordinator clears the prompt
    /// on its next turn; until then the alert must not come back.
    @State private var answeredPromptID: UUID?

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .alert(
                router.signInPrompt?.copy.title ?? "",
                isPresented: Binding(
                    get: { router.signInPrompt.map { $0.id != answeredPromptID } ?? false },
                    // Only the buttons answer.
                    set: { _ in }
                ),
                presenting: router.signInPrompt
            ) { prompt in
                Button(prompt.copy.confirmTitle, role: prompt.copy.confirmIsDestructive ? .destructive : nil) {
                    answer(prompt, accept: true)
                }
                Button(ConfirmationCopy.cancelTitle, role: .cancel) {
                    answer(prompt, accept: false)
                }
            } message: { prompt in
                Text(prompt.copy.message)
            }
            .background {
                Color.clear
                    .allowsHitTesting(false)
                    .alert(
                        router.removalRequest?.copy.title ?? "",
                        isPresented: Binding(
                            get: { router.removalRequest != nil },
                            set: { if !$0 { router.removalRequest = nil } }
                        ),
                        presenting: router.removalRequest
                    ) { request in
                        Button(request.copy.confirmTitle, role: request.copy.confirmIsDestructive ? .destructive : nil) {
                            router.removalRequest = nil
                            router.performRemoval(request)
                        }
                        if let additional = request.copy.additionalDestructiveTitle {
                            Button(additional, role: .destructive) {
                                router.removalRequest = nil
                                router.performRemoval(request, removingServer: true)
                            }
                        }
                        Button(ConfirmationCopy.cancelTitle, role: .cancel) {
                            router.removalRequest = nil
                        }
                    } message: { request in
                        Text(request.copy.message)
                    }
            }
    }

    private func answer(_ prompt: SignInPrompt, accept: Bool) {
        answeredPromptID = prompt.id
        Task { await users.answer(prompt, accept: accept, router: router) }
    }
}
#endif
