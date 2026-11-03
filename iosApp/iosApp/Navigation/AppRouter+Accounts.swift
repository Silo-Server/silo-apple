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
    /// A second destructive choice: "Sign Out & Remove Server" while the
    /// account is the server's only one.
    var alternative: Alternative? = nil

    struct Alternative: Equatable {
        let title: String
        let action: Action
    }

    var id: String {
        switch action {
        case .signOut(let id): "sign-out|\(serverId)|\(id)"
        case .removeServer: "remove|\(serverId)"
        case .replace(let id): "replace|\(serverId)|\(id)"
        }
    }

    /// "This deletes 12 downloads (8.4 GB) from this iPhone." Nil without
    /// downloads.
    static func downloadsSentence(count: Int, bytes: Int64, lead: String = "This deletes") -> String? {
        guard count > 0 else { return nil }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        let noun = count == 1 ? "download" : "downloads"
        return "\(lead) \(count) \(noun) (\(size)) from this \(DeviceNoun.current)."
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
    /// routes), else to server setup.
    func leaveSignIn() {
        if canReturnToPicker {
            returnToPicker()
        } else if signInLeavesForChangeAccount {
            showChangeAccount()
        } else {
            resetToServerSetup()
        }
    }

    /// Whether leaving sign-in goes to Change Account rather than server
    /// setup: something besides this sign-in's account is saved.
    var signInLeavesForChangeAccount: Bool {
        AccountDirectory.shared.accounts.count > 1 || ServerRegistry.shared.entries.count > 1
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
    /// (`renewing`), or a fresh sign-in on a server with no account left.
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
    /// is still selected (the person backed out of adding).
    func returnToPicker() {
        let request = accountSignIn
        accountSignIn = nil
        if request?.returnsToChangeAccount == true {
            showChangeAccount()
            return
        }
        // Adding a server may have made it the active one, with no account.
        if AuthService.shared.isLoggedIn, AuthService.shared.hasProfile {
            resetAfterServerResolution(to: .authenticated)
        } else {
            pickerRequestedByPerson = true
            resetAfterServerResolution(to: .needsProfile)
        }
    }

    private func startSignIn(_ request: AccountSignInRequest) {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        Task {
            defer { isSigningOut = false }
            if ServerRegistry.shared.activeServerId != request.serverId {
                guard await ServerRegistry.shared.switchTo(serverId: request.serverId) else {
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
        let serverName = ServerRegistry.shared.entry(with: request.serverId)?.displayName ?? "this server"
        let oldName = old.username ?? "the old account"
        let newName = signedIn.username ?? "this account"
        Task {
            let summary = await AccountSessions.downloadSummary(account: renewing, onServer: request.serverId)
            let downloads = summary.flatMap {
                AccountRemovalRequest.downloadsSentence(count: $0.count, bytes: $0.bytes, lead: "It also deletes")
            }
            pendingRemoval = AccountRemovalRequest(
                serverId: request.serverId,
                action: .replace(localAccountId: renewing),
                title: "Replace \(oldName) with \(newName)?",
                message: ["You're now signed in to \(serverName) as \(newName). Replacing signs out of \(oldName).",
                          downloads].compactMap { $0 }.joined(separator: " "),
                confirmTitle: "Replace",
                cancelTitle: "Keep Both"
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
    /// downloads that go with it (spec §4.4). While it is the server's only
    /// account, the server can go with it.
    func confirmSignOut(account localAccountId: String, onServer serverId: String) async {
        let directory = AccountDirectory.shared
        directory.reload()
        let account = directory.account(localAccountId)
        let serverName = ServerRegistry.shared.entry(with: serverId)?.displayName ?? "this server"
        let summary = await AccountSessions.downloadSummary(account: localAccountId, onServer: serverId)
        let isOnlyAccount = directory.accounts(onServer: serverId).allSatisfy { $0.localAccountId == localAccountId }
        pendingRemoval = AccountRemovalRequest(
            serverId: serverId,
            action: .signOut(localAccountId: localAccountId),
            title: "Sign out of \(account?.username ?? "this account") on \(serverName)?",
            message: Self.signOutMessage(downloads: summary.flatMap {
                AccountRemovalRequest.downloadsSentence(count: $0.count, bytes: $0.bytes)
            }),
            confirmTitle: "Sign Out",
            cancelTitle: "Cancel",
            alternative: isOnlyAccount
                ? AccountRemovalRequest.Alternative(title: "Sign Out & Remove Server", action: .removeServer)
                : nil
        )
    }

    /// What signing out deletes. Apple TV also says what leaves and what
    /// stays, as Roku and Android TV do.
    private static func signOutMessage(downloads: String?) -> String? {
        #if os(tvOS)
        let leaves = "This account's profiles and settings leave this \(DeviceNoun.current). The server stays saved, so you can sign in again."
        return [leaves, downloads].compactMap { $0 }.joined(separator: " ")
        #else
        return downloads
        #endif
    }

    /// Asks before removing a server, which signs out of every account on it.
    func confirmRemoveServer(_ serverId: String) async {
        let accounts = AccountDirectory.shared.accounts(onServer: serverId)
        let serverName = ServerRegistry.shared.entry(with: serverId)?.displayName ?? "this server"
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
        case 1: "This signs out of \(accounts[0].username ?? "its account")."
        default: "This signs out of its \(accounts.count) accounts."
        }
        pendingRemoval = AccountRemovalRequest(
            serverId: serverId,
            action: .removeServer,
            title: "Remove \(serverName)?",
            message: [signsOut, AccountRemovalRequest.downloadsSentence(count: count, bytes: bytes)]
                .compactMap { $0 }.joined(separator: " "),
            confirmTitle: "Remove",
            cancelTitle: "Cancel"
        )
    }

    /// Runs a confirmed request: its action, or its alternative.
    func perform(_ request: AccountRemovalRequest, choosingAlternative: Bool = false) {
        pendingRemoval = nil
        let alternative = choosingAlternative ? request.alternative : nil
        let action = alternative?.action ?? request.action
        switch action {
        case .signOut(let id), .replace(let id):
            signOut(account: id, onServer: request.serverId)
        case .removeServer:
            removeServer(request.serverId)
        }
    }

    /// Signs out of one account. Signing out of the account in use leaves
    /// for Change Account when another account can be chosen, else for
    /// sign-in; any other account goes without leaving the current screen.
    private func signOut(account localAccountId: String, onServer serverId: String) {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        Task {
            defer { isSigningOut = false }
            #if os(tvOS)
            // A phone's remote playback borrows this TV's identity; it ends
            // before any account can sign out.
            if await TokenStore.shared.hasTemporaryScope() {
                guard await RemotePlaybackIdentityManager.shared.end() else {
                    accountActionError = "Couldn't end remote playback. Try signing out again."
                    return
                }
            }
            #endif
            let requestAccountId = await TokenStore.shared.requestAccountId(onServer: serverId)
            let wasInUse = ServerRegistry.shared.activeServerId == serverId && requestAccountId == localAccountId
            let outcome = await AccountSessions.signOut(account: localAccountId, onServer: serverId)
            switch outcome {
            case .refused:
                accountActionError = "Silo couldn't sign out of that account. Try again."
                return
            case .localOnly:
                accountActionError = "Silo couldn't clear the saved sign-in on this device. Please try signing out again."
            case .diagnosticsCleanupFailed:
                accountActionError = "You're signed out, but Silo couldn't erase local diagnostics. Remove this server in Settings > Accounts to retry cleanup."
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

    private func removeServer(_ serverId: String) {
        guard !isSigningOut else { return }
        isSigningOut = true
        accountActionError = nil
        Task {
            defer { isSigningOut = false }
            let wasActive = ServerRegistry.shared.activeServerId == serverId
            guard await AccountSessions.removeServer(serverId) else {
                accountActionError = "Silo couldn't remove the saved server. Please try again."
                return
            }
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
