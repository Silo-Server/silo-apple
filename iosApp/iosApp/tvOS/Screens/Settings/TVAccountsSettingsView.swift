#if os(tvOS)
import SwiftUI

/// Settings › Accounts on Apple TV (spec §4.5): every saved server with its
/// accounts, where accounts are added, signed in again, or signed out, and
/// servers are added or removed. Apple TV keeps no downloads, so none are
/// counted. Switching happens in Change Account.
///
/// Drawn with Roku's rows (`SettingsAccounts`): under each server's name,
/// its accounts with how many profiles each has, Add an account on it, and
/// Remove Server; then Add a server and a line on what signing out keeps.
/// Select on an account asks to sign out of it, or offers to sign in again
/// when it needs to.
///
/// Focus: one vertical column of full-width rows in a native focus graph.
/// Up and Down walk the rows; the shared confirmation
/// (`AccountRemovalConfirmationModifier`) asks before anything is signed out
/// or removed.
struct TVAccountsSettingsView: View {
    @Environment(AppRouter.self) private var router
    @State private var registry = ServerRegistry.shared
    @State private var directory = AccountDirectory.shared
    /// The account waiting to sign in again whose choices are open.
    @State private var expiredTarget: SavedAccountSummary?
    @FocusState private var focusedRow: Row?
    @Environment(\.locale) private var locale

    private enum Row: Hashable {
        case account(String)
        case addAccount(String)
        case removeServer(String)
        case addServer
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                header
                    .padding(.bottom, 10)

                ForEach(registry.sortedEntries) { server in
                    serverSection(server)
                }

                row(.settingsAccountsAddServer, id: .addServer) {
                    // Pushed, so Menu returns here (TVMainTabView `.serverSetup`).
                    router.navigate(to: .serverSetup)
                }
                .padding(.top, 18)

                Text(.settingsAccountsFooterAppleTv)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.siloSecondaryText)
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.bottom, 64)
        }
        .contentMargins(.horizontal, 18, for: .scrollContent)
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaPadding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 64)
        .background(SettingsBackdrop())
        .defaultFocus($focusedRow, defaultRow)
        .onAppear { directory.reload() }
        .confirmationDialog(
            expiredTarget.map { account in
                Text(.settingsAccountsExpiredTitleAppleTv(account.username ?? AppLanguage.string(.settingsAccountsAccount, locale: locale)))
            } ?? Text(verbatim: ""),
            isPresented: Binding(get: { expiredTarget != nil }, set: { if !$0 { expiredTarget = nil } }),
            titleVisibility: .visible,
            presenting: expiredTarget
        ) { account in
            Button(.accountSignInAgain) {
                router.beginSignIn(onServer: account.serverId, renewing: account.localAccountId)
            }
            Button(.settingsAccountsSignOut, role: .destructive) {
                Task { await router.confirmSignOut(account: account.localAccountId, onServer: account.serverId) }
            }
            Button(.commonCancel, role: .cancel) {}
        }
    }

    /// The Settings pane header: the category's tile, title, and line.
    private var header: some View {
        HStack(alignment: .center, spacing: 20) {
            Image(systemName: "server.rack")
                .font(.system(size: 34, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(Color.siloIconTile, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(.accountsTitle)
                    .font(.system(size: 42, weight: .bold))
                    .foregroundStyle(Color.siloOnSurface)
                Text(.serversAccountsBlurbAppleTv)
                    .font(.system(size: 20))
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        .padding(.horizontal, 24)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private var defaultRow: Row {
        let first = registry.sortedEntries.first
        if let account = first.flatMap({ directory.accounts(onServer: $0.id).first }) {
            return .account(account.localAccountId)
        }
        return first.map { .addAccount($0.id) } ?? .addServer
    }

    @ViewBuilder
    private func serverSection(_ server: ServerEntry) -> some View {
        TVSettingsSectionHeader(.verbatim(server.displayName.uppercased()))
            .accessibilityAddTraits(.isHeader)

        ForEach(directory.accounts(onServer: server.id)) { account in
            row(
                account.username.map { .verbatim($0) } ?? .settingsAccountsAccount,
                value: value(for: account),
                id: .account(account.localAccountId)
            ) {
                if account.needsSignIn {
                    expiredTarget = account
                } else {
                    Task { await router.confirmSignOut(account: account.localAccountId, onServer: account.serverId) }
                }
            }
        }

        row(.accountsAddAccountOnServer(server.displayName), id: .addAccount(server.id)) {
            router.beginAddAccount(onServer: server.id)
        }
        row(.settingsAccountsRemove, id: .removeServer(server.id), isDestructive: true) {
            Task { await router.confirmRemoveServer(server.id) }
        }
    }

    /// A pane row: its title, an optional value, and a chevron unless it
    /// removes something.
    private func row(
        _ title: LocalizedStringResource,
        value: LocalizedStringResource? = nil,
        id: Row,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Text(title)
                    .font(.system(size: 26))
                    .lineLimit(1)
                Spacer(minLength: 16)
                if let value {
                    Text(value)
                        .font(.system(size: 24))
                        .opacity(0.68)
                        .lineLimit(1)
                }
                if !isDestructive {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 18, weight: .semibold))
                        .opacity(0.55)
                }
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: isDestructive))
        .focused($focusedRow, equals: id)
    }

    /// "3 profiles", or "Sign in again" while the account can't be used.
    private func value(for account: SavedAccountSummary) -> LocalizedStringResource? {
        if account.needsSignIn { return .accountsBadgeSignInAgain }
        return ChangeAccountList.profileCount(account.cachedProfiles.count)
    }
}
#endif
