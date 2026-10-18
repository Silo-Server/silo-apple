#if !os(tvOS)
import SwiftUI

/// Choose a Server on iPhone, iPad, and Mac (spec §5.3): this user's
/// servers, each with its username when it differs from the user's name and
/// Active or Sign in again, then Add Server. Touch and hold (or
/// Control-click) a server to sign out of it.
struct ChooseServerScreen: View {
    var router: AppRouter
    let userID: String
    var focusServerID: String?

    /// The row whose action is running, so a second tap doesn't start
    /// another.
    @State private var busyItemID: String?

    private var users: SiloUserCoordinator { router.users }

    static let title = "Choose a server"

    static var hint: String {
        #if os(macOS)
        "Control-click a server to sign out of it."
        #else
        "Touch and hold a server to sign out of it."
        #endif
    }

    var body: some View {
        let model = ChooseServerViewModel(directory: users.directory, userID: userID, focusServerID: focusServerID)
        UserFlowPage(router: router) { _ in
            MarqueeHeadline(title: Self.title, lead: model.map(\.title), alignment: .center)
            if let model {
                rows(model)
                    .padding(.top, 32)
                addServer
                    .padding(.top, 12)
                if model.rows.contains(where: { $0.key != nil }) {
                    UserFlowHint(text: Self.hint)
                        .padding(.top, 18)
                }
            }
        } footer: {
            EmptyView()
        }
        .disabled(busyItemID != nil)
        .task {
            MarqueeScene.shared.focus = .profiles
            await users.reloadDirectory()
        }
        // A user removed while its servers show (its last sign-out): back
        // to where it was opened from. A root goes through the launch rules.
        .onChange(of: users.directory.isAvailable && users.directory.user(userID) == nil) { _, gone in
            if gone, !router.path.isEmpty { router.goBack() }
        }
    }

    private func rows(_ model: ChooseServerViewModel) -> some View {
        UserFlowRowGroup {
            ForEach(Array(model.rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 { UserFlowRowDivider() }
                Button {
                    run(row.id) { await users.openServer(row.id, userID: userID, router: router) }
                } label: {
                    UserServerRowLabel(name: row.name, address: row.address, username: row.username, status: row.status)
                }
                .buttonStyle(.marqueePressable)
                #if os(iOS)
                .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 16, style: .continuous))
                #endif
                .contextMenu {
                    if let key = row.key {
                        Button(role: .destructive) {
                            Task { await users.requestRemoval(.signIn(key), router: router) }
                        } label: {
                            Label(SignOutConfirmationCopy.signOutOfServerTitle(serverName: row.name),
                                  systemImage: "rectangle.portrait.and.arrow.right")
                        }
                    }
                }
            }
        }
    }

    private var addServer: some View {
        Button {
            run("add-server") { await users.startSignIn(.addServer(userID: userID), router: router) }
        } label: {
            UserFlowAdditionLabel(title: ChooseServerViewModel.addServerTitle)
        }
        .buttonStyle(UserFlowCardButtonStyle(isAddition: true))
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
