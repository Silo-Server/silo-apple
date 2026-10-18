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
    let userID: String?
    let authState: AppRouter.AuthState
    let path: NavigationPath
    /// The profile open on those screens, which Cancel opens again.
    var profileID: String? = nil
}

/// A question a finished sign-in raised (spec §5.4.1). The sign-in stays in
/// memory, unsaved, until the question is answered; Cancel revokes it.
struct SignInPrompt: Identifiable {
    let id = UUID()
    let kind: SignInPromptKind
    let copy: ConfirmationCopy
    let pending: PendingSignIn
}

/// A sign-out or removal waiting for its confirmation (spec §5.6).
struct RemovalRequest: Identifiable {
    enum Target: Equatable, Sendable {
        /// Sign out of the current sign-in. Its confirmation also offers Sign
        /// Out & Remove Server.
        case currentSignIn
        /// Sign Out of {server}: one sign-in, current or not.
        case signIn(SignInKey)
        /// Remove from This Apple TV: every sign-in in the user.
        case user(String)
        /// Remove a server and every user's sign-in on it.
        case server(String)
    }

    let id = UUID()
    let target: Target
    let copy: ConfirmationCopy
}

/// A user being renamed: the field starts with its current name.
struct UserRenameRequest: Identifiable, Equatable {
    /// The user's ID.
    let id: String
    let currentName: String
}

/// How a finished sign-in ended (`SiloUserCoordinator.completeSignIn`).
enum SignInCompletion: Equatable, Sendable {
    /// Saved and opened. Nil key: saved as the server's own session, before
    /// sign-in migration.
    case opened(SignInKey?)
    /// A question is showing; nothing is saved until it is answered.
    case prompted
}

/// Every Silo user flow (spec §5–§6, plan §2.10): launch and the choosers,
/// the sign-in flows with placement and their two questions, sign-out and
/// removal with the §6.2 fallback, rename, and the directory the screens
/// draw. Screens call it with their router; it never holds one.
@MainActor
@Observable
final class SiloUserCoordinator {
    static let shared = SiloUserCoordinator()

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

    /// The users as the screens show them. Rebuilt after every change.
    private(set) var directory = SiloUserDirectory.empty
    /// The index snapshot `directory` was built from; nil before migration.
    private(set) var snapshot: SiloUserDirectorySnapshot?
    /// A chooser pick or sign-in start is running (`pickingOnce`).
    @ObservationIgnored private var isPicking = false

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

    /// Rebuilds `directory` from the user index, the saved servers, and this
    /// Apple TV user's launch state.
    func reloadDirectory() async {
        guard let snapshot = try? await tokenStore.directory() else {
            self.snapshot = nil
            directory = .empty
            return
        }
        self.snapshot = snapshot
        let selection = await tokenStore.currentSelection()
        directory = SiloUserDirectory(
            snapshot: snapshot,
            servers: registry.entries,
            state: preferences.state,
            currentUserID: selection == .none ? nil : await tokenStore.currentUserID(),
            currentServerID: registry.activeServerId
        )
    }

    /// "Signed in as alex", plus " · Home Silo" when the user has more than
    /// one server (spec §5.1, plan G6). `fallbackUsername` names the account
    /// before sign-in migration.
    func accountLine(fallbackUsername: String?) -> String? {
        guard let user = directory.currentUser else {
            return fallbackUsername.map { "Signed in as \($0)" }
        }
        guard user.servers.count > 1,
              let server = directory.currentServerID.flatMap(user.server) else {
            return "Signed in as \(user.name)"
        }
        return "Signed in as \(user.name)\(SiloUserNaming.separator)\(server.name)"
    }

    // MARK: - Launch (spec §6.2, §6.3)

    /// The launch rules' decision for `trigger`. Nil before sign-in
    /// migration, or while the user index can't be read: the device then
    /// uses each server's own session, as before users existed.
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

    /// The current user's current server, as if picked again, resolved the
    /// same way: server recovery's Try again, which must not ask for a user
    /// or move to another one. Nil before migration or with no current user.
    func resolveCurrentServer() async -> RestoredSessionAuthResolver.LocalResolution? {
        guard let userID = await tokenStore.currentUserID(), let serverID = registry.activeServerId else { return nil }
        return await resolveLocally(.serverPicked(userID: userID, serverID: serverID))
    }

    private func resolveLocally(_ trigger: SiloLaunchTrigger) async -> RestoredSessionAuthResolver.LocalResolution? {
        guard let decision = await resolve(trigger) else { return nil }
        let resolution: RestoredSessionAuthResolver.LocalResolution
        switch decision {
        case .serverSetup(let context):
            await selectNothing(userID: nil)
            resolution = .init(state: .needsServerSetup, restoredAccount: nil, signInContext: context)
        case .signInTarget(let context):
            await selectNothing(userID: nil)
            resolution = .init(state: .needsSignInTarget(context), restoredAccount: nil, signInContext: context)
        case .chooseUser(let focus):
            await selectNothing(userID: nil)
            resolution = .init(state: .needsUser(focusUserID: focus), restoredAccount: nil)
        case .chooseServer(let userID, let focus):
            await selectNothing(userID: userID)
            resolution = .init(state: .needsServer(userID: userID, focusServerID: focus), restoredAccount: nil)
        case .open(let userID, let serverID, let credential, _):
            preferences.link(userID: userID)
            preferences.setLastServer(serverID, for: userID)
            await selectAtLaunch(serverID: serverID, credential: credential, userID: userID)
            if await tokenStore.hasUsableCredential() {
                let hasProfile = await auth.resolveActiveProfileForSession()
                resolution = .init(
                    state: hasProfile ? .authenticated : .needsProfile,
                    restoredAccount: await tokenStore.refreshAccountIdentity()
                )
            } else if case .signIn(let key) = credential {
                resolution = .init(state: .needsLogin, restoredAccount: nil,
                                   signInContext: .signInAgain(userID: userID, key: key), loginNotice: .sessionExpired)
            } else {
                // A pending legacy server whose session can't be read: sign
                // in to it again inside the same user.
                await selectNone(serverID: serverID, userID: userID)
                resolution = .init(state: .needsLogin, restoredAccount: nil,
                                   signInContext: .addServer(userID: userID))
            }
        case .signInAgain(let userID, let key):
            preferences.link(userID: userID)
            preferences.setLastServer(key.serverID, for: userID)
            await selectAtLaunch(serverID: key.serverID, credential: .signIn(key), userID: userID)
            resolution = .init(state: .needsLogin, restoredAccount: nil,
                               signInContext: .signInAgain(userID: userID, key: key), loginNotice: .sessionExpired)
        }
        await reloadDirectory()
        return resolution
    }

    /// Selects a credential while the splash is up: through the registry
    /// when the server changes, so every mirror and cache follows it.
    private func selectAtLaunch(serverID: String, credential: CredentialSelection, userID: String) async {
        if registry.activeServerId == serverID {
            await tokenStore.select(serverID: serverID, credential: credential, userID: userID)
        } else if !(await registry.switchTo(serverId: serverID, credential: credential, userID: userID)) {
            // The switch could not be saved; the credential still follows
            // the active server so nothing is sent to the wrong one.
            await selectNone(serverID: registry.activeServerId ?? "", userID: nil)
        }
    }

    /// No credential while a chooser, the server step, or setup shows: the
    /// active server stays, and so does nothing else (plan §2.4).
    private func selectNothing(userID: String?) async {
        let serverID = registry.activeServerId ?? ""
        if await tokenStore.currentSelection() != .none, !serverID.isEmpty,
           await registry.switchTo(serverId: serverID, credential: .none, userID: userID) {
            return
        }
        await selectNone(serverID: serverID, userID: userID)
    }

    /// Nothing selected on `serverID`, and no profile either: with no
    /// account mirror, local stores read data from before sign-ins existed,
    /// so a profile left set would show the legacy owner's data with nobody
    /// signed in.
    private func selectNone(serverID: String, userID: String?) async {
        await tokenStore.select(serverID: serverID, credential: .none, userID: userID)
        _ = await tokenStore.deactivateProfile(expectedAccount: nil)
    }

    /// Applies a launch decision interactively. `pushes` puts a chooser on
    /// the current navigation stack instead of making it the root.
    func apply(_ decision: SiloLaunchDecision, router: AppRouter, pushes: Bool = false) async {
        switch decision {
        case .serverSetup(let context):
            await selectNothing(userID: nil)
            router.signInReturnPoint = nil
            router.resetToServerSetup(context: context)
        case .signInTarget(let context):
            // Saved servers and no user, even just one server: "Sign in to…"
            // with Add a New Server (spec §5.4).
            router.signInReturnPoint = nil
            await selectNothing(userID: nil)
            router.showSignInTarget(context)
        case .chooseUser(let focus):
            if pushes {
                router.navigate(to: .chooseUser(focusUserID: focus))
            } else {
                await selectNothing(userID: nil)
                router.showUserChooser(focus: focus)
            }
        case .chooseServer(let userID, let focus):
            if pushes {
                router.navigate(to: .chooseServer(userID: userID, focusServerID: focus))
            } else {
                await selectNothing(userID: userID)
                router.showServerChooser(userID: userID, focus: focus)
            }
        case .open(let userID, let serverID, let credential, _):
            await open(userID: userID, serverID: serverID, credential: credential, router: router)
        case .signInAgain(let userID, let key):
            preferences.link(userID: userID)
            preferences.setLastServer(key.serverID, for: userID)
            await beginSignIn(serverID: key.serverID, context: .signInAgain(userID: userID, key: key),
                              router: router, notice: .sessionExpired)
        }
        await reloadDirectory()
    }

    /// A return from the background while Who's Watching shows (spec §6.3).
    /// No profile is open, so nothing needs retiring, but when Profile
    /// Selection requires a selection and Ask For is User + Profile on a
    /// device with two or more users, Choose a User shows first, with focus
    /// on the linked user. Otherwise the away interval ends here. After
    /// Choose a User it lasts until a profile is picked, so the user opened
    /// next shows Who's Watching rather than reopening its remembered
    /// profile, as after a return with a profile open.
    func applyAskForOnReturnToProfileSelection(router: AppRouter) async {
        guard router.authState == .needsProfile else { return }
        guard preferences.requiresSelectionAfterBackground(at: now()),
              case .chooseUser(let focus)? = await resolve(.foregroundAfterAway),
              router.authState == .needsProfile,
              !(await tokenStore.hasTemporaryScope()) else {
            preferences.clearBackgroundedAt()
            return
        }
        await apply(.chooseUser(focusUserID: focus), router: router)
    }

    /// Opens a user's server: links the user, records the server as its
    /// last, switches to the credential (restoring the remembered profile),
    /// validates it with the server, and resets the router.
    private func open(userID: String, serverID: String, credential: CredentialSelection, router: AppRouter) async {
        guard await endTemporaryIdentity() else {
            router.accountActionError = "Couldn't end remote playback. Try again."
            return
        }
        guard await registry.switchTo(serverId: serverID, credential: credential, userID: userID,
                                      resolveDestinationProfile: true) else {
            // Nothing opened, so this Apple TV user's link stays as it was.
            router.accountActionError = "Couldn't switch to that server. Try again."
            return
        }
        preferences.link(userID: userID)
        preferences.setLastServer(serverID, for: userID)
        guard await tokenStore.hasUsableCredential() else {
            // Expired without anyone noticing (plan G11): its sign-in screen.
            if case .signIn(let key) = credential {
                router.showSignIn(context: .signInAgain(userID: userID, key: key), notice: .sessionExpired)
            } else {
                await selectNone(serverID: serverID, userID: userID)
                router.showSignIn(context: .addServer(userID: userID))
            }
            router.noteSignInChanged()
            return
        }
        let local: AppRouter.AuthState = auth.profileId == nil ? .needsProfile : .authenticated
        var state = local
        if let expected = await tokenStore.refreshAccountIdentity() {
            switch await auth.validateRestoredSession(expected: expected) {
            case .valid, .indeterminate, .identityChanged:
                state = auth.profileId == nil ? .needsProfile : local
            case .needsLogin:
                // The server rejected the session while opening it.
                if case .signIn(let key) = credential {
                    router.showSignIn(context: .signInAgain(userID: userID, key: key), notice: .sessionExpired)
                } else {
                    router.showSignIn(context: .addServer(userID: userID), notice: .sessionExpired)
                }
                router.noteSignInChanged()
                return
            case .serverRecovery(let reason):
                state = .serverRecovery(reason)
            }
        }
        // The account line and menus of the screen about to show name this
        // user, not the one before.
        await reloadDirectory()
        router.signInReturnPoint = nil
        router.resetAfterServerResolution(to: state)
        router.noteSignInChanged()
    }

    /// Choose a User picked `userID` (spec §5.2): links it, then opens its
    /// only server or shows its servers with focus on the last one.
    func openUser(_ userID: String, router: AppRouter) async {
        await pickingOnce {
            preferences.link(userID: userID)
            guard let decision = await resolve(.userPicked(userID)) else { return }
            await apply(decision, router: router, pushes: true)
        }
    }

    /// Choose a Server picked `serverID` in `userID` (spec §5.3). Opening it
    /// links the user and makes it the user's last server.
    func openServer(_ serverID: String, userID: String, router: AppRouter) async {
        await pickingOnce {
            guard let decision = await resolve(.serverPicked(userID: userID, serverID: serverID)) else { return }
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

    /// Re-opens the current user and server, as after picking it again:
    /// for screens that need the route re-evaluated (server recovery, the
    /// device server list). Before migration, the active server's own
    /// session.
    func reopenCurrent(router: AppRouter) async {
        let userID = await tokenStore.currentUserID()
        if let userID, let serverID = registry.activeServerId,
           let decision = await resolve(.serverPicked(userID: userID, serverID: serverID)) {
            await apply(decision, router: router)
            return
        }
        if let decision = await resolve(.afterRemoval) {
            await apply(decision, router: router)
            return
        }
        router.resetAfterServerResolution(to: await legacyState())
    }

    /// Before migration: the active server's own session, as before users
    /// existed.
    private func legacyState() async -> AppRouter.AuthState {
        guard let serverID = registry.activeServerId else { return .needsServerSetup }
        if await tokenStore.currentSelection() != .legacy(serverID: serverID) {
            await tokenStore.select(serverID: serverID, credential: .legacy(serverID: serverID), userID: nil)
        }
        guard await tokenStore.hasUsableCredential() else { return .needsLogin }
        return await auth.resolveActiveProfileForSession() ? .authenticated : .needsProfile
    }

    /// The launch rules after a sign-out or removal (spec §6.2): another
    /// server in the same user, the chooser, or the server step. For removals
    /// made elsewhere (server recovery), first drops what this Apple TV user
    /// kept for users that are gone.
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

    /// Switch User (spec §5.1): Choose a User with focus on the current user,
    /// on top of what is showing. From Settings › Paired Silo Profile it
    /// first runs explicit profile selection, as Switch Profile does.
    func beginSwitchUser(router: AppRouter, deactivatingProfile: Bool = false) async {
        await reloadDirectory()
        let focus = directory.currentUserID ?? directory.linkedUserID
        if deactivatingProfile {
            guard await beginExplicitProfileSelection() else {
                router.accountActionError = "Couldn't switch user. Try again."
                return
            }
            router.showProfileSelection()
            router.navigate(to: .chooseUser(focusUserID: focus))
            return
        }
        switch router.authState {
        case .needsUser:
            return
        case .needsProfile, .authenticated, .needsLogin, .needsServer, .needsSignInTarget, .serverRecovery:
            router.navigate(to: .chooseUser(focusUserID: focus))
        case .loading, .needsServerSetup:
            await selectNothing(userID: nil)
            router.showUserChooser(focus: focus)
        }
    }

    /// Settings › Paired Silo Profile: with two or more users, changing it
    /// goes through the user chooser (spec §5.7); otherwise it is Switch
    /// Profile, as before.
    func changePairedProfile(router: AppRouter) async {
        await reloadDirectory()
        if directory.users.count >= 2 {
            await beginSwitchUser(router: router, deactivatingProfile: true)
        } else {
            router.switchProfile()
        }
    }

    private func beginExplicitProfileSelection() async -> Bool {
        if await auth.beginExplicitProfileSelection() { return true }
        guard await endTemporaryIdentity() else { return false }
        return await auth.beginExplicitProfileSelection()
    }

    /// Change server on Who's Watching, and Switch Server in the menus: this
    /// user's servers (spec §5.3, plan G12). Before migration, the device's
    /// server list, as before.
    func showServers(router: AppRouter) async {
        await reloadDirectory()
        guard let userID = directory.currentUserID else {
            router.navigate(to: .serverList)
            return
        }
        router.navigate(to: .chooseServer(userID: userID, focusServerID: directory.currentServerID))
    }

    // MARK: - Sign-in flows (spec §5.4, §5.4.1, §5.5)

    /// Starts Add User, Add Server, or a first sign-in: remembers where
    /// Cancel returns, then shows the server step. The server step never
    /// sits on a stack keyed by the active server (Who's Watching, Home):
    /// adding a server makes it active before its sign-in, which would
    /// rebuild that stack under the setup screen. It becomes the root there,
    /// with Cancel going back.
    func startSignIn(_ context: SignInContext, router: AppRouter) async {
        await pickingOnce { await showServerStep(context, router: router) }
    }

    private func showServerStep(_ context: SignInContext, router: AppRouter) async {
        router.signInReturnPoint = await returnPoint(router)
        router.signInContext = context
        let step: SignInServerStep
        if let snapshot = try? await tokenStore.directory() {
            step = SignInTargetList.step(for: context, in: registry.sortedEntries.map(\.id), directory: snapshot)
        } else {
            step = .serverSetup
        }
        if case .signIn(let serverID) = step {
            await beginSignIn(serverID: serverID, context: context, router: router)
            return
        }
        let staysOnStack: Bool
        switch router.authState {
        case .needsUser, .needsServer, .needsSignInTarget:
            staysOnStack = true
        default:
            staysOnStack = false
        }
        if !staysOnStack {
            router.showSignInTarget(context)
        }
        switch step {
        case .serverSetup:
            router.navigate(to: .serverSetup)
        case .list:
            if staysOnStack { router.navigate(to: .signInTarget(context)) }
        case .signIn:
            break
        }
    }

    /// Add User from anywhere: a new sign-in that creates a user, unless the
    /// account is already saved.
    func startAddUser(router: AppRouter) async {
        let snapshot = try? await tokenStore.directory()
        await startSignIn(snapshot?.users.isEmpty == false ? .addUser : .firstRun, router: router)
    }

    /// Add Server inside the current user; Add User when no user is current.
    func startAddServer(router: AppRouter) async {
        if let userID = await tokenStore.currentUserID(), await tokenStore.currentSelection() != .none {
            await startSignIn(.addServer(userID: userID), router: router)
        } else {
            await startAddUser(router: router)
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
        if case .signInAgain(_, let key) = context, key.serverID == serverID {
            credential = .signIn(key)
        }
        if registry.activeServerId == serverID, credential == .none,
           await tokenStore.currentSelection() == .none {
            await selectNone(serverID: serverID, userID: context.userID)
        } else if !(await registry.switchTo(serverId: serverID, credential: credential, userID: context.userID)) {
            router.accountActionError = "Couldn't switch to that server. Try again."
            return false
        }
        router.showSignIn(context: context, notice: notice)
        return true
    }

    /// A device-level server pick (Manage Servers, a TV approval link): the
    /// current user's sign-in there opens, an expired one asks to sign in
    /// again, and a server the user doesn't have starts Add Server for it.
    @discardableResult
    func beginSignIn(forServer serverID: String, router: AppRouter) async -> Bool {
        guard let snapshot = try? await tokenStore.directory() else {
            // Before migration: the server's own session, as before.
            guard await registry.switchTo(serverId: serverID, credential: .legacy(serverID: serverID),
                                          userID: nil) else { return false }
            router.resetAfterServerResolution(to: await legacyState())
            return true
        }
        let userID = await tokenStore.currentUserID() ?? preferences.state.linkedUserID
        guard let userID, let user = snapshot.user(withID: userID) else {
            router.signInReturnPoint = await returnPoint(router)
            return await beginSignIn(serverID: serverID, context: snapshot.users.isEmpty ? .firstRun : .addUser,
                                     router: router)
        }
        if let key = user.signIns.first(where: { $0.serverID == serverID }) {
            if snapshot.signIns[key]?.isSignedIn == true {
                await openServer(serverID, userID: userID, router: router)
                return true
            }
            return await beginSignIn(serverID: serverID, context: .signInAgain(userID: userID, key: key),
                                     router: router, notice: .sessionExpired)
        }
        if user.pendingLegacyServerIDs?.contains(serverID) == true {
            await openServer(serverID, userID: userID, router: router)
            return true
        }
        router.signInReturnPoint = await returnPoint(router)
        return await beginSignIn(serverID: serverID, context: .addServer(userID: userID), router: router)
    }

    /// Change server on the sign-in screen: back to the server step, or for
    /// Sign in again, the user's servers.
    func changeSignInServer(router: AppRouter) async {
        let context = router.signInContext
        if case .signInAgain(let userID, let key) = context {
            await selectNothing(userID: userID)
            router.showServerChooser(userID: userID, focus: key.serverID)
            return
        }
        guard let snapshot = try? await tokenStore.directory() else {
            router.resetToServerSetup()
            return
        }
        switch SignInTargetList.step(for: context, in: registry.sortedEntries.map(\.id), directory: snapshot) {
        case .serverSetup, .signIn:
            router.resetToServerSetup(context: context)
        case .list:
            router.showSignInTarget(context)
        }
    }

    /// Switch User on the sign-in screen (Sign in again).
    func switchUserFromSignIn(router: AppRouter) async {
        let focus = router.signInContext.userID
        await selectNothing(userID: nil)
        await reloadDirectory()
        router.showUserChooser(focus: focus)
    }

    /// Cancel on a sign-in, or on its question: back to the user, server,
    /// profile, and screen showing before the server step, or to the launch
    /// rules when the sign-in had nothing to return to.
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
                  await registry.switchTo(serverId: serverID, credential: point.credential, userID: point.userID,
                                          resolveDestinationProfile: profileID == nil),
                  await tokenStore.hasUsableCredential() else {
                await applyAfterRemoval(router: router)
                return
            }
            if let profileID, !(await auth.reopenProfile(profileID)) {
                _ = await auth.resolveActiveProfileForSession()
            }
            state = auth.profileId == nil ? .needsProfile : point.authState
        case .needsUser, .needsServer, .needsSignInTarget, .needsServerSetup:
            if let serverID {
                _ = await registry.switchTo(serverId: serverID, credential: .none, userID: point.userID)
            } else {
                await selectNothing(userID: point.userID)
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
            userID: await tokenStore.currentUserID(),
            authState: router.authState,
            path: router.path,
            profileID: router.authState == .authenticated ? auth.profileId : nil
        )
    }

    /// Every sign-in path ends here (plan §2.9): placement first, then the
    /// sign-in is saved and opened, or a question shows with the sign-in
    /// kept in memory. `routesWhenOpened: false` leaves the move to Who's
    /// Watching to the caller (the TV's code screen shows "Signed in as …"
    /// first). A sign-in that finishes after its screen was left (Change
    /// server, Switch User, or Cancel while it was in flight) is revoked and
    /// saved nowhere: the person chose something else, and placing it would
    /// add or change a user behind the screen now showing.
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
        let context = router.signInContext
        let snapshot: SiloUserDirectorySnapshot
        do {
            snapshot = try await tokenStore.directory()
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
        guard let decision = SignInPlacementPolicy.decide(
            context: context,
            serverID: pending.serverID,
            accountID: pending.account.id,
            username: pending.account.username,
            directory: snapshot
        ) else {
            auth.discardSignIn(pending)
            throw AccountSessionPersistenceError.invalidIdentity
        }
        switch decision {
        case .place(let placement):
            return .opened(try await commit(pending, placement: SignInPlacement(placement),
                                            router: router, routes: routesWhenOpened))
        case .switchToExisting(let key, _):
            return .opened(try await commit(pending, placement: .refresh(key), router: router,
                                            routes: routesWhenOpened))
        case .ask(let kind):
            await reloadDirectory()
            present(SignInPrompt(kind: kind, copy: promptCopy(kind, pending: pending), pending: pending), router: router)
            return .prompted
        }
    }

    /// Answers a sign-in's question (spec §5.4.1). Switch to {user} and Add
    /// {username} as a Separate User save the sign-in and open it; Cancel
    /// revokes the new session and goes back to before the server step.
    func answer(_ prompt: SignInPrompt, accept: Bool, router: AppRouter) async {
        // Answered once: a second tap finds the prompt gone.
        guard router.signInPrompt?.id == prompt.id else { return }
        router.signInPrompt = nil
        guard accept else {
            auth.discardSignIn(prompt.pending)
            await cancelSignIn(router: router)
            // Back on a sign-in screen (Sign in again has nowhere else to
            // go): the one that asked has finished, so it starts over.
            if router.authState == .needsLogin { router.restartSignInScreen() }
            return
        }
        do {
            _ = try await commit(prompt.pending, placement: SignInPlacement(prompt.kind.acceptedPlacement),
                                 router: router, routes: true)
        } catch {
            auth.discardSignIn(prompt.pending)
            router.accountActionError = "Silo couldn't save that sign-in. Please sign in again."
        }
    }

    /// Shows a sign-in's question. A question still unanswered from an
    /// earlier sign-in is dropped, and its session revoked.
    private func present(_ prompt: SignInPrompt, router: AppRouter) {
        if let earlier = router.signInPrompt {
            auth.discardSignIn(earlier.pending)
        }
        router.signInPrompt = prompt
    }

    private func commit(
        _ pending: PendingSignIn,
        placement: SignInPlacement,
        router: AppRouter,
        routes: Bool
    ) async throws -> SignInKey {
        let result: SignInInstallResult
        do {
            result = try await auth.commitSignIn(pending, placement: placement)
        } catch {
            // Nothing kept the session; end it on the server.
            auth.discardSignIn(pending)
            throw error
        }
        preferences.link(userID: result.userID)
        preferences.setLastServer(result.key.serverID, for: result.userID)
        await reloadDirectory()
        finishOpened(router: router, routes: routes)
        return result.key
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

    private func promptCopy(_ kind: SignInPromptKind, pending: PendingSignIn) -> ConfirmationCopy {
        let serverName = registry.entry(with: pending.serverID)?.displayName ?? pending.origin
        switch kind {
        case .separateUser(let existingUserID, let newUsername):
            return SignOutConfirmationCopy.separateUser(
                existingUserName: directory.user(existingUserID)?.name(besides: [serverName]) ?? SiloUserNaming.fallbackName,
                serverName: serverName,
                newUsername: newUsername
            )
        case .switchToUser(let userID, _):
            return SignOutConfirmationCopy.switchToUser(
                otherUserName: directory.user(userID)?.name(besides: [serverName]) ?? SiloUserNaming.fallbackName,
                serverName: serverName
            )
        }
    }

    // MARK: - Phone pairing

    /// Phone pairing's commit (plan §2.13): adds the registry entry, then
    /// places the paired session like any other sign-in, under one identity
    /// transition so nothing sees a server without its credential. A question
    /// (an account already in another user, or a second account on a
    /// server the user has) shows the sign-in screen behind it and needs
    /// `router`; without one the session is dropped. A later server in the
    /// same pairing joins the user this one opened.
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
        let previousUserID = await tokenStore.currentUserID()
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
        let context = await pairingContext(router: router)
        await tokenStore.setServerUrl(url)
        await selectNone(serverID: serverID, userID: context.userID)
        // The registry entry stays either way so the person can retry.
        func rollBack() async {
            await tokenStore.setServerUrl(previousURL)
            await tokenStore.select(serverID: previousServerID, credential: previousSelection, userID: previousUserID)
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
            let snapshot: SiloUserDirectorySnapshot?
            do {
                snapshot = try await tokenStore.directory()
            } catch SavedSignInAccessError.notMigrated {
                snapshot = nil
            }
            if let snapshot {
                guard let decision = SignInPlacementPolicy.decide(
                    context: context, serverID: serverID, accountID: pairing.accountID,
                    username: nil, directory: snapshot
                ) else { throw AccountSessionPersistenceError.invalidIdentity }
                let placement: SignInPlacement
                switch decision {
                case .place(let value):
                    placement = SignInPlacement(value)
                case .switchToExisting(let key, _):
                    placement = .refresh(key)
                case .ask(let kind):
                    guard let router,
                          await registry.commitSwitchTo(serverId: serverID, credential: .none,
                                                        userID: context.userID, holding: lease) else {
                        throw AccountSessionPersistenceError.invalidIdentity
                    }
                    await httpClient.endIdentityTransition(lease)
                    await registry.refreshFeaturesAfterGatedServerSwitch()
                    await reloadDirectory()
                    router.showSignIn(context: context)
                    present(SignInPrompt(kind: kind, copy: promptCopy(kind, pending: pending), pending: pending),
                            router: router)
                    return true
                }
                opened = try await auth.commitSignIn(pending, placement: placement, holding: lease)
            } else {
                try await auth.commitLegacySignIn(pending, holding: lease)
            }
        } catch {
            auth.discardSignIn(pending)
            await rollBack()
            return false
        }
        let selection = await tokenStore.currentSelection()
        let userID = await tokenStore.currentUserID()
        guard await registry.commitSwitchTo(serverId: serverID, credential: selection, userID: userID,
                                            holding: lease) else {
            // The sign-in is saved; only this switch failed. It opens from
            // Choose a Server later.
            await rollBack()
            return false
        }
        await httpClient.endIdentityTransition(lease)
        if let opened {
            preferences.link(userID: opened.userID)
            preferences.setLastServer(opened.key.serverID, for: opened.userID)
        }
        await registry.refreshFeaturesAfterGatedServerSwitch()
        await reloadDirectory()
        if let router {
            // Who's Watching for the paired sign-in, as setup from a phone
            // always went straight there. A later server in the same pairing
            // joins the user this one opened.
            finishOpened(router: router, routes: true)
            if let opened { router.signInContext = .addServer(userID: opened.userID) }
        }
        return true
    }

    /// The context a pairing places its session in: the sign-in that is
    /// running, else Add Server for the current user, else a new user.
    private func pairingContext(router: AppRouter?) async -> SignInContext {
        if let router { return router.signInContext }
        if let userID = await tokenStore.currentUserID() { return .addServer(userID: userID) }
        let snapshot = try? await tokenStore.directory()
        return snapshot?.users.isEmpty == false ? .addUser : .firstRun
    }

    // MARK: - Sign out and remove (spec §5.6)

    /// The confirmation for `target` (spec §5.6 copy). Every sentence names
    /// its servers, so user names leave out a server added to tell users
    /// apart when the sentence names it already.
    func confirmation(for target: RemovalRequest.Target) -> ConfirmationCopy {
        func serverName(_ serverID: String?) -> String {
            serverID.flatMap { registry.entry(with: $0)?.displayName } ?? "this server"
        }
        switch target {
        case .currentSignIn:
            let serverID = directory.currentServerID ?? registry.activeServerId
            let server = serverName(serverID)
            return namingOthersOnServer(SignOutConfirmationCopy.signOut(
                userName: directory.currentUser?.name(besides: [server]) ?? "your account",
                serverName: server,
                device: device
            ), serverID: serverID, serverName: server, besides: directory.currentUserID)
        case .signIn(let key):
            let owner = directory.users.first { $0.servers.contains { $0.key == key } }
            let server = serverName(key.serverID)
            return namingOthersOnServer(SignOutConfirmationCopy.signOut(
                userName: owner?.name(besides: [server]) ?? "your account",
                serverName: server,
                device: device
            ), serverID: key.serverID, serverName: server, besides: owner?.id)
        case .user(let userID):
            let user = directory.user(userID)
            let servers = user?.servers.map(\.name) ?? []
            return SignOutConfirmationCopy.removeUser(
                userName: user?.name(besides: servers) ?? SiloUserNaming.fallbackName,
                serverNames: servers,
                device: device
            )
        case .server(let serverID):
            let server = serverName(serverID)
            return SignOutConfirmationCopy.signOutAndRemoveServer(
                serverName: server,
                userNames: directory.users(onServer: serverID).map { $0.name(besides: [server]) },
                device: device
            )
        }
    }

    /// Sign Out & Remove Server signs every user out of the server, so the
    /// confirmation that offers it names the others (spec §5.6).
    private func namingOthersOnServer(_ copy: ConfirmationCopy, serverID: String?, serverName: String,
                                      besides userID: String?) -> ConfirmationCopy {
        guard let serverID, copy.additionalDestructiveTitle != nil else { return copy }
        let others = directory.users(onServer: serverID).filter { $0.id != userID }.map { $0.name(besides: [serverName]) }
        guard !others.isEmpty else { return copy }
        let names = others.count == 1
            ? others[0]
            : others.dropLast().joined(separator: ", ") + (others.count > 2 ? ", and " : " and ") + others[others.count - 1]
        return ConfirmationCopy(
            title: copy.title,
            message: copy.message + " \(SignOutConfirmationCopy.signOutAndRemoveServerTitle) also signs out \(names).",
            confirmTitle: copy.confirmTitle,
            confirmIsDestructive: copy.confirmIsDestructive,
            additionalDestructiveTitle: copy.additionalDestructiveTitle
        )
    }

    /// Asks for the confirmation of `target` through the router's presenter.
    func requestRemoval(_ target: RemovalRequest.Target, router: AppRouter) async {
        await reloadDirectory()
        router.removalRequest = RemovalRequest(target: target, copy: confirmation(for: target))
    }

    /// Runs a confirmed sign-out or removal. `removingServer` is Sign Out &
    /// Remove Server.
    func perform(_ request: RemovalRequest, removingServer: Bool, router: AppRouter) async {
        switch request.target {
        case .currentSignIn:
            await signOutCurrent(alsoRemoveServer: removingServer, asksForAccountChoice: true, router: router)
        case .signIn(let key):
            if removingServer {
                await removeServer(key.serverID, router: router)
            } else {
                await signOut(key, router: router)
            }
        case .user(let userID):
            await removeUser(userID, router: router)
        case .server(let serverID):
            await removeServer(serverID, router: router)
        }
    }

    /// Sign out on Who's Watching, in Settings, and in the menus: the current
    /// user's sign-in on the current server (spec §5.6), or with
    /// `alsoRemoveServer`, the server and everyone's sign-in on it. Then the
    /// launch rules pick what opens (§6.2).
    func signOutCurrent(alsoRemoveServer: Bool, asksForAccountChoice: Bool, router: AppRouter) async {
        guard await endTemporaryIdentity() else {
            router.accountActionError = "Couldn't end remote playback. Try signing out again."
            return
        }
        let serverID = registry.activeServerId
        if alsoRemoveServer, let serverID {
            await removeServer(serverID, router: router)
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

    /// Sign Out of {server}: one sign-in, current or not. The launch rules
    /// run only when it was the current one; otherwise the screen stays.
    func signOut(_ key: SignInKey, router: AppRouter) async {
        let wasCurrent = await tokenStore.currentSelection() == .signIn(key)
        if wasCurrent {
            guard await endTemporaryIdentity() else {
                router.accountActionError = "Couldn't end remote playback. Try signing out again."
                return
            }
        }
        let outcome = await auth.removeSignIns(.signIn(key))
        guard outcome != .refused else {
            router.accountActionError = "The active session changed. Try signing out again."
            return
        }
        report(outcome, router: router)
        await pruneLaunchState()
        await reloadDirectory()
        if wasCurrent || showsRemovedUser(router: router) {
            await applyAfterRemoval(router: router)
        }
    }

    /// Whether the root shows a user that no longer exists (its servers, at
    /// launch), which leaves nothing to pick.
    private func showsRemovedUser(router: AppRouter) -> Bool {
        guard case .needsServer(let shown, _) = router.authState else { return false }
        return directory.user(shown) == nil
    }

    /// Remove from This Apple TV: every sign-in in the user, and the user.
    func removeUser(_ userID: String, router: AppRouter) async {
        let wasCurrent = await tokenStore.currentUserID() == userID
        if wasCurrent {
            guard await endTemporaryIdentity() else {
                router.accountActionError = "Couldn't end remote playback. Try again."
                return
            }
        }
        let outcome = await auth.removeSignIns(.user(userID))
        guard outcome != .refused else {
            router.accountActionError = "The active session changed. Try again."
            return
        }
        report(outcome, router: router)
        await pruneLaunchState()
        await reloadDirectory()
        if wasCurrent || directory.users.isEmpty || showsRemovedUser(router: router) {
            await applyAfterRemoval(router: router)
        }
    }

    /// Sign Out & Remove Server, and removing a server from Manage Servers:
    /// the server and every user's sign-in on it. A user whose only server
    /// it was goes too.
    func removeServer(_ serverID: String, router: AppRouter) async {
        let wasCurrent = registry.activeServerId == serverID
        if wasCurrent {
            guard await endTemporaryIdentity() else {
                router.accountActionError = "Couldn't end remote playback. Try again."
                return
            }
        }
        let removed = await registry.remove(serverId: serverID)
        if !removed {
            router.accountActionError = "Silo couldn't remove the saved server. Please try again."
        }
        await pruneLaunchState()
        await reloadDirectory()
        if removed, wasCurrent || directory.users.isEmpty || showsRemovedUser(router: router) {
            await applyAfterRemoval(router: router)
        }
    }

    private func report(_ outcome: AuthService.SignOutOutcome, router: AppRouter) {
        switch outcome {
        case .completed, .refused:
            break
        case .diagnosticsCleanupFailed:
            router.accountActionError = "You're signed out, but Silo couldn't erase local diagnostics. Remove this server from the server list to retry cleanup."
        case .localOnly:
            router.accountActionError = "Silo couldn't clear the saved sign-in on this device. Please try signing out again."
        }
    }

    /// Drops this Apple TV user's link and last servers for users that are
    /// gone. Nothing changes while the index can't be read.
    private func pruneLaunchState() async {
        guard let snapshot = try? await tokenStore.directory() else { return }
        let userIDs = Set(snapshot.users.map(\.id))
        let state = preferences.state
        var gone = Set((state.lastServerByUserID ?? [:]).keys.filter { !userIDs.contains($0) })
        if let linked = state.linkedUserID, !userIDs.contains(linked) { gone.insert(linked) }
        for userID in gone {
            preferences.forgetUser(userID)
        }
    }

    // MARK: - Session events

    /// A refresh was rejected for the selected credential. A saved sign-in
    /// shows its sign-in screen with Change server and Switch User (spec
    /// §6.2.3). A pending legacy server is dropped from its user (its
    /// record is already gone) and signing in adds it back to that user.
    func handleSessionExpired(router: AppRouter) async {
        let selection = await tokenStore.currentSelection()
        let currentUserID = await tokenStore.currentUserID()
        let snapshot = try? await tokenStore.directory()
        switch selection {
        case .signIn(let key):
            if let userID = currentUserID ?? snapshot?.user(owning: key)?.id {
                await reloadDirectory()
                router.expiredSession(context: .signInAgain(userID: userID, key: key),
                                      hasActiveServer: registry.hasActiveServer)
                return
            }
        case .legacy(let serverID) where snapshot != nil:
            _ = await tokenStore.removeLegacyServer(serverID)
            await pruneLaunchState()
            let remaining = try? await tokenStore.directory()
            let context: SignInContext
            if let currentUserID, remaining?.user(withID: currentUserID) != nil {
                context = .addServer(userID: currentUserID)
            } else {
                context = remaining?.users.isEmpty == false ? .addUser : .firstRun
            }
            await selectNone(serverID: serverID, userID: context.userID)
            await reloadDirectory()
            router.expiredSession(context: context, hasActiveServer: registry.hasActiveServer)
            return
        default:
            break
        }
        router.expiredSession(hasActiveServer: registry.hasActiveServer)
    }

    /// "Sign In Again" on an error screen: the current saved sign-in's
    /// sign-in screen, keeping the sign-in so nobody else on the device is
    /// signed out. False when the current credential isn't a saved sign-in
    /// (before migration, a pending legacy server).
    func signInAgainForCurrentSession(router: AppRouter) async -> Bool {
        guard case .signIn(let key) = await tokenStore.currentSelection(),
              let userID = await tokenStore.currentUserID() else { return false }
        await reloadDirectory()
        router.expiredSession(context: .signInAgain(userID: userID, key: key),
                              hasActiveServer: registry.hasActiveServer)
        return true
    }

    /// `.siloSignInMigrated`: a pending legacy server became a saved
    /// sign-in, or its account was already saved and it was dropped (plan
    /// §3.3). The first changes the account mirror from nil to the account,
    /// so downloads re-scope. The second leaves nothing selected, so the
    /// launch rules run, unless `routes` is false (the launch under the
    /// splash re-resolves by itself).
    func handleSignInMigrated(_ outcome: BindOutcome, router: AppRouter, routes: Bool = true) async {
        switch outcome {
        case .legacyMigrated(let key):
            let epoch = await tokenStore.getOrCreateAccountEpoch(for: key.serverID)
            preferences.adoptLegacyEntries(for: key, accountEpoch: epoch, legacyOwnerAccountID: key.accountID)
            if let userID = await tokenStore.currentUserID() {
                preferences.setLastServer(key.serverID, for: userID)
            }
            await reloadDirectory()
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

    // MARK: - Rename (spec §5.2, §5.7)

    /// Renames a user on this device; an empty name restores the default.
    @discardableResult
    func renameUser(_ userID: String, to name: String?) async -> Bool {
        let renamed = await tokenStore.renameUser(userID, to: name)
        await reloadDirectory()
        return renamed
    }

    /// Asks for a new name through the router's presenter.
    func requestRename(_ userID: String, router: AppRouter) async {
        await reloadDirectory()
        guard let user = directory.user(userID) else { return }
        router.renameRequest = UserRenameRequest(id: userID, currentName: user.baseName)
    }
}
