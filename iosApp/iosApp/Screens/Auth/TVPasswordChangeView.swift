#if os(tvOS)
import SwiftUI

/// Apple TV, after signing in with a temporary password an admin set. The
/// server refuses everything but the password change until the account
/// chooses its own, and three passwords are a lot to type with a remote, so
/// the TV points at the iPhone or iPad app (`PasswordChangeView`) or the web,
/// and offers sign-out. Changing the password there ends this TV's session;
/// the TV finds out on its next request, so Sign out is the way forward.
struct TVPasswordChangeView: View {
    var router: AppRouter
    @State private var accountName: String?

    var body: some View {
        MarqueeTVScreen {
            Text("Choose a new\npassword")
                .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                .kerning(-2)
                .foregroundStyle(Color.siloOnSurface)
                .lineLimit(2)
                .minimumScaleFactor(0.6)
                .accessibilityAddTraits(.isHeader)
            MarqueeTVBody(message)
                .padding(.top, 26)

            Button("Sign out") { router.signOutAndReset() }
                .buttonStyle(.marquee(.primary, fullWidth: false))
                .padding(.top, 56)
                .accessibilityIdentifier("passwordChange.signOut")
        } card: {
            EmptyView()
        }
        .onAppear { MarqueeScene.shared.showActiveServer() }
        .task { accountName = try? await SiloAPI.shared.currentUser().username }
    }

    private var message: String {
        let account = accountName.flatMap { $0.isEmpty ? nil : $0 } ?? "this account"
        return "An admin set a temporary password for \(account). Choose your own in Silo on your iPhone or iPad, or in a web browser, then sign in here with it."
    }
}
#endif
