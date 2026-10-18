#if !os(tvOS)
import SwiftUI

/// Choose a User on iPhone, iPad, and Mac (spec §5.2, §5.8): one card per
/// user with the profiles of its last server, then Add User. Touch and hold
/// (or Control-click) a card to rename or remove the user. Picking a user
/// with two or more servers opens Choose a Server on its last one.
struct ChooseUserScreen: View {
    var router: AppRouter
    var focusUserID: String?

    /// The card whose action is running, so a second tap doesn't start
    /// another.
    @State private var busyItemID: String?

    private var users: SiloUserCoordinator { router.users }

    static var hint: String {
        #if os(macOS)
        "Control-click a user to rename or remove it."
        #else
        "Touch and hold a user to rename or remove it."
        #endif
    }

    var body: some View {
        let model = ChooseUserViewModel(directory: users.directory, focusUserID: focusUserID)
        UserFlowPage(router: router, wideColumnWidth: 720) { isWide in
            MarqueeHeadline(title: ChooseUserViewModel.title, alignment: .center)
            cards(model, isWide: isWide)
                .padding(.top, 32)
            if model.showsRemoveHint {
                UserFlowHint(text: Self.hint)
                    .padding(.top, 18)
            }
        } footer: {
            UserFlowUtilityButton(title: ServerChipMenuModel.manageUsersTitle, systemImage: "person.2") {
                router.navigate(to: .manageUsers)
            }
        }
        .disabled(busyItemID != nil)
        .task {
            MarqueeScene.shared.focus = .profiles
            MarqueeScene.shared.personalTint = nil
            await users.reloadDirectory()
        }
    }

    /// A card per user, then Add User: one column on iPhone, two in a wide
    /// window, where the cards in a row share a height.
    private func cards(_ model: ChooseUserViewModel, isWide: Bool) -> some View {
        let items = model.cards.map(Item.user) + [.addUser]
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
        case user(ChooseUserViewModel.Card)
        case addUser

        var id: String {
            switch self {
            case .user(let card): card.id
            case .addUser: "add-user"
            }
        }
    }

    @ViewBuilder
    private func cell(_ item: Item) -> some View {
        switch item {
        case .user(let card):
            Button {
                run(item.id) { await users.openUser(card.id, router: router) }
            } label: {
                UserCardLabel(card: card, serverAddress: users.directory.user(card.id)?.lastUsedServer?.address)
            }
            .buttonStyle(UserFlowCardButtonStyle(fillsHeight: true))
            .contextMenu {
                Button {
                    Task { await users.requestRename(card.id, router: router) }
                } label: {
                    Label(ManageUsersView.renameTitle, systemImage: "pencil")
                }
                Button(role: .destructive) {
                    Task { await users.requestRemoval(.user(card.id), router: router) }
                } label: {
                    Label(SignOutConfirmationCopy.removeFromDeviceTitle(device: users.device),
                          systemImage: "person.crop.circle.badge.minus")
                }
            }
        case .addUser:
            Button {
                run(item.id) { await users.startAddUser(router: router) }
            } label: {
                UserFlowAdditionLabel(title: ChooseUserViewModel.addUserTitle, systemImage: "person.badge.plus")
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
#endif
