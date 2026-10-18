#if os(tvOS)
import SwiftUI

/// A focusable row of Settings › Users.
enum TVUsersSettingsRow: Hashable {
    /// Sign Out of one server.
    case server(userID: String, serverID: String)
    case rename(userID: String)
    case remove(userID: String)
    case addUser
}

/// Settings › Users on Apple TV (spec §5.7) as its own page: the
/// `.manageUsers` route. Settings shows the same rows as its Users category
/// (`TVUsersSettingsSection` inside `TVSettingsView`).
struct TVUsersSettingsPane: View {
    var router: AppRouter

    private var users: SiloUserCoordinator { router.users }
    @State private var hasLoaded = false
    @State private var registry = ServerRegistry.shared
    @FocusState private var focus: TVSettingsDetailFocus?
    /// The row whose action opened a confirmation or rename.
    @State private var returnRow: TVUsersSettingsRow?

    var body: some View {
        let model = UsersSettingsViewModel(directory: users.directory, device: users.device)
        let rowIDs = TVUsersSettingsSection.rows(in: model)
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("ACCOUNTS")
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .tracking(2)
                        .foregroundColor(.siloSecondaryText)
                    Text(UsersSettingsViewModel.title)
                        .font(.system(size: 38, weight: .semibold))
                        .foregroundColor(.siloOnSurface)
                        .accessibilityAddTraits(.isHeader)
                    Text(TVUsersSettingsSection.blurb)
                        .font(.system(size: 20))
                        .foregroundColor(.siloSecondaryText)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

                TVUsersSettingsSection(
                    model: model,
                    phase: TVUserListPhase(directory: users.directory, hasLoaded: hasLoaded),
                    addresses: Dictionary(registry.entries.map { ($0.id, $0.url) }, uniquingKeysWith: { first, _ in first }),
                    focus: $focus,
                    actions: actions
                )
            }
            .frame(maxWidth: 1080, alignment: .leading)
            .padding(.bottom, 64)
            .focusSection()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .safeAreaPadding(.horizontal, SiloTheme.Skyline.safeAreaX)
        .safeAreaPadding(.top, 64)
        .background(SettingsBackdrop())
        .defaultFocus($focus, rowIDs.first.map(TVSettingsDetailFocus.users))
        .task {
            await users.reloadDirectory()
            hasLoaded = true
        }
        .onChange(of: router.removalRequest == nil && router.renameRequest == nil) { _, closed in
            guard closed, let row = returnRow, rowIDs.contains(row) else { return }
            claimFocus(row)
        }
        .onChange(of: rowIDs) { before, after in
            guard let row = returnRow, !after.contains(row) else { return }
            returnRow = nil
            if let next = TVFocusNeighbor.replacement(for: row, before: before, after: after) {
                claimFocus(next)
            }
        }
    }

    private var actions: TVUsersSettingsSection.Actions {
        TVUsersSettingsSection.Actions(
            signOut: { key, row in
                returnRow = row
                Task { await users.requestRemoval(.signIn(key), router: router) }
            },
            rename: { userID, row in
                returnRow = row
                Task { await users.requestRename(userID, router: router) }
            },
            remove: { userID, row in
                returnRow = row
                Task { await users.requestRemoval(.user(userID), router: router) }
            },
            addUser: { Task { await users.startAddUser(router: router) } }
        )
    }

    private func claimFocus(_ row: TVUsersSettingsRow) {
        Task { @MainActor in
            await Task.yield()
            focus = .users(row)
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(80))
                guard focus == nil else { return }
                focus = .users(row)
            }
        }
    }
}

/// The rows of Settings › Users: each user with its servers (Sign Out),
/// Rename, and Remove from This Apple TV; then Add User.
///
/// Focus: native settings rows in one column; the owner seeds and restores
/// focus through `focus` with `TVSettingsDetailFocus.users`.
struct TVUsersSettingsSection: View {
    struct Actions {
        /// Sign Out of a server, from its row.
        var signOut: (SignInKey, TVUsersSettingsRow) -> Void
        var rename: (String, TVUsersSettingsRow) -> Void
        var remove: (String, TVUsersSettingsRow) -> Void
        var addUser: () -> Void
    }

    static let blurb = "Silo users on this Apple TV and the servers each one signs in to."
    static let footer = "Users and their sign-ins are shared by everyone on this Apple TV. Profiles and watch history stay on the servers."

    let model: UsersSettingsViewModel
    var phase: TVUserListPhase = .ready
    /// Server addresses by ID, for each server's mark.
    var addresses: [String: String] = [:]
    let focus: FocusState<TVSettingsDetailFocus?>.Binding
    let actions: Actions

    /// Every focusable row, top to bottom.
    static func rows(in model: UsersSettingsViewModel) -> [TVUsersSettingsRow] {
        model.users.flatMap { user in
            user.servers.compactMap { $0.key == nil ? nil : TVUsersSettingsRow.server(userID: user.id, serverID: $0.id) }
                + [.rename(userID: user.id), .remove(userID: user.id)]
        } + [.addUser]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch phase {
            case .loading where model.users.isEmpty:
                HStack(spacing: 14) {
                    ProgressView()
                    Text("Loading users…")
                }
                .font(.system(size: 22))
                .foregroundStyle(Color.siloSecondaryText)
                .padding(.horizontal, 24)
                .padding(.top, 12)
            case .unavailable:
                TVSettingsFooter("Users appear here once Silo finishes updating the sign-ins saved on this Apple TV.")
            case .loading, .ready:
                ForEach(model.users) { user in
                    userRows(user)
                }
                Button(action: actions.addUser) {
                    HStack(spacing: 16) {
                        Image(systemName: "person.badge.plus")
                            .font(.system(size: 22, weight: .medium))
                            .frame(width: 34)
                        Text(UsersSettingsViewModel.addUserTitle)
                            .font(.system(size: 26))
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 18, weight: .semibold))
                            .opacity(0.55)
                    }
                }
                .buttonStyle(TVSettingsPaneRowStyle())
                .focused(focus, equals: .users(.addUser))
                .padding(.top, model.users.isEmpty ? 0 : 26)
                TVSettingsFooter(Self.footer)
            }
        }
    }

    @ViewBuilder
    private func userRows(_ user: UsersSettingsViewModel.User) -> some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            TVSettingsSectionHeader(user.name.uppercased())
            if user.isLastUsed {
                TVUserStatusBadge(kind: .lastUsed)
                    .padding(.bottom, 2)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)

        ForEach(user.servers) { server in
            serverRow(server, of: user)
        }

        Button {
            actions.rename(user.id, .rename(userID: user.id))
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "pencil")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 34)
                Text(UsersSettingsViewModel.renameTitle)
                    .font(.system(size: 26))
                Spacer(minLength: 16)
                Text(user.baseName)
                    .font(.system(size: 24))
                    .opacity(0.68)
                    .lineLimit(1)
                Image(systemName: "chevron.right")
                    .font(.system(size: 18, weight: .semibold))
                    .opacity(0.55)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle())
        .focused(focus, equals: .users(.rename(userID: user.id)))
        .accessibilityLabel("Rename \(user.name)")

        Button {
            actions.remove(user.id, .remove(userID: user.id))
        } label: {
            HStack(spacing: 16) {
                Image(systemName: "trash")
                    .font(.system(size: 22, weight: .medium))
                    .frame(width: 34)
                Text(model.removeTitle)
                    .font(.system(size: 26))
                Spacer(minLength: 0)
            }
        }
        .buttonStyle(TVSettingsPaneRowStyle(isDestructive: true))
        .focused(focus, equals: .users(.remove(userID: user.id)))
        .accessibilityLabel("\(model.removeTitle): \(user.name)")
    }

    @ViewBuilder
    private func serverRow(_ server: UsersSettingsViewModel.Server, of user: UsersSettingsViewModel.User) -> some View {
        let address = addresses[server.id] ?? ""
        let detail = [server.username, address.isEmpty ? nil : ServerBranding.hostLabel(address)]
            .compactMap { $0 }
            .joined(separator: SiloUserNaming.separator)
        let label = HStack(spacing: 16) {
            MarqueeServerMark(name: server.name, imageURL: ServerBrandingCache.branding(for: address)?.markURL, size: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(server.name)
                    .font(.system(size: 26))
                    .lineLimit(1)
                if !detail.isEmpty {
                    Text(detail)
                        .font(.system(size: 19))
                        .opacity(0.62)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 16)
            if server.needsSignInAgain {
                TVUserStatusBadge(kind: .signInAgain)
            }
            if server.key != nil {
                Text(UsersSettingsViewModel.signOutTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .opacity(0.72)
            }
        }

        if let key = server.key {
            let row = TVUsersSettingsRow.server(userID: user.id, serverID: server.id)
            Button {
                actions.signOut(key, row)
            } label: {
                label
            }
            .buttonStyle(TVSettingsPaneRowStyle())
            .focused(focus, equals: .users(row))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(SignOutConfirmationCopy.signOutOfServerTitle(serverName: server.name))
            .accessibilityValue([server.username.map { "Signed in as \($0)" },
                                 server.needsSignInAgain ? ChooseUserViewModel.signInAgainLabel : nil]
                .compactMap { $0 }.joined(separator: ", "))
        } else {
            // Waiting for the server to confirm its account: only Remove
            // reaches it, so the row is information, not a focus target.
            label
                .padding(.horizontal, 24)
                .padding(.vertical, 17)
                .foregroundStyle(Color.siloOnSurface)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.siloSurfaceElevated.opacity(0.84))
                )
                .accessibilityElement(children: .combine)
        }
    }
}
#endif
