import Foundation

/// Finds the credential Top Shelf may use for this Apple TV user without the
/// app running (plan §2.12). Pure: every keychain read arrives as a value or
/// a closure, and nothing is ever written.
///
/// Before the user index exists, Top Shelf keeps reading the active server's
/// per-server slots as it always has. Afterwards it picks the user and server
/// with the app's launch rules (`SiloLaunchResolver`, plan §2.8), and that
/// user's sign-in there. The app's runtime mirrors must agree, so nothing
/// shows while the app is signed in somewhere else.
enum TopShelfCredentialResolver {
    struct SignInCredential: Equatable, Sendable {
        let key: SignInKey
        /// The address the tokens are bound to and the only one they go to.
        let origin: String
        let accessToken: String
        let refreshToken: String
        let accountEpoch: String
        let profileToken: String?
        /// The account that owns the server's data from before sign-ins
        /// existed, for the remembered-profile and pending-selection rules.
        let legacyOwnerAccountID: String?
    }

    enum Resolution: Equatable, Sendable {
        /// The per-server slots of this server, as before sign-ins existed.
        case legacy(serverID: String)
        case signIn(SignInCredential)
        /// No personalized content.
        case unavailable
    }

    /// - Parameters:
    ///   - index: `users.v1`, or nil when it was never written.
    ///   - savedServerIDs: the saved server list's IDs.
    ///   - state: this Apple TV user's launch state.
    ///   - activeServerID, activeAccountID, activeProfileID, serverURL: the
    ///     app's runtime mirrors for this Apple TV user.
    ///   - signIn: reads a saved sign-in; nil when missing or unreadable.
    ///   - proof: reads this Apple TV user's proof for a sign-in.
    ///   - legacyProof: reads this Apple TV user's `<serverID>.profileToken`.
    static func resolve(
        index: SiloUserIndex?,
        savedServerIDs: Set<String>,
        state: ProfileLaunchState,
        activeServerID: String?,
        activeAccountID: String?,
        activeProfileID: String?,
        serverURL: String?,
        signIn: (SignInKey) -> SavedSignIn?,
        proof: (SignInKey) -> SignInProfileProof?,
        legacyProof: (String) -> String?
    ) -> Resolution {
        guard let activeServerID, !activeServerID.isEmpty else { return .unavailable }
        guard let index else { return .legacy(serverID: activeServerID) }

        guard let user = user(in: index, state: state),
              let serverID = server(of: user, savedServerIDs: savedServerIDs,
                                    state: state, activeServerID: activeServerID),
              serverID == activeServerID else {
            return .unavailable
        }
        if user.pendingLegacyServerIDs?.contains(serverID) == true {
            return .legacy(serverID: serverID)
        }

        guard let key = user.signIns.first(where: { $0.serverID == serverID }),
              let saved = signIn(key), saved.userID == user.id, saved.isSignedIn,
              let accessToken = saved.accessToken, let refreshToken = saved.refreshToken,
              let epoch = saved.epoch else {
            return .unavailable
        }
        let origin = normalize(saved.origin)
        guard let serverURL, normalize(serverURL) == origin else { return .unavailable }
        let legacyOwner = index.legacyDataOwnerByServerID?[serverID]
        // A missing account mirror means the app hasn't run since the update;
        // only the sign-in that took over the server's old session matches it.
        if let activeAccountID {
            guard activeAccountID == key.accountID else { return .unavailable }
        } else if legacyOwner != key.accountID {
            return .unavailable
        }

        var profileToken: String?
        if let stored = proof(key) {
            if stored.profileID == nil || stored.profileID == activeProfileID {
                profileToken = stored.token
            }
        } else if legacyOwner == key.accountID {
            profileToken = legacyProof(serverID)
        }
        return .signIn(SignInCredential(
            key: key,
            origin: origin,
            accessToken: accessToken,
            refreshToken: refreshToken,
            accountEpoch: epoch.uuidString,
            profileToken: profileToken,
            legacyOwnerAccountID: legacyOwner
        ))
    }

    /// The linked user while it exists; else the migrated user for an Apple
    /// TV user who used Silo before users existed; else the only user.
    /// "Used Silo before" means remembered profiles or an active server from
    /// then, and no user opened since (every open records a last server).
    /// `resolve` already requires the active-server mirror, so only the
    /// last-server check is left.
    private static func user(in index: SiloUserIndex, state: ProfileLaunchState) -> SiloUser? {
        if let linked = state.linkedUserID, let user = index.users.first(where: { $0.id == linked }) {
            return user
        }
        let hasLegacyHistory = (state.lastServerByUserID ?? [:]).isEmpty
        if hasLegacyHistory, let migrated = index.migratedUserID,
           let user = index.users.first(where: { $0.id == migrated }) {
            return user
        }
        return index.users.count == 1 ? index.users.first : nil
    }

    /// The user's last server while the user can still open it; else, when
    /// none is recorded for the user yet, the server the app has active
    /// (plan §2.12: the migrated user's server from before users existed, or
    /// any user's while no last server is written); else the user's only
    /// server.
    private static func server(
        of user: SiloUser,
        savedServerIDs: Set<String>,
        state: ProfileLaunchState,
        activeServerID: String
    ) -> String? {
        let openable = Set(user.signIns.map(\.serverID) + (user.pendingLegacyServerIDs ?? []))
            .intersection(savedServerIDs)
        let last = state.lastServer(for: user.id)
        if let last, openable.contains(last) {
            return last
        }
        if last == nil, openable.contains(activeServerID) {
            return activeServerID
        }
        return openable.count == 1 ? openable.first : nil
    }

    /// `ServerRegistry.normalize(url:)`, which the extension doesn't compile.
    private static func normalize(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
