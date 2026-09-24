import Foundation

/// Only verified account epochs can recover a room after an app restart.
/// Join codes stay in Keychain; access tokens and room proofs are never copied.
struct WatchPartyRecentOwner: Codable, Equatable, Sendable {
    let accountID: String
    let accountEpoch: UUID
    let serverID: String
    let serverURL: String
    let profileID: String

    init?(auth: CapturedDurableAccountAuth) {
        guard let profile = auth.request.profileId, !profile.isEmpty else { return nil }
        accountID = auth.accountID
        accountEpoch = auth.accountEpoch
        serverID = auth.request.account.serverId
        serverURL = auth.request.account.serverURL
        profileID = profile
    }
}

final class WatchPartyRecentStore: @unchecked Sendable {
    private struct Entry: Codable {
        let owner: WatchPartyRecentOwner
        let room: WatchPartyRecentRoom
        let updatedAt: Date
    }

    static let key = "watchParty.recent.v1"
    static let lifetime: TimeInterval = 24 * 60 * 60
    let keychain: SharedKeychain
    private let lock = NSLock()
    private var generation = UUID()

    var writeGeneration: UUID { lock.withLock { generation } }

    init(keychain: SharedKeychain = SharedKeychain(audience: TokenStore.profileCredentialAudience)) {
        self.keychain = keychain
    }

    func load(owner: WatchPartyRecentOwner, now: Date = Date()) -> WatchPartyRecentRoom? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = try? keychain.getChecked(Self.key), let data = value.data(using: .utf8) else { return nil }
        guard let entry = try? JSONDecoder().decode(Entry.self, from: data), !entry.room.roomId.isEmpty,
              !entry.room.code.isEmpty, now.timeIntervalSince(entry.updatedAt) < Self.lifetime,
              entry.updatedAt.timeIntervalSince(now) < 60 else {
            generation = UUID()
            keychain.delete(Self.key)
            return nil
        }
        guard entry.owner == owner else { return nil }
        return entry.room
    }

    @discardableResult
    func save(_ room: WatchPartyRecentRoom, owner: WatchPartyRecentOwner, now: Date = Date(), expectedGeneration: UUID? = nil) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if let expectedGeneration, expectedGeneration != generation { return false }
        guard !room.roomId.isEmpty, !room.code.isEmpty,
              let data = try? JSONEncoder().encode(Entry(owner: owner, room: room, updatedAt: now)),
              let value = String(data: data, encoding: .utf8) else { return false }
        return keychain.set(value, for: Self.key)
    }

    func clear() {
        lock.withLock {
            generation = UUID()
            keychain.delete(Self.key)
        }
    }
}
