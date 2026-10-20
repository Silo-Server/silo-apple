#if os(iOS)
import SwiftUI

/// The native-style companion pairing card: rises from the bottom over a dimmed
/// app and runs the whole flow for one discovered TV — discovery, account
/// selection, match-code confirm, progress, result — beneath a consistent
/// header. Pure presentation: the coordinator owns the transport
/// (`CompanionPairingCoordinator.connect(to:)`).
struct CompanionPairingCard: View {
    let tv: DiscoveredTV
    /// A sign-in TV's choices: the accounts on its server, the one to
    /// preselect first (`CompanionPairingOffer.accounts`). Empty for a setup
    /// TV, whose accounts are chosen once connected.
    var signInAccounts: [CompanionPairingAccount] = []
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
    /// A setup TV's chosen accounts.
    @State private var selection: Set<SiloAccountRef> = []
    /// The account a sign-in TV is signed in with, when there are several.
    @State private var signInChoice: SiloAccountRef?
    @State private var choosingSignInAccount = false
    /// The full account list, past `compactPickerLimit` accounts.
    @State private var browsingAllAccounts = false
    @State private var started = false
    @State private var appeared = false

    /// Past this many accounts the setup picker shows only the chosen ones,
    /// with the full list a step away.
    static let compactPickerLimit = 4

    private var isSignIn: Bool { !signInAccounts.isEmpty }
    private var server: ServerEntry? { signInAccounts.first?.server }

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
            stepContent
                .padding(.horizontal, 22)
                .padding(.bottom, 22)
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
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: choosingSignInAccount)
        .animation(.spring(response: 0.35, dampingFraction: 0.9), value: browsingAllAccounts)
    }

    @ViewBuilder private var stepContent: some View {
        if !started {
            if choosingSignInAccount {
                signInAccountPicker
            } else {
                discovery
            }
        } else {
            switch coordinator?.state ?? .connecting {
            case .connecting:
                progressStep(title: "Connecting…", subtitle: tv.name)
            case let .pickAccounts(_, accounts):
                accountPicker(accounts)
                    .onAppear { preselectCurrentAccount(in: accounts) }
            case let .confirmMatch(_, serverName, serverHost, accountName, code, matchWords):
                confirm(serverName: serverName, serverHost: serverHost, accountName: accountName,
                        code: code, matchWords: matchWords)
            case let .working(progress):
                progressStep(title: isSignIn ? "Signing in…" : "Setting up…", subtitle: progress)
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
                primaryButton("Sign In") {
                    if signInAccounts.count > 1 {
                        choosingSignInAccount = true
                    } else {
                        setUp()
                    }
                }
                .padding(.top, 22)
            } else {
                Text("Set Up \(tv.name)")
                    .font(.siloTitle)
                    .multilineTextAlignment(.center)
                Text("Sign \(tv.name) in to your accounts from this \(UIDevice.current.model).")
                    .font(.siloCaption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.top, 6)
                primaryButton("Set Up") { setUp() }.padding(.top, 22)
            }
            tertiaryButton("Not Now") { dismiss() }.padding(.top, 4)
        }
    }

    /// A sign-in TV with several accounts on its server: pick the one it
    /// signs in as. The confirm step then names it.
    private var signInAccountPicker: some View {
        VStack(spacing: 0) {
            compactHeader(title: "Choose an account",
                          subtitle: "Sign \(tv.name) in to \(server?.displayName ?? "") as…")
            VStack(spacing: 8) {
                ForEach(signInAccounts) { account in
                    let isOn = account.id == (signInChoice ?? signInAccounts.first?.id)
                    accountButton(account, isOn: isOn) { signInChoice = account.id }
                }
            }
            primaryButton("Sign In") { setUp() }.padding(.top, 18)
            tertiaryButton("Not Now") { dismiss() }.padding(.top, 4)
        }
    }

    /// A setup TV: choose the accounts to sign it in with. Past
    /// `compactPickerLimit` accounts only the chosen ones show, with the full
    /// list one step away.
    private func accountPicker(_ accounts: [CompanionPairingAccount]) -> some View {
        VStack(spacing: 0) {
            compactHeader(title: "Choose accounts", subtitle: "Sign \(tv.name) in as…")
            if browsingAllAccounts {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(accounts) { account in toggleRow(account) }
                    }
                }
                .frame(maxHeight: 380)
                primaryButton("Done") { browsingAllAccounts = false }.padding(.top, 18)
            } else {
                VStack(spacing: 8) {
                    if accounts.count > Self.compactPickerLimit {
                        ForEach(accounts.filter { selection.contains($0.id) }) { account in
                            accountRow(account, isOn: true)
                        }
                        chooseAccountsRow
                    } else {
                        ForEach(accounts) { account in toggleRow(account) }
                    }
                }
                primaryButton("Continue") {
                    let chosen = accounts.filter { selection.contains($0.id) }
                    Task { await coordinator?.pushSelected(chosen) }
                }
                .disabled(!accounts.contains { selection.contains($0.id) })
                .opacity(accounts.contains { selection.contains($0.id) } ? 1 : 0.5)
                .padding(.top, 18)
                cancelButton().padding(.top, 4)
            }
        }
    }

    private func toggleRow(_ account: CompanionPairingAccount) -> some View {
        let isOn = selection.contains(account.id)
        return accountButton(account, isOn: isOn) {
            if isOn { selection.remove(account.id) } else { selection.insert(account.id) }
        }
    }

    private func accountButton(_ account: CompanionPairingAccount, isOn: Bool,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) { accountRow(account, isOn: isOn) }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isOn ? [.isSelected] : [])
    }

    /// An account as Choose an Account shows it: its profiles, username,
    /// email, and server.
    private func accountRow(_ account: CompanionPairingAccount, isOn: Bool) -> some View {
        HStack(spacing: 12) {
            StackedProfileAvatars(
                profiles: account.profiles,
                fallbackID: account.id.storageKey,
                fallbackName: account.name,
                serverAddress: account.server.url,
                maxCount: 3
            )
            VStack(alignment: .leading, spacing: 2) {
                Text(account.name)
                    .font(.siloBody)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                ForEach(account.detailLines, id: \.self) { line in
                    Text(line)
                        .font(.siloCaption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isOn ? Color.siloOnSurface : Color.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            isOn ? Color.siloChromeSelectedFill : Color.siloChromeRestingFill,
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .accessibilityElement(children: .combine)
    }

    /// Opens the full account list.
    private var chooseAccountsRow: some View {
        Button { browsingAllAccounts = true } label: {
            HStack(spacing: 12) {
                Image(systemName: "person.2")
                    .font(.system(size: 16, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .background(Color.siloIconTile, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .foregroundStyle(.white)
                Text("Choose Accounts…")
                    .font(.siloBody)
                    .foregroundStyle(.primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.siloChromeRestingFill, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    /// The sign-in offer's body. It reports what the TV says, not a fact.
    private static func signInOfferBody(tvName: String) -> String {
        "A TV nearby named “\(tvName)” says it's on its sign-in screen. You'll check its code before approving."
    }

    /// The same content model as `TVApprovalCard`, the web `/activate` card
    /// and Android: the code, which server and account, what approving
    /// grants, and the warning.
    private func confirm(serverName: String, serverHost: String, accountName: String?,
                         code: String, matchWords: String?) -> some View {
        VStack(spacing: 0) {
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

    private func finished(signedIn: [String], failed: [CompanionPairingCoordinator.FailedAccount]) -> some View {
        VStack(spacing: 0) {
            Image(systemName: signedIn.isEmpty ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(signedIn.isEmpty ? Color.yellow : Color.green)
                .padding(.bottom, 12)
            Text(signedIn.isEmpty
                ? (isSignIn ? "Sign-in didn’t finish" : "Setup didn’t finish")
                : (isSignIn ? "\(tv.name) is signed in" : "\(tv.name) is set up"))
                .font(.siloHeadline)
                .multilineTextAlignment(.center)
            ForEach(Array(signedIn.enumerated()), id: \.offset) { _, label in
                Text(label)
                    .font(.siloBody)
                    .multilineTextAlignment(.center)
                    .padding(.top, 4)
            }
            ForEach(Array(failed.enumerated()), id: \.offset) { _, failure in
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
            let coordinator = await CompanionPairingCoordinator.connect(to: tv, account: signInAccount)
            guard !Task.isCancelled else {
                await coordinator.cancel()
                return
            }
            self.coordinator = coordinator
        }
    }

    /// Start the flow over with a fresh session against the same TV. Account
    /// selection is intentionally kept.
    private func retry() {
        Task { [coordinator] in await coordinator?.cancel() }
        coordinator = nil
        browsingAllAccounts = false
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

    /// The chosen account for a sign-in TV, nil for a setup TV.
    private var signInAccount: CompanionPairingAccount? {
        signInAccounts.first { $0.id == signInChoice } ?? signInAccounts.first
    }

    /// The chooser starts with the account this device is using; the user
    /// can add or remove others.
    private func preselectCurrentAccount(in accounts: [CompanionPairingAccount]) {
        guard selection.isEmpty, let current = accounts.first(where: \.isCurrent) else { return }
        selection.insert(current.id)
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
