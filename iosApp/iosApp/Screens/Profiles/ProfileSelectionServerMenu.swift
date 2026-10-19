#if !os(tvOS)
import SwiftUI

/// The server chip on Who's Watching for iPhone, iPad, and Mac (spec §5.8):
/// a menu with the device's accounts, Add Account, and Manage Accounts….
struct ProfileSelectionServerMenu: View {
    var router: AppRouter

    private var accounts: SiloAccountCoordinator { router.accounts }

    var body: some View {
        let serverURL = accounts.auth.serverRegistry.activeServerUrl
        let branding = ServerBrandingCache.branding(for: serverURL)
        let name = ServerBranding.displayName(branding, serverURL: serverURL)
        Menu {
            AccountMenuItems(router: router, model: AccountMenuModel(directory: accounts.directory))
        } label: {
            MarqueeServerChipLabel(name: name, markURL: branding?.markURL)
        }
        .menuStyle(.button)
        .buttonStyle(.marqueePressable)
        .accessibilityLabel("\(name), server")
        .accessibilityHint("Shows the accounts on this device.")
    }
}

/// What the chip menu lists, in order (spec §5.8). Kept apart from the
/// `Menu` so its sections can be drawn in rendered checks.
struct AccountMenuItems: View {
    var router: AppRouter
    let model: AccountMenuModel

    private var accounts: SiloAccountCoordinator { router.accounts }

    var body: some View {
        Section(AccountMenuModel.accountsTitle) {
            ForEach(model.items) { item in
                let icon = item.isCurrent ? "checkmark" : "person.crop.circle"
                Button {
                    open(item)
                } label: {
                    // Written out in the label itself: iOS menus read a
                    // second Text there as the item's subtitle, but show
                    // only the first one inside a Label or a helper view.
                    #if os(macOS)
                    Label(Self.oneLine(item.name, item.detail), systemImage: icon)
                    #else
                    Text(item.name)
                    if let detail = item.detail { Text(detail) }
                    Image(systemName: icon)
                    #endif
                }
                .accessibilityValue(item.isCurrent ? "Current" : "")
            }
            Button {
                Task { await accounts.startAddAccount(router: router) }
            } label: {
                Label(AccountMenuModel.addAccountTitle, systemImage: "person.badge.plus")
            }
        }
        Section {
            Button {
                router.navigate(to: .manageAccounts)
            } label: {
                Label(AccountMenuModel.manageAccountsTitle, systemImage: "person.2")
            }
        }
    }

    /// A menu item's title with its detail on the same line, for the Mac's
    /// menus, which draw no second line.
    static func oneLine(_ title: String, _ detail: String?) -> String {
        detail.map { title + AccountMenuModel.separator + $0 } ?? title
    }

    /// The account open now stays open; another one opens its Who's
    /// Watching, or its sign-in screen when it expired.
    private func open(_ item: AccountMenuModel.Item) {
        guard !item.isCurrent else { return }
        Task { await accounts.openAccount(item.id, router: router) }
    }
}
#endif
