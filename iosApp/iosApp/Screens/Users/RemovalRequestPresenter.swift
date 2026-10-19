import SwiftUI

/// Presents, over the whole app, the sign-out and removal confirmations
/// (spec §5.6) on the platform's surface. Attached once at the root; screens
/// raise them through `SiloAccountCoordinator.requestRemoval`.
struct RemovalRequestPresenter: ViewModifier {
    var router: AppRouter

    func body(content: Content) -> some View {
        #if os(tvOS)
        // While a confirmation shows, the screen under it can't take focus.
        content
            .disabled(router.removalRequest != nil)
            .overlay { TVRemovalRequestOverlay(router: router) }
        #else
        content
            .background { RemovalRequestAlert(router: router) }
        #endif
    }
}

#if os(tvOS)
/// The confirmations on Apple TV, in the settings confirmation style. Focus
/// starts on Cancel and Menu cancels; the screen that asked puts focus back
/// on the card or row that opened it.
private struct TVRemovalRequestOverlay: View {
    var router: AppRouter

    var body: some View {
        ZStack {
            if let request = router.removalRequest {
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
                        router.performRemoval(request, removingAccount: true)
                    }
                )
                .id(request.id)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: SiloTheme.fastDuration), value: router.removalRequest?.id)
    }
}
#else
/// The confirmations as alerts on iPhone, iPad, and Mac. Sign out of the
/// current account also offers Remove Account.
private struct RemovalRequestAlert: View {
    var router: AppRouter

    var body: some View {
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
                        router.performRemoval(request, removingAccount: true)
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
#endif
