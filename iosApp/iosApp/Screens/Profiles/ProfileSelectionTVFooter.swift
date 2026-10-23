#if os(tvOS)
import SwiftUI

/// Who's Watching's footer on Apple TV (spec §5.1): Switch Account and Sign
/// out. Small glass utilities below the people, in one row; the picker
/// makes the row a full-width focus section so Down from any avatar column
/// reaches it.
struct ProfileSelectionTVFooter: View {
    var router: AppRouter
    @Binding var showsSignOutConfirmation: Bool
    var signOutFocus: FocusState<Bool>.Binding

    private var accounts: SiloAccountCoordinator { router.accounts }

    var body: some View {
        HStack(spacing: 20) {
            Button {
                Task { await accounts.beginSwitchAccount(router: router) }
            } label: {
                Label("Switch Account", systemImage: "person.2")
            }
            .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))
            .accessibilityHint("Choose another Silo account on this Apple TV, or add one.")

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
}

/// The footer's Sign out confirmation (spec §5.6): it names the account and
/// its server, says everyone on this Apple TV is affected, and offers Remove
/// Account.
struct ProfileSelectionTVSignOutConfirmation: View {
    var router: AppRouter
    let cancel: () -> Void

    var body: some View {
        let copy = router.accounts.confirmation(for: .currentAccount)
        TVSettingsConfirmationOverlay(
            title: copy.title,
            message: copy.message,
            confirmTitle: copy.confirmTitle,
            additionalDestructiveTitle: copy.additionalDestructiveTitle,
            cancel: cancel,
            confirm: router.signOutAndReset,
            additionalDestructiveAction: router.signOutRemoveAccountAndReset
        )
    }
}
#endif
