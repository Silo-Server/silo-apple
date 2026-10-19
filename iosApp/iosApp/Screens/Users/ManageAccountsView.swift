#if !os(tvOS)
import SwiftUI

/// Settings › Accounts on iPhone, iPad, and Mac (spec §5.7, §5.8 Manage
/// Accounts…): a row per account with Sign Out (or Sign In Again once it
/// expired), and Remove in its swipe and context menus; Add Account at the
/// end. Every sign-out and removal asks first, since saved accounts are
/// shared by everyone on the device.
struct ManageAccountsView: View {
    var router: AppRouter

    /// Add Account is starting; a second tap waits for it.
    @State private var isAddingAccount = false

    private var accounts: SiloAccountCoordinator { router.accounts }

    var body: some View {
        let model = AccountsSettingsViewModel(directory: accounts.directory, device: accounts.device)
        List {
            Section {
                ForEach(model.rows) { row in
                    accountRow(row, removeTitle: model.removeTitle)
                }
            }
            .listRowBackground(Color.siloGroupedCell)
            Section {
                Button {
                    guard !isAddingAccount else { return }
                    isAddingAccount = true
                    Task {
                        await accounts.startAddAccount(router: router)
                        isAddingAccount = false
                    }
                } label: {
                    Label(AccountsSettingsViewModel.addAccountTitle, systemImage: "person.badge.plus")
                        .foregroundStyle(Color.siloOnSurface)
                }
                .settingsRowButtonStyle()
                .disabled(isAddingAccount)
            } footer: {
                Text(AccountsSettingsViewModel.footer(device: accounts.device))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
        .navigationTitle(AccountsSettingsViewModel.title)
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task { await accounts.reloadDirectory() }
    }

    /// The account: avatars of its profiles, its name, email, and server,
    /// Current, and Sign Out or Sign In Again.
    private func accountRow(_ row: AccountsSettingsViewModel.Row, removeTitle: String) -> some View {
        let entry = accounts.directory.account(row.id)
        return HStack(spacing: 12) {
            StackedProfileAvatars(
                profiles: entry?.profiles ?? [],
                fallbackID: row.id.storageKey,
                fallbackName: row.name,
                serverAddress: entry?.serverAddress,
                maxCount: 3
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name)
                    .font(.headline)
                    .foregroundStyle(Color.siloOnSurface)
                ForEach(row.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                if row.needsSignInAgain {
                    Text(ChooseAccountViewModel.signInAgainLabel)
                        .font(.footnote)
                        .foregroundStyle(Color.siloStatusWarning)
                } else if row.isCurrent {
                    Text(AccountsSettingsViewModel.currentLabel)
                        .font(.footnote)
                        .foregroundStyle(Color.siloSecondaryText)
                    if LocalRouteController.shared.isOnLocalNetwork {
                        LocalRouteStatusLine()
                            .font(.footnote)
                            .foregroundStyle(Color.siloSecondaryText)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if row.needsSignInAgain {
                Button(AccountsSettingsViewModel.signInAgainTitle) {
                    Task { await accounts.openAccount(row.id, router: router) }
                }
                .buttonStyle(.borderless)
            } else if row.canSignOut {
                Button(AccountsSettingsViewModel.signOutTitle) {
                    Task { await accounts.requestRemoval(.signOut(row.id), router: router) }
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.siloErrorInk)
            }
        }
        .padding(.vertical, 4)
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                Task { await accounts.requestRemoval(.remove(row.id), router: router) }
            } label: {
                Label(removeTitle, systemImage: "person.crop.circle.badge.minus")
            }
        }
        .contextMenu {
            if row.needsSignInAgain {
                Button {
                    Task { await accounts.openAccount(row.id, router: router) }
                } label: {
                    Label(AccountsSettingsViewModel.signInAgainTitle, systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            AccountActionsMenuItems(router: router, account: row.id, isSignedIn: row.canSignOut)
        }
    }
}

private extension View {
    /// A whole-row action in a settings list: the Mac's list would draw a
    /// bordered push button, which its other settings rows don't use.
    @ViewBuilder
    func settingsRowButtonStyle() -> some View {
        #if os(macOS)
        buttonStyle(.plain)
        #else
        self
        #endif
    }
}
#endif
