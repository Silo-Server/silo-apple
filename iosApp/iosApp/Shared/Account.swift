import Foundation

/// A profile as Silo last saw it in an account, cached so the profile picker
/// can draw it without reaching the server. Display only.
struct AccountProfile: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let name: String
    let avatarEmoji: String?
    let avatarImageUrl: String?
    let hasPin: Bool
    let isChild: Bool
}

/// One sign-in on one server. Shared by every Apple TV user and stored in the
/// user-independent keychain under `SharedStorage.accountRecordAccount`.
///
/// `localAccountId` keys everything stored on this device for the account. It
/// is made here when the account is saved and never changes, so no local data
/// is ever renamed. `serverUserId` is only an attribute: it finds the saved
/// account a new sign-in belongs to.
struct Account: Codable, Equatable, Sendable, Identifiable {
    static let currentVersion = 1

    let version: Int
    let localAccountId: String
    /// Registry server ID (`ServerRegistry.serverId(for:)`).
    let serverId: String
    /// Normalized server URL. The bearer is only ever sent here.
    let origin: String
    /// The server's user ID. Nil for a migrated session until the first
    /// verified `/api/v2/account/me` fills it in.
    var serverUserId: String?
    var username: String?
    var accessToken: String?
    var refreshToken: String?
    /// Changes on every sign-in. Durable work and remembered profiles are
    /// bound to it, so they never carry over to a later sign-in.
    var epoch: UUID?
    var cachedProfiles: [AccountProfile]
    let addedAt: Date
    var lastUsedAt: Date
    /// The server rejected the account's credentials. The account and its
    /// local data stay until the person signs in again or signs out.
    var needsSignIn: Bool

    var id: String { localAccountId }

    init(
        localAccountId: String = UUID().uuidString,
        serverId: String,
        origin: String,
        serverUserId: String? = nil,
        username: String? = nil,
        accessToken: String?,
        refreshToken: String?,
        epoch: UUID?,
        cachedProfiles: [AccountProfile] = [],
        addedAt: Date = Date(),
        lastUsedAt: Date = Date(),
        needsSignIn: Bool = false
    ) {
        self.version = Self.currentVersion
        self.localAccountId = localAccountId
        self.serverId = serverId
        self.origin = origin
        self.serverUserId = serverUserId
        self.username = username
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.epoch = epoch
        self.cachedProfiles = cachedProfiles
        self.addedAt = addedAt
        self.lastUsedAt = lastUsedAt
        self.needsSignIn = needsSignIn
    }

    /// Whether requests can authenticate as this account. A refresh token is
    /// not required: sessions from before refresh tokens carried only an
    /// access token, and still work until it expires.
    var isSignedIn: Bool {
        !needsSignIn && accessToken?.isEmpty == false && epoch != nil
    }

    /// The account's credentials, without the display fields that other
    /// writers update. Two records with the same credentials authenticate
    /// identically.
    var credentials: AccountCredentials {
        AccountCredentials(
            localAccountId: localAccountId,
            accessToken: accessToken,
            refreshToken: refreshToken,
            epoch: epoch,
            needsSignIn: needsSignIn
        )
    }

    /// Registry IDs are base64url without padding and local IDs are UUIDs, so
    /// a real pair never contains "." or "/" and keychain names built from
    /// them split back exactly.
    static func isValidServerId(_ serverId: String) -> Bool {
        !serverId.isEmpty && !serverId.contains(".") && !serverId.contains("/")
    }

    static func isValidLocalAccountId(_ localAccountId: String) -> Bool {
        UUID(uuidString: localAccountId) != nil
    }

    /// A record that breaks an invariant is corrupt, never a usable account.
    var isWellFormed: Bool {
        guard Self.isValidServerId(serverId), Self.isValidLocalAccountId(localAccountId),
              !origin.isEmpty, serverUserId?.isEmpty != true else { return false }
        return needsSignIn || isSignedIn
    }
}

struct AccountCredentials: Equatable, Sendable {
    let localAccountId: String
    let accessToken: String?
    let refreshToken: String?
    let epoch: UUID?
    let needsSignIn: Bool
}

/// The list of saved accounts, stored with a backup copy in the
/// user-independent keychain. Records it doesn't list are never read.
struct AccountIndex: Codable, Equatable, Sendable {
    struct Entry: Codable, Hashable, Sendable {
        let serverId: String
        let localAccountId: String
    }

    static let currentVersion = 1

    let version: Int
    var entries: [Entry]
    /// For each server, the account that adopted the server's local data from
    /// before accounts existed (downloads, preferences, caches, push,
    /// remembered profile). Written by migration; an entry goes when its
    /// account is signed out or its server removed.
    var legacyDataOwners: [String: String]
    /// Set once `AccountMigration` has moved every per-server session from
    /// before accounts into this index. From then on nothing reads those
    /// sessions. A sign-in can write the index first (a migration deferred by
    /// an unreadable keychain); migration then skips servers it already lists.
    var legacySessionsMigrated: Bool
    /// Servers whose credential slots from before accounts still need
    /// deleting. Nothing reads those slots once migration is done.
    var pendingLegacyCleanup: [String]
    /// Saved servers folded into another saved server that reported the same
    /// `verifiedServerId` (`ServerRegistry.mergeDuplicateServers`): each
    /// dropped registry ID and the ID that holds its accounts now. A
    /// selection or active server another Apple TV user left on a dropped
    /// ID, or a transfer an earlier process tagged with one, resolves
    /// through it. Absent in indexes from earlier builds.
    var mergedServerIds: [String: String]?
    /// Accounts such a merge removed in favour of another account of the same
    /// server user: each removed `localAccountId` and the one that holds its
    /// downloads now. A transfer an earlier process tagged with a removed
    /// account resolves through it. Absent in indexes from earlier builds.
    var mergedAccountIds: [String: String]?
    /// Records a server merge stopped listing and has yet to delete.
    var pendingRecordRemovals: [Entry]?

    init(
        entries: [Entry] = [],
        legacyDataOwners: [String: String] = [:],
        legacySessionsMigrated: Bool = false,
        pendingLegacyCleanup: [String] = []
    ) {
        self.version = Self.currentVersion
        self.entries = entries
        self.legacyDataOwners = legacyDataOwners
        self.legacySessionsMigrated = legacySessionsMigrated
        self.pendingLegacyCleanup = pendingLegacyCleanup
    }
}

/// The account this device user has selected, in `SharedStorage.activeAccountKey`.
/// Stored with its server so a server switch that has not yet picked an
/// account can never pair one server with another server's account.
struct AccountSelection: Codable, Equatable, Sendable {
    let serverId: String
    let localAccountId: String

    /// A selection left on a server that was merged into another names the
    /// server its account moved to, unless `resolvingMergedServers` is off.
    static func load(from defaults: SharedDefaults, resolvingMergedServers: Bool = true) -> AccountSelection? {
        guard let data = defaults.data(forKey: SharedStorage.activeAccountKey),
              let selection = try? JSONDecoder().decode(AccountSelection.self, from: data),
              Account.isValidServerId(selection.serverId),
              Account.isValidLocalAccountId(selection.localAccountId) else { return nil }
        guard resolvingMergedServers, let survivor = MergedServerIds.survivor(of: selection.serverId) else {
            return selection
        }
        return AccountSelection(serverId: survivor, localAccountId: selection.localAccountId)
    }
}

/// The server, account, and profile that local data belongs to. Profile IDs
/// repeat across accounts on one server, so stores key by all three.
struct AccountScope: Hashable, Sendable {
    let serverId: String
    let localAccountId: String
    /// Nil while no profile is selected (Who's Watching).
    let profileId: String?

    /// The current scope, read synchronously from the defaults mirrors that
    /// `ServerRegistry` and `TokenStore` write. For stores and extensions
    /// that can't await the token store. Nil while no account is selected
    /// on the active server.
    static var current: AccountScope? { current(defaults: .shared) }

    static func current(defaults: SharedDefaults) -> AccountScope? {
        guard let serverId = defaults.string(forKey: SharedStorage.activeServerIdKey),
              let selection = AccountSelection.load(from: defaults),
              selection.serverId == serverId else { return nil }
        let profileId = defaults.string(forKey: SharedStorage.profileIdKey)
        return AccountScope(
            serverId: serverId,
            localAccountId: selection.localAccountId,
            profileId: profileId?.isEmpty == false ? profileId : nil
        )
    }
}
