import SwiftUI

#if !os(tvOS)
/// Settings › Accounts (spec §4.5): every saved server with its accounts,
/// where accounts are added, signed in again, or signed out, and servers are
/// added or removed. Replaces the server list as the management surface;
/// switching happens in Change Account.
struct AccountsSettingsView: View {
    @Environment(AppRouter.self) private var router
    @State private var registry = ServerRegistry.shared
    @State private var directory = AccountDirectory.shared
    @State private var downloads = AccountDownloadSummaries()

    var body: some View {
        List {
            ForEach(registry.sortedEntries) { server in
                serverSection(server)
            }

            Section {
                Button {
                    router.resetToServerSetup()
                } label: {
                    Label(.accountsAddAServer, systemImage: "plus")
                        .foregroundColor(.siloOnSurface)
                }
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
        .navigationTitle(Text(.accountsTitle))
        .siloNavigationTitleDisplayMode(.inline)
        .task(id: directory.accounts.map(\.id)) {
            directory.reload()
            await downloads.load(directory.accounts)
        }
    }

    private func serverSection(_ server: ServerEntry) -> some View {
        Section {
            ForEach(directory.accounts(onServer: server.id)) { account in
                NavigationLink {
                    AccountDetailView(serverId: server.id, localAccountId: account.localAccountId, downloads: downloads)
                } label: {
                    AccountRow(account: account, isInUse: isInUse(account), downloads: downloads[account.localAccountId])
                }
                // Not `.destructive`: that removes the row at once, and it
                // would stay gone after Cancel in the confirmation.
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button(.settingsAccountsSignOut) { signOut(account) }
                        .tint(.red)
                }
                .contextMenu {
                    if account.needsSignIn {
                        Button(.settingsAccountsSignInAgain, systemImage: "person.crop.circle.badge.exclamationmark") {
                            router.beginSignIn(onServer: server.id, renewing: account.localAccountId)
                        }
                    }
                    Button(.settingsAccountsSignOut, systemImage: "rectangle.portrait.and.arrow.right", role: .destructive) {
                        signOut(account)
                    }
                }
            }

            Button {
                router.beginAddAccount(onServer: server.id)
            } label: {
                Label(.accountsAddAccountOnServer(server.displayName), systemImage: "person.badge.plus")
                    .foregroundColor(.siloOnSurface)
            }

            Button(role: .destructive) {
                Task { await router.confirmRemoveServer(server.id) }
            } label: {
                Label(.accountsRemoveServer, systemImage: "trash")
            }
        } header: {
            ServerSectionHeader(server: server)
        }
        .listRowBackground(Color.siloGroupedCell)
    }

    /// Asks first, through the app's shared sign-out confirmation.
    private func signOut(_ account: SavedAccountSummary) {
        Task { await router.confirmSignOut(account: account.localAccountId, onServer: account.serverId) }
    }

    private func isInUse(_ account: SavedAccountSummary) -> Bool {
        account.serverId == registry.activeServerId
            && AccountScope.localAccountId(onServer: account.serverId) == account.localAccountId
    }
}

/// Download counts per account, read once per visit (no network).
@Observable
@MainActor
final class AccountDownloadSummaries {
    private(set) var byAccount: [String: DownloadAccountSummary] = [:]

    subscript(localAccountId: String) -> DownloadAccountSummary? { byAccount[localAccountId] }

    func load(_ accounts: [SavedAccountSummary]) async {
        var loaded: [String: DownloadAccountSummary] = [:]
        for account in accounts {
            loaded[account.localAccountId] = await AccountSessions.downloadSummary(
                account: account.localAccountId, onServer: account.serverId)
        }
        byAccount = loaded
    }
}

private struct ServerSectionHeader: View {
    let server: ServerEntry

    var body: some View {
        HStack(spacing: 8) {
            MarqueeServerMark(server: server, size: 20)
            Text(server.displayName)
                .lineLimit(1)
        }
        .foregroundColor(.siloSecondaryText)
        .accessibilityElement(children: .combine)
    }
}

private struct AccountRow: View {
    let account: SavedAccountSummary
    let isInUse: Bool
    let downloads: DownloadAccountSummary?
    @Environment(\.locale) private var locale

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isInUse ? "checkmark.circle.fill" : "person.crop.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.siloOnSurface)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.username.map { LocalizedStringResource.verbatim($0) } ?? .settingsAccountsAccount)
                    .font(.siloSubheadline)
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
                Text(details)
                    .font(.siloCaption)
                    .foregroundColor(account.needsSignIn ? .siloOnSurface : .siloSecondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(isInUse ? Text(.settingsAccountsInUse) : Text(verbatim: ""))
    }

    /// "3 profiles · 12 downloads", or why the account can't be used yet.
    private var details: String {
        var resources: [LocalizedStringResource] = []
        if account.needsSignIn { resources.append(.accountsBadgeSignInAgain) }
        if let profiles = ChangeAccountList.profileCount(account.cachedProfiles.count) { resources.append(profiles) }
        if let count = downloads?.count, count > 0 {
            resources.append(.accountsDownloadCount(count: count, String(count)))
        }
        let parts = resources.map { AppLanguage.string($0, locale: locale) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}

/// One account: its server, profiles and downloads, with Sign in again and
/// Sign out.
private struct AccountDetailView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.dismiss) private var dismiss
    let serverId: String
    let localAccountId: String
    let downloads: AccountDownloadSummaries
    @State private var directory = AccountDirectory.shared

    private var account: SavedAccountSummary? { directory.account(localAccountId) }

    var body: some View {
        List {
            if let account {
                Section {
                    LabeledContent {
                        Text(account.username.map { LocalizedStringResource.verbatim($0) } ?? .settingsAccountsPageUsernameUnknown)
                    } label: {
                        Text(.settingsAccountsPageAccount)
                    }
                    .accessibilityElement(children: .combine)
                    LabeledContent {
                        Text(verbatim: ServerRegistry.shared.entry(with: serverId)?.displayName ?? "")
                    } label: {
                        Text(.accountServer)
                    }
                    .accessibilityElement(children: .combine)
                    LabeledContent {
                        Text(downloadsText)
                    } label: {
                        Text(.accountDownloads)
                    }
                    .accessibilityElement(children: .combine)
                }
                .listRowBackground(Color.siloGroupedCell)

                if !account.cachedProfiles.isEmpty {
                    Section {
                        ForEach(account.cachedProfiles) { profile in
                            Text(profile.name)
                        }
                    } header: {
                        Text(.accountProfiles)
                    }
                    .listRowBackground(Color.siloGroupedCell)
                }

                Section {
                    if account.needsSignIn {
                        Button(.accountSignInAgain) {
                            router.beginSignIn(onServer: serverId, renewing: localAccountId)
                        }
                    }
                    Button(.commonSignOut, role: .destructive) {
                        Task { await router.confirmSignOut(account: localAccountId, onServer: serverId) }
                    }
                } footer: {
                    Text(.settingsAccountsPageSignOutFooter)
                }
                .listRowBackground(Color.siloGroupedCell)
            }
        }
        .settingsListChrome()
        .navigationTitle(Text(account?.username.map { LocalizedStringResource.verbatim($0) } ?? .settingsAccountsAccount))
        .siloNavigationTitleDisplayMode(.inline)
        .onChange(of: account == nil) { _, gone in
            // Signed out from here: nothing left to show.
            if gone { dismiss() }
        }
    }

    private var downloadsText: LocalizedStringResource {
        guard let summary = downloads[localAccountId], summary.count > 0 else { return .accountDownloadsNone }
        let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
        return .verbatim("\(summary.count) · \(size)")
    }
}
#endif
