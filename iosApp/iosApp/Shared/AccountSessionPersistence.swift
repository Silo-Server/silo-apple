import Foundation

struct CanonicalAccountSession: Codable, Equatable, Sendable {
    let version: Int
    let signedOut: Bool
    let origin: String?
    let accountID: String?
    let epoch: UUID?
    let accessToken: String?
    let refreshToken: String?

    static let tombstone = CanonicalAccountSession(version: 1, signedOut: true, origin: nil,
        accountID: nil, epoch: nil, accessToken: nil, refreshToken: nil)
}

enum AccountSessionPersistenceError: Error {
    case unavailable, invalidRecord, invalidIdentity
}

/// The adoption marker is written first. Once present, missing/corrupt/inaccessible
/// canonical state fails closed; legacy mirrors can never become authoritative again.
struct AccountSessionPersistence: Sendable {
    enum State { case legacy, signedOut, session(CanonicalAccountSession) }
    let read: @Sendable (String) throws -> String?
    let write: @Sendable (String, String) -> Bool
    let remove: @Sendable (String) -> Bool

    init(keychain: SharedKeychain) {
        let account = keychain.withAudience(.userIndependent)
        read = { try account.getChecked($0) }
        write = { account.set($0, for: $1) }
        remove = { account.delete($0) }
    }

    init(read: @escaping @Sendable (String) throws -> String?,
         write: @escaping @Sendable (String, String) -> Bool,
         remove: @escaping @Sendable (String) -> Bool) {
        self.read = read; self.write = write; self.remove = remove
    }

    static func recordKey(_ serverID: String) -> String { "com.continuum.\(serverID).accountSession" }
    static func markerKey(_ serverID: String) -> String { "com.continuum.\(serverID).accountSessionAdopted" }

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

    func save(_ value: CanonicalAccountSession, serverID: String) throws {
        guard !serverID.isEmpty else { throw AccountSessionPersistenceError.invalidIdentity }
        let raw = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        guard write("1", Self.markerKey(serverID)), write(raw, Self.recordKey(serverID)) else {
            throw AccountSessionPersistenceError.unavailable
        }
    }

    /// A durable marker plus absent record is also a signed-out state. If neither
    /// tombstone nor removal can persist, callers must report durable sign-out failure.
    func invalidate(_ serverID: String) -> Bool {
        guard !serverID.isEmpty, write("1", Self.markerKey(serverID)) else { return false }
        if let raw = try? JSONEncoder().encode(CanonicalAccountSession.tombstone),
           write(String(decoding: raw, as: UTF8.self), Self.recordKey(serverID)) { return true }
        return remove(Self.recordKey(serverID))
    }
}

extension AccountSessionPersistenceError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "Sign-in could not be saved on this device. Try again."
        case .invalidRecord:
            return "The sign-in saved on this device is unreadable. Sign in again."
        case .invalidIdentity:
            return "The active server changed before sign-in could be saved."
        }
    }
}
