import SwiftUI

/// Asks before signing out of an account, removing a server, or replacing an
/// account that signed in again as someone else (`AppRouter.pendingRemoval`).
/// Applied once at the root, so every screen that starts one (the profile
/// menu, the picker, Settings › Accounts, the server list) shows the same
/// confirmation.
///
/// iPhone, iPad and Mac use the system alert, like the app's other
/// confirmations. Apple TV uses the app's own dialog with Cancel focused
/// (spec §4.4): a system dialog that focused "Sign out" caused an accidental
/// sign-out on a TV.
struct AccountRemovalConfirmationModifier: ViewModifier {
    let router: AppRouter

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
            // Focus stays in the dialog while it is up.
            .disabled(router.pendingRemoval != nil)
            .overlay {
                if let request = router.pendingRemoval {
                    TVSettingsConfirmationOverlay(
                        title: request.title,
                        message: request.message ?? "",
                        confirmTitle: request.confirmTitle,
                        cancel: cancel,
                        confirm: { router.perform(request) }
                    )
                    .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: router.pendingRemoval)
        #else
        content
            .alert(
                router.pendingRemoval?.title ?? "",
                isPresented: isPresented,
                presenting: router.pendingRemoval
            ) { request in
                Button(request.confirmTitle, role: .destructive) { router.perform(request) }
                Button(request.cancelTitle, role: .cancel, action: cancel)
            } message: { request in
                if let message = request.message {
                    Text(message)
                }
            }
        #endif
    }

    #if !os(tvOS)
    private var isPresented: Binding<Bool> {
        Binding(
            get: { router.pendingRemoval != nil },
            set: { if !$0 { cancel() } }
        )
    }
    #endif

    private func cancel() {
        router.pendingRemoval = nil
    }
}
