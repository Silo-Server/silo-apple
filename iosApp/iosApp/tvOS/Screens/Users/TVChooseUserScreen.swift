#if os(tvOS)
import SwiftUI

/// Whether a user screen has its directory: still reading it, read, or
/// unreadable (before sign-in migration, or the user index can't be read).
enum TVUserListPhase: Equatable {
    case loading
    case ready
    case unavailable

    /// `hasLoaded` is false until the screen's first reload finishes.
    init(directory: SiloUserDirectory, hasLoaded: Bool) {
        if directory.isAvailable {
            self = .ready
        } else {
            self = hasLoaded ? .unavailable : .loading
        }
    }
}

/// Choose a User on Apple TV (spec §5.2): a card per user and Add User. A
/// card opens the user's only server, or Choose a Server when it has more;
/// pressing and holding it offers Rename and Remove from This Apple TV.
struct TVChooseUserScreen: View {
    var router: AppRouter
    var focusUserID: String?

    private var users: SiloUserCoordinator { router.users }
    @State private var hasLoaded = false
    @State private var isOpening = false

    var body: some View {
        let directory = users.directory
        TVChooseUserContent(
            model: ChooseUserViewModel(directory: directory, focusUserID: focusUserID),
            serverURLs: Dictionary(
                directory.users.map { ($0.id, $0.lastUsedServer?.address ?? "") },
                uniquingKeysWith: { first, _ in first }
            ),
            phase: TVUserListPhase(directory: directory, hasLoaded: hasLoaded),
            showsBrandLight: router.authState.showsMarqueeBackdrop,
            isOverlayPresented: router.removalRequest != nil || router.renameRequest != nil,
            actions: TVChooseUserContent.Actions(
                open: open,
                addUser: { Task { await users.startAddUser(router: router) } },
                rename: { id in Task { await users.requestRename(id, router: router) } },
                remove: { id in Task { await users.requestRemoval(.user(id), router: router) } },
                retry: { Task { await reload() } }
            )
        )
        .task {
            // Choosing who is watching: the backdrop's warm profiles light.
            MarqueeScene.shared.focus = .profiles
            MarqueeScene.shared.personalTint = nil
            await reload()
        }
    }

    private func reload() async {
        await users.reloadDirectory()
        hasLoaded = true
    }

    /// One press opens one user; a second press while it opens does nothing.
    private func open(_ userID: String) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            await users.openUser(userID, router: router)
            isOpening = false
        }
    }
}

/// What Choose a User draws, from its view model. Separate from the screen
/// so it renders from fixed data.
///
/// Focus: one native graph. The cards and Add User sit in one focus section;
/// focus starts on the user this Apple TV user is linked to (or the one
/// asked for). After Rename or Remove closes, focus returns to the card
/// that opened it, or to the card that took its place.
struct TVChooseUserContent: View {
    struct Actions {
        var open: (String) -> Void
        var addUser: () -> Void
        var rename: (String) -> Void
        var remove: (String) -> Void
        var retry: () -> Void
    }

    enum Target: Hashable {
        case user(String)
        case addUser
        case retry
    }

    let model: ChooseUserViewModel
    /// Each user's last-used server address, which resolves its avatars.
    var serverURLs: [String: String] = [:]
    var phase: TVUserListPhase = .ready
    var showsBrandLight = true
    /// A confirmation, question, or rename is over the screen.
    var isOverlayPresented = false
    let actions: Actions

    @FocusState private var focused: Target?
    /// The card whose menu opened the overlay.
    @State private var returnTarget: Target?

    var body: some View {
        ZStack {
            TVUserFlowBackground(showsBrandLight: showsBrandLight)

            switch phase {
            case .unavailable:
                unavailable
            case .loading, .ready:
                chooser
            }
        }
        .defaultFocus($focused, entryTarget)
        .marqueeTVSeedFocus($focused, entryTarget)
        .onChange(of: isOverlayPresented) { _, presented in
            guard !presented, let target = returnTarget, isShowing(target) else { return }
            claimFocus(target)
        }
        .onChange(of: model.cards.map(\.id)) { before, after in
            guard case .user(let id)? = returnTarget, !after.contains(id) else { return }
            returnTarget = nil
            claimFocus(TVFocusNeighbor.replacement(for: id, before: before, after: after).map(Target.user) ?? .addUser)
        }
    }

    private var entryTarget: Target {
        if phase == .unavailable { return .retry }
        return model.focusUserID.map(Target.user) ?? .addUser
    }

    private func isShowing(_ target: Target) -> Bool {
        switch target {
        case .user(let id): return model.cards.contains { $0.id == id }
        case .addUser: return phase != .unavailable
        case .retry: return phase == .unavailable
        }
    }

    /// Claims focus once the overlay's focus subtree has gone, and again
    /// while nothing holds it (the engine can drop a claim made mid-exit).
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
                    TVChooserTitle(text: ChooseUserViewModel.title)
                    statusLine
                        .padding(.top, 14)
                    grid
                        .padding(.top, 56)
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 70)
                .frame(maxWidth: .infinity)
                .frame(minHeight: geometry.size.height)
            }
            .scrollClipDisabled()
        }
        .overlay(alignment: .bottomTrailing) {
            if model.showsRemoveHint, phase == .ready {
                TVHoldHint(text: ChooseUserViewModel.removeHint)
                    .padding(.trailing, 90)
                    .padding(.bottom, 54)
            }
        }
    }

    /// Under the title: loading, or why the grid holds only Add User.
    @ViewBuilder
    private var statusLine: some View {
        if phase == .loading && model.cards.isEmpty {
            HStack(spacing: 14) {
                ProgressView()
                Text("Loading users…")
            }
            .font(.system(size: MarqueeMetrics.leadFont))
            .foregroundStyle(Color.siloOnSurface.opacity(0.62))
        } else if phase == .ready && model.cards.isEmpty {
            Text("No users on this Apple TV yet. Add one to sign in.")
                .font(.system(size: MarqueeMetrics.leadFont))
                .foregroundStyle(Color.siloOnSurface.opacity(0.62))
        } else {
            Text(" ")
                .font(.system(size: MarqueeMetrics.leadFont))
                .accessibilityHidden(true)
        }
    }

    private var grid: some View {
        let columns = Array(
            repeating: GridItem(.fixed(TVUserCardMetrics.width), spacing: TVUserCardMetrics.spacing),
            count: min(model.cards.count + 1, TVUserCardMetrics.maxColumns)
        )
        return LazyVGrid(columns: columns, spacing: TVUserCardMetrics.spacing) {
            ForEach(model.cards) { card in
                userCard(card)
            }
            addUserCard
        }
        .focusSection()
    }

    private func userCard(_ card: ChooseUserViewModel.Card) -> some View {
        Button {
            actions.open(card.id)
        } label: {
            TVUserCardLabel(card: card, serverURL: serverURLs[card.id])
        }
        .buttonStyle(TVUserCardStyle())
        .focused($focused, equals: .user(card.id))
        .contextMenu {
            Button {
                returnTarget = .user(card.id)
                actions.rename(card.id)
            } label: {
                Label(UsersSettingsViewModel.renameTitle, systemImage: "pencil")
            }
            Button(role: .destructive) {
                returnTarget = .user(card.id)
                actions.remove(card.id)
            } label: {
                Label(SignOutConfirmationCopy.removeFromDeviceTitle(device: .appleTV), systemImage: "trash")
            }
        }
        .accessibilityLabel(card.accessibilityName)
        .accessibilityValue(card.accessibilityValue)
        .accessibilityHint("Press and hold to rename or remove.")
    }

    private var addUserCard: some View {
        Button(action: actions.addUser) {
            VStack(spacing: 0) {
                Image(systemName: "plus")
                    .font(.system(size: 40, weight: .light))
                    .frame(width: 100, height: 100)
                    .overlay {
                        Circle()
                            .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6, 5]))
                            .foregroundStyle(Color.white.opacity(0.4))
                    }
                    .padding(.top, 32)
                Text(ChooseUserViewModel.addUserTitle)
                    .font(.system(size: 30, weight: .semibold))
                    .padding(.top, 26)
                Text("Sign in with another account")
                    .font(.system(size: 22))
                    .opacity(0.62)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 22)
            .foregroundStyle(Color.siloOnSurface)
        }
        .buttonStyle(TVUserCardStyle(isDashed: true))
        .focused($focused, equals: .addUser)
        .accessibilityLabel(ChooseUserViewModel.addUserTitle)
    }

    // MARK: - Unavailable

    private var unavailable: some View {
        VStack(spacing: 0) {
            TVChooserTitle(text: ChooseUserViewModel.title)
            MarqueeTVBody("Silo couldn't read the users saved on this Apple TV.")
                .multilineTextAlignment(.center)
                .padding(.top, 18)
            Button(action: actions.retry) {
                Label("Try Again", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.marquee(.glass, fullWidth: false))
            .focused($focused, equals: .retry)
            .padding(.top, 48)
        }
        .padding(90)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusSection()
    }
}

/// One user card: stacked avatars, the name, its servers, and its badges.
struct TVUserCardLabel: View {
    let card: ChooseUserViewModel.Card
    var serverURL: String?

    var body: some View {
        VStack(spacing: 0) {
            TVUserAvatarStack(profiles: card.avatars, serverURL: serverURL, size: 100)
                .padding(.top, 32)
            Text(card.name)
                .font(.system(size: 30, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 26)
            Text(card.serverLabel)
                .font(.system(size: 22))
                .opacity(0.62)
                .lineLimit(1)
                .padding(.top, 6)
            Spacer(minLength: 0)
            // Holds its height without badges so names line up across cards.
            HStack(spacing: 10) {
                if card.isLastUsed { TVUserStatusBadge(kind: .lastUsed) }
                if card.needsSignInAgain { TVUserStatusBadge(kind: .signInAgain) }
            }
            .frame(height: 36)
            .padding(.bottom, 26)
        }
        .padding(.horizontal, 20)
        .foregroundStyle(Color.siloOnSurface)
    }
}
#endif
