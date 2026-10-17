import Foundation
import OSLog

enum SavedSignInStoreError: Error, Equatable {
    /// The keychain refused the write, or reading it back returned something
    /// else.
    case writeFailed
    /// The item decodes as JSON, but a build with another format wrote it.
    case unsupportedVersion(Int)
    /// The item exists but can't be decoded.
    case corrupt
    /// A sign-in item names a different server or account than its key.
    case keyMismatch
}

/// Reads and writes the user index and saved sign-ins in the
/// user-independent keychain. Reads are strict: a keychain error throws and
/// is never reported as an absent item. Closure-based like
/// `AccountSessionPersistence`, so tests can use memory.
struct SavedSignInStore: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "SavedSignInStore"
    )

    private let readItem: @Sendable (String) throws -> String?
    private let writeItem: @Sendable (String, String) -> Bool
    private let removeItem: @Sendable (String) -> Bool

    init(keychain: SharedKeychain) {
        let shared = keychain.withAudience(.userIndependent)
        readItem = { try shared.getChecked($0) }
        writeItem = { shared.set($0, for: $1) }
        removeItem = { shared.delete($0) }
    }

    init(read: @escaping @Sendable (String) throws -> String?,
         write: @escaping @Sendable (String, String) -> Bool,
         remove: @escaping @Sendable (String) -> Bool) {
        readItem = read; writeItem = write; removeItem = remove
    }

    /// Nil means the index was never written, so migration hasn't run. An
    /// index that can't be decoded falls back to the backup copy; without
    /// one, it throws. A keychain read error always throws.
    func loadIndex() throws -> SiloUserIndex? {
        guard let raw = try readItem(SharedStorage.usersIndexAccount) else { return nil }
        do {
            return try Self.decode(SiloUserIndex.self, from: raw, currentVersion: SiloUserIndex.currentVersion)
        } catch SavedSignInStoreError.corrupt {
            Self.logger.error("Users index can't be decoded; trying its backup copy.")
            guard let backup = try readItem(SharedStorage.usersIndexBackupAccount) else {
                throw SavedSignInStoreError.corrupt
            }
            return try Self.decode(SiloUserIndex.self, from: backup, currentVersion: SiloUserIndex.currentVersion)
        }
    }

    /// Writes the index and reads it back; this write is the commit point.
    /// The backup copy is then rewritten to match. If that write fails, the
    /// backup is removed rather than left older than the index.
    func saveIndex(_ index: SiloUserIndex) throws {
        guard index.version == SiloUserIndex.currentVersion else {
            throw SavedSignInStoreError.unsupportedVersion(index.version)
        }
        let raw = try Self.encode(index)
        try writeVerified(raw, to: SharedStorage.usersIndexAccount)
        if !writeItem(raw, SharedStorage.usersIndexBackupAccount) {
            Self.logger.error("Users index backup write failed; removing the stale backup.")
            if !removeItem(SharedStorage.usersIndexBackupAccount) {
                Self.logger.error("Stale users index backup could not be removed.")
            }
        }
    }

    /// Nil when no item exists. Throws when the item can't be read, was
    /// written in another format, or names a different key.
    func loadSignIn(_ key: SignInKey) throws -> SavedSignIn? {
        guard let raw = try readItem(SharedStorage.signInAccount(key)) else { return nil }
        let signIn = try Self.decode(SavedSignIn.self, from: raw, currentVersion: SavedSignIn.currentVersion)
        guard signIn.key == key else { throw SavedSignInStoreError.keyMismatch }
        return signIn
    }

    /// Writes the sign-in and reads it back.
    func saveSignIn(_ signIn: SavedSignIn) throws {
        guard signIn.version == SavedSignIn.currentVersion else {
            throw SavedSignInStoreError.unsupportedVersion(signIn.version)
        }
        try writeVerified(try Self.encode(signIn), to: SharedStorage.signInAccount(signIn.key))
    }

    @discardableResult
    func removeSignIn(_ key: SignInKey) -> Bool {
        removeItem(SharedStorage.signInAccount(key))
    }

    private func writeVerified(_ raw: String, to account: String) throws {
        guard writeItem(raw, account), try readItem(account) == raw else {
            throw SavedSignInStoreError.writeFailed
        }
    }

    private struct VersionHeader: Decodable {
        let version: Int
    }

    /// Reads the version before the body, so a record from another format
    /// fails closed as unsupported instead of looking corrupt.
    private static func decode<Value: Decodable>(
        _ type: Value.Type,
        from raw: String,
        currentVersion: Int
    ) throws -> Value {
        let data = Data(raw.utf8)
        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(VersionHeader.self, from: data) else {
            throw SavedSignInStoreError.corrupt
        }
        guard header.version == currentVersion else {
            throw SavedSignInStoreError.unsupportedVersion(header.version)
        }
        guard let value = try? decoder.decode(Value.self, from: data) else {
            throw SavedSignInStoreError.corrupt
        }
        return value
    }

    fileprivate static func encode<Value: Encodable>(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// Reads and writes this Apple TV user's PIN proofs in the current-user
/// keychain: one slot per sign-in.
struct SignInProofStore: Sendable {
    private let readItem: @Sendable (String) throws -> String?
    /// The lenient read today's code uses for `<serverID>.profileToken`.
    private let readLegacyItem: @Sendable (String) -> String?
    private let writeItem: @Sendable (String, String) -> Bool
    private let removeItem: @Sendable (String) -> Bool

    init(keychain: SharedKeychain) {
        let proofs = keychain.withAudience(.currentUser)
        readItem = { try proofs.getChecked($0) }
        readLegacyItem = { proofs.get($0) }
        writeItem = { proofs.set($0, for: $1) }
        removeItem = { proofs.delete($0) }
    }

    init(read: @escaping @Sendable (String) throws -> String?,
         write: @escaping @Sendable (String, String) -> Bool,
         remove: @escaping @Sendable (String) -> Bool) {
        readItem = read
        readLegacyItem = { try? read($0) }
        writeItem = write
        removeItem = remove
    }

    /// Nil when no proof is saved. Throws when the slot can't be read or
    /// decoded.
    func load(_ key: SignInKey) throws -> SignInProfileProof? {
        guard let raw = try readItem(SharedStorage.signInProofAccount(key)) else { return nil }
        guard let proof = try? JSONDecoder().decode(SignInProfileProof.self, from: Data(raw.utf8)) else {
            throw SavedSignInStoreError.corrupt
        }
        return proof
    }

    /// Writes the proof and reads it back.
    func save(_ proof: SignInProfileProof, for key: SignInKey) -> Bool {
        let account = SharedStorage.signInProofAccount(key)
        guard let raw = try? SavedSignInStore.encode(proof), writeItem(raw, account) else { return false }
        return (try? readItem(account)) == raw
    }

    @discardableResult
    func remove(_ key: SignInKey) -> Bool {
        removeItem(SharedStorage.signInProofAccount(key))
    }

    /// This Apple TV user's proof from before sign-ins existed, read only so
    /// migration can adopt it.
    func loadLegacy(serverID: String) -> String? {
        guard let token = readLegacyItem(SharedStorage.profileTokenAccount(for: serverID)),
              !token.isEmpty else { return nil }
        return token
    }

    @discardableResult
    func removeLegacy(serverID: String) -> Bool {
        removeItem(SharedStorage.profileTokenAccount(for: serverID))
    }
}
