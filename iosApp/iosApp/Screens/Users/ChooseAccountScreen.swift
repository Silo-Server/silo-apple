#if !os(tvOS)
import SwiftUI

/// Choose an Account on iPhone, iPad, and Mac (spec §5.2, §5.8): one card
/// per account with its username, email, server, and profiles, then Add
/// Account. Touch and hold (or Control-click) a card to sign out of or
/// remove the account.
struct ChooseAccountScreen: View {
    var router: AppRouter
    var focus: SiloAccountRef?

    /// The card whose action is running, so a second tap doesn't start
    /// another.
    @State private var busyItemID: String?

    private var accounts: SiloAccountCoordinator { router.accounts }

    static var hint: String {
        #if os(macOS)
        "Control-click an account to sign out or remove it."
        #else
        "Touch and hold an account to sign out or remove it."
        #endif
    }

    var body: some View {
        let model = ChooseAccountViewModel(directory: accounts.directory, focus: focus)
        UserFlowPage(router: router, wideColumnWidth: 720) { isWide in
            MarqueeHeadline(title: ChooseAccountViewModel.title, alignment: .center)
            cards(model, isWide: isWide)
                .padding(.top, 32)
            if model.showsRemoveHint {
                UserFlowHint(text: Self.hint)
                    .padding(.top, 18)
            }
        } footer: {
            UserFlowUtilityButton(title: AccountMenuModel.manageAccountsTitle, systemImage: "person.2") {
                router.navigate(to: .manageAccounts)
            }
        }
        .disabled(busyItemID != nil)
        .task {
            MarqueeScene.shared.focus = .profiles
            MarqueeScene.shared.personalTint = nil
            await accounts.reloadDirectory()
        }
    }

    /// A card per account, then Add Account: one column on iPhone, two in a
    /// wide window, where the cards in a row share a height.
    private func cards(_ model: ChooseAccountViewModel, isWide: Bool) -> some View {
        let items = model.cards.map(Item.account) + [.addAccount]
        let perRow = isWide ? 2 : 1
        let rows = stride(from: 0, to: items.count, by: perRow).map { Array(items[$0..<min($0 + perRow, items.count)]) }
        return Grid(horizontalSpacing: 12, verticalSpacing: 12) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { item in
                        cell(item)
                    }
                }
            }
        }
        // Rows keep their natural height however tall the page is.
        .fixedSize(horizontal: false, vertical: true)
    }

    private enum Item: Identifiable {
        case account(ChooseAccountViewModel.Card)
        case addAccount

        var id: String {
            switch self {
            case .account(let card): card.id.storageKey
            case .addAccount: "add-account"
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: Item) -> some View {
        switch item {
        case .account(let card):
            Button {
                run(item.id) { await accounts.openAccount(card.id, router: router) }
            } label: {
                AccountCardLabel(card: card)
            }
            .buttonStyle(UserFlowCardButtonStyle(fillsHeight: true))
            .contextMenu {
                AccountActionsMenuItems(router: router, account: card.id,
                                        isSignedIn: card.id.signInKey != nil && !card.needsSignInAgain)
            }
        case .addAccount:
            Button {
                run(item.id) { await accounts.startAddAccount(router: router) }
            } label: {
                UserFlowAdditionLabel(title: ChooseAccountViewModel.addAccountTitle, systemImage: "person.badge.plus")
            }
            .buttonStyle(UserFlowCardButtonStyle(isAddition: true, fillsHeight: true))
        }
    }

    private func run(_ itemID: String, _ action: @escaping () async -> Void) {
        guard busyItemID == nil else { return }
        busyItemID = itemID
        Task {
            await action()
            busyItemID = nil
        }
    }
}

/// An account's long-press (or Control-click) actions: Sign Out while it is
/// signed in, and Remove from This Device.
struct AccountActionsMenuItems: View {
    var router: AppRouter
    let account: SiloAccountRef
    let isSignedIn: Bool

    private var accounts: SiloAccountCoordinator { router.accounts }

    var body: some View {
        if isSignedIn {
            Button(role: .destructive) {
                Task { await accounts.requestRemoval(.signOut(account), router: router) }
            } label: {
                Label(SignOutConfirmationCopy.signOutTitle, systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
        Button(role: .destructive) {
            Task { await accounts.requestRemoval(.remove(account), router: router) }
        } label: {
            Label(SignOutConfirmationCopy.removeFromDeviceTitle(device: accounts.device),
                  systemImage: "person.crop.circle.badge.minus")
        }
    }
}
#endif
