import Foundation

/// What asks for a launch decision.
enum SiloLaunchTrigger: Equatable, Sendable {
    case coldLaunch
    /// Back in the foreground. Only Ask For can change what's showing.
    case foregroundAfterAway
    /// A sign-in, user, or server was just removed (spec §5.6).
    case afterRemoval
    /// A card picked in Choose a User.
    case userPicked(String)
    /// A row picked in Choose a Server.
    case serverPicked(userID: String, serverID: String)
}

/// Where Silo goes next for this Apple TV user (spec §6.2, §6.3).
enum SiloLaunchDecision: Equatable, Sendable {
    /// No saved servers: today's server setup (spec §5.4).
    case serverSetup(SignInContext)
    /// Saved servers but no user: "Sign in to…".
    case signInTarget(SignInContext)
    case chooseUser(focusUserID: String?)
    case chooseServer(userID: String, focusServerID: String?)
    /// Open the user's server. `linkUser` is true when this Apple TV user
    /// isn't linked to the user yet; opening a user links it.
    case open(userID: String, serverID: String, credential: CredentialSelection, linkUser: Bool)
    /// The user's sign-in on the server expired: its sign-in screen, with
    /// Change server and Switch User.
    case signInAgain(userID: String, key: SignInKey)
}

struct SiloLaunchInput: Equatable, Sendable {
    struct UserSnapshot: Equatable, Sendable {
        struct SignIn: Equatable, Sendable {
            let key: SignInKey
            let isSignedIn: Bool
        }

        let id: String
        /// Oldest first.
        var signIns: [SignIn]
        var pendingLegacyServerIDs: [String]
    }

    /// Index order.
    var users: [UserSnapshot]
    /// `ServerRegistry.sortedEntries` IDs. A sign-in on a server that isn't
    /// saved can't be opened, so launch ignores it.
    var savedServerIDs: [String]
    var migratedUserID: String?
    var state: ProfileLaunchState
    /// The `activeServerId` defaults mirror: the server this Apple TV user
    /// last had open, before Silo users existed or since.
    var currentServerMirror: String?
    var trigger: SiloLaunchTrigger
    var now: Date
}

extension SiloLaunchInput {
    init(
        directory: SiloUserDirectorySnapshot,
        savedServerIDs: [String],
        state: ProfileLaunchState,
        currentServerMirror: String?,
        trigger: SiloLaunchTrigger,
        now: Date
    ) {
        self.init(
            users: directory.users.map { UserSnapshot($0, signIns: directory.signIns) },
            savedServerIDs: savedServerIDs,
            migratedUserID: directory.migratedUserID,
            state: state,
            currentServerMirror: currentServerMirror,
            trigger: trigger,
            now: now
        )
    }
}

extension SiloLaunchInput.UserSnapshot {
    /// A key the index lists but whose item couldn't be read counts as
    /// expired, so opening it asks for sign-in instead of skipping the server.
    init(_ user: SiloUser, signIns: [SignInKey: SignInSummary]) {
        self.init(
            id: user.id,
            signIns: user.signIns.map { SignIn(key: $0, isSignedIn: signIns[$0]?.isSignedIn ?? false) },
            pendingLegacyServerIDs: user.pendingLegacyServerIDs ?? []
        )
    }
}

/// Picks the user, then the server, then the credential (spec §6.2), with
/// Ask For applied at launch (spec §6.3) and decision 16 for picked users.
/// Profile selection runs afterwards, keyed by the sign-in. No default user
/// or server is stored, so a removed one falls through to the next rule.
enum SiloLaunchResolver {
    static func resolve(_ input: SiloLaunchInput) -> SiloLaunchDecision {
        guard !input.users.isEmpty else {
            return input.savedServerIDs.isEmpty ? .serverSetup(.firstRun) : .signInTarget(.firstRun)
        }

        switch input.trigger {
        case .userPicked(let userID):
            // A user removed while its card was showing: choose again.
            guard let user = input.userSnapshot(userID) else { return .chooseUser(focusUserID: nil) }
            let servers = input.openableServerIDs(of: user)
            if servers.count == 1 {
                return input.credentialDecision(user: user, serverID: servers[0])
            }
            let last = input.state.lastServer(for: userID).flatMap { servers.contains($0) ? $0 : nil }
            return .chooseServer(userID: userID, focusServerID: last)

        case .serverPicked(let userID, let serverID):
            guard let user = input.userSnapshot(userID) else { return .chooseUser(focusUserID: nil) }
            guard input.openableServerIDs(of: user).contains(serverID) else {
                return .chooseServer(userID: userID, focusServerID: nil)
            }
            return input.credentialDecision(user: user, serverID: serverID)

        case .coldLaunch, .foregroundAfterAway, .afterRemoval:
            guard let user = input.launchUser() else { return .chooseUser(focusUserID: nil) }
            if input.asksForUser {
                return .chooseUser(focusUserID: user.id)
            }
            guard let serverID = input.launchServer(of: user) else {
                return .chooseServer(userID: user.id, focusServerID: nil)
            }
            return input.credentialDecision(user: user, serverID: serverID)
        }
    }
}

private extension SiloLaunchInput {
    func userSnapshot(_ id: String) -> UserSnapshot? {
        users.first { $0.id == id }
    }

    /// The user's saved servers: sign-ins oldest first, then pending legacy
    /// servers, each once.
    func openableServerIDs(of user: UserSnapshot) -> [String] {
        let saved = Set(savedServerIDs)
        var seen = Set<String>()
        return (user.signIns.map(\.key.serverID) + user.pendingLegacyServerIDs)
            .filter { saved.contains($0) && seen.insert($0).inserted }
    }

    /// Spec §6.2 step 1: the linked user; otherwise the migrated user for an
    /// Apple TV user who used Silo before users existed; otherwise the only
    /// user. Nil shows Choose a User.
    func launchUser() -> UserSnapshot? {
        if let linked = state.linkedUserID, let user = userSnapshot(linked) {
            return user
        }
        if trigger != .afterRemoval, hasLegacyHistory,
           let migratedUserID, let user = userSnapshot(migratedUserID) {
            return user
        }
        return users.count == 1 ? users[0] : nil
    }

    /// Remembered profiles or an active server from before users existed,
    /// and no user opened since: every open records a last server. Without
    /// the second check, an Apple TV user whose linked user was removed would
    /// land in the migrated user instead of choosing.
    var hasLegacyHistory: Bool {
        guard state.lastServerByUserID?.isEmpty ?? true else { return false }
        return !state.rememberedByServerID.isEmpty || currentServerMirror != nil
    }

    /// Spec §6.3: User + Profile shows Choose a User first when Profile
    /// Selection requires a selection at launch or on return, and the device
    /// has two or more users. Automatic never requires one. A pending
    /// explicit Switch Profile doesn't count: Switch Profile opens Who's
    /// Watching as it always has.
    var asksForUser: Bool {
        guard users.count >= 2, state.effectiveAskFor == .userAndProfile else { return false }
        switch trigger {
        case .coldLaunch:
            return state.requiresSelectionAtLaunch(at: now)
        case .foregroundAfterAway:
            return state.requiresSelectionAfterBackground(at: now)
        case .afterRemoval, .userPicked, .serverPicked:
            return false
        }
    }

    /// Spec §6.2 step 2: the user's last server while it's still in the user;
    /// otherwise the only server. Until this Apple TV user opens the migrated
    /// user, that user's last server is the active server from before users
    /// existed (spec §9). Nil shows Choose a Server.
    func launchServer(of user: UserSnapshot) -> String? {
        let servers = openableServerIDs(of: user)
        if let last = state.lastServer(for: user.id) {
            if servers.contains(last) { return last }
        } else if user.id == migratedUserID,
                  let currentServerMirror, servers.contains(currentServerMirror) {
            return currentServerMirror
        }
        return servers.count == 1 ? servers[0] : nil
    }

    /// Spec §6.2 step 3: an expired sign-in shows its sign-in screen. A
    /// pending legacy server opens its old per-server sign-in.
    func credentialDecision(user: UserSnapshot, serverID: String) -> SiloLaunchDecision {
        let linkUser = state.linkedUserID != user.id
        guard let signIn = user.signIns.first(where: { $0.key.serverID == serverID }) else {
            return .open(userID: user.id, serverID: serverID, credential: .legacy(serverID: serverID), linkUser: linkUser)
        }
        guard signIn.isSignedIn else {
            return .signInAgain(userID: user.id, key: signIn.key)
        }
        return .open(userID: user.id, serverID: serverID, credential: .signIn(signIn.key), linkUser: linkUser)
    }
}
