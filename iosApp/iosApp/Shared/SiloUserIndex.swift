import Foundation

/// A device-side group of sign-ins, created by its first sign-in. Shared by
/// every Apple TV user.
struct SiloUser: Codable, Equatable, Sendable, Identifiable {
    /// `UUID().uuidString`.
    let id: String
    let createdAt: Date
    /// Trimmed, 1...40 characters. Nil uses the default name, derived from
    /// the oldest sign-in.
    var displayName: String?
    /// At most one per server, oldest first (`SavedSignIn.addedAt`).
    var signIns: [SignInKey]
    /// Migrated user only: servers whose old per-server sign-in is still in
    /// use because the server hasn't verified its account yet.
    var pendingLegacyServerIDs: [String]?
}

/// Every Silo user on the device and which sign-ins belong to each. Stored
/// in the user-independent keychain under `SharedStorage.usersIndexAccount`.
/// Once this item exists the user model is authoritative; it is never
/// deleted, so the old per-server sign-ins can't come back.
struct SiloUserIndex: Codable, Equatable, Sendable {
    static let currentVersion = 1

    var version: Int = SiloUserIndex.currentVersion
    /// Display order is creation order.
    var users: [SiloUser] = []
    /// The user that migration created. Nil on fresh installs.
    var migratedUserID: String? = nil
    /// Server ID to the account that takes over that server's local data
    /// stored under the old server-and-profile keys.
    var legacyDataOwnerByServerID: [String: String]? = nil
}
