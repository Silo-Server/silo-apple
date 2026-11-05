#if os(iOS)
import SwiftUI

/// The native-style companion pairing card: rises from the bottom over a dimmed
/// app and runs the whole flow for one discovered TV — discovery, server
/// selection, match-code confirm, progress, result — beneath a consistent
/// header. Pure presentation: the coordinator owns the transport
/// (`CompanionPairingCoordinator.connect(to:)`).
struct CompanionPairingCard: View {
    let tv: DiscoveredTV
    /// A sign-in TV's own server; nil for a setup TV (the user chooses).
    var server: ServerEntry? = nil
    /// Any exit — Not Now, Cancel mid-flow, Done, Close. The modifier records
    /// a per-setup-session dismissal so the card doesn't immediately re-latch;
    /// mid-flow retry lives INSIDE the card ("Try Again" on the error step).
    var onDismiss: () -> Void
    /// The TV no longer advertises what this card offers (it left the
    /// sign-in or setup screen, or started a new session). An offer the user
    /// hasn't acted on is withdrawn; a flow already under way keeps running
    /// and reports its own result.
    var offerWithdrawn: Bool = false

    @State private var coordinator: CompanionPairingCoordinator?
    @State private var startupTask: Task<Void, Never>?
    @State private var selection: Set<CompanionAccountChoice> = []
    @State private var didPreselect = false
    /// A sign-in TV: the signed-in accounts on its server, and the one to
    /// sign it in as (decision D3: one).
    @State private var signInAccounts: [CompanionAccountOption] = []
    @State private var signInChoice: CompanionAccountChoice?
    @State private var started = false
    @State private var appeared = false

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(appeared ? 0.45 : 0)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { if !started { dismiss() } }
                .accessibilityAddTraits(.isButton)
                .accessibilityLabel("Dismiss")
                .accessibilityHidden(started)

            card
                .siloFormWidth(540)
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                .offset(y: appeared ? 0 : 700)
        }
        .onAppear {
            withAnimation(.spring(response: 0.45, dampingFraction: 0.85)) { appeared = true }
        }
        .onChange(of: offerWithdrawn) { _, withdrawn in
            if withdrawn, !started { dismiss() }
        }
        .onDisappear {
            startupTask?.cancel()
            startupTask = nil
            Task { [coordinator] in await coordinator?.cancel() }
        }
    }

    // MARK: - Card shell

    private var card: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(Color.white.opacity(0.25))
                .frame(width: 38, height: 5)
                .padding(.top, 10)
                .padding(.bottom, 18)
            // The step as laid out when it fits. Otherwise (large text, a
            // short screen, a long summary) the whole step scrolls, so its
            // actions stay reachable.
            ViewThatFits(in: .vertical) {
                paddedStep(scrollsWhole: false)
                ScrollView { paddedStep(scrollsWhole: true) }
                    .scrollBounceBehavior(.basedOnSize)
            }
        }
        .frame(maxWidth: .infinity)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 30, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 30, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: coordinator?.state)
        .sensoryFeedback(trigger: coordinator?.state) { _, state in
            switch state {
            case let .finished(signedIn, failed):
                if signedIn.isEmpty { return .error }
                return failed.isEmpty ? .success : .warning
            case .error: return .error
            default: return nil
            }
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: started)
    }

    private func paddedStep(scrollsWhole: Bool) -> some View {
        stepContent(scrollsWhole: scrollsWhole)
            .padding(.horizontal, 22)
            .padding(.bottom, 22)
    }

    /// `scrollsWhole`: the step sits in a scroll view, so the account list
    /// doesn't scroll on its own.
    @ViewBuilder private func stepContent(scrollsWhole: Bool) -> some View {
        if !started {
            discovery
        } else {
            switch coordinator?.state ?? .connecting {
            case .connecting:
                progressStep(title: "Connecting…", subtitle: tv.name)
            case let .pickAccounts(_, sections):
                accountPicker(sections, listScrolls: !scrollsWhole)
                    .onAppear { preselect() }
            case let .confirmMatch(_, serverName, serverHost, accountName, code, matchWords, step):
                confirm(serverName: serverName, serverHost: serverHost, accountName: accountName,
                        code: code, matchWords: matchWords, step: step)
            case let .working(progress):
                progressStep(title: server == nil ? "Setting up…" : "Signing in…", subtitle: progress)
            case let .finished(signedIn, failed):
                finished(signedIn: signedIn, failed: failed)
            case let .error(message):
                errorState(message)
            }
        }
    }

    // MARK: - Steps

    private var discovery: some View {
        VStack(spacing: 0) {
            heroGlyph.padding(.bottom, 16)
            if let server {
                Text("Sign in \(tv.name) to \(server.displayName)?")
                    .font(.siloTitle)
                    .multilineTextAlignment(.center)
                // Unauthenticated Bonjour: the name and state are the TV's
                // claim, checked against its code on the next step.
                Text(Self.signInOfferBody(tvName: tv.name))
                    .font(.siloCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                if signInAccounts.count > 1 {
                    signInAccountChoice(server)
                }
                primaryButton("Sign In") { setUp() }.padding(.top, 22)
            } else {
                Text("Set Up \(tv.name)")
                    .font(.siloTitle)
                    .multilineTextAlignment(.center)
                Text(tv.isRoku
                     ? "Sign \(tv.name) in to a server from this \(UIDevice.current.model)."
                     : "Sign \(tv.name) in to your servers from this \(UIDevice.current.model).")
                    .font(.siloCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                primaryButton("Set Up") { setUp() }.padding(.top, 22)
            }
            tertiaryButton("Not Now") { dismiss() }.padding(.top, 4)
        }
        .task(id: server?.id) { await loadSignInAccounts() }
    }

    /// "Sign in Living Room to Home as" with one row per signed-in account,
    /// the one in use first and chosen.
    private func signInAccountChoice(_ server: ServerEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in \(tv.name) to \(server.displayName) as")
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                // Long TV and server names wrap instead of truncating.
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            ForEach(signInAccounts) { option in
                accountRow(option, isOn: signInChoice == option.id, isActiveAccount: option.isInUse,
                           unavailable: nil) {
                    signInChoice = option.id
                }
            }
        }
        .padding(.top, 18)
    }

    private func accountPicker(_ sections: [CompanionServerSection], listScrolls: Bool) -> some View {
        let chooser = coordinator?.chooser ?? CompanionAccountChooser(isRoku: tv.isRoku, acceptsSeveralAccounts: tv.acceptsSeveralAccounts)
        let activeServerId = ServerRegistry.shared.activeServerId
        let count = chooser.sendingOrder(selection, in: sections, activeServerId: activeServerId).count
        let limitReached = sections.contains { section in
            section.accounts.contains {
                if case .limitReached = chooser.unavailable($0, in: selection) { return true }
                return false
            }
        }
        return VStack(spacing: 0) {
            compactHeader(title: chooser.mode == .several ? "Choose accounts" : "Choose an account",
                          subtitle: "Sign \(tv.name) in to…")
            let list = VStack(alignment: .leading, spacing: 14) {
                ForEach(sections) { section in
                    serverSection(section, chooser: chooser, activeServerId: activeServerId)
                }
            }
            if listScrolls {
                ScrollView { list }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(maxHeight: 420)
            } else {
                list
            }
            if let note = Self.chooserNote(chooser, tvName: tv.name, limitReached: limitReached) {
                Text(note)
                    .font(.siloCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 10)
            }
            primaryButton(Self.continueTitle(count: count)) {
                let chosen = selection
                Task { await coordinator?.pushSelected(chosen) }
            }
            .disabled(count == 0)
            .opacity(count == 0 ? 0.5 : 1)
            .padding(.top, 18)
            cancelButton().padding(.top, 4)
        }
    }

    private func serverSection(_ section: CompanionServerSection, chooser: CompanionAccountChooser,
                               activeServerId: String?) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: "server.rack")
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Color.siloIconTile, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .foregroundStyle(.white)
                Text(section.server.displayName)
                    .font(.siloBody.weight(.semibold))
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(section.accounts) { option in
                accountRow(
                    option,
                    isOn: selection.contains(option.id),
                    isActiveAccount: option.isInUse && section.server.id == activeServerId,
                    unavailable: chooser.unavailable(option, in: selection)
                ) {
                    selection = chooser.toggling(option, in: selection)
                }
            }
        }
    }

    /// One account: its initial, its name ("alex · this iPhone" for the
    /// account the phone uses), and a check. An account that must sign in
    /// again on this phone, or that the TV's limit leaves no room for, is
    /// shown but can't be ticked.
    private func accountRow(
        _ option: CompanionAccountOption,
        isOn: Bool,
        isActiveAccount: Bool,
        unavailable: CompanionAccountChooser.Unavailable?,
        action: @escaping () -> Void
    ) -> some View {
        let name = option.username ?? "Your account"
        return Button(action: action) {
            HStack(spacing: 12) {
                Text(String(name.prefix(1)).uppercased())
                    .font(.siloBody.weight(.semibold))
                    .frame(width: 32, height: 32)
                    .background(Color.siloIconTile, in: Circle())
                    .foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 2) {
                    Text(isActiveAccount ? "\(name) · this \(UIDevice.current.model)" : name)
                        .font(.siloBody)
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if unavailable == .needsSignIn {
                        Text("Sign in again on \(UIDevice.current.model)")
                            .font(.siloCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(isOn ? Color.siloOnSurface : Color.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                isOn ? Color.siloChromeSelectedFill : Color.siloChromeRestingFill,
                in: RoundedRectangle(cornerRadius: 13, style: .continuous)
            )
            .opacity(unavailable == nil ? 1 : 0.5)
        }
        .buttonStyle(.plain)
        .disabled(unavailable != nil)
        .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// "Continue — 3 accounts".
    static func continueTitle(count: Int) -> String {
        switch count {
        case 0: return "Continue"
        case 1: return "Continue — 1 account"
        default: return "Continue — \(count) accounts"
        }
    }

    /// What the chooser can't do on this TV, under the list.
    static func chooserNote(_ chooser: CompanionAccountChooser, tvName: String, limitReached: Bool) -> String? {
        if limitReached, let limit = chooser.limit {
            return limit == 1
                ? "\(tvName) can keep 1 account from this setup."
                : "\(tvName) can keep \(limit) accounts from this setup."
        }
        switch chooser.mode {
        case .several: return nil
        case .onePerServer: return "\(tvName) keeps one account per server."
        case .one: return "\(tvName) keeps one account."
        }
    }

    /// The sign-in offer's body. It reports what the TV says, not a fact.
    private static func signInOfferBody(tvName: String) -> String {
        "A TV nearby named “\(tvName)” says it's on its sign-in screen. You'll check its code before approving."
    }

    /// The same content model as `TVApprovalCard`, the web `/activate` card
    /// and Android: the code, which server and account, what approving
    /// grants, and the warning.
    private func confirm(serverName: String, serverHost: String, accountName: String?,
                         code: String, matchWords: String?, step: String?) -> some View {
        VStack(spacing: 0) {
            if let step {
                Text(step)
                    .font(.siloCaption)
                    .foregroundStyle(.tertiary)
                    .padding(.bottom, 4)
            }
            Text("Check that \(tv.name) shows")
                .font(.siloCaption)
                .foregroundStyle(.secondary)
            Text(DeviceUserCode.display(code))
                .font(.siloPIN)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.top, 8)
                .accessibilityLabel(Text(DeviceUserCode.spokenCharacters(code)).speechSpellsOutCharacters())
            // Rollout fallback: TVs released before user codes show only the
            // match words. Remove together with Android's
            // CompanionPairingBottomOverlay line, the web /activate card's
            // "Older TV apps show ..." line and the Apple TV pairing panel's
            // "Older phones show ..." line.
            if let olderTVLine = Self.olderTVLine(matchWords: matchWords) {
                Text(olderTVLine)
                    .font(.siloCaption)
                    .foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            Text(TVApprovalCard.signInLine(serverName: serverName, serverHost: serverHost, accountName: accountName))
                .font(.siloBody)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 14)
            Text(TVApprovalCard.profilesLine)
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Text(TVApprovalCard.onlyApproveInFrontLine)
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            primaryButton("Yes, this matches") { Task { await coordinator?.confirmMatch() } }
                .padding(.top, 22)
            tertiaryButton("Doesn’t match") { Task { await coordinator?.declineMatch() } }
                .padding(.top, 4)
        }
    }

    /// The line under the code naming what TVs released before user codes
    /// show instead; the same wording as Android and the web `/activate` card.
    static func olderTVLine(matchWords: String?) -> String? {
        guard let words = matchWords?.trimmingCharacters(in: .whitespacesAndNewlines), !words.isEmpty else { return nil }
        return "Older TV apps show \(words.uppercased()) instead."
    }

    private func finished(signedIn: [String], failed: [CompanionPairingCoordinator.FailedServer]) -> some View {
        VStack(spacing: 0) {
            let complete = signedIn.isEmpty == false && failed.isEmpty
            Image(systemName: complete ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(complete ? Color.green : Color.yellow)
                .padding(.bottom, 12)
            Text(signedIn.isEmpty
                ? (server == nil ? "Setup didn’t finish" : "Sign-in didn’t finish")
                : (server == nil
                    ? (failed.isEmpty ? "\(tv.name) is set up" : "\(tv.name) is set up, with problems")
                    : "\(tv.name) is signed in"))
                .font(.siloHeadline)
                .multilineTextAlignment(.center)
            // One line per server: "Home — alex, sam".
            ForEach(signedIn.indices, id: \.self) { index in
                Text(signedIn[index])
                    .font(.siloBody)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            ForEach(failed.indices, id: \.self) { index in
                let failure = failed[index]
                Text(failure.summary)
                    .font(.siloCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            if signedIn.isEmpty {
                primaryButton("Try Again") { retry() }.padding(.top, 22)
                tertiaryButton("Close") { dismiss() }.padding(.top, 4)
            } else {
                primaryButton("Done") { dismiss() }.padding(.top, 22)
            }
        }
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 0) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.yellow)
                .padding(.bottom, 12)
            Text(message)
                .font(.siloBody)
                .multilineTextAlignment(.center)
            primaryButton("Try Again") { retry() }.padding(.top, 22)
            tertiaryButton("Close") { dismiss() }.padding(.top, 4)
        }
    }

    // MARK: - Header & building blocks

    private var heroGlyph: some View {
        Image(systemName: "tv")
            .font(.system(size: 56))
            .foregroundStyle(.primary)
            .frame(width: 104, height: 104)
    }

    private func compactHeader(title: String, subtitle: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "tv").font(.system(size: 22)).frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.siloHeadline)
                Text(subtitle).font(.siloCaption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.bottom, 14)
    }

    private func progressStep(title: String, subtitle: String) -> some View {
        VStack(spacing: 10) {
            Text(title).font(.siloHeadline)
            Text(subtitle)
                .font(.siloCaption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            ProgressView().padding(.top, 4)
            // Every non-terminal step needs an exit: without one, a wedged TV
            // leaves the user trapped behind the scrim (which stops dismissing
            // once the flow starts).
            cancelButton().padding(.top, 10)
        }
        .padding(.vertical, 8)
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.siloHeadline).frame(maxWidth: .infinity).padding(.vertical, 6)
        }
        .pairingPrimaryButton()
    }

    private func tertiaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.siloBody).frame(maxWidth: .infinity).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.siloSecondaryText)
    }

    private func cancelButton() -> some View {
        // `dismiss()` cancels the coordinator.
        tertiaryButton("Cancel") { dismiss() }
    }

    // MARK: - Actions

    private func setUp() {
        started = true
        startupTask?.cancel()
        startupTask = Task {
            let account = server == nil ? nil : signInAccounts.first { $0.id == signInChoice }
            let coordinator = await CompanionPairingCoordinator.connect(to: tv, server: server, account: account)
            guard !Task.isCancelled else {
                await coordinator.cancel()
                return
            }
            self.coordinator = coordinator
        }
    }

    /// Start the flow over with a fresh session against the same TV. Server
    /// selection is intentionally kept.
    private func retry() {
        Task { [coordinator] in await coordinator?.cancel() }
        coordinator = nil
        setUp()
    }

    private func dismiss() {
        startupTask?.cancel()
        startupTask = nil
        Task { [coordinator] in await coordinator?.cancel() }
        withAnimation(.spring(response: 0.4, dampingFraction: 0.9)) {
            appeared = false
        } completion: {
            onDismiss()
        }
    }

    /// The chooser starts with the account this device uses on its active
    /// server; the user can add or remove others. Kept across Try Again.
    private func preselect() {
        guard !didPreselect, let coordinator else { return }
        didPreselect = true
        if selection.isEmpty { selection = coordinator.defaultSelection }
    }

    /// A sign-in TV's server: the accounts that can approve, the one in use
    /// chosen.
    private func loadSignInAccounts() async {
        guard let server else { return }
        let options = await CompanionPairingCoordinator.accountOptions(on: server).filter { !$0.needsSignIn }
        guard !Task.isCancelled else { return }
        signInAccounts = options
        if signInChoice == nil || !options.contains(where: { $0.id == signInChoice }) {
            signInChoice = (options.first(where: \.isInUse) ?? options.first)?.id
        }
    }
}

extension View {
    /// Large white-filled button with dark text, like the app's other
    /// primary buttons. Shared by the pairing and TV approval cards.
    func pairingPrimaryButton() -> some View {
        self
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .tint(.siloOnSurface)
            .foregroundStyle(Color.siloBackground)
    }
}
#endif
