#if os(tvOS)
import SwiftUI

/// Settings › Accounts on Apple TV (spec §4.5): every saved server with its
/// accounts, where accounts are added, signed in again, or signed out, and
/// servers are added or removed. Mirrors `AccountsSettingsView` on iPhone,
/// iPad and Mac; Apple TV keeps no downloads, so none are counted.
/// Switching happens in Change Account.
///
/// Focus: one vertical column of full-width rows in a native focus graph.
/// Up and Down walk the rows; an account's actions open in a dialog, and the
/// shared confirmation (`AccountRemovalConfirmationModifier`) asks before
/// anything is signed out or removed.
struct TVAccountsSettingsView: View {
    @Environment(AppRouter.self) private var router
    @State private var registry = ServerRegistry.shared
    @State private var directory = AccountDirectory.shared
    /// The account whose actions are open.
    @State private var actionTarget: SavedAccountSummary?
    @FocusState private var focusedRow: Row?

    private enum Row: Hashable {
        case account(String)
        case addAccount(String)
        case removeServer(String)
        case addServer
    }

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Accounts")
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                    Text("The servers and accounts saved on this Apple TV, for every Apple TV user.")
                        .font(.system(size: 20))
                        .foregroundColor(.siloSecondaryText)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                ForEach(registry.sortedEntries) { server in
                    serverSection(server)
                }

                TVSettingsSectionHeader("SERVERS")
                row("Add a server", systemImage: "plus", id: .addServer) {
                    router.resetToServerSetup()
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.bottom, 64)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaPadding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 64)
        .background(SettingsBackdrop())
        .defaultFocus($focusedRow, defaultRow)
        .onAppear { directory.reload() }
        .confirmationDialog(
            actionTarget?.username ?? "Account",
            isPresented: Binding(get: { actionTarget != nil }, set: { if !$0 { actionTarget = nil } }),
            titleVisibility: .visible,
            presenting: actionTarget
        ) { account in
            if account.needsSignIn {
                Button("Sign in again") {
                    router.beginSignIn(onServer: account.serverId, renewing: account.localAccountId)
                }
            }
            Button("Sign Out", role: .destructive) {
                Task { await router.confirmSignOut(account: account.localAccountId, onServer: account.serverId) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text(details(for: account))
        }
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
        serverHeader(server)

        ForEach(directory.accounts(onServer: server.id)) { account in
            Button {
                actionTarget = account
            } label: {
                accountLabel(account)
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused($focusedRow, equals: .account(account.localAccountId))
        }

        row("Add an account on \(server.displayName)", systemImage: "person.badge.plus",
            id: .addAccount(server.id)) {
            router.beginAddAccount(onServer: server.id)
        }
        row("Remove \(server.displayName)", systemImage: "trash", id: .removeServer(server.id),
            isDestructive: true) {
            Task { await router.confirmRemoveServer(server.id) }
        }
    }

    private func serverHeader(_ server: ServerEntry) -> some View {
        HStack(spacing: 14) {
            MarqueeServerMark(server: server, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.displayName)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.siloOnSurface)
                    .lineLimit(1)
                Text(server.url)
                    .font(.system(size: 18))
                    .foregroundColor(.siloSecondaryText)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 26)
        .padding(.bottom, 6)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func accountLabel(_ account: SavedAccountSummary) -> some View {
        let inUse = isInUse(account)
        return HStack(spacing: 16) {
            Image(systemName: inUse ? "checkmark.circle.fill" : "person.crop.circle")
                .font(.system(size: 24, weight: .medium))
                .frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(account.username ?? "Account")
                    .font(.system(size: 26, weight: .medium))
                    .lineLimit(1)
                Text(details(for: account))
                    .font(.system(size: 19))
                    .opacity(0.62)
                    .lineLimit(1)
            }
            Spacer(minLength: 16)
            Image(systemName: "ellipsis")
                .font(.system(size: 18, weight: .semibold))
                .opacity(0.55)
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(inUse ? "In use" : "")
    }

    private func row(
        _ title: String,
        systemImage: String,
        id: Row,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 16) {
                Image(systemName: systemImage)
                    .font(.system(size: 22, weight: .semibold))
                    .frame(width: 34)
                Text(title)
                    .font(.system(size: 26))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: isDestructive))
        .focused($focusedRow, equals: id)
    }

    /// "In use · 3 profiles", or why the account can't be used yet.
    private func details(for account: SavedAccountSummary) -> String {
        var parts: [String] = []
        if account.needsSignIn { parts.append("Sign in again") }
        if isInUse(account) { parts.append("In use") }
        if let profiles = ChangeAccountList.profileCount(account.cachedProfiles.count) { parts.append(profiles) }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }

    private func isInUse(_ account: SavedAccountSummary) -> Bool {
        account.serverId == registry.activeServerId
            && AccountScope.localAccountId(onServer: account.serverId) == account.localAccountId
    }
}
#endif
