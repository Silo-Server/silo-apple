import Foundation
import Synchronization

/// The server, account, and profile that local data belongs to. Profile IDs
/// repeat across accounts on one server, so local stores key by all three.
struct AccountScope: Hashable, Sendable {
    let serverID: String
    let accountID: String
    let profileID: String
}

/// Synchronous access to the current scope, from the defaults mirrors that
/// `TokenStore` and `ServerRegistry` write. For stores that can't await the
/// actor.
enum AccountScopeReader {
    /// Nil unless the server, account, and profile mirrors are all set and
    /// the server and account IDs are valid sign-in key parts.
    static func current(defaults: SharedDefaults = .shared) -> AccountScope? {
        guard let serverID = defaults.string(forKey: SharedStorage.activeServerIdKey),
              SignInKey.isValidServerID(serverID),
              let accountID = currentAccountID(defaults: defaults),
              let profileID = defaults.string(forKey: SharedStorage.profileIdKey),
              !profileID.isEmpty else {
            return nil
        }
        return AccountScope(serverID: serverID, accountID: accountID, profileID: profileID)
    }

    /// The `activeAccountId` mirror. Nil while no saved sign-in is selected.
    static func currentAccountID(defaults: SharedDefaults = .shared) -> String? {
        guard let accountID = defaults.string(forKey: SharedStorage.activeAccountIdKey),
              SignInKey.isValidAccountID(accountID) else {
            return nil
        }
        return accountID
    }
}

/// Which account on each server takes over local data stored under the old
/// server-and-profile keys. A process-wide cache of
/// `SiloUserIndex.legacyDataOwnerByServerID`; `TokenStore` publishes it after
/// every index load or write.
enum LegacyLocalDataOwner {
    private static let owners = Mutex<[String: String]>([:])

    static func accountID(forServerID serverID: String) -> String? {
        owners.withLock { $0[serverID] }
    }

    static func publish(_ owners: [String: String]) {
        self.owners.withLock { $0 = owners }
    }
}
