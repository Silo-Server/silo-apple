#if os(tvOS)
import SwiftUI

/// Who's Watching's footer on Apple TV (spec §5.1): Switch User, Change
/// server (this user's servers), and Sign out. Small utilities below the
/// people. WP4 finishes it.
struct ProfileSelectionTVFooter: View {
    var router: AppRouter
    @Binding var showsSignOutConfirmation: Bool
    var signOutFocus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 20) {
            Button {
                Task { await router.users.beginSwitchUser(router: router) }
            } label: {
                Label("Switch User", systemImage: "person.2")
            }
            .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))

            Button {
                Task { await router.users.showServers(router: router) }
            } label: {
                Label("Change server", systemImage: "server.rack")
            }
            .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))

            Button {
                showsSignOutConfirmation = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))
            .focused(signOutFocus)
        }
    }
}

/// The footer's Sign out confirmation (spec §5.6): it names the user and the
/// server, and says everyone on this Apple TV is affected.
struct ProfileSelectionTVSignOutConfirmation: View {
    var router: AppRouter
    let cancel: () -> Void

    var body: some View {
        let copy = router.users.confirmation(for: .currentSignIn)
        TVSettingsConfirmationOverlay(
            title: copy.title,
            message: copy.message,
            confirmTitle: copy.confirmTitle,
            additionalDestructiveTitle: copy.additionalDestructiveTitle,
            cancel: cancel,
            confirm: router.signOutAndReset,
            additionalDestructiveAction: router.signOutRemoveServerAndReset
        )
    }
}
#endif
