import Foundation

/// Finds the credential Top Shelf may use for this Apple TV user without the
/// app running (plan §2.12). Pure: every keychain read arrives as a value or
/// a closure, and nothing is ever written.
///
/// Before the accounts index exists, Top Shelf keeps reading the active
/// server's per-server slots as it always has. Afterwards it picks the
/// account with the app's launch rules (`SiloLaunchResolver`, plan §2.8),
/// and only when that account is on the active server. The app's runtime mirrors must agree, so nothing
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
    ///   - index: the accounts index, or nil when it was never written.
    ///   - savedServerIDs: the saved server list's IDs.
    ///   - state: this Apple TV user's launch state.
    ///   - activeServerID, activeAccountID, activeProfileID, serverURL: the
    ///     app's runtime mirrors for this Apple TV user.
    ///   - signIn: reads a saved sign-in; nil when missing or unreadable.
    ///   - proof: reads this Apple TV user's proof for a sign-in.
    ///   - legacyProof: reads this Apple TV user's `<serverID>.profileToken`.
    static func resolve(
        index: SiloAccountIndex?,
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

        guard let account = account(in: index, savedServerIDs: savedServerIDs, state: state,
                                    activeServerID: activeServerID),
              account.serverID == activeServerID, savedServerIDs.contains(activeServerID) else {
            return .unavailable
        }
        let serverID = activeServerID
        guard case .signIn(let key) = account else {
            return .legacy(serverID: serverID)
        }

        guard let saved = signIn(key), saved.isSignedIn,
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

    /// The linked account while it exists; else, for an Apple TV user who
    /// used Silo before accounts existed, the account that took over the
    /// active server's session from then; else the only account on a saved
    /// server, as the app's launch rules count them. "Used Silo before" means
    /// no account linked yet; `resolve` already requires the active-server
    /// mirror.
    private static func account(
        in index: SiloAccountIndex,
        savedServerIDs: Set<String>,
        state: ProfileLaunchState,
        activeServerID: String
    ) -> SiloAccountRef? {
        if let linked = state.linkedAccountRef.flatMap(index.resolve) {
            return linked
        }
        if state.linkedAccount == nil, let owner = index.legacyAccount(onServer: activeServerID) {
            return owner
        }
        let openable = index.accounts.filter { savedServerIDs.contains($0.serverID) }
        return openable.count == 1 ? openable.first : nil
    }

    /// `ServerRegistry.normalize(url:)`, which the extension doesn't compile.
    private static func normalize(_ url: String) -> String {
        var value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
