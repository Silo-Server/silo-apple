import Foundation
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Where Cancel on a sign-in goes back to (plan §2.10): the credential,
/// profile, and screens showing when the sign-in started.
struct SignInReturnPoint {
    let serverID: String?
    let credential: CredentialSelection
    let authState: AppRouter.AuthState
    let path: NavigationPath
    /// The profile open on those screens, which Cancel opens again.
    var profileID: String? = nil
}

/// A sign-out or removal waiting for its confirmation (spec §5.6).
struct RemovalRequest: Identifiable {
    enum Target: Equatable, Sendable {
        /// Sign out of the current account. Its confirmation also offers
        /// Remove Account.
        case currentAccount
        /// Sign out of one account, current or not. Its card stays.
        case signOut(SiloAccountRef)
        /// Remove one account from the device.
        case remove(SiloAccountRef)
    }

    let id = UUID()
    let target: Target
    let copy: ConfirmationCopy
    /// For `.currentAccount`, the account current when the confirmation
    /// showed; confirming acts only while it still is.
    var account: SiloAccountRef? = nil
}

/// How a finished sign-in ended (`SiloAccountCoordinator.completeSignIn`).
enum SignInCompletion: Equatable, Sendable {
    /// Saved and opened. Nil key: saved as the server's own session, before
    /// sign-in migration.
    case opened(SignInKey?)
}

/// Every Silo account flow (spec §5–§6, plan §2.10): launch and Choose an
/// Account, the sign-in flows, sign-out and removal with the §6.2 fallback,
/// and the directory the screens draw. Screens call it with their router;
/// it never holds one.
@MainActor
@Observable
final class SiloAccountCoordinator {
    static let shared = SiloAccountCoordinator()

    @ObservationIgnored let auth: AuthService
    @ObservationIgnored private let tokenStore: TokenStore
    @ObservationIgnored private let registry: ServerRegistry
    @ObservationIgnored private let preferences: ProfileLaunchPreferences
    @ObservationIgnored private let now: () -> Date
    /// Ends a remote-playback identity before the persistent one changes.
    /// False keeps it, and the switch is refused.
    @ObservationIgnored private let endTemporaryIdentity: () async -> Bool
    /// How sign-out and removal copy names this device.
    @ObservationIgnored let device: SignOutConfirmationCopy.Device

    /// The accounts as the screens show them. Rebuilt after every change.
    private(set) var directory = SiloAccountDirectory.empty
    /// The index snapshot `directory` was built from; nil before migration.
    private(set) var snapshot: SiloAccountDirectorySnapshot?
    /// A chooser pick or sign-in start is running (`pickingOnce`).
    @ObservationIgnored private var isPicking = false
    /// Bumped each time an account is opened. App-wide, because the
    /// selected sign-in is: every window's `AppRouter.signInRevision` reads
    /// it.
    private(set) var signInRevision = 0

    func noteSignInChanged() {
        signInRevision &+= 1
    }

    init(
        auth: AuthService = .shared,
        now: @escaping () -> Date = { Date() },
        endTemporaryIdentity: (() async -> Bool)? = nil,
        device: SignOutConfirmationCopy.Device? = nil
    ) {
        self.auth = auth
        self.tokenStore = auth.tokenStore
        self.registry = auth.serverRegistry
        self.preferences = auth.launchPreferences
        self.now = now
        self.device = device ?? Self.currentDevice
        let tokenStore = auth.tokenStore
        self.endTemporaryIdentity = endTemporaryIdentity ?? {
            guard await tokenStore.hasTemporaryScope() else { return true }
            #if os(tvOS)
            return await RemotePlaybackIdentityManager.shared.end()
            #else
            return false
            #endif
        }
    }

    /// How sign-out and removal copy names this device.
    static var currentDevice: SignOutConfirmationCopy.Device {
        #if os(tvOS)
        return .appleTV
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
            ? SignOutConfirmationCopy.Device(noun: "iPad")
            : SignOutConfirmationCopy.Device(noun: "iPhone")
        #else
        return SignOutConfirmationCopy.Device(noun: "Mac")
        #endif
    }

    // MARK: - Directory

    /// Rebuilds `directory` from the accounts index, the saved servers, and
    /// this Apple TV user's launch state.
    func reloadDirectory() async {
        guard let snapshot = try? await tokenStore.directory() else {
            self.snapshot = nil
            directory = .empty
            return
        }
        self.snapshot = snapshot
        directory = SiloAccountDirectory(
            snapshot: snapshot,
            servers: registry.entries,
            state: preferences.state,
            currentAccountID: await tokenStore.currentAccount()
        )
    }

    /// "Signed in as alex", plus " · Home Silo" when the device has accounts
    /// on more than one server (spec §5.1). `fallbackUsername` names the
    /// account before sign-in migration, and before the server names it.
    func accountLine(fallbackUsername: String?) -> String? {
        guard let account = directory.currentAccount else {
            return fallbackUsername.map { "Signed in as \($0)" }
        }
        let name = account.username ?? fallbackUsername ?? account.serverName
        guard directory.spansServers, account.username != nil || fallbackUsername != nil else {
            return "Signed in as \(name)"
        }
        return "Signed in as \(name) · \(account.serverName)"
    }

    // MARK: - Launch (spec §6.2, §6.3)

    /// The launch rules' decision for `trigger`. Nil before sign-in
    /// migration, or while the accounts index can't be read: the device then
    /// uses each server's own session, as before accounts existed.
    func resolve(_ trigger: SiloLaunchTrigger) async -> SiloLaunchDecision? {
        guard let snapshot = try? await tokenStore.directory() else { return nil }
        return SiloLaunchResolver.resolve(SiloLaunchInput(
            directory: snapshot,
            savedServerIDs: registry.sortedEntries.map(\.id),
            state: preferences.state,
            currentServerMirror: registry.activeServerMirror,
            trigger: trigger,
            now: now()
        ))
    }

    /// Cold launch, with the splash up: selects what the launch rules decide
    /// and returns the route to commit, without touching the router. Nil
    /// before sign-in migration (the caller uses each server's own session).
    func resolveLaunch() async -> RestoredSessionAuthResolver.LocalResolution? {
        await resolveLocally(.coldLaunch)
    }

    /// The current account, as if picked again, resolved the same way:
    /// server recovery's Try again, which must not ask for an account or
    /// move to another one. Nil before migration or with no current account.
    func resolveCurrentAccount() async -> RestoredSessionAuthResolver.LocalResolution? {
        guard let account = await tokenStore.currentAccount() else { return nil }
        return await resolveLocally(.accountPicked(account))
    }

    private func resolveLocally(_ trigger: SiloLaunchTrigger) async -> RestoredSessionAuthResolver.LocalResolution? {
        guard let decision = await resolve(trigger) else { return nil }
        let resolution: RestoredSessionAuthResolver.LocalResolution
        switch decision {
        case .serverSetup(let context):
            await selectNothing()
            resolution = .init(state: .needsServerSetup, restoredAccount: nil, signInContext: context)
        case .signInTarget(let context):
            await selectNothing()
            resolution = .init(state: .needsSignInTarget(context), restoredAccount: nil, signInContext: context)
        case .chooseAccount(let focus):
            await selectNothing()
            resolution = .init(state: .needsAccount(focus: focus), restoredAccount: nil)
        case .open(let account, _):
            preferences.link(account)
            await selectAtLaunch(account)
            if await tokenStore.hasUsableCredential() {
                let hasProfile = await auth.resolveActiveProfileForSession()
                resolution = .init(
                    state: hasProfile ? .authenticated : .needsProfile,
                    restoredAccount: await tokenStore.refreshAccountIdentity()
                )
            } else if case .signIn(let key) = account {
                resolution = .init(state: .needsLogin, restoredAccount: nil,
                                   signInContext: .signInAgain(key), loginNotice: .sessionExpired)
            } else {
                // A pending legacy account whose session can't be read: sign
                // in to its server again.
                await selectNone(serverID: account.serverID)
                resolution = .init(state: .needsLogin, restoredAccount: nil, signInContext: .addAccount)
            }
        case .signInAgain(let key):
            preferences.link(.signIn(key))
            await selectAtLaunch(.signIn(key))
            resolution = .init(state: .needsLogin, restoredAccount: nil,
                               signInContext: .signInAgain(key), loginNotice: .sessionExpired)
        }
        await reloadDirectory()
        return resolution
    }

    /// Selects an account while the splash is up: through the registry when
    /// the server changes, so every mirror and cache follows it.
    private func selectAtLaunch(_ account: SiloAccountRef) async {
        if registry.activeServerId == account.serverID {
            await tokenStore.select(serverID: account.serverID, credential: account.credential)
        } else if !(await registry.switchTo(serverId: account.serverID, credential: account.credential)) {
            // The switch could not be saved; the credential still follows
            // the active server so nothing is sent to the wrong one.
            await selectNone(serverID: registry.activeServerId ?? "")
        }
    }

    /// No credential while a chooser, the server step, or setup shows: the
    /// active server stays, and so does nothing else (plan §2.4).
    private func selectNothing() async {
        let serverID = registry.activeServerId ?? ""
        if await tokenStore.currentSelection() != .none, !serverID.isEmpty,
           await registry.switchTo(serverId: serverID, credential: .none) {
            return
        }
        await selectNone(serverID: serverID)
    }

    /// Nothing selected on `serverID`, and no profile either: with no
    /// account mirror, local stores read data from before sign-ins existed,
    /// so a profile left set would show the legacy owner's data with nobody
    /// signed in.
    private func selectNone(serverID: String) async {
        await tokenStore.select(serverID: serverID, credential: .none)
        _ = await tokenStore.deactivateProfile(expectedAccount: nil)
    }

    /// Applies a launch decision interactively. `pushes` puts the chooser on
    /// the current navigation stack instead of making it the root.
    func apply(_ decision: SiloLaunchDecision, router: AppRouter, pushes: Bool = false) async {
        switch decision {
        case .serverSetup(let context):
            await selectNothing()
            router.signInReturnPoint = nil
            router.resetToServerSetup(context: context)
        case .signInTarget(let context):
            // Saved servers and no account, even just one server: "Sign in
            // to…" with Add a New Server (spec §5.4).
            router.signInReturnPoint = nil
            await selectNothing()
            router.showSignInTarget(context)
        case .chooseAccount(let focus):
            if pushes {
                router.navigate(to: .chooseAccount(focus: focus))
            } else {
                await selectNothing()
                router.showAccountChooser(focus: focus)
            }
        case .open(let account, _):
            await open(account, router: router)
        case .signInAgain(let key):
            preferences.link(.signIn(key))
            await beginSignIn(serverID: key.serverID, context: .signInAgain(key),
                              router: router, notice: .sessionExpired)
        }
        await reloadDirectory()
    }

    /// A return from the background while Who's Watching shows (spec §6.3).
    /// No profile is open, so nothing needs retiring, but when Profile
    /// Selection requires a selection and Ask For is Account + Profile on a
    /// device with two or more accounts, Choose an Account shows first, with
    /// focus on the linked account. Otherwise the away interval ends here.
    /// After Choose an Account it lasts until a profile is picked, so the
    /// account opened next shows Who's Watching rather than reopening its
    /// remembered profile, as after a return with a profile open.
    func applyAskForOnReturnToProfileSelection(router: AppRouter) async {
        guard router.authState == .needsProfile else { return }
        guard preferences.requiresSelectionAfterBackground(at: now()),
              case .chooseAccount(let focus)? = await resolve(.foregroundAfterAway),
              router.authState == .needsProfile,
              !(await tokenStore.hasTemporaryScope()) else {
            preferences.clearBackgroundedAt()
            return
        }
        await apply(.chooseAccount(focus: focus), router: router)
    }

    /// Opens an account: links it, switches to its server and credential
    /// (restoring the remembered profile), validates it with the server, and
    /// resets the router. Picked from the Paired Silo Profile chooser, it
    /// restores no profile and ends on Who's Watching, as Switch Profile
    /// does.
    private func open(_ account: SiloAccountRef, router: AppRouter) async {
        guard await endTemporaryIdentity() else {
            router.accountActionError = "Couldn't end remote playback. Try again."
            return
        }
        let picksPairedProfile = choosesPairedProfile(router)
        guard await registry.switchTo(serverId: account.serverID, credential: account.credential,
                                      resolveDestinationProfile: !picksPairedProfile) else {
            // Nothing opened, so this Apple TV user's link stays as it was.
            router.accountActionError = "Couldn't open that account. Try again."
            return
        }
        if picksPairedProfile {
            router.pairedProfileChooserDepth = nil
            // Saved like Switch Profile's request, so a relaunch on Who's
            // Watching asks too instead of restoring under Automatic.
            _ = await auth.beginExplicitProfileSelection()
        }
        preferences.link(account)
        guard await tokenStore.hasUsableCredential() else {
            // Expired without anyone noticing (plan G11): its sign-in screen.
            await showSignInAfterFailedOpen(account, router: router)
            return
        }
        let local: AppRouter.AuthState = auth.profileId == nil ? .needsProfile : .authenticated
        var state = local
        if let expected = await tokenStore.refreshAccountIdentity() {
            switch await auth.validateRestoredSession(expected: expected) {
            case .identityChanged:
                // Another switch or sign-out took over while this checked;
                // that one routes.
                return
            case .valid, .indeterminate:
                state = auth.profileId == nil ? .needsProfile : local
            case .needsLogin:
                // The server rejected the session while opening it.
                await showSignInAfterFailedOpen(account, router: router)
                return
            case .serverRecovery(let reason):
                state = .serverRecovery(reason)
            }
        }
        // The account line and menus of the screen about to show name this
        // account, not the one before.
        await reloadDirectory()
        router.signInReturnPoint = nil
        router.resetAfterServerResolution(to: state)
        router.noteSignInChanged()
    }

    private func showSignInAfterFailedOpen(_ account: SiloAccountRef, router: AppRouter) async {
        if case .signIn(let key) = account {
            router.showSignIn(context: .signInAgain(key), notice: .sessionExpired)
        } else {
            await selectNone(serverID: account.serverID)
            router.showSignIn(context: .addAccount, notice: .sessionExpired)
        }
        router.noteSignInChanged()
    }

    /// Choose an Account picked `account` (spec §5.2): opens it, or its
    /// sign-in screen when it expired.
    func openAccount(_ account: SiloAccountRef, router: AppRouter) async {
        await pickingOnce {
            guard let decision = await resolve(.accountPicked(account)) else { return }
            if case .chooseAccount = decision {
                // Removed while its card showed: the chooser already on
                // screen redraws without it.
                await reloadDirectory()
                return
            }
            await apply(decision, router: router, pushes: true)
        }
    }

    /// Runs one chooser pick or sign-in start at a time. A second press
    /// while the first is still switching would push its screen twice, or
    /// record the half-finished first as where Cancel returns.
    private func pickingOnce(_ pick: () async -> Void) async {
        guard !isPicking else { return }
        isPicking = true
        defer { isPicking = false }
        await pick()
    }

    /// Re-opens the current account, as after picking it again: for screens
    /// that need the route re-evaluated (server recovery). Before migration,
    /// the active server's own session.
    func reopenCurrent(router: AppRouter) async {
        if let account = await tokenStore.currentAccount(),
           let decision = await resolve(.accountPicked(account)) {
            await apply(decision, router: router)
            return
        }
        if let decision = await resolve(.afterRemoval) {
            await apply(decision, router: router)
            return
        }
        router.resetAfterServerResolution(to: await legacyState())
    }

    /// Before migration: the active server's own session, as before
    /// accounts existed.
    private func legacyState() async -> AppRouter.AuthState {
        guard let serverID = registry.activeServerId else { return .needsServerSetup }
        if await tokenStore.currentSelection() != .legacy(serverID: serverID) {
            await tokenStore.select(serverID: serverID, credential: .legacy(serverID: serverID))
        }
        guard await tokenStore.hasUsableCredential() else { return .needsLogin }
        return await auth.resolveActiveProfileForSession() ? .authenticated : .needsProfile
    }

    /// The launch rules after a sign-out or removal (spec §6.2): another
    /// account, the chooser, or the server step. For removals made elsewhere
    /// (server recovery), first drops this Apple TV user's link to an
    /// account that is gone.
    func routeAfterRemoval(router: AppRouter) async {
        await pruneLaunchState()
        await reloadDirectory()
        await applyAfterRemoval(router: router)
    }

    private func applyAfterRemoval(router: AppRouter) async {
        if let decision = await resolve(.afterRemoval) {
            await apply(decision, router: router)
            return
        }
        router.signInReturnPoint = nil
        router.resetAfterServerResolution(to: await legacyState())
    }

    // MARK: - Switching

    /// Switch Account (spec §5.1): Choose an Account with focus on the
    /// current account, on top of what is showing. From Settings › Paired
    /// Silo Profile it first runs explicit profile selection, as Switch
    /// Profile does.
    func beginSwitchAccount(router: AppRouter, deactivatingProfile: Bool = false) async {
        router.pairedProfileChooserDepth = nil
        await reloadDirectory()
        let focus = directory.currentAccountID ?? directory.linkedAccount?.id
        if deactivatingProfile {
            guard await beginExplicitProfileSelection() else {
                router.accountActionError = "Couldn't switch account. Try again."
                return
            }
            router.showProfileSelection()
            router.navigate(to: .chooseAccount(focus: focus))
            router.pairedProfileChooserDepth = router.path.count
            return
        }
        switch router.authState {
        case .needsAccount:
            return
        case .needsProfile, .authenticated, .needsLogin, .needsSignInTarget, .serverRecovery:
            router.navigate(to: .chooseAccount(focus: focus))
        case .loading, .needsServerSetup:
            await selectNothing()
            router.showAccountChooser(focus: focus)
        }
    }

    /// Settings › Paired Silo Profile: with two or more accounts, changing
    /// it goes through Choose an Account (spec §5.7), and the account picked
    /// ends on its Who's Watching, even under Automatic; otherwise it is
    /// Switch Profile, as before.
    func changePairedProfile(router: AppRouter) async {
        await reloadDirectory()
        if directory.accounts.count >= 2 {
            await beginSwitchAccount(router: router, deactivatingProfile: true)
        } else {
            router.switchProfile()
        }
    }

    private func beginExplicitProfileSelection() async -> Bool {
        if await auth.beginExplicitProfileSelection() { return true }
        guard await endTemporaryIdentity() else { return false }
        return await auth.beginExplicitProfileSelection()
    }

    /// Whether a pick now comes from the Paired Silo Profile chooser: it
    /// still shows on Who's Watching. Once the person goes back past it,
    /// the next pick is ordinary.
    private func choosesPairedProfile(_ router: AppRouter) -> Bool {
        guard let depth = router.pairedProfileChooserDepth else { return false }
        guard router.authState == .needsProfile, router.path.count >= depth else {
            router.pairedProfileChooserDepth = nil
            return false
        }
        return true
    }

    // MARK: - Sign-in flows (spec §5.4, §5.5)

    /// Starts Add Account or a first sign-in: remembers where Cancel
    /// returns, then shows the server step. The server step never sits on a
    /// stack keyed by the active server (Who's Watching, Home): adding a
    /// server makes it active before its sign-in, which would rebuild that
    /// stack under the setup screen. It becomes the root there, with Cancel
    /// going back.
    func startSignIn(_ context: SignInContext, router: AppRouter) async {
        await pickingOnce { await showServerStep(context, router: router) }
    }

    private func showServerStep(_ context: SignInContext, router: AppRouter) async {
        router.signInReturnPoint = await returnPoint(router)
        router.signInContext = context
        let step = SignInTargetList.step(for: context, in: registry.sortedEntries.map(\.id))
        if case .signIn(let serverID) = step {
            await beginSignIn(serverID: serverID, context: context, router: router)
            return
        }
        let staysOnStack: Bool
        switch router.authState {
        case .needsAccount, .needsSignInTarget:
            staysOnStack = true
        default:
            staysOnStack = false
        }
        switch step {
        case .serverSetup:
            if staysOnStack {
                router.navigate(to: .serverSetup)
            } else {
                router.resetToServerSetup(context: context)
            }
        case .list:
            if staysOnStack {
                router.navigate(to: .signInTarget(context))
            } else {
                router.showSignInTarget(context)
            }
        case .signIn:
            break
        }
    }

    /// Add Account from anywhere: a new sign-in, which refreshes the
    /// account instead when it is already saved.
    func startAddAccount(router: AppRouter) async {
        let snapshot = try? await tokenStore.directory()
        await startSignIn(snapshot?.accounts.isEmpty == false ? .addAccount : .firstRun, router: router)
    }

    /// Add Account on a server that isn't saved yet (a TV approval link
    /// naming a new server): server setup, which the caller prefills.
    func startAddAccountOnNewServer(router: AppRouter) async {
        await pickingOnce {
            let snapshot = try? await tokenStore.directory()
            let context: SignInContext = snapshot?.accounts.isEmpty == false ? .addAccount : .firstRun
            router.signInReturnPoint = await returnPoint(router)
            router.signInContext = context
            router.resetToServerSetup(context: context)
        }
    }

    /// "Sign in to…" picked `serverID`, or the server step has nothing to
    /// pick: makes the server active with nothing selected (Sign in again
    /// keeps the expired sign-in selected) and shows its sign-in screen.
    @discardableResult
    func beginSignIn(
        serverID: String,
        context: SignInContext,
        router: AppRouter,
        notice: AppRouter.LoginNotice? = nil
    ) async -> Bool {
        guard await endTemporaryIdentity() else {
            router.accountActionError = "Couldn't end remote playback. Try again."
            return false
        }
        var credential = CredentialSelection.none
        if case .signInAgain(let key) = context, key.serverID == serverID {
            credential = .signIn(key)
        }
        if registry.activeServerId == serverID, credential == .none,
           await tokenStore.currentSelection() == .none {
            await selectNone(serverID: serverID)
        } else if !(await registry.switchTo(serverId: serverID, credential: credential)) {
            router.accountActionError = "Couldn't switch to that server. Try again."
            return false
        }
        router.showSignIn(context: context, notice: notice)
        return true
    }

    /// A server named from outside the account screens (a TV approval
    /// link): the account the launch rules give that server opens, an
    /// expired one asks to sign in again, a server with several accounts and
    /// none of them current or linked shows Choose an Account, and a server
    /// with none starts Add Account there.
    @discardableResult
    func beginSignIn(forServer serverID: String, router: AppRouter) async -> Bool {
        guard let snapshot = try? await tokenStore.directory() else {
            // Before migration: the server's own session, as before.
            guard await registry.switchTo(serverId: serverID, credential: .legacy(serverID: serverID)) else {
                return false
            }
            router.resetAfterServerResolution(to: await legacyState())
            return true
        }
        let account = snapshot.index.launchAccount(
            onServer: serverID,
            current: await tokenStore.currentAccount(),
            linked: preferences.state.linkedAccountRef,
            hasLegacyHistory: false
        )
        guard let account else {
            if snapshot.accounts.contains(where: { $0.serverID == serverID }) {
                await beginSwitchAccount(router: router)
                return true
            }
            router.signInReturnPoint = await returnPoint(router)
            return await beginSignIn(serverID: serverID,
                                     context: snapshot.accounts.isEmpty ? .firstRun : .addAccount,
                                     router: router)
        }
        if case .signIn(let key) = account, !snapshot.isSignedIn(account) {
            return await beginSignIn(serverID: serverID, context: .signInAgain(key),
                                     router: router, notice: .sessionExpired)
        }
        await openAccount(account, router: router)
        return true
    }

    /// Back on the sign-in screen: the server step, or for Sign in again,
    /// Choose an Account.
    func leaveSignIn(router: AppRouter) async {
        let context = router.signInContext
        if case .signInAgain = context {
            await switchAccountFromSignIn(router: router)
            return
        }
        switch SignInTargetList.step(for: context, in: registry.sortedEntries.map(\.id)) {
        case .serverSetup, .signIn:
            router.resetToServerSetup(context: context)
        case .list:
            router.showSignInTarget(context)
        }
    }

    /// Switch Account on the sign-in screen (Sign in again).
    func switchAccountFromSignIn(router: AppRouter) async {
        var focus: SiloAccountRef?
        if case .signInAgain(let key) = router.signInContext { focus = .signIn(key) }
        await selectNothing()
        await reloadDirectory()
        router.showAccountChooser(focus: focus)
    }

    /// Cancel on a sign-in: back to the account, profile, and screen
    /// showing before the server step, or to the launch rules when the
    /// sign-in had nothing to return to.
    func cancelSignIn(router: AppRouter) async {
        let point = router.signInReturnPoint
        router.signInReturnPoint = nil
        router.signInContext = .firstRun
        guard let point else {
            await applyAfterRemoval(router: router)
            return
        }
        let serverID = point.serverID.flatMap { registry.entry(with: $0) == nil ? nil : $0 }
        var state = point.authState
        switch point.authState {
        case .authenticated, .needsProfile:
            // The profile that was open comes back as it was, whatever
            // Profile Selection says for a launch: the person never left it.
            let profileID = point.authState == .authenticated ? point.profileID : nil
            guard let serverID, point.credential != .none,
                  await registry.switchTo(serverId: serverID, credential: point.credential,
                                          resolveDestinationProfile: profileID == nil),
                  await tokenStore.hasUsableCredential() else {
                await applyAfterRemoval(router: router)
                return
            }
            if let profileID, !(await auth.reopenProfile(profileID)) {
                _ = await auth.resolveActiveProfileForSession()
            }
            state = auth.profileId == nil ? .needsProfile : point.authState
        case .needsAccount, .needsSignInTarget, .needsServerSetup:
            if let serverID {
                _ = await registry.switchTo(serverId: serverID, credential: .none)
            } else {
                await selectNothing()
            }
            if case .needsSignInTarget(let context) = point.authState { router.signInContext = context }
        case .loading, .needsLogin, .serverRecovery:
            await applyAfterRemoval(router: router)
            return
        }
        await reloadDirectory()
        router.resetAfterServerResolution(to: state)
        if state == point.authState {
            router.path = point.path
        }
        router.noteSignInChanged()
    }

    private func returnPoint(_ router: AppRouter) async -> SignInReturnPoint {
        SignInReturnPoint(
            serverID: registry.activeServerId,
            credential: await tokenStore.currentSelection(),
            authState: router.authState,
            path: router.path,
            profileID: router.authState == .authenticated ? auth.profileId : nil
        )
    }

    /// Every sign-in path ends here (plan §2.9): the sign-in is saved, as a
    /// new account or a refresh of the saved one, and opened.
    /// `routesWhenOpened: false` leaves the move to Who's Watching to the
    /// caller (the TV's code screen shows "Signed in as …" first). A sign-in
    /// that finishes after its screen was left (Switch Account or Cancel
    /// while it was in flight) is revoked and saved nowhere: the person
    /// chose something else, and saving it would add or change an account
    /// behind the screen now showing.
    @discardableResult
    func completeSignIn(
        _ pending: PendingSignIn,
        router: AppRouter,
        routesWhenOpened: Bool = true
    ) async throws -> SignInCompletion {
        guard router.authState == .needsLogin else {
            auth.discardSignIn(pending)
            throw CancellationError()
        }
        do {
            _ = try await tokenStore.directory()
        } catch SavedSignInAccessError.notMigrated {
            do {
                try await auth.commitLegacySignIn(pending)
            } catch {
                auth.discardSignIn(pending)
                throw error
            }
            finishOpened(router: router, routes: routesWhenOpened)
            return .opened(nil)
        } catch {
            auth.discardSignIn(pending)
            throw AccountSessionPersistenceError.unavailable
        }
        let result: SignInInstallResult
        do {
            result = try await auth.commitSignIn(pending)
        } catch {
            // Nothing kept the session; end it on the server.
            auth.discardSignIn(pending)
            throw error
        }
        preferences.link(.signIn(result.key))
        await reloadDirectory()
        finishOpened(router: router, routes: routesWhenOpened)
        return .opened(result.key)
    }

    private func finishOpened(router: AppRouter, routes: Bool) {
        router.signInReturnPoint = nil
        router.signInContext = .firstRun
        router.noteSignInChanged()
        guard routes else { return }
        showSignedIn(router: router)
    }

    /// Who's Watching for the sign-in just opened; a household with one
    /// profile and no PIN goes straight to Home.
    func showSignedIn(router: AppRouter) {
        router.skipsSingleProfilePicker = true
        router.showProfileSelection()
    }

    // MARK: - Phone pairing

    /// Phone pairing's commit (plan §2.13): adds the registry entry, then
    /// saves the paired session like any other sign-in, under one identity
    /// transition so nothing sees a server without its credential.
    func completePairing(_ pairing: ReceiverPairingCoordinator.PersistedPairing, router: AppRouter?) async -> Bool {
        let httpClient = auth.httpClient
        // The phone's approval already issued the session; a pairing that
        // stops before anything keeps it ends it on the server.
        func abandon() -> Bool {
            auth.revoke([RevocableCredential(serverURL: pairing.url, accessToken: pairing.accessToken,
                                             refreshToken: pairing.refreshToken)])
            return false
        }
        guard let lease = await httpClient.beginIdentityTransition() else { return abandon() }
        guard !Task.isCancelled else {
            await httpClient.endIdentityTransition(lease)
            return abandon()
        }
        await httpClient.cancelInFlightRequests()
        guard !Task.isCancelled else {
            await httpClient.endIdentityTransition(lease)
            return abandon()
        }
        let previousServerID = await tokenStore.getActiveServerId()
        let previousURL = await tokenStore.getServerUrl()
        let previousSelection = await tokenStore.currentSelection()
        let previousProfileID = await tokenStore.getProfileId()
        // A server already saved under a differently cased URL keeps that
        // entry's id and URL, which key its credentials and settings.
        let pairedID = ServerRegistry.serverId(for: pairing.url)
        let saved = registry.entry(matching: pairedID)
        let url = saved?.url ?? pairing.url
        let serverID = saved?.id ?? pairedID
        let entry = ServerEntry(id: serverID, url: url, fetchedName: pairing.fetchedName, profileId: nil,
                                lastUsedAt: Date(), verifiedServerId: pairing.verifiedServerId)
        guard registry.addOrUpdate(entry) != nil else {
            await httpClient.endIdentityTransition(lease)
            return abandon()
        }
        await tokenStore.setServerUrl(url)
        await selectNone(serverID: serverID)
        // The registry entry stays either way so the person can retry.
        func rollBack() async {
            await tokenStore.setServerUrl(previousURL)
            await tokenStore.select(serverID: previousServerID, credential: previousSelection)
            await tokenStore.setProfileId(previousProfileID)
            await httpClient.endIdentityTransition(lease)
        }
        guard let expected = await tokenStore.refreshAccountIdentity() else {
            await rollBack()
            return abandon()
        }
        let pending = PendingSignIn(accessToken: pairing.accessToken, refreshToken: pairing.refreshToken,
                                    account: SignInAccount(id: pairing.accountID, username: nil), expected: expected)
        var opened: SignInInstallResult?
        do {
            do {
                _ = try await tokenStore.directory()
                opened = try await auth.commitSignIn(pending, holding: lease)
            } catch SavedSignInAccessError.notMigrated {
                try await auth.commitLegacySignIn(pending, holding: lease)
            }
        } catch {
            auth.discardSignIn(pending)
            await rollBack()
            return false
        }
        let selection = await tokenStore.currentSelection()
        guard await registry.commitSwitchTo(serverId: serverID, credential: selection, holding: lease) else {
            // The sign-in is saved; only this switch failed. It opens from
            // Choose an Account later.
            await rollBack()
            return false
        }
        await httpClient.endIdentityTransition(lease)
        if let opened {
            preferences.link(.signIn(opened.key))
        }
        await registry.refreshFeaturesAfterGatedServerSwitch()
        await reloadDirectory()
        if let router {
            // Who's Watching for the paired sign-in, as setup from a phone
            // always went straight there.
            finishOpened(router: router, routes: true)
        }
        return true
    }

    // MARK: - Sign out and remove (spec §5.6)

    /// The confirmation for `target` (spec §5.6 copy).
    func confirmation(for target: RemovalRequest.Target) -> ConfirmationCopy {
        func names(_ account: SiloAccountRef?) -> (account: String, server: String) {
            if let account, let shown = directory.account(account) {
                return (shown.name, shown.serverName)
            }
            let server = (account?.serverID ?? registry.activeServerId)
                .flatMap { registry.entry(with: $0)?.displayName } ?? "this server"
            return ("your account", server)
        }
        switch target {
        case .currentAccount:
            let (account, server) = names(directory.currentAccountID)
            return SignOutConfirmationCopy.signOut(accountName: account, serverName: server, device: device,
                                                   offersRemove: directory.currentAccountID != nil)
        case .signOut(let ref):
            let (account, server) = names(ref)
            return SignOutConfirmationCopy.signOut(accountName: account, serverName: server, device: device)
        case .remove(let ref):
            let (account, server) = names(ref)
            return SignOutConfirmationCopy.removeAccount(accountName: account, serverName: server, device: device)
        }
    }

    /// Asks for the confirmation of `target` through the router's presenter.
    func requestRemoval(_ target: RemovalRequest.Target, router: AppRouter) async {
        await reloadDirectory()
        // Read from the selection, not the directory: before migration, or
        // while the index can't be read, the directory is empty but a
        // server's own session can still be signed out.
        router.removalRequest = RemovalRequest(target: target, copy: confirmation(for: target),
                                               account: await tokenStore.currentAccount())
    }

    /// Runs a confirmed sign-out or removal. `removingAccount` is Remove
    /// Account on the current account's sign-out confirmation.
    func perform(_ request: RemovalRequest, removingAccount: Bool, router: AppRouter) async {
        switch request.target {
        case .currentAccount:
            // Another window opened a different account while this asked.
            guard await tokenStore.currentAccount() == request.account else {
                router.accountActionError = "The account changed. Try signing out again."
                return
            }
            await signOutCurrent(alsoRemoveAccount: removingAccount, asksForAccountChoice: true, router: router)
        case .signOut(let account):
            await signOut(account, router: router)
        case .remove(let account):
            await removeAccount(account, router: router)
        }
    }

    /// Sign out on Who's Watching, in Settings, and in the menus: the
    /// current account (spec §5.6), whose card stays with Sign in again, or
    /// with `alsoRemoveAccount`, the account removed. Then the launch rules
    /// pick what opens (§6.2).
    func signOutCurrent(alsoRemoveAccount: Bool, asksForAccountChoice: Bool, router: AppRouter) async {
        guard await endTemporaryIdentity() else {
            router.accountActionError = "Couldn't end remote playback. Try signing out again."
            return
        }
        let serverID = registry.activeServerId
        if alsoRemoveAccount, let account = await tokenStore.currentAccount() {
            await removeAccount(account, router: router)
            return
        }
        let outcome = await auth.signOutWithOutcome()
        guard outcome != .refused else {
            router.accountActionError = "The active session changed. Try signing out again."
            return
        }
        #if !os(tvOS)
        // The provider still has the person signed in in the system
        // browser; the next browser sign-in asks it for an account choice.
        if asksForAccountChoice, let serverID {
            SelectAccountPrompt.shared.request(serverId: serverID)
        }
        #endif
        report(outcome, router: router)
        await pruneLaunchState()
        await applyAfterRemoval(router: router)
    }

    /// Sign out of one account, current or not; its card stays. The launch
    /// rules run only when it was the current one; otherwise the screen
    /// stays.
    func signOut(_ account: SiloAccountRef, router: AppRouter) async {
        let wasCurrent = await tokenStore.currentAccount() == account
        if wasCurrent {
            guard await endTemporaryIdentity() else {
                router.accountActionError = "Couldn't end remote playback. Try signing out again."
                return
            }
        }
        let outcome = await auth.removeSignIns(.signOut(account))
        guard outcome != .refused else {
            router.accountActionError = "The active session changed. Try signing out again."
            return
        }
        report(outcome, router: router)
        await pruneLaunchState()
        await reloadDirectory()
        if wasCurrent {
            await applyAfterRemoval(router: router)
        }
    }

    /// Remove an account from the device. The last account on a server goes
    /// with its server, through the registry's removal, which turns push off
    /// while the credential can still authenticate and puts the server back
    /// when its sign-ins can't be removed.
    /// Before migration the account is the server's own session, so the
    /// server goes with it, as forgetting a server always did. Returns
    /// whether the account is gone.
    @discardableResult
    func removeAccount(_ account: SiloAccountRef, router: AppRouter) async -> Bool {
        let wasCurrent = await tokenStore.currentAccount() == account
        if wasCurrent {
            guard await endTemporaryIdentity() else {
                router.accountActionError = "Couldn't end remote playback. Try again."
                return false
            }
        }
        let othersOnServer = (try? await tokenStore.directory())?
            .accounts.contains { $0.serverID == account.serverID && $0 != account }
        if othersOnServer != true {
            switch await removeLastAccount(account, router: router) {
            case .removed: return true
            case .failed: return false
            // Another account was added there meanwhile: only this one goes.
            case .othersOnServer: break
            }
        }
        let outcome = await auth.removeSignIns(.remove(account))
        guard outcome != .refused else {
            router.accountActionError = "The active session changed. Try again."
            return false
        }
        report(outcome, router: router)
        await pruneLaunchState()
        await reloadDirectory()
        if wasCurrent || directory.accounts.isEmpty {
            await applyAfterRemoval(router: router)
        }
        return outcome != .localOnly
    }

    /// Remove Account on server recovery: the current account, then the
    /// launch rules.
    @discardableResult
    func removeCurrentAccount(router: AppRouter) async -> Bool {
        if let account = await tokenStore.currentAccount() {
            return await removeAccount(account, router: router)
        }
        guard let serverID = registry.activeServerId else { return false }
        return await removeServer(serverID, router: router)
    }

    /// `account` and its server, while it is the server's only account.
    private func removeLastAccount(_ account: SiloAccountRef,
                                   router: AppRouter) async -> ServerRegistry.LastAccountRemoval {
        let wasCurrent = registry.activeServerId == account.serverID
        if wasCurrent {
            guard await endTemporaryIdentity() else {
                router.accountActionError = "Couldn't end remote playback. Try again."
                return .failed
            }
        }
        let outcome = await registry.removeLastAccount(account)
        if outcome == .failed {
            router.accountActionError = "Silo couldn't remove that account. Please try again."
        }
        guard outcome == .removed else { return outcome }
        await pruneLaunchState()
        await reloadDirectory()
        if wasCurrent || directory.accounts.isEmpty {
            await applyAfterRemoval(router: router)
        }
        return outcome
    }

    /// A server and every account on it.
    private func removeServer(_ serverID: String, router: AppRouter) async -> Bool {
        let wasCurrent = registry.activeServerId == serverID
        if wasCurrent {
            guard await endTemporaryIdentity() else {
                router.accountActionError = "Couldn't end remote playback. Try again."
                return false
            }
        }
        let removed = await registry.remove(serverId: serverID)
        if !removed {
            router.accountActionError = "Silo couldn't remove that account. Please try again."
        }
        await pruneLaunchState()
        await reloadDirectory()
        if removed, wasCurrent || directory.accounts.isEmpty {
            await applyAfterRemoval(router: router)
        }
        return removed
    }

    private func report(_ outcome: AuthService.SignOutOutcome, router: AppRouter) {
        switch outcome {
        case .completed, .refused:
            break
        case .diagnosticsCleanupFailed:
            router.accountActionError = "You're signed out, but Silo couldn't erase local diagnostics. Remove the account to retry cleanup."
        case .localOnly:
            router.accountActionError = "Silo couldn't clear the saved sign-in on this device. Please try signing out again."
        }
    }

    /// Drops this Apple TV user's link to an account that is gone. Nothing
    /// changes while the index can't be read.
    private func pruneLaunchState() async {
        guard let snapshot = try? await tokenStore.directory(),
              let linked = preferences.state.linkedAccountRef,
              snapshot.index.resolve(linked) == nil else { return }
        preferences.forgetAccount(linked)
    }

    // MARK: - Session events

    /// A refresh was rejected for the selected credential. A saved sign-in
    /// shows its sign-in screen with Switch Account (spec §6.2.3). A pending
    /// legacy account is removed (its record is already gone), and signing
    /// in adds it back as an account.
    func handleSessionExpired(router: AppRouter) async {
        let selection = await tokenStore.currentSelection()
        let snapshot = try? await tokenStore.directory()
        switch selection {
        case .signIn(let key) where snapshot != nil:
            await reloadDirectory()
            router.expiredSession(context: .signInAgain(key), hasActiveServer: registry.hasActiveServer)
            return
        case .legacy(let serverID) where snapshot != nil:
            _ = await tokenStore.removeLegacyServer(serverID)
            await pruneLaunchState()
            let remaining = try? await tokenStore.directory()
            // A switch made while this ran owns the selection now; this
            // expiry no longer describes what shows.
            guard registry.activeServerId == serverID, await tokenStore.currentSelection() == .none else {
                await reloadDirectory()
                return
            }
            await selectNone(serverID: serverID)
            await reloadDirectory()
            router.expiredSession(context: remaining?.accounts.isEmpty == false ? .addAccount : .firstRun,
                                  hasActiveServer: registry.hasActiveServer)
            return
        default:
            break
        }
        router.expiredSession(hasActiveServer: registry.hasActiveServer)
    }

    /// "Sign In Again" on an error screen: the current saved sign-in's
    /// sign-in screen, keeping the account so nobody else on the device is
    /// signed out. False when the current credential isn't a saved sign-in
    /// (before migration, a pending legacy account).
    func signInAgainForCurrentSession(router: AppRouter) async -> Bool {
        guard case .signIn(let key) = await tokenStore.currentSelection() else { return false }
        await reloadDirectory()
        router.expiredSession(context: .signInAgain(key), hasActiveServer: registry.hasActiveServer)
        return true
    }

    /// `.siloSignInMigrated`: a pending legacy account became a saved
    /// sign-in, or its account was already saved and it was dropped (plan
    /// §3.3). The first changes the account mirror from nil to the account,
    /// so downloads and the session's stores re-scope: their data moves to
    /// the account's keys, and a refresh begun under the old keys gives up.
    /// The second leaves nothing selected, so the launch rules run, unless
    /// `routes` is false (the launch under the splash re-resolves by itself).
    func handleSignInMigrated(_ outcome: BindOutcome, router: AppRouter, routes: Bool = true) async {
        switch outcome {
        case .legacyMigrated(let key):
            let epoch = await tokenStore.getOrCreateAccountEpoch(for: key.serverID)
            preferences.adoptLegacyEntries(for: key, accountEpoch: epoch, legacyOwnerAccountID: key.accountID)
            if preferences.state.linkedAccountRef == .pendingLegacy(serverID: key.serverID) {
                preferences.link(.signIn(key))
            }
            await reloadDirectory()
            router.noteSignInChanged()
            #if !os(tvOS)
            await DownloadManager.shared.onAppActive()
            #endif
        case .legacyDuplicate:
            await pruneLaunchState()
            await reloadDirectory()
            if routes { await applyAfterRemoval(router: router) }
        case .unchanged, .usernameUpdated:
            await reloadDirectory()
        }
    }
}
