import Foundation

/// The per-server session record from before accounts. Only
/// `AccountMigration` reads it; `AccountStore` holds sessions now.
struct CanonicalAccountSession: Codable, Equatable, Sendable {
    let version: Int
    let signedOut: Bool
    let origin: String?
    let accountID: String?
    let epoch: UUID?
    let accessToken: String?
    let refreshToken: String?
}

enum AccountSessionPersistenceError: Error {
    case invalidRecord
}

/// Reads and deletes the per-server session records from before accounts.
/// The adoption marker was written first, so once present, a missing record
/// means signed out and the raw per-token slots no longer count.
struct AccountSessionPersistence: Sendable {
    enum State { case legacy, signedOut, session(CanonicalAccountSession) }
    let read: @Sendable (String) throws -> String?
    let remove: @Sendable (String) -> Bool

    init(keychain: SharedKeychain) {
        let account = keychain.withAudience(.userIndependent)
        read = { try account.getChecked($0) }
        remove = { account.delete($0) }
    }

    init(read: @escaping @Sendable (String) throws -> String?,
         remove: @escaping @Sendable (String) -> Bool) {
        self.read = read; self.remove = remove
    }

    static func recordKey(_ serverID: String) -> String { SharedStorage.keychainAccountPrefix + "\(serverID).accountSession" }
    static func markerKey(_ serverID: String) -> String { SharedStorage.keychainAccountPrefix + "\(serverID).accountSessionAdopted" }

    func load(_ serverID: String) throws -> State {
        let adopted = try read(Self.markerKey(serverID))
        guard let raw = try read(Self.recordKey(serverID)) else {
            return adopted == nil ? .legacy : .signedOut
        }
        let value = try JSONDecoder().decode(CanonicalAccountSession.self, from: Data(raw.utf8))
        guard value.version == 1 else { throw AccountSessionPersistenceError.invalidRecord }
        if value.signedOut { return .signedOut }
        guard let origin = value.origin, !origin.isEmpty, value.epoch != nil,
              value.accessToken?.isEmpty == false, value.refreshToken?.isEmpty == false,
              value.accountID == nil || value.accountID?.isEmpty == false else {
            throw AccountSessionPersistenceError.invalidRecord
        }
        return .session(value)
    }

    /// Removes the record and its adoption marker. Migration calls this only
    /// after the account made from the record has been committed.
    func delete(_ serverID: String) -> Bool {
        guard !serverID.isEmpty else { return false }
        let recordRemoved = remove(Self.recordKey(serverID))
        let markerRemoved = remove(Self.markerKey(serverID))
        return recordRemoved && markerRemoved
    }
}
