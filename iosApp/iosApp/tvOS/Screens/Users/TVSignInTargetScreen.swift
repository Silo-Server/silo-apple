#if os(tvOS)
import SwiftUI

/// "Sign in to…" on Apple TV (spec §5.4): the server step of first run and
/// Add Account. Saved servers, then Add a New Server.
struct TVSignInTargetScreen: View {
    var router: AppRouter
    let context: SignInContext
    /// An auth-state root, where Menu would leave the app: Menu cancels back
    /// to where the sign-in started instead.
    var isRoot = false

    private var accounts: SiloAccountCoordinator { router.accounts }
    @State private var registry = ServerRegistry.shared
    @State private var isStarting = false

    private var canCancel: Bool { router.signInReturnPoint != nil }

    var body: some View {
        TVSignInTargetContent(
            model: SignInTargetViewModel(context: context, servers: registry.sortedEntries),
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
            await accounts.reloadDirectory()
        }
    }

    private func pick(_ serverID: String) {
        guard !isStarting else { return }
        isStarting = true
        Task {
            await accounts.beginSignIn(serverID: serverID, context: context, router: router)
            isStarting = false
        }
    }

    /// One way out at a time, as on iPhone: a pick still switching servers
    /// would otherwise open its sign-in over the screen Cancel restored, and
    /// a second Cancel would find no return point and apply the launch rules.
    private func cancel() {
        guard !isStarting else { return }
        isStarting = true
        Task {
            await accounts.cancelSignIn(router: router)
            isStarting = false
        }
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
        case .addAccount:
            return (ChooseAccountViewModel.addAccountTitle, "person.badge.plus")
        }
    }

    private var lead: String {
        switch model.context {
        case .addAccount:
            return "Choose the server the account signs in to, or add a new one."
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
