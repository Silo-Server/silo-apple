import Foundation

/// One saved account: a server account on one server, with its sign-in.
/// Shared by every Apple TV user. Its own credential names it, so an
/// account has no separate ID.
enum SiloAccountRef: Hashable, Sendable {
    /// A saved sign-in (`SavedSignIn`).
    case signIn(SignInKey)
    /// A server session from before accounts existed whose server account
    /// isn't verified yet. It still signs in with the server's own session,
    /// and becomes `.signIn` on the first account read (plan §3.3).
    case pendingLegacy(serverID: String)

    var serverID: String {
        switch self {
        case .signIn(let key): return key.serverID
        case .pendingLegacy(let serverID): return serverID
        }
    }

    var credential: CredentialSelection {
        switch self {
        case .signIn(let key): return .signIn(key)
        case .pendingLegacy(let serverID): return .legacy(serverID: serverID)
        }
    }

    var signInKey: SignInKey? {
        guard case .signIn(let key) = self else { return nil }
        return key
    }

    init?(_ credential: CredentialSelection) {
        switch credential {
        case .none: return nil
        case .signIn(let key): self = .signIn(key)
        case .legacy(let serverID): self = .pendingLegacy(serverID: serverID)
        }
    }

    /// `ProfileLaunchState.linkedAccount`. The prefix names the case, and
    /// the rest is the server ID or the sign-in's storage key.
    var storageKey: String {
        switch self {
        case .signIn(let key): return "signIn:\(key.storageKey)"
        case .pendingLegacy(let serverID): return "legacy:\(serverID)"
        }
    }

    init?(storageKey: String) {
        if storageKey.hasPrefix("signIn:"),
           let key = SignInKey(storageKey: String(storageKey.dropFirst("signIn:".count))) {
            self = .signIn(key)
        } else if storageKey.hasPrefix("legacy:") {
            let serverID = String(storageKey.dropFirst("legacy:".count))
            guard SignInKey.isValidServerID(serverID) else { return nil }
            self = .pendingLegacy(serverID: serverID)
        } else {
            return nil
        }
    }
}

extension SiloAccountRef: Codable {
    private enum CodingKeys: String, CodingKey {
        case serverID, accountID
    }

    /// A sign-in stores its server and account; a pending legacy account
    /// only its server.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.accountID) {
            self = .signIn(try SignInKey(from: decoder))
            return
        }
        let serverID = try container.decode(String.self, forKey: .serverID)
        guard SignInKey.isValidServerID(serverID) else {
            throw DecodingError.dataCorruptedError(forKey: .serverID, in: container,
                                                   debugDescription: "Invalid server ID")
        }
        self = .pendingLegacy(serverID: serverID)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .signIn(let key):
            try container.encode(key.serverID, forKey: .serverID)
            try container.encode(key.accountID, forKey: .accountID)
        case .pendingLegacy(let serverID):
            try container.encode(serverID, forKey: .serverID)
        }
    }
}

/// Every account saved on the device. Stored in the user-independent
/// keychain under `SharedStorage.usersIndexAccount`. Once this item exists
/// the account model is authoritative; it is never deleted, so the old
/// per-server sign-ins can't come back.
struct SiloAccountIndex: Codable, Equatable, Sendable {
    static let currentVersion = 2

    var version: Int = SiloAccountIndex.currentVersion
    /// Display order is the order accounts were added. Each at most once,
    /// and at most one pending legacy account per server.
    var accounts: [SiloAccountRef] = []
    /// True when migration created the index from sessions saved before
    /// accounts existed. Nil on fresh installs.
    var migrated: Bool? = nil
    /// Server ID to the account that takes over that server's local data
    /// stored under the old server-and-profile keys.
    var legacyDataOwnerByServerID: [String: String]? = nil

    func contains(_ account: SiloAccountRef) -> Bool {
        accounts.contains(account)
    }

    func accounts(onServer serverID: String) -> [SiloAccountRef] {
        accounts.filter { $0.serverID == serverID }
    }

    /// The account that holds `serverID`'s session from before accounts
    /// existed: its pending legacy account, else the saved sign-in that took
    /// over the server's data.
    func legacyAccount(onServer serverID: String) -> SiloAccountRef? {
        resolve(.pendingLegacy(serverID: serverID))
    }

    /// The account work for `serverID` uses when nothing was chosen for it
    /// (plan §2.8): `current` or `linked` when on that server, else, for an
    /// Apple TV user who used Silo before accounts existed, the account that
    /// took over the server's session from then, else the server's only
    /// account. Shared by `TokenStore` and Top Shelf.
    func launchAccount(
        onServer serverID: String,
        current: SiloAccountRef?,
        linked: SiloAccountRef?,
        hasLegacyHistory: Bool
    ) -> SiloAccountRef? {
        func usable(_ account: SiloAccountRef?) -> SiloAccountRef? {
            guard let account = account.flatMap(resolve), account.serverID == serverID else { return nil }
            return account
        }
        if let account = usable(current) ?? usable(linked) { return account }
        if hasLegacyHistory, let owner = legacyAccount(onServer: serverID) {
            return owner
        }
        let onServer = accounts(onServer: serverID)
        return onServer.count == 1 ? onServer[0] : nil
    }

    /// The account a stored reference names now. A pending legacy account
    /// that was verified since names its sign-in: the account that took over
    /// the server's old data (`legacyDataOwnerByServerID`).
    func resolve(_ account: SiloAccountRef) -> SiloAccountRef? {
        if contains(account) { return account }
        guard case .pendingLegacy(let serverID) = account,
              let owner = legacyDataOwnerByServerID?[serverID],
              let key = SignInKey(serverID: serverID, accountID: owner),
              contains(.signIn(key)) else { return nil }
        return .signIn(key)
    }
}

extension SiloAccountIndex {
    /// The format test builds of the first multi-account design wrote:
    /// sign-ins grouped into users. Read only to convert it, one account
    /// per sign-in or pending server, in user order.
    struct Version1: Decodable {
        struct User: Decodable {
            var signIns: [SignInKey]
            var pendingLegacyServerIDs: [String]?
        }

        var users: [User]
        var migratedUserID: String?
        var legacyDataOwnerByServerID: [String: String]?
    }

    init(converting old: Version1) {
        var seen = Set<SiloAccountRef>()
        let accounts = old.users.flatMap { user in
            user.signIns.map(SiloAccountRef.signIn)
                + (user.pendingLegacyServerIDs ?? [])
                .filter(SignInKey.isValidServerID)
                .map { SiloAccountRef.pendingLegacy(serverID: $0) }
        }
        self.init(
            accounts: accounts.filter { seen.insert($0).inserted },
            migrated: old.migratedUserID == nil ? nil : true,
            legacyDataOwnerByServerID: old.legacyDataOwnerByServerID
        )
    }
}
