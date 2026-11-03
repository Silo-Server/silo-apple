import SwiftUI

/// Asks before signing out of an account, removing a server, or replacing an
/// account that signed in again as someone else (`AppRouter.pendingRemoval`).
/// Applied once at the root, so every screen that starts one (the profile
/// menu, the picker, Settings › Accounts, the server list) shows the same
/// confirmation.
///
/// It is the app's own dialog with Cancel as the default (spec §4.4): a
/// system dialog that focused "Sign out" caused an accidental sign-out on a
/// TV.
struct AccountRemovalConfirmationModifier: ViewModifier {
    let router: AppRouter

    func body(content: Content) -> some View {
        content
            #if os(tvOS)
            // Focus stays in the dialog while it is up.
            .disabled(router.pendingRemoval != nil)
            #endif
            .overlay {
                if let request = router.pendingRemoval {
                    dialog(for: request)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.2), value: router.pendingRemoval)
    }

    @ViewBuilder
    private func dialog(for request: AccountRemovalRequest) -> some View {
        #if os(tvOS)
        TVSettingsConfirmationOverlay(
            title: request.title,
            message: request.message ?? "",
            confirmTitle: request.confirmTitle,
            additionalDestructiveTitle: request.alternative?.title,
            cancel: cancel,
            confirm: { router.perform(request) },
            additionalDestructiveAction: request.alternative == nil
                ? nil
                : { router.perform(request, choosingAlternative: true) }
        )
        #else
        AccountRemovalDialog(
            request: request,
            onConfirm: { router.perform(request, choosingAlternative: $0) },
            onCancel: cancel
        )
        #endif
    }

    private func cancel() {
        router.pendingRemoval = nil
    }
}

#if !os(tvOS)
/// The confirmation on iPhone, iPad and Mac: the destructive choices, then
/// Cancel as the prominent default (Return answers it).
private struct AccountRemovalDialog: View {
    let request: AccountRemovalRequest
    /// `true` for the alternative ("Sign Out & Remove Server").
    let onConfirm: (Bool) -> Void
    let onCancel: () -> Void

    @FocusState private var isCancelFocused: Bool

    var body: some View {
        MarqueeDialog(onCancel: onCancel) {
            MarqueeDialogHeader(title: request.title, message: request.message)
            VStack(spacing: 10) {
                destructiveButton(request.confirmTitle) { onConfirm(false) }
                if let alternative = request.alternative {
                    destructiveButton(alternative.title) { onConfirm(true) }
                }
                Button(request.cancelTitle, action: onCancel)
                    .buttonStyle(.marquee(.primary))
                    .keyboardShortcut(.defaultAction)
                    .focused($isCancelFocused)
            }
            .padding(.top, 20)
        }
        .defaultFocus($isCancelFocused, true)
        .onAppear { isCancelFocused = true }
    }

    private func destructiveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).foregroundStyle(Color.siloErrorInk)
        }
        .buttonStyle(.marquee(.glass))
    }
}
#endif
