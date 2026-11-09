import SwiftUI

/// A sign-in for a saved server that isn't a first sign-in (spec §4.1, §4.4).
struct AccountSignInRequest: Equatable {
    let serverId: String
    /// Filled into the username field when an account signs in again.
    let username: String?
    /// The saved account this sign-in renews. Signing in as a different
    /// account asks before it replaces this one.
    let renewingAccountId: String?
    /// Started from Change Account, so Back returns there.
    var returnsToChangeAccount = false
}

/// A destructive account action waiting for confirmation: signing out of
/// an account, removing a server, or replacing an account that signed in
/// again as someone else. The copy names the account and server and the
/// downloads it deletes.
struct AccountRemovalRequest: Identifiable, Equatable {
    enum Action: Equatable {
        /// Also removes the server when, once confirmed, this is its last
        /// account: a server with no account isn't kept.
        case signOut(localAccountId: String)
        case removeServer
        /// Keep the new sign-in and sign out of the old account.
        case replace(localAccountId: String)
    }

    let serverId: String
    let action: Action
    let title: String
    let message: String?
    let confirmTitle: String
    let cancelTitle: String

    var id: String {
        switch action {
        case .signOut(let id): "sign-out|\(serverId)|\(id)"
        case .removeServer: "remove|\(serverId)"
        case .replace(let id): "replace|\(serverId)|\(id)"
        }
    }

    /// "This deletes 12 downloads (8.4 GB) from this iPhone.", or "It also
    /// deletes …" after another sentence. Nil without downloads.
    static func downloadsSentence(count: Int, bytes: Int64, also: Bool = false) -> String? {
        guard count > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let device = DeviceNoun.current
        return AppLanguage.string(also
            ? LocalizedStringResource.accountRemovalDownloadsAlso(count: count, "\(count)", size, device)
            : .accountRemovalDownloads(count: count, "\(count)", size, device))
    }
}

/// Where the app goes when the active server has no signed-in account.
enum SignedOutDestination: Equatable {
    /// Other saved accounts can be chosen: Change Account, as the root of
    /// the profile flow.
    case changeAccount
    /// Nothing else to choose: sign-in, for the account signing in again
    /// when there is one.
    case signIn(renewing: SavedAccountSummary?)
}

extension AppRouter {
    // MARK: - Routing without a signed-in account

    /// Change Account while another saved account can open a profile;
    /// otherwise the active server's sign-in, renewing its account that waits
    /// to sign in again, as Android and Roku route.
    func signedOutDestination() -> SignedOutDestination {
        Self.signedOutDestination(activeServerId: ServerRegistry.shared.activeServerId)
    }

    static func signedOutDestination(activeServerId: String?) -> SignedOutDestination {
        let directory = AccountDirectory.shared
        directory.reload()
        if directory.hasSignedInAccount { return .changeAccount }
        guard let activeServerId else { return .signIn(renewing: nil) }
        let waiting = directory.accounts(onServer: activeServerId).filter(\.needsSignIn)
        let selected = AccountScope.localAccountId(onServer: activeServerId)
        return .signIn(renewing: waiting.first { $0.localAccountId == selected } ?? waiting.first)
    }

    /// Whether leaving the sign-in or server setup screen has somewhere to
    /// go other than server setup: a sign-in started from Change Account
    /// goes back there, and otherwise some saved account can open a profile.
    var canReturnToPicker: Bool {
        accountSignIn?.returnsToChangeAccount == true || AccountDirectory.shared.hasSignedInAccount
    }

    /// Leaving sign-in without signing in: back where it started, else to
    /// Change Account while other accounts or servers are saved (as Android
    /// routes), else to server setup. A server with no account goes first.
    func leaveSignIn() {
        if canReturnToPicker {
            returnToPicker()
            return
        }
        // Decided before the server goes, as the screen's Back title was.
        let leavesForChangeAccount = signInLeavesForChangeAccount
        removingActiveServerWithoutAccounts { [self] in
            if leavesForChangeAccount {
                showChangeAccount()
            } else {
                resetToServerSetup()
            }
        }
    }

    /// Whether leaving sign-in goes to Change Account rather than server
    /// setup: something besides this sign-in's account is saved. A server
    /// with no account is removed on the way out, so only other servers count.
    var signInLeavesForChangeAccount: Bool {
        let directory = AccountDirectory.shared
        let servers = ServerRegistry.shared
        if let serverId = servers.activeServerId, directory.accounts(onServer: serverId).isEmpty {
            return servers.entries.count > 1
        }
        return directory.accounts.count > 1 || servers.entries.count > 1
    }

    /// Runs `next` once the active server is removed when no account is
    /// saved on it, as after backing out of signing in to a server just
    /// added: a server with no account isn't kept. The registry then makes
    /// the most recently used server active. Otherwise runs `next` at once.
    private func removingActiveServerWithoutAccounts(then next: @escaping () -> Void) {
        guard let serverId = ServerRegistry.shared.activeServerId,
              AccountSessions.hasNoAccounts(onServer: serverId) else {
            next()
            return
        }
        guard !isSigningOut else { return }
        isSigningOut = true
        Task {
            defer { isSigningOut = false }
            // When removal fails the server stays; leaving goes on as before.
            _ = await AccountSessions.removeServer(serverId)
            next()
        }
    }

    /// The username the sign-in screen starts with: the account signing in
    /// again, when there is one.
    var signInPrefill: String? {
        if let username = accountSignIn?.username { return username }
        guard let serverId = ServerRegistry.shared.activeServerId,
              let selected = AccountScope.localAccountId(onServer: serverId) else { return nil }
        let account = AccountDirectory.shared.account(selected)
        return account?.needsSignIn == true ? account?.username : nil
    }

    // MARK: - Change Account

    /// Opens Change Account (spec §4.1): pushed over the picker or Home, or
    /// the profile flow's root while no account is open.
    func showChangeAccount() {
        switch authState {
        case .needsProfile where showsChangeAccountRoot:
            // Already on screen as the root.
            return
        case .authenticated, .needsProfile:
            recordScreenBreadcrumb(target: "changeAccount", action: "navigate")
            navigate(to: .changeAccount)
        default:
            // From sign-in or server setup: back into the profile flow, whose
            // root is Change Account when no account is open.
            withoutStackCrossfade {
                if AuthService.shared.isLoggedIn, AuthService.shared.hasProfile {
                    resetAfterServerResolution(to: .authenticated)
                    navigate(to: .changeAccount)
                } else {
                    pickerRequestedByPerson = true
                    resetAfterServerResolution(to: .needsProfile)
                    if !showsChangeAccountRoot { navigate(to: .changeAccount) }
                }
            }
        }
    }

    /// Swaps the signed-out and profile stacks in one update. Both bind
    /// `path`, so a stack still fading out would push the other's route (a
    /// sign-in stack has no Change Account) or be freed mid-pop, which on
    /// Apple TV leaves focus locked with nothing focused.
    func withoutStackCrossfade(_ body: () -> Void) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction, body)
    }

    /// The open account chosen in Change Account: its picker again.
    func showCurrentAccountPicker() {
        if authState == .needsProfile {
            popToRoot()
        } else {
            switchProfile()
        }
    }

    /// Makes another saved account the active one on its server (switching
    /// server first when needed) and shows its picker, which waits for a
    /// choice; a single profile without a PIN opens directly.
    func openAccount(_ localAccountId: String, onServer serverId: String) async throws {
        guard !isSigningOut else { throw CancellationError() }
        isSigningOut = true
        accountActionError = nil
        defer { isSigningOut = false }
        try await AccountSessions.switchTo(account: localAccountId, onServer: serverId)
        MarqueeScene.shared.showActiveServer()
        recordScreenBreadcrumb(target: "profileSelection", action: "changeAccount")
        skipsSingleProfilePicker = true
        pickerRequestedByPerson = false
        // The server can refuse the account's session during the switch.
        // It then waits to sign in again, and routes as an expiry does.
        guard AuthService.shared.openAccount != nil else {
            routeWithoutSignedInAccount()
            return
        }
        withoutStackCrossfade { resetAfterServerResolution(to: .needsProfile) }
    }

    // MARK: - Sign-in

    /// Opens sign-in for `serverId` with the account's username filled in
    /// (`renewing`), or a fresh sign-in.
    /// The server becomes the active one first.
    func beginSignIn(onServer serverId: String, renewing localAccountId: String?,
                     returningToChangeAccount: Bool = false) {
        let renewing = localAccountId.flatMap { AccountDirectory.shared.account($0) }
        startSignIn(AccountSignInRequest(serverId: serverId, username: renewing?.username,
                                         renewingAccountId: renewing?.localAccountId,
                                         returnsToChangeAccount: returningToChangeAccount))
    }

    /// "Add an account": signs in to another account on a saved server,
    /// keeping every account already saved.
    func beginAddAccount(onServer serverId: String, returningToChangeAccount: Bool = false) {
        startSignIn(AccountSignInRequest(serverId: serverId, username: nil, renewingAccountId: nil,
                                         returnsToChangeAccount: returningToChangeAccount))
    }

    /// Leaves sign-in or server setup: back to Change Account when the
    /// sign-in started there, else to the picker, or to Home when a profile
    /// is still selected (the person backed out of adding). A server added
    /// on the way, with no account yet, is removed first.
    func returnToPicker() {
        let request = accountSignIn
        accountSignIn = nil
        removingActiveServerWithoutAccounts { [self] in
            if request?.returnsToChangeAccount == true {
                showChangeAccount()
                return
            }
            if AuthService.shared.isLoggedIn, AuthService.shared.hasProfile {
                resetAfterServerResolution(to: .authenticated)
            } else {
                pickerRequestedByPerson = true
                resetAfterServerResolution(to: .needsProfile)
            }
        }
    }

    /// "Use a different server" on sign-in: server setup, without the
    /// server being left when it has no account.
    func leaveSignInForServerSetup() {
        removingActiveServerWithoutAccounts { [self] in resetToServerSetup() }
    }

    private func startSignIn(_ request: AccountSignInRequest) {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        #if os(iOS)
        let approval = pendingDeviceApproval
        #endif
        Task {
            defer { isSigningOut = false }
            if ServerRegistry.shared.activeServerId != request.serverId {
                guard await ServerRegistry.shared.switchTo(serverId: request.serverId) else {
                    #if os(iOS)
                    // The TV approval waiting on this sign-in has none to wait
                    // on; a newer one that arrived during the switch stays.
                    if let approval, pendingDeviceApproval == approval { _ = takePendingDeviceApproval() }
                    #endif
                    accountActionError = AccountSwitchError.serverSwitchFailed.errorDescription
                    return
                }
            } else if request.renewingAccountId == nil {
                await AccountSessions.verifyActiveAccountIfNeeded()
            }
            loginNotice = nil
            accountSignIn = request
            recordScreenBreadcrumb(target: "login", action: request.renewingAccountId == nil ? "addAccount" : "signInAgain")
            withoutStackCrossfade {
                path = NavigationPath()
                setAuthState(.needsLogin, reason: "accountSignIn")
            }
        }
    }

    /// A sign-in from `request` finished. The picker shows the account that
    /// signed in. Signing in again as a different account asks whether that
    /// replaces the old one; until answered both stay saved.
    func finishAccountSignIn(_ request: AccountSignInRequest) {
        let signedIn = AuthService.shared.activeAccount
        AccountDirectory.shared.reload()
        guard let renewing = request.renewingAccountId, let signedIn,
              signedIn.localAccountId != renewing,
              let old = AccountDirectory.shared.account(renewing),
              // The same username is the same person: an account saved before
              // its server user was known. Replacing it would delete their
              // downloads, so both stay until the person signs one out.
              old.username?.lowercased() != signedIn.username?.lowercased() || old.username == nil
        else { return }
        skipsSingleProfilePicker = false
        let serverName = ServerRegistry.shared.entry(with: request.serverId)?.displayName
            ?? AppLanguage.string(.accountFallbackThisServer)
        let oldName = old.username ?? AppLanguage.string(.accountFallbackOldAccount)
        let newName = signedIn.username ?? AppLanguage.string(.accountFallbackThisAccount)
        Task {
            let summary = await AccountSessions.downloadSummary(account: renewing, onServer: request.serverId)
            let downloads = summary.flatMap {
                AccountRemovalRequest.downloadsSentence(count: $0.count, bytes: $0.bytes, also: true)
            }
            pendingRemoval = AccountRemovalRequest(
                serverId: request.serverId,
                action: .replace(localAccountId: renewing),
                title: AppLanguage.string(.accountReplaceTitle(oldName, newName)),
                message: [AppLanguage.string(.accountReplaceMessage(serverName, newName, oldName)),
                          downloads].compactMap { $0 }.joined(separator: " "),
                confirmTitle: AppLanguage.string(.loginReplaceConfirm),
                cancelTitle: AppLanguage.string(.accountReplaceKeepBoth)
            )
        }
    }

    // MARK: - Sign-out and removal

    /// Sign Out in the profile menu: the account requests use now, or the
    /// selected account waiting to sign in again.
    func confirmSignOutOfCurrentAccount() {
        Task {
            guard let serverId = ServerRegistry.shared.activeServerId,
                  let localAccountId = await TokenStore.shared.requestAccountId(onServer: serverId) else {
                // Nothing saved to sign out of, so nothing to delete: only route on.
                routeWithoutSignedInAccount()
                return
            }
            await confirmSignOut(account: localAccountId, onServer: serverId)
        }
    }

    /// Asks before signing out of an account, naming it, its server, and the
    /// downloads that go with it (spec §4.4). Signing out of the server's
    /// only account removes the server too: a server with no account isn't
    /// kept.
    func confirmSignOut(account localAccountId: String, onServer serverId: String) async {
        let directory = AccountDirectory.shared
        directory.reload()
        let account = directory.account(localAccountId)
        let serverName = ServerRegistry.shared.entry(with: serverId)?.displayName
            ?? AppLanguage.string(.accountFallbackThisServer)
        let summary = await AccountSessions.downloadSummary(account: localAccountId, onServer: serverId)
        let isOnlyAccount = Self.isLastAccount(localAccountId, onServer: serverId, in: directory)
        pendingRemoval = AccountRemovalRequest(
            serverId: serverId,
            action: .signOut(localAccountId: localAccountId),
            title: AppLanguage.string(.shellSignOutTitleNamed(
                account?.username ?? AppLanguage.string(.accountFallbackThisAccount), serverName
            )),
            message: Self.signOutMessage(
                removingServer: isOnlyAccount ? serverName : nil,
                downloads: summary.flatMap {
                    AccountRemovalRequest.downloadsSentence(count: $0.count, bytes: $0.bytes)
                }
            ),
            confirmTitle: AppLanguage.string(.shellSignOutConfirm),
            cancelTitle: AppLanguage.string(.commonCancel)
        )
    }

    /// What signing out deletes, and the server when this is its only
    /// account. Apple TV also says what leaves and what stays, as Roku and
    /// Android TV do.
    private static func signOutMessage(removingServer serverName: String?, downloads: String?) -> String? {
        let device = DeviceNoun.current
        #if os(tvOS)
        let leaves = AppLanguage.string(serverName.map {
            LocalizedStringResource.accountSignOutLeavesRemovingServer(device, $0)
        } ?? .accountSignOutLeaves(device))
        #else
        let leaves = serverName.map { AppLanguage.string(.accountSignOutRemovesServer($0, device)) }
        #endif
        let message = [leaves, downloads].compactMap { $0 }.joined(separator: " ")
        return message.isEmpty ? nil : message
    }

    /// Asks before removing a server, which signs out of every account on it.
    func confirmRemoveServer(_ serverId: String) async {
        let accounts = AccountDirectory.shared.accounts(onServer: serverId)
        let serverName = ServerRegistry.shared.entry(with: serverId)?.displayName
            ?? AppLanguage.string(.accountFallbackThisServer)
        var count = 0
        var bytes: Int64 = 0
        for account in accounts {
            if let summary = await AccountSessions.downloadSummary(account: account.localAccountId, onServer: serverId) {
                count += summary.count
                bytes += summary.bytes
            }
        }
        let signsOut: String? = switch accounts.count {
        case 0: nil
        case 1: AppLanguage.string(.accountRemoveServerSignsOutOne(
            accounts[0].username ?? AppLanguage.string(.accountFallbackItsAccount)
        ))
        default: AppLanguage.string(.accountRemoveServerSignsOutMany(accounts.count))
        }
        pendingRemoval = AccountRemovalRequest(
            serverId: serverId,
            action: .removeServer,
            title: AppLanguage.string(.serversRemoveTitle(serverName)),
            message: [signsOut, AccountRemovalRequest.downloadsSentence(count: count, bytes: bytes)]
                .compactMap { $0 }.joined(separator: " "),
            confirmTitle: AppLanguage.string(.serversRemoveConfirm),
            cancelTitle: AppLanguage.string(.commonCancel)
        )
    }

    /// Runs a confirmed request.
    func perform(_ request: AccountRemovalRequest) {
        pendingRemoval = nil
        switch request.action {
        case .signOut(let id), .replace(let id):
            signOut(account: id, onServer: request.serverId)
        case .removeServer:
            removeServer(request.serverId)
        }
    }

    /// Whether `localAccountId` is the only account saved on `serverId`.
    /// False when the account list couldn't be read or doesn't list it, so
    /// an unreadable list never takes the whole server, and other accounts,
    /// with one sign-out.
    private static func isLastAccount(_ localAccountId: String, onServer serverId: String,
                                      in directory: AccountDirectory) -> Bool {
        directory.isReadable && directory.accounts(onServer: serverId).map(\.localAccountId) == [localAccountId]
    }

    /// Signs out of one account. Signing out of the account in use leaves
    /// for Change Account when another account can be chosen, else for
    /// sign-in; any other account goes without leaving the current screen.
    /// The server's last account takes the server with it, decided now
    /// rather than when the confirmation was asked, so an account added
    /// meanwhile stays.
    private func signOut(account localAccountId: String, onServer serverId: String) {
        guard !isSigningOut else { return }
        let directory = AccountDirectory.shared
        directory.reload()
        if Self.isLastAccount(localAccountId, onServer: serverId, in: directory) {
            removeServer(serverId, signingOut: localAccountId)
            return
        }
        isSigningOut = true
        accountActionError = nil
        Task {
            defer { isSigningOut = false }
            guard await endRemotePlaybackBeforeSignOut() else { return }
            let requestAccountId = await TokenStore.shared.requestAccountId(onServer: serverId)
            let wasInUse = ServerRegistry.shared.activeServerId == serverId && requestAccountId == localAccountId
            let outcome = await AccountSessions.signOut(account: localAccountId, onServer: serverId)
            switch outcome {
            case .refused:
                accountActionError = AppLanguage.string(.accountErrorSignOutRefused)
                return
            case .localOnly:
                accountActionError = AppLanguage.string(.tvSignInSignOutLocalFailed)
            case .diagnosticsCleanupFailed:
                accountActionError = AppLanguage.string(.accountErrorDiagnosticsCleanupFailed)
            case .completed:
                break
            }
            guard wasInUse else { return }
            #if !os(tvOS)
            // The provider still has the person signed in in the system
            // browser; the next browser sign-in asks it for an account choice.
            SelectAccountPrompt.shared.request(serverId: serverId, autoStart: false)
            #endif
            routeWithoutSignedInAccount()
        }
    }

    /// A phone's remote playback borrows this TV's identity; it ends before
    /// any account can sign out. False when it couldn't end.
    private func endRemotePlaybackBeforeSignOut() async -> Bool {
        #if os(tvOS)
        if await TokenStore.shared.hasTemporaryScope() {
            guard await RemotePlaybackIdentityManager.shared.end() else {
                accountActionError = AppLanguage.string(.tvSignInSignOutRemotePlaybackNotEnded)
                return false
            }
        }
        #endif
        return true
    }

    /// Removes a server and every account on it. `signingOut` is the last
    /// account when a sign-out removes the server.
    private func removeServer(_ serverId: String, signingOut localAccountId: String? = nil) {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        Task {
            defer { isSigningOut = false }
            guard await endRemotePlaybackBeforeSignOut() else { return }
            let wasActive = ServerRegistry.shared.activeServerId == serverId
            let signsOutAccountInUse: Bool
            if let localAccountId, wasActive {
                signsOutAccountInUse = await TokenStore.shared.requestAccountId(onServer: serverId) == localAccountId
            } else {
                signsOutAccountInUse = false
            }
            guard await AccountSessions.removeServer(serverId) else {
                accountActionError = AppLanguage.string(.accountErrorRemoveServerFailed)
                return
            }
            #if !os(tvOS)
            // As for any sign-out of the account in use: if the server is
            // added again, its next browser sign-in asks for an account choice.
            if signsOutAccountInUse { SelectAccountPrompt.shared.request(serverId: serverId, autoStart: false) }
            #endif
            guard wasActive else { return }
            if !ServerRegistry.shared.hasActiveServer {
                withoutStackCrossfade { resetAfterServerResolution(to: .needsServerSetup) }
            } else if AuthService.shared.isLoggedIn {
                let state = await RestoredSessionAuthResolver.resolveValidated()
                withoutStackCrossfade { resetAfterServerResolution(to: state) }
            } else {
                routeWithoutSignedInAccount()
            }
        }
    }

    /// The active server's account is gone: Change Account when another
    /// account can be chosen, sign-in when it was the last account (spec §4.4).
    func routeWithoutSignedInAccount() {
        let state: AuthState
        if !ServerRegistry.shared.hasActiveServer {
            state = .needsServerSetup
        } else {
            switch signedOutDestination() {
            case .changeAccount:
                // With no account open, the profile flow's root is Change Account.
                state = .needsProfile
            case .signIn:
                state = .needsLogin
            }
        }
        // Signing out from Settings or a pushed Change Account replaces that stack.
        withoutStackCrossfade { resetAfterServerResolution(to: state) }
    }
}
