#if os(tvOS)
import SwiftUI

/// Who's Watching's footer on Apple TV (spec §5.1): Switch User, Change
/// server (this user's servers), and Sign out. Small glass utilities below
/// the people, in one row; the picker makes the row a full-width focus
/// section so Down from any avatar column reaches it.
struct ProfileSelectionTVFooter: View {
    var router: AppRouter
    @Binding var showsSignOutConfirmation: Bool
    var signOutFocus: FocusState<Bool>.Binding

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        HStack(spacing: 20) {
            Button {
                Task { await users.beginSwitchUser(router: router) }
            } label: {
                Label("Switch User", systemImage: "person.2")
            }
            .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))
            .accessibilityHint("Choose another Silo user on this Apple TV, or add one.")

            Button {
                Task { await users.showServers(router: router) }
            } label: {
                Label("Change server", systemImage: "server.rack")
            }
            .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))
            .accessibilityHint(changeServerHint)

            Button {
                showsSignOutConfirmation = true
            } label: {
                Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
            .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))
            .focused(signOutFocus)
            .accessibilityHint("Asks first. Signing out affects everyone on this Apple TV.")
        }
    }

    private var changeServerHint: String {
        guard let user = users.directory.currentUser else { return "Choose another server." }
        return "Choose another of \(user.name)'s servers, or add one."
    }
}

/// The footer's Sign out confirmation (spec §5.6): it names the user and the
/// server, says everyone on this Apple TV is affected, and offers Sign Out &
/// Remove Server, which names the server's other users.
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
