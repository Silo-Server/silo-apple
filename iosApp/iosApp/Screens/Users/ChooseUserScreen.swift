#if !os(tvOS)
import SwiftUI

/// Choose a User on iPhone, iPad, and Mac (spec §5.2, §5.8). A working
/// plain list: WP5 gives it the cards and final layout.
struct ChooseUserScreen: View {
    var router: AppRouter
    var focusUserID: String?

    private var users: SiloUserCoordinator { router.users }

    var body: some View {
        let model = ChooseUserViewModel(directory: users.directory, focusUserID: focusUserID)
        List {
            Section {
                ForEach(model.cards) { card in
                    Button {
                        Task { await users.openUser(card.id, router: router) }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(card.name)
                                .font(.siloSubheadline)
                                .foregroundColor(.siloOnSurface)
                            Text(card.accessibilityValue)
                                .font(.siloCaption)
                                .foregroundColor(.siloSecondaryText)
                        }
                    }
                    .accessibilityValue(card.accessibilityValue)
                    .contextMenu {
                        Button("Rename") {
                            Task { await users.requestRename(card.id, router: router) }
                        }
                        Button(SignOutConfirmationCopy.removeFromDeviceTitle(device: users.device),
                               role: .destructive) {
                            Task { await users.requestRemoval(.user(card.id), router: router) }
                        }
                    }
                }
            } footer: {
                if model.showsRemoveHint {
                    Text("Touch and hold a user to rename or remove it.")
                }
            }
            Section {
                Button(ChooseUserViewModel.addUserTitle) {
                    Task { await users.startAddUser(router: router) }
                }
                Button(ServerChipMenuModel.manageUsersTitle) {
                    router.navigate(to: .manageUsers)
                }
            }
        }
        .navigationTitle(ChooseUserViewModel.title)
        .task { await users.reloadDirectory() }
    }
}
#endif
