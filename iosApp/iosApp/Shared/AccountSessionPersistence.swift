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

/// Legacy canonical saves publish their adoption marker first. TV storage has a
/// separate envelope migration. Once its marker is present, missing or corrupt
/// state fails closed; legacy mirrors can never become authoritative again.
struct AccountSessionPersistence: Sendable {
    enum State: Equatable, Sendable { case legacy, signedOut, session(CanonicalAccountSession) }
    private static let legacyLock = NSLock()
    let read: @Sendable (String) throws -> String?
    let write: @Sendable (String, String) -> Bool
    let remove: @Sendable (String) -> Bool
    private let tvStorage: TVAccountSessionStorage?

    init(keychain: SharedKeychain) {
        let account = keychain.withAudience(.userIndependent)
        read = { try account.getChecked($0) }
        write = { account.set($0, for: $1) }
        remove = { account.delete($0) }
        #if os(tvOS)
        let selection = keychain.withAudience(.currentUser)
        tvStorage = TVAccountSessionStorage(sharedRead: read, sharedWrite: write, sharedRemove: remove,
            selectionRead: { try selection.getChecked($0) },
            selectionWrite: { selection.set($0, for: $1) },
            selectionRemove: { selection.delete($0) })
        #else
        tvStorage = nil
        #endif
    }

    init(read: @escaping @Sendable (String) throws -> String?,
         write: @escaping @Sendable (String, String) -> Bool,
         remove: @escaping @Sendable (String) -> Bool) {
        self.read = read; self.write = write; self.remove = remove
        tvStorage = nil
    }

    /// Injection seam for the same TV storage used by the app and Top Shelf.
    init(tvStorage: TVAccountSessionStorage) {
        self.tvStorage = tvStorage
        read = { _ in throw AccountSessionPersistenceError.unavailable }
        write = { _, _ in false }
        remove = { _ in false }
    }

    static func recordKey(_ serverID: String) -> String { SharedStorage.keychainAccountPrefix + "\(serverID).accountSession" }
    static func markerKey(_ serverID: String) -> String { SharedStorage.keychainAccountPrefix + "\(serverID).accountSessionAdopted" }

    func load(_ serverID: String) throws -> State {
        if let tvStorage { return try tvStorage.load(serverID) }
        return try Self.legacyLock.withLock { try Self.loadLegacy(serverID, read: read) }
    }

    /// Unlocked legacy decoder, also used when the TV writer first adopts the
    /// old canonical record. Loading never performs a schema migration.
    static func loadLegacy(_ serverID: String, read: (String) throws -> String?) throws -> State {
        let adopted = try read(markerKey(serverID))
        guard let raw = try read(recordKey(serverID)) else {
            return adopted == nil ? .legacy : .signedOut
        }
        let value = try JSONDecoder().decode(CanonicalAccountSession.self, from: Data(raw.utf8))
        guard value.version == 1 else { throw AccountSessionPersistenceError.invalidRecord }
        if value.signedOut { return .signedOut }
        try validateSession(value)
        return .session(value)
    }

    static func validateSession(_ value: CanonicalAccountSession) throws {
        guard value.version == 1, !value.signedOut,
              let origin = value.origin, !origin.isEmpty, value.epoch != nil,
              value.accessToken?.isEmpty == false, value.refreshToken?.isEmpty == false,
              value.accountID == nil || value.accountID?.isEmpty == false else {
            throw AccountSessionPersistenceError.invalidRecord
        }
    }

    func hasSession(serverID: String, origin: String) -> Bool {
        do {
            switch try load(serverID) {
            case .session(let session):
                return session.origin == origin
            case .signedOut:
                return false
            case .legacy:
                // A TV selector can only resolve .legacy before adoption, so
                // the same checked shared raw-token read remains authoritative.
                if let tvStorage { return tvStorage.hasLegacyAccessToken(serverID: serverID) }
                return try read(SharedStorage.accessTokenAccount(for: serverID))?.isEmpty == false
            }
        } catch {
            return false
        }
    }

    func save(_ value: CanonicalAccountSession, serverID: String) throws {
        if let tvStorage {
            if value.signedOut {
                guard tvStorage.invalidate(serverID) else { throw AccountSessionPersistenceError.unavailable }
            } else {
                _ = try tvStorage.installAccountSession(value, serverID: serverID)
            }
            return
        }
        try Self.legacyLock.withLock { try saveLegacy(value, serverID: serverID) }
    }

    private func saveLegacy(_ value: CanonicalAccountSession, serverID: String) throws {
        guard !serverID.isEmpty else { throw AccountSessionPersistenceError.invalidIdentity }
        let raw = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        guard write("1", Self.markerKey(serverID)), write(raw, Self.recordKey(serverID)) else {
            throw AccountSessionPersistenceError.unavailable
        }
    }

    /// Legacy pairing rollback returns a slot to its never-adopted state.
    /// TV rollback uses an installation receipt instead; forgetting a TV
    /// selection only deselects locally and retains the shared authority.
    func forget(_ serverID: String) -> Bool {
        if let tvStorage { return tvStorage.deselectAccount(serverID: serverID) }
        return Self.legacyLock.withLock { forgetLegacy(serverID) }
    }

    private func forgetLegacy(_ serverID: String) -> Bool {
        guard !serverID.isEmpty else { return false }
        let recordRemoved = remove(Self.recordKey(serverID))
        let markerRemoved = remove(Self.markerKey(serverID))
        return recordRemoved && markerRemoved
    }

    /// A durable marker plus absent record is also a signed-out state. If neither
    /// tombstone nor removal can persist, callers must report durable sign-out failure.
    func invalidate(_ serverID: String) -> Bool {
        if let tvStorage { return tvStorage.invalidate(serverID) }
        return Self.legacyLock.withLock { invalidateLegacy(serverID) }
    }

    private func invalidateLegacy(_ serverID: String) -> Bool {
        guard !serverID.isEmpty, write("1", Self.markerKey(serverID)) else { return false }
        if let raw = try? JSONEncoder().encode(CanonicalAccountSession.tombstone),
           write(String(decoding: raw, as: UTF8.self), Self.recordKey(serverID)) { return true }
        return remove(Self.recordKey(serverID))
    }

    var supportsAccountSelection: Bool { tvStorage != nil }

    func savedAccountIDs(for serverID: String) throws -> [String] {
        if let tvStorage { return try tvStorage.savedAccountIDs(for: serverID) }
        return try Self.legacyLock.withLock {
            if case .session(let value) = try Self.loadLegacy(serverID, read: read),
               let accountID = value.accountID { return [accountID] }
            return []
        }
    }

    func accountSelectionSnapshot(for serverID: String) throws -> TVAccountSelectionSnapshot? {
        try tvStorage?.accountSelectionSnapshot(for: serverID)
    }

    func matchesAccountSelection(_ snapshot: TVAccountSelectionSnapshot, serverID: String) -> Bool {
        tvStorage?.matchesAccountSelection(snapshot, serverID: serverID) ?? false
    }

    func installAccountSession(_ value: CanonicalAccountSession, serverID: String) throws -> TVAccountInstallationReceipt? {
        if let tvStorage { return try tvStorage.installAccountSession(value, serverID: serverID) }
        try save(value, serverID: serverID)
        return nil
    }

    func rollbackAccountInstallation(_ receipt: TVAccountInstallationReceipt, serverID: String) -> Bool {
        tvStorage?.rollbackAccountInstallation(receipt, serverID: serverID) ?? false
    }

    func deselectAccount(serverID: String) -> Bool {
        if let tvStorage { return tvStorage.deselectAccount(serverID: serverID) }
        return invalidate(serverID)
    }

    func invalidateAllAccounts(serverID: String) -> Bool {
        if let tvStorage { return tvStorage.invalidateAllAccounts(serverID: serverID) }
        return invalidate(serverID)
    }

    func replaceSession(_ replacement: CanonicalAccountSession, replacing expected: CanonicalAccountSession,
                        serverID: String) -> Bool {
        if let tvStorage { return tvStorage.replaceSession(replacement, replacing: expected, serverID: serverID) }
        return Self.legacyLock.withLock {
            guard (try? Self.loadLegacy(serverID, read: read)) == .session(expected) else { return false }
            do { try saveLegacy(replacement, serverID: serverID); return true } catch { return false }
        }
    }

    func invalidateSession(_ expected: CanonicalAccountSession, serverID: String) -> Bool {
        if let tvStorage { return tvStorage.invalidateSession(expected, serverID: serverID) }
        return Self.legacyLock.withLock {
            guard (try? Self.loadLegacy(serverID, read: read)) == .session(expected) else { return false }
            return invalidateLegacy(serverID)
        }
    }

    func bindLegacySession(_ verified: CanonicalAccountSession, serverID: String) -> Bool {
        if let tvStorage { return tvStorage.bindLegacySession(verified, serverID: serverID) }
        do { try save(verified, serverID: serverID); return true } catch { return false }
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
