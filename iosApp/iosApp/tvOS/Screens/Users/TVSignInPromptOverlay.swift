#if os(tvOS)
import SwiftUI

/// The sign-in questions (spec §5.4.1) and sign-out and removal
/// confirmations (spec §5.6) on Apple TV, in the settings confirmation
/// style. Focus starts on Cancel, and Menu cancels. WP4 finishes the look.
struct TVSignInPromptOverlay: View {
    var router: AppRouter

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        ZStack {
            if let prompt = router.signInPrompt {
                TVSettingsConfirmationOverlay(
                    title: prompt.copy.title,
                    message: prompt.copy.message,
                    confirmTitle: prompt.copy.confirmTitle,
                    cancel: { Task { await users.answer(prompt, accept: false, router: router) } },
                    confirm: { Task { await users.answer(prompt, accept: true, router: router) } }
                )
                .transition(.opacity)
            } else if let request = router.removalRequest {
                TVSettingsConfirmationOverlay(
                    title: request.copy.title,
                    message: request.copy.message,
                    confirmTitle: request.copy.confirmTitle,
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
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: router.signInPrompt?.id)
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: router.removalRequest?.id)
    }
}
#endif
