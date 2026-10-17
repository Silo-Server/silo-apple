import SwiftUI

/// Presents, over the whole app, the questions a sign-in raises (spec
/// §5.4.1), sign-out and removal confirmations (spec §5.6), and rename
/// (spec §5.2), on the platform's surface. Attached once at the root;
/// screens raise them through `SiloUserCoordinator`.
struct SignInPromptPresenter: ViewModifier {
    var router: AppRouter

    func body(content: Content) -> some View {
        #if os(tvOS)
        // While a question or confirmation shows, the screen under it can't
        // take focus.
        content
            .disabled(router.signInPrompt != nil || router.removalRequest != nil)
            .overlay { TVSignInPromptOverlay(router: router) }
            .fullScreenCover(item: Binding(
                get: { router.renameRequest },
                set: { router.renameRequest = $0 }
            )) { request in
                TVRenameUserSheet(router: router, request: request)
            }
        #else
        content
            .background { SignInPromptAlert(router: router) }
            .background { RenameUserAlert(router: router) }
        #endif
    }
}
