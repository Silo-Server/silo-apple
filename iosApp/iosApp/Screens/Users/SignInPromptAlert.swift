#if !os(tvOS)
import SwiftUI

/// The sign-in questions (spec §5.4.1) and sign-out and removal
/// confirmations (spec §5.6, plan G10) as alerts on iPhone, iPad, and Mac.
/// WP5 finishes them.
struct SignInPromptAlert: View {
    var router: AppRouter

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        Color.clear
            .allowsHitTesting(false)
            .alert(
                router.signInPrompt?.copy.title ?? "",
                isPresented: Binding(
                    get: { router.signInPrompt != nil },
                    set: { _ in }
                ),
                presenting: router.signInPrompt
            ) { prompt in
                Button(prompt.copy.confirmTitle) {
                    Task { await users.answer(prompt, accept: true, router: router) }
                }
                Button(ConfirmationCopy.cancelTitle, role: .cancel) {
                    Task { await users.answer(prompt, accept: false, router: router) }
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
                        Button(request.copy.confirmTitle, role: .destructive) {
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
}
#endif
