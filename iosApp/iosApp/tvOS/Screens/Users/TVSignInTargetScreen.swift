#if os(tvOS)
import SwiftUI

/// "Sign in to…" on Apple TV (spec §5.4): the server step of first run, Add
/// User, and Add Server. Saved servers, then Add a New Server; Add Server
/// leaves out the servers the user already has.
struct TVSignInTargetScreen: View {
    var router: AppRouter
    let context: SignInContext
    /// An auth-state root, where Menu would leave the app: Menu cancels back
    /// to where the sign-in started instead.
    var isRoot = false

    private var users: SiloUserCoordinator { router.users }
    @State private var registry = ServerRegistry.shared
    @State private var isStarting = false

    private var canCancel: Bool { router.signInReturnPoint != nil }

    var body: some View {
        TVSignInTargetContent(
            model: SignInTargetViewModel(context: context, servers: registry.sortedEntries, snapshot: users.snapshot),
            userName: context.userID.flatMap { users.directory.user($0)?.name },
            canCancel: canCancel,
            actions: TVSignInTargetContent.Actions(
                pick: pick,
                addNewServer: {
                    router.signInContext = context
                    router.navigate(to: .serverSetup)
                },
                cancel: cancel
            )
        )
        .onExitCommand(perform: isRoot && canCancel ? cancel : nil)
        .task {
            MarqueeScene.shared.focus = .account
            MarqueeScene.shared.personalTint = nil
            router.signInContext = context
            await users.reloadDirectory()
        }
    }

    private func pick(_ serverID: String) {
        guard !isStarting else { return }
        isStarting = true
        Task {
            await users.beginSignIn(serverID: serverID, context: context, router: router)
            isStarting = false
        }
    }

    private func cancel() {
        Task { await users.cancelSignIn(router: router) }
    }
}

/// What "Sign in to…" draws, in the first-run layout: what is happening on
/// the left, the servers on the right.
///
/// Focus: the copy column (Cancel) and the server column are separate focus
/// sections; focus starts on the first saved server, or Add a New Server
/// when there is none.
struct TVSignInTargetContent: View {
    struct Actions {
        var pick: (String) -> Void
        var addNewServer: () -> Void
        var cancel: () -> Void
    }

    enum Target: Hashable {
        case server(String)
        case addNewServer
        case cancel
    }

    let model: SignInTargetViewModel
    /// The user Add Server adds to.
    var userName: String?
    var canCancel = false
    let actions: Actions

    @FocusState private var focused: Target?

    var body: some View {
        MarqueeTVScreen {
            if let chip = contextChip {
                MarqueeTVStatusChip(text: chip.text, systemImage: chip.systemImage)
            }
        } copy: {
            Text(SignInTargetViewModel.title)
                .font(.system(size: MarqueeMetrics.heroFont, weight: .heavy))
                .kerning(-2)
                .foregroundStyle(Color.siloOnSurface)
                .accessibilityAddTraits(.isHeader)
            MarqueeTVBody(lead)
                .padding(.top, 22)
            if canCancel {
                Button(ConfirmationCopy.cancelTitle, action: actions.cancel)
                    .buttonStyle(.marquee(.plain, fullWidth: false))
                    .focused($focused, equals: .cancel)
                    .padding(.top, 48)
            }
        } card: {
            servers
        }
        .defaultFocus($focused, entryTarget, priority: .userInitiated)
        .marqueeTVSeedFocus($focused, entryTarget)
    }

    private var entryTarget: Target {
        model.rows.first.map { .server($0.id) } ?? .addNewServer
    }

    private var contextChip: (text: String, systemImage: String)? {
        switch model.context {
        case .firstRun, .signInAgain:
            return nil
        case .addUser:
            return (ChooseUserViewModel.addUserTitle, "person.badge.plus")
        case .addServer:
            return (userName.map { "Add a server for \($0)" } ?? ChooseServerViewModel.addServerTitle, "server.rack")
        }
    }

    private var lead: String {
        switch model.context {
        case .addUser:
            return "Choose the server the new user signs in to. They sign in with their own account."
        case .addServer:
            return "Choose a server to add to \(userName ?? "this user")."
        case .firstRun, .signInAgain:
            return "Choose a server saved on this Apple TV, or add a new one."
        }
    }

    private var servers: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !model.rows.isEmpty {
                Text("SAVED SERVERS")
                    .font(.system(size: 19, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.siloOnSurface.opacity(0.45))
                    .padding(.leading, 8)
                    .padding(.bottom, 18)
            }
            // A long list scrolls; a short one sits in the middle beside the copy.
            ViewThatFits(in: .vertical) {
                rows
                ScrollView(.vertical, showsIndicators: false) { rows }
                    .scrollClipDisabled()
            }
        }
        .frame(width: 700)
    }

    private var rows: some View {
        VStack(spacing: 18) {
            ForEach(model.rows) { row in
                Button {
                    actions.pick(row.id)
                } label: {
                    TVServerRowLabel(
                        name: row.name,
                        detail: ServerBranding.hostLabel(row.address),
                        address: row.address
                    )
                }
                .buttonStyle(TVServerRowStyle())
                .focused($focused, equals: .server(row.id))
                .accessibilityLabel(row.name)
                .accessibilityValue(ServerBranding.hostLabel(row.address))
            }
            Button(action: actions.addNewServer) {
                TVAddRowLabel(title: SignInTargetViewModel.addNewServerTitle)
            }
            .buttonStyle(TVServerRowStyle(isDashed: true))
            .focused($focused, equals: .addNewServer)
            .accessibilityLabel(SignInTargetViewModel.addNewServerTitle)
        }
        .padding(.vertical, 12)
    }
}
#endif
