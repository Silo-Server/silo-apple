#if os(tvOS)
import SwiftUI

/// Choose a Server on Apple TV (spec §5.3): Change server on Who's Watching,
/// Switch Server in the top menu, and a launch with no last server. Lists
/// this user's servers, then Add Server. Pressing and holding a row offers
/// Sign Out of {server}.
struct TVChooseServerScreen: View {
    var router: AppRouter
    let userID: String
    var focusServerID: String?

    private var users: SiloUserCoordinator { router.users }
    @State private var hasLoaded = false
    @State private var isOpening = false

    var body: some View {
        let directory = users.directory
        TVChooseServerContent(
            model: ChooseServerViewModel(directory: directory, userID: userID, focusServerID: focusServerID),
            user: directory.user(userID),
            phase: TVUserListPhase(directory: directory, hasLoaded: hasLoaded),
            showsBrandLight: router.authState.showsMarqueeBackdrop,
            showsSwitchUser: isRoot,
            isOverlayPresented: router.removalRequest != nil || router.renameRequest != nil,
            actions: TVChooseServerContent.Actions(
                open: open,
                addServer: { Task { await users.startSignIn(.addServer(userID: userID), router: router) } },
                signOut: { key in Task { await users.requestRemoval(.signIn(key), router: router) } },
                switchUser: { Task { await users.beginSwitchUser(router: router) } },
                retry: { Task { await reload() } }
            )
        )
        .task {
            MarqueeScene.shared.focus = .account
            MarqueeScene.shared.personalTint = nil
            await reload()
        }
        // A user removed while its servers show (its last sign-out): back
        // to where it was opened from. A root goes through the launch rules.
        .onChange(of: directory.isAvailable && directory.user(userID) == nil) { _, gone in
            if gone, !router.path.isEmpty { router.goBack() }
        }
    }

    /// The launch showed this screen because the user has no last server:
    /// Menu would leave Silo, so it offers Switch User itself.
    private var isRoot: Bool {
        guard router.path.isEmpty, case .needsServer(let shown, _) = router.authState else { return false }
        return shown == userID
    }

    private func reload() async {
        await users.reloadDirectory()
        hasLoaded = true
    }

    private func open(_ serverID: String) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            await users.openServer(serverID, userID: userID, router: router)
            isOpening = false
        }
    }
}

/// What Choose a Server draws, from its view model.
///
/// Focus: one native graph. The rows and Add Server form one focus section,
/// Switch User another; focus starts on the server asked for, else the
/// active one. After Sign Out of {server} closes, focus returns to its row,
/// or to the row that took its place.
struct TVChooseServerContent: View {
    struct Actions {
        var open: (String) -> Void
        var addServer: () -> Void
        var signOut: (SignInKey) -> Void
        var switchUser: () -> Void
        var retry: () -> Void
    }

    enum Target: Hashable {
        case server(String)
        case addServer
        case switchUser
        case retry
    }

    /// Nil while the directory loads, or once the user is gone.
    let model: ChooseServerViewModel?
    /// The user, for the avatars beside its name.
    var user: SiloUserDirectory.User?
    var phase: TVUserListPhase = .ready
    var showsBrandLight = true
    var showsSwitchUser = false
    var isOverlayPresented = false
    let actions: Actions

    @FocusState private var focused: Target?
    @State private var returnTarget: Target?

    static let title = "Choose a server"
    static let holdHint = "Press and hold a server to sign out of it"

    var body: some View {
        ZStack {
            TVUserFlowBackground(showsBrandLight: showsBrandLight)

            if model == nil, phase != .loading {
                unavailable
            } else {
                chooser
            }
        }
        .defaultFocus($focused, entryTarget)
        .marqueeTVSeedFocus($focused, entryTarget)
        .onChange(of: isOverlayPresented) { _, presented in
            guard !presented, let target = returnTarget, isShowing(target) else { return }
            claimFocus(target)
        }
        .onChange(of: rowIDs) { before, after in
            guard case .server(let id)? = returnTarget, !after.contains(id) else { return }
            returnTarget = nil
            claimFocus(TVFocusNeighbor.replacement(for: id, before: before, after: after).map(Target.server) ?? .addServer)
        }
    }

    private var rowIDs: [String] { model?.rows.map(\.id) ?? [] }

    private var entryTarget: Target {
        guard let model else { return phase == .loading ? .addServer : .retry }
        return model.focusServerID.map(Target.server) ?? .addServer
    }

    private func isShowing(_ target: Target) -> Bool {
        switch target {
        case .server(let id): return rowIDs.contains(id)
        case .addServer: return model != nil || phase == .loading
        case .switchUser: return showsSwitchUser
        case .retry: return model == nil && phase != .loading
        }
    }

    private func claimFocus(_ target: Target) {
        Task { @MainActor in
            await Task.yield()
            focused = target
            for _ in 0..<5 {
                try? await Task.sleep(for: .milliseconds(80))
                guard focused == nil else { return }
                focused = target
            }
        }
    }

    // MARK: - Chooser

    private var chooser: some View {
        GeometryReader { geometry in
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    TVChooserTitle(text: Self.title)
                    userLine
                        .padding(.top, 18)
                    rows
                        .frame(width: 1040)
                        .padding(.top, 64)
                    if showsSwitchUser {
                        Button(action: actions.switchUser) {
                            Label("Switch User", systemImage: "person.2")
                        }
                        .buttonStyle(.marquee(.glass, fullWidth: false, compact: true))
                        .focused($focused, equals: .switchUser)
                        .frame(maxWidth: .infinity)
                        .focusSection()
                        .padding(.top, 48)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 90)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollClipDisabled()
        }
        .overlay(alignment: .bottomTrailing) {
            if model?.rows.contains(where: { $0.key != nil }) == true {
                TVHoldHint(text: Self.holdHint)
                    .padding(.trailing, 90)
                    .padding(.bottom, 54)
            }
        }
    }

    /// Whose servers these are: the user's avatars and name.
    @ViewBuilder
    private var userLine: some View {
        if let model {
            HStack(spacing: 16) {
                TVUserAvatarStack(
                    profiles: user.map { Array(($0.lastUsedServer?.profiles ?? []).prefix(ChooseUserViewModel.maxAvatars)) } ?? [],
                    serverURL: user?.lastUsedServer?.address,
                    size: 44
                )
                Text(model.userName)
                    .font(.system(size: MarqueeMetrics.leadFont))
                    .foregroundStyle(Color.siloOnSurface.opacity(0.62))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(model.title)
        } else {
            HStack(spacing: 14) {
                ProgressView()
                Text("Loading servers…")
            }
            .font(.system(size: MarqueeMetrics.leadFont))
            .foregroundStyle(Color.siloOnSurface.opacity(0.62))
        }
    }

    private var rows: some View {
        VStack(spacing: 18) {
            ForEach(model?.rows ?? []) { row in
                serverRow(row)
            }
            Button(action: actions.addServer) {
                TVAddRowLabel(title: ChooseServerViewModel.addServerTitle)
            }
            .buttonStyle(TVServerRowStyle(isDashed: true))
            .focused($focused, equals: .addServer)
            .accessibilityLabel(ChooseServerViewModel.addServerTitle)
        }
        .focusSection()
    }

    private func serverRow(_ row: ChooseServerViewModel.Row) -> some View {
        let button = Button {
            actions.open(row.id)
        } label: {
            TVServerRowLabel(
                name: row.name,
                detail: Self.detail(for: row),
                address: row.address,
                badge: Self.badge(for: row.status)
            )
        }
        .buttonStyle(TVServerRowStyle())
        .focused($focused, equals: .server(row.id))
        .accessibilityLabel(row.name)
        .accessibilityValue(Self.accessibilityValue(for: row))

        return Group {
            if let key = row.key {
                button
                    .contextMenu {
                        Button(role: .destructive) {
                            returnTarget = .server(row.id)
                            actions.signOut(key)
                        } label: {
                            Label(
                                SignOutConfirmationCopy.signOutOfServerTitle(serverName: row.name),
                                systemImage: "rectangle.portrait.and.arrow.right"
                            )
                        }
                    }
                    .accessibilityHint("Press and hold to sign out.")
            } else {
                button
            }
        }
    }

    /// The username when it says something the user's name doesn't, then
    /// the address.
    static func detail(for row: ChooseServerViewModel.Row) -> String {
        [row.username, ServerBranding.hostLabel(row.address)].compactMap { $0 }.joined(separator: SiloUserNaming.separator)
    }

    static func badge(for status: ChooseServerViewModel.Status) -> TVUserStatusBadge.Kind? {
        switch status {
        case .none: return nil
        case .active: return .active
        case .signInAgain: return .signInAgain
        }
    }

    static func accessibilityValue(for row: ChooseServerViewModel.Row) -> String {
        ([row.username.map { "Signed in as \($0)" }, row.status.label].compactMap { $0 })
            .joined(separator: ", ")
    }

    // MARK: - Unavailable

    private var unavailable: some View {
        VStack(spacing: 0) {
            TVChooserTitle(text: Self.title)
            MarqueeTVBody("Silo couldn't read this user's servers on this Apple TV.")
                .multilineTextAlignment(.center)
                .padding(.top, 18)
            HStack(spacing: 22) {
                Button(action: actions.retry) {
                    Label("Try Again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.marquee(.glass, fullWidth: false))
                .focused($focused, equals: .retry)
                if showsSwitchUser {
                    Button(action: actions.switchUser) {
                        Label("Switch User", systemImage: "person.2")
                    }
                    .buttonStyle(.marquee(.plain, fullWidth: false))
                    .focused($focused, equals: .switchUser)
                }
            }
            .padding(.top, 48)
        }
        .padding(90)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }
}
#endif
