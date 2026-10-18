#if !os(tvOS)
import SwiftUI

/// Settings › Users on iPhone, iPad, and Mac (spec §5.7, §5.8 Manage
/// Users…): a section per user with its servers, each with Sign Out (or Sign
/// In Again once it expired), then Rename and Remove; Add User at the end.
/// Every sign-out and removal asks first, since saved sign-ins are shared by
/// everyone on the device.
struct ManageUsersView: View {
    var router: AppRouter

    /// Add User is starting; a second tap waits for it.
    @State private var isAddingUser = false

    private var users: SiloUserCoordinator { router.users }

    static let renameTitle = UsersSettingsViewModel.renameTitle + "…"
    static let signInAgainTitle = "Sign In Again"
    static let currentLabel = "Current"

    static func footer(device: SignOutConfirmationCopy.Device) -> String {
        "Everyone who uses Silo on this \(device.noun) shares these users. Signing out or removing a user affects everyone here."
    }

    var body: some View {
        let model = UsersSettingsViewModel(directory: users.directory, device: users.device)
        List {
            ForEach(model.users) { user in
                Section {
                    summaryRow(user, removeTitle: model.removeTitle)
                    ForEach(user.servers.map { ServerRow(userID: user.id, server: $0) }) { row in
                        serverRow(row.server, in: user)
                    }
                    Button {
                        Task { await users.requestRename(user.id, router: router) }
                    } label: {
                        Label(Self.renameTitle, systemImage: "pencil")
                            .foregroundStyle(Color.siloOnSurface)
                    }
                    .settingsRowButtonStyle()
                    Button(role: .destructive) {
                        Task { await users.requestRemoval(.user(user.id), router: router) }
                    } label: {
                        Label(model.removeTitle, systemImage: "person.crop.circle.badge.minus")
                            .foregroundStyle(Color.siloErrorInk)
                    }
                    .settingsRowButtonStyle()
                }
                .listRowBackground(Color.siloGroupedCell)
            }
            Section {
                Button {
                    guard !isAddingUser else { return }
                    isAddingUser = true
                    Task {
                        await users.startAddUser(router: router)
                        isAddingUser = false
                    }
                } label: {
                    Label(UsersSettingsViewModel.addUserTitle, systemImage: "person.badge.plus")
                        .foregroundStyle(Color.siloOnSurface)
                }
                .settingsRowButtonStyle()
                .disabled(isAddingUser)
            } footer: {
                Text(Self.footer(device: users.device))
                    .foregroundStyle(Color.siloSecondaryText)
            }
            .listRowBackground(Color.siloGroupedCell)
        }
        .settingsListChrome()
        .navigationTitle(UsersSettingsViewModel.title)
        .siloNavigationTitleDisplayMode(.inline)
        .siloToolbarColorSchemeDark()
        .task { await users.reloadDirectory() }
    }

    /// A server row keyed by user and server: two users can share a server,
    /// and every row in a list needs its own ID.
    private struct ServerRow: Identifiable {
        let userID: String
        let server: UsersSettingsViewModel.Server

        var id: String { userID + "|" + server.id }
    }

    /// The user: avatars of its last server's profiles, its name, and its
    /// servers.
    private func summaryRow(_ user: UsersSettingsViewModel.User, removeTitle: String) -> some View {
        let entry = users.directory.user(user.id)
        return HStack(spacing: 12) {
            StackedProfileAvatars(
                profiles: entry?.lastUsedServer?.profiles ?? [],
                fallbackID: user.id,
                fallbackName: user.name,
                serverAddress: entry?.lastUsedServer?.address,
                maxCount: 3
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .font(.headline)
                    .foregroundStyle(Color.siloOnSurface)
                if let entry {
                    Text(ChooseUserViewModel.serverLabel(for: entry))
                        .font(.subheadline)
                        .foregroundStyle(Color.siloSecondaryText)
                }
            }
            Spacer(minLength: 8)
            if user.isCurrent {
                Text(Self.currentLabel)
                    .font(.subheadline)
                    .foregroundStyle(Color.siloSecondaryText)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button {
                Task { await users.requestRename(user.id, router: router) }
            } label: {
                Label(Self.renameTitle, systemImage: "pencil")
            }
            Button(role: .destructive) {
                Task { await users.requestRemoval(.user(user.id), router: router) }
            } label: {
                Label(removeTitle, systemImage: "person.crop.circle.badge.minus")
            }
        }
    }

    /// One server in the user, with Sign Out, or Sign In Again once it
    /// expired. A pending legacy server has no saved sign-in to act on yet.
    private func serverRow(_ server: UsersSettingsViewModel.Server, in user: UsersSettingsViewModel.User) -> some View {
        let address = users.directory.user(user.id)?.server(server.id)?.address ?? ""
        return HStack(spacing: 12) {
            MarqueeServerMark(
                name: server.name,
                imageURL: ServerBrandingCache.branding(for: address)?.markURL,
                size: 30
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name)
                    .foregroundStyle(Color.siloOnSurface)
                if let detail = Self.serverDetail(server) {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(server.needsSignInAgain ? Color.siloStatusWarning : Color.siloSecondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            Spacer(minLength: 8)
            if let key = server.key {
                if server.needsSignInAgain {
                    Button(Self.signInAgainTitle) {
                        Task { await users.openServer(server.id, userID: user.id, router: router) }
                    }
                    .buttonStyle(.borderless)
                } else {
                    Button(UsersSettingsViewModel.signOutTitle) {
                        Task { await users.requestRemoval(.signIn(key), router: router) }
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Color.siloErrorInk)
                }
            }
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let key = server.key {
                Button(role: .destructive) {
                    Task { await users.requestRemoval(.signIn(key), router: router) }
                } label: {
                    Label(UsersSettingsViewModel.signOutTitle, systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
        // Sign Out stays in reach once the row offers Sign In Again.
        .contextMenu {
            if let key = server.key {
                if server.needsSignInAgain {
                    Button {
                        Task { await users.openServer(server.id, userID: user.id, router: router) }
                    } label: {
                        Label(Self.signInAgainTitle, systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
                Button(role: .destructive) {
                    Task { await users.requestRemoval(.signIn(key), router: router) }
                } label: {
                    Label(SignOutConfirmationCopy.signOutOfServerTitle(serverName: server.name),
                          systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
        }
    }

    /// The server username when it says something the user's name doesn't,
    /// and "Sign in again" once the sign-in expired: "sam2 · Sign in again".
    static func serverDetail(_ server: UsersSettingsViewModel.Server) -> String? {
        let parts = [server.username, server.needsSignInAgain ? ChooseUserViewModel.signInAgainLabel : nil]
            .compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: SiloUserNaming.separator)
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
