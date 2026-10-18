import Foundation
import OSLog

/// A removed session whose logout hasn't reached its server yet
/// (`HTTPClient.revoke(_:)`). Holds secrets; never logged. A refresh made to
/// revoke it replaces the entry's tokens and is kept nowhere else.
struct PendingRevocation: Codable, Equatable, Sendable {
    let id: UUID
    let serverURL: String
    var accessToken: String
    var refreshToken: String?
    let queuedAt: Date

    init(_ credential: RevocableCredential, id: UUID = UUID(), queuedAt: Date) {
        self.id = id
        serverURL = credential.serverURL
        accessToken = credential.accessToken
        refreshToken = credential.refreshToken
        self.queuedAt = queuedAt
    }

    var credential: RevocableCredential {
        RevocableCredential(serverURL: serverURL, accessToken: accessToken, refreshToken: refreshToken)
    }
}

/// The sessions this device still has to end on their servers, as one
/// keychain item in the user-independent audience, like the sign-ins they
/// came from: a removal affects everyone on the device, so any Apple TV
/// user's next launch finishes it. Bounded, so a server that never answers
/// can't grow it forever: entries older than `maxAge` drop, and past
/// `maxCount` the oldest go. Closure-based like `SavedSignInStore`, so tests
/// can use memory.
struct PendingRevocationStore: Sendable {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "PendingRevocationStore"
    )

    static let audience: KeychainAudience = .userIndependent
    static let account = SharedStorage.keychainAccountPrefix + "revocations.pending.v1"
    static let maxCount = 20
    /// Past this, the server has long expired the session's refresh token.
    static let maxAge: TimeInterval = 30 * 24 * 60 * 60

    private struct Payload: Codable {
        static let currentVersion = 1
        var version = Payload.currentVersion
        var entries: [PendingRevocation]
    }

    private let readItem: @Sendable () throws -> String?
    private let writeItem: @Sendable (String) -> Bool
    private let removeItem: @Sendable () -> Bool

    init(keychain: SharedKeychain) {
        let shared = keychain.withAudience(Self.audience)
        readItem = { try shared.getChecked(Self.account) }
        writeItem = { shared.set($0, for: Self.account) }
        removeItem = { shared.delete(Self.account) }
    }

    init(read: @escaping @Sendable () throws -> String?,
         write: @escaping @Sendable (String) -> Bool,
         remove: @escaping @Sendable () -> Bool) {
        readItem = read; writeItem = write; removeItem = remove
    }

    /// The queue, oldest first, within its bounds; entries past them are
    /// dropped from the keychain too. Throws when the keychain can't be
    /// read, so a locked keychain is never taken for an empty queue and
    /// overwritten. An item that can't be decoded reads as empty: there is
    /// nothing left to revoke with.
    func load(now: Date = Date()) throws -> [PendingRevocation] {
        guard let raw = try readItem() else { return [] }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(raw.utf8)),
              payload.version == Payload.currentVersion else {
            Self.logger.error("Pending revocations can't be decoded; dropping them.")
            _ = removeItem()
            return []
        }
        let bounded = Self.bounded(payload.entries, now: now)
        if bounded.count != payload.entries.count {
            save(bounded, now: now)
        }
        return bounded
    }

    /// Writes the queue within its bounds; an empty one removes the item.
    @discardableResult
    func save(_ entries: [PendingRevocation], now: Date = Date()) -> Bool {
        let bounded = Self.bounded(entries, now: now)
        guard !bounded.isEmpty else { return removeItem() }
        guard let data = try? JSONEncoder().encode(Payload(entries: bounded)),
              let raw = String(data: data, encoding: .utf8) else { return false }
        guard writeItem(raw) else {
            Self.logger.error("Pending revocations couldn't be saved.")
            return false
        }
        return true
    }

    private static func bounded(_ entries: [PendingRevocation], now: Date) -> [PendingRevocation] {
        let fresh = entries
            .filter { now.timeIntervalSince($0.queuedAt) < maxAge }
            .sorted { $0.queuedAt < $1.queuedAt }
        return Array(fresh.suffix(maxCount))
    }
}
