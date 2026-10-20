#if os(tvOS)
import SwiftUI

/// Whether an account screen has its directory: still reading it, read, or
/// unreadable (before sign-in migration, or the accounts index can't be
/// read).
enum TVUserListPhase: Equatable {
    case loading
    case ready
    case unavailable

    /// `hasLoaded` is false until the screen's first reload finishes.
    init(directory: SiloAccountDirectory, hasLoaded: Bool) {
        if directory.isAvailable {
            self = .ready
        } else {
            self = hasLoaded ? .unavailable : .loading
        }
    }
}

/// Choose an Account on Apple TV (spec §5.2): a card per account and Add
/// Account. A card opens the account, or its sign-in screen when it
/// expired; pressing and holding it offers Sign Out and Remove from This
/// Apple TV.
struct TVChooseAccountScreen: View {
    var router: AppRouter
    var focus: SiloAccountRef?

    private var accounts: SiloAccountCoordinator { router.accounts }
    @State private var hasLoaded = false
    @State private var isOpening = false

    var body: some View {
        let directory = accounts.directory
        TVChooseAccountContent(
            model: ChooseAccountViewModel(directory: directory, focus: focus),
            phase: TVUserListPhase(directory: directory, hasLoaded: hasLoaded),
            showsBrandLight: router.authState.showsMarqueeBackdrop,
            isOverlayPresented: router.removalRequest != nil,
            actions: TVChooseAccountContent.Actions(
                open: open,
                addAccount: { Task { await accounts.startAddAccount(router: router) } },
                signOut: { id in Task { await accounts.requestRemoval(.signOut(id), router: router) } },
                remove: { id in Task { await accounts.requestRemoval(.remove(id), router: router) } },
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
        await accounts.reloadDirectory()
        hasLoaded = true
    }

    /// One press opens one account; a second press while it opens does
    /// nothing.
    private func open(_ account: SiloAccountRef) {
        guard !isOpening else { return }
        isOpening = true
        Task {
            await accounts.openAccount(account, router: router)
            isOpening = false
        }
    }
}

/// What Choose an Account draws, from its view model. Separate from the
/// screen so it renders from fixed data.
///
/// Focus: one native graph. The cards and Add Account sit in one focus
/// section; focus starts on the account this Apple TV user is linked to (or
/// the one asked for). After Sign Out or Remove closes, focus returns to the
/// card that opened it, or to the card that took its place.
struct TVChooseAccountContent: View {
    struct Actions {
        var open: (SiloAccountRef) -> Void
        var addAccount: () -> Void
        var signOut: (SiloAccountRef) -> Void
        var remove: (SiloAccountRef) -> Void
        var retry: () -> Void
    }

    enum Target: Hashable {
        case account(SiloAccountRef)
        case addAccount
        case retry
    }

    private struct PendingMenuAction {
        let id = UUID()
        let card: SiloAccountRef
        let run: () -> Void
    }

    let model: ChooseAccountViewModel
    var phase: TVUserListPhase = .ready
    var showsBrandLight = true
    /// A confirmation is over the screen.
    var isOverlayPresented = false
    let actions: Actions

    @FocusState private var focused: Target?
    /// The card whose menu opened the overlay.
    @State private var returnTarget: Target?
    /// A card menu's choice, waiting for the menu to close
    /// (`runAfterMenuCloses`).
    @State private var pendingMenuAction: PendingMenuAction?

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
        .onChange(of: focused) { _, target in
            // Focus is back on the card: the system menu has closed.
            guard let pending = pendingMenuAction, target == .account(pending.card) else { return }
            runPendingMenuAction()
        }
        .onChange(of: isOverlayPresented) { _, presented in
            guard !presented, let target = returnTarget, isShowing(target) else { return }
            claimFocus(target)
        }
        .onChange(of: model.cards.map(\.id)) { before, after in
            guard case .account(let id)? = returnTarget, !after.contains(id) else { return }
            returnTarget = nil
            claimFocus(TVFocusNeighbor.replacement(for: id, before: before, after: after).map(Target.account)
                ?? .addAccount)
        }
    }

    private var entryTarget: Target {
        if phase == .unavailable { return .retry }
        return model.focus.map(Target.account) ?? .addAccount
    }

    private func isShowing(_ target: Target) -> Bool {
        switch target {
        case .account(let id): return model.cards.contains { $0.id == id }
        case .addAccount: return phase != .unavailable
        case .retry: return phase == .unavailable
        }
    }

    /// The system menu takes about a second to close and ignores the
    /// remote until it has. A confirmation raised from inside it shows under
    /// the lifted card and drops the first Select. So the choice runs once
    /// focus is back on the card, or once the close is surely over.
    private func runAfterMenuCloses(_ card: SiloAccountRef, _ action: @escaping () -> Void) {
        returnTarget = .account(card)
        let pending = PendingMenuAction(card: card, run: action)
        pendingMenuAction = pending
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(1400))
            guard pendingMenuAction?.id == pending.id else { return }
            runPendingMenuAction()
        }
    }

    private func runPendingMenuAction() {
        guard let pending = pendingMenuAction else { return }
        pendingMenuAction = nil
        pending.run()
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
                    TVChooserTitle(text: ChooseAccountViewModel.title)
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
                TVHoldHint(text: ChooseAccountViewModel.removeHint)
                    .padding(.trailing, 90)
                    .padding(.bottom, 54)
            }
        }
    }

    /// Under the title: loading, or why the grid holds only Add Account.
    @ViewBuilder
    private var statusLine: some View {
        if phase == .loading && model.cards.isEmpty {
            HStack(spacing: 14) {
                ProgressView()
                Text("Loading accounts…")
            }
            .font(.system(size: MarqueeMetrics.leadFont))
            .foregroundStyle(Color.siloOnSurface.opacity(0.62))
        } else if phase == .ready && model.cards.isEmpty {
            Text("No accounts on this Apple TV yet. Add one to sign in.")
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
                accountCard(card)
            }
            addAccountCard
        }
        .focusSection()
    }

    private func accountCard(_ card: ChooseAccountViewModel.Card) -> some View {
        Button {
            actions.open(card.id)
        } label: {
            TVAccountCardLabel(card: card)
        }
        .buttonStyle(TVUserCardStyle())
        .focused($focused, equals: .account(card.id))
        .contextMenu {
            if !card.needsSignInAgain, card.id.signInKey != nil {
                Button(role: .destructive) {
                    runAfterMenuCloses(card.id) { actions.signOut(card.id) }
                } label: {
                    Label(SignOutConfirmationCopy.signOutTitle, systemImage: "rectangle.portrait.and.arrow.right")
                }
            }
            Button(role: .destructive) {
                runAfterMenuCloses(card.id) { actions.remove(card.id) }
            } label: {
                Label(SignOutConfirmationCopy.removeFromDeviceTitle(device: .appleTV), systemImage: "trash")
            }
        }
        .accessibilityLabel(card.name)
        .accessibilityValue(card.accessibilityValue)
        .accessibilityHint("Press and hold to sign out or remove.")
    }

    private var addAccountCard: some View {
        Button(action: actions.addAccount) {
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
                Text(ChooseAccountViewModel.addAccountTitle)
                    .font(.system(size: 30, weight: .semibold))
                    .padding(.top, 26)
                Text("Sign in to any Silo server")
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
        .focused($focused, equals: .addAccount)
        .accessibilityLabel(ChooseAccountViewModel.addAccountTitle)
    }

    // MARK: - Unavailable

    private var unavailable: some View {
        VStack(spacing: 0) {
            TVChooserTitle(text: ChooseAccountViewModel.title)
            MarqueeTVBody("Silo couldn't read the accounts saved on this Apple TV.")
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

/// One account card: stacked avatars, the username, the email when known,
/// the server, and its badges.
struct TVAccountCardLabel: View {
    let card: ChooseAccountViewModel.Card

    var body: some View {
        VStack(spacing: 0) {
            TVUserAvatarStack(profiles: card.avatars, serverURL: card.serverAddress, size: 100)
                .padding(.top, 32)
            Text(card.name)
                .font(.system(size: 30, weight: .semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.top, 22)
            ForEach(card.detailLines, id: \.self) { line in
                Text(line)
                    .font(.system(size: 22))
                    .opacity(0.62)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .padding(.top, 4)
            }
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
