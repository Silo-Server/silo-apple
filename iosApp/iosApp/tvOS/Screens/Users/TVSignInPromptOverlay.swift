#if os(tvOS)
import SwiftUI

/// The sign-in questions (spec §5.4.1) and the sign-out and removal
/// confirmations (spec §5.6) on Apple TV, in the settings confirmation
/// style. Focus starts on Cancel and Menu cancels. The screen under it is
/// disabled meanwhile (`SignInPromptPresenter`); the screen that asked puts
/// focus back on the card or row that opened it.
struct TVSignInPromptOverlay: View {
    var router: AppRouter

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        ZStack {
            if let prompt = router.signInPrompt {
                // A question about where a sign-in goes: answering it loses
                // nothing, so its button isn't red. Cancel revokes the new
                // session.
                TVSettingsConfirmationOverlay(
                    title: prompt.copy.title,
                    message: prompt.copy.message,
                    confirmTitle: prompt.copy.confirmTitle,
                    confirmIsDestructive: prompt.copy.confirmIsDestructive,
                    cancel: { Task { await users.answer(prompt, accept: false, router: router) } },
                    confirm: { Task { await users.answer(prompt, accept: true, router: router) } }
                )
                .id(prompt.id)
                .transition(.opacity)
            } else if let request = router.removalRequest {
                TVSettingsConfirmationOverlay(
                    title: request.copy.title,
                    message: request.copy.message,
                    confirmTitle: request.copy.confirmTitle,
                    confirmIsDestructive: request.copy.confirmIsDestructive,
                    additionalDestructiveTitle: request.copy.additionalDestructiveTitle,
                    cancel: { router.removalRequest = nil },
                    confirm: {
                        router.removalRequest = nil
                        router.performRemoval(request)
                    },
                    additionalDestructiveAction: request.copy.additionalDestructiveTitle == nil ? nil : {
                        router.removalRequest = nil
                        router.performRemoval(request, removingServer: true)
                    }
                )
                .id(request.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: router.signInPrompt?.id)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: router.removalRequest?.id)
    }
}
#endif
