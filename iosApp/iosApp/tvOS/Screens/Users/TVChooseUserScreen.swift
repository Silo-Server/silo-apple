#if os(tvOS)
import SwiftUI

/// Choose a User on Apple TV (spec §5.2). A working plain screen: WP4 gives
/// it the stacked-avatar cards and the final layout.
struct TVChooseUserScreen: View {
    var router: AppRouter
    var focusUserID: String?

    private var users: SiloUserCoordinator { router.users }
    @FocusState private var focused: Target?

    private enum Target: Hashable {
        case user(String)
        case addUser
        case manageUsers
    }

    private var model: ChooseUserViewModel {
        ChooseUserViewModel(directory: users.directory, focusUserID: focusUserID)
    }

    var body: some View {
        let model = model
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(ChooseUserViewModel.title)
                    .font(.system(size: 52, weight: .heavy))
                    .accessibilityAddTraits(.isHeader)
                    .padding(.bottom, 12)

                VStack(alignment: .leading, spacing: 12) {
                    ForEach(model.cards) { card in
                        Button {
                            Task { await users.openUser(card.id, router: router) }
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(card.name)
                                    .font(.system(size: 30, weight: .semibold))
                                Text(cardDetail(card))
                                    .font(.system(size: 22))
                                    .opacity(0.7)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(TVSettingsPaneRowStyle())
                        .focused($focused, equals: .user(card.id))
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

                    Button {
                        Task { await users.startAddUser(router: router) }
                    } label: {
                        Label(ChooseUserViewModel.addUserTitle, systemImage: "plus")
                            .font(.system(size: 28, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($focused, equals: .addUser)

                    Button {
                        router.navigate(to: .manageUsers)
                    } label: {
                        Label("Manage Users", systemImage: "person.2")
                            .font(.system(size: 24))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .buttonStyle(TVSettingsPaneRowStyle())
                    .focused($focused, equals: .manageUsers)
                }
                .focusSection()

                if model.showsRemoveHint {
                    Text(ChooseUserViewModel.removeHint)
                        .font(.system(size: 20))
                        .opacity(0.55)
                }
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.vertical, 64)
            .frame(maxWidth: .infinity)
        }
        .defaultFocus($focused, model.focusUserID.map(Target.user) ?? .addUser)
        .task { await users.reloadDirectory() }
    }

    private func cardDetail(_ card: ChooseUserViewModel.Card) -> String {
        ([card.serverLabel]
            + (card.isLastUsed ? [ChooseUserViewModel.lastUsedLabel] : [])
            + (card.needsSignInAgain ? [ChooseUserViewModel.signInAgainLabel] : []))
            .joined(separator: " · ")
    }
}
#endif
