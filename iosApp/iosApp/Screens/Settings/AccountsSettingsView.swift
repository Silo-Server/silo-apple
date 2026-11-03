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
                    Label("Add a server", systemImage: "plus")
                        .foregroundColor(.siloOnSurface)
                }
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
        .navigationTitle("Accounts")
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
            }

            Button {
                router.beginAddAccount(onServer: server.id)
            } label: {
                Label("Add an account on \(server.displayName)", systemImage: "person.badge.plus")
                    .foregroundColor(.siloOnSurface)
            }

            Button(role: .destructive) {
                Task { await router.confirmRemoveServer(server.id) }
            } label: {
                Label("Remove server", systemImage: "trash")
            }
        } header: {
            ServerSectionHeader(server: server)
        }
        .listRowBackground(Color.siloGroupedCell)
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

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isInUse ? "checkmark.circle.fill" : "person.crop.circle")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(.siloOnSurface)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(account.username ?? "Account")
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
        .accessibilityValue(isInUse ? "In use" : "")
    }

    /// "3 profiles · 12 downloads", or why the account can't be used yet.
    private var details: String {
        var parts: [String] = []
        if account.needsSignIn { parts.append("Sign in again") }
        if let profiles = ChangeAccountList.profileCount(account.cachedProfiles.count) { parts.append(profiles) }
        if let count = downloads?.count, count > 0 {
            parts.append("\(count) \(count == 1 ? "download" : "downloads")")
        }
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
                    LabeledContent("Account", value: account.username ?? "Not known yet")
                    LabeledContent("Server", value: ServerRegistry.shared.entry(with: serverId)?.displayName ?? "")
                    LabeledContent("Downloads", value: downloadsText)
                }
                .listRowBackground(Color.siloGroupedCell)

                if !account.cachedProfiles.isEmpty {
                    Section("Profiles") {
                        ForEach(account.cachedProfiles) { profile in
                            Text(profile.name)
                        }
                    }
                    .listRowBackground(Color.siloGroupedCell)
                }

                Section {
                    if account.needsSignIn {
                        Button("Sign in again") {
                            router.beginSignIn(onServer: serverId, renewing: localAccountId)
                        }
                    }
                    Button("Sign out", role: .destructive) {
                        Task { await router.confirmSignOut(account: localAccountId, onServer: serverId) }
                    }
                } footer: {
                    Text("Signing out deletes this account's downloads from this device.")
                }
                .listRowBackground(Color.siloGroupedCell)
            }
        }
        .settingsListChrome()
        .navigationTitle(account?.username ?? "Account")
        .siloNavigationTitleDisplayMode(.inline)
        .onChange(of: account == nil) { _, gone in
            // Signed out from here: nothing left to show.
            if gone { dismiss() }
        }
    }

    private var downloadsText: String {
        guard let summary = downloads[localAccountId], summary.count > 0 else { return "None" }
        let size = ByteCountFormatter.string(fromByteCount: summary.bytes, countStyle: .file)
        return "\(summary.count) · \(size)"
    }
}
#endif
