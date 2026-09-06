#if os(iOS)
import Foundation
import OSLog

struct ApplePushNotificationSyncResponse: Decodable, Equatable {
    let items: [ApplePushNotificationSyncItem]
    let page: APIv2Page
    let syncCursor: String
    let unreadCount: Int
    let initialSnapshot: Bool
}

struct ApplePushNotificationSyncItem: Decodable, Equatable, Identifiable {
    let id: String
    let type: String?
    let profileId: String
    let createdAt: Date?
    let readAt: Date?
}

enum ApplePushNotificationSyncWire {
    static let endpoint = "/api/v2/notifications/sync"
    static let defaultLimit = 50

    static func query(cursor: String?) -> [String: String] {
        var query = ["limit": String(defaultLimit)]
        if let cursor, !cursor.isEmpty { query["cursor"] = cursor }
        return query
    }
}

private struct ApplePushSyncCheckpoint: Codable {
    let serverID: String
    let origin: String
    let accountID: String
    let epoch: UUID
    let profileID: String
    let cursor: String

    init(auth: CapturedDurableAccountAuth, cursor: String) {
        serverID = auth.request.account.serverId
        origin = auth.request.account.serverURL
        accountID = auth.accountID
        epoch = auth.accountEpoch
        profileID = auth.request.profileId ?? ""
        self.cursor = cursor
    }

    func matches(_ auth: CapturedDurableAccountAuth) -> Bool {
        serverID == auth.request.account.serverId && origin == auth.request.account.serverURL &&
            accountID == auth.accountID && epoch == auth.accountEpoch && profileID == auth.request.profileId
    }
}

@MainActor
final class ApplePushNotificationSyncCoordinator {
    static let shared = ApplePushNotificationSyncCoordinator()
    private static let checkpointKey = "notification-sync-v2-checkpoint"
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo", category: "ApplePushSync")

    private let api: APIv2Client
    private let tokens: TokenStore
    private let defaults: SharedDefaults
    private var inFlight = false

    init(api: APIv2Client = SiloAPI.shared.v2, tokens: TokenStore = .shared,
         defaults: SharedDefaults = .shared) {
        self.api = api
        self.tokens = tokens
        self.defaults = defaults
    }

    @discardableResult
    func refreshFromRemoteNotification() async -> Bool {
        // A background wake can precede ContentView's active-server setup.
        if let serverID = ServerRegistry.shared.activeServerId, !serverID.isEmpty {
            await tokens.retargetActiveServer(serverId: serverID)
        }
        return await refresh()
    }

    @discardableResult
    func refresh() async -> Bool {
        guard !inFlight else { return false }
        inFlight = true
        defer { inFlight = false }
        guard let auth = await tokens.captureDurableAccountAuth(),
              let profileID = auth.request.profileId, !profileID.isEmpty else { return false }
        let saved = defaults.data(forKey: Self.checkpointKey).flatMap {
            try? JSONDecoder().decode(ApplePushSyncCheckpoint.self, from: $0)
        }
        var cursor = saved?.matches(auth) == true ? saved?.cursor : nil
        var seen = Set(cursor.map { [$0] } ?? [])
        do {
            // Bound work during a background wake. Every completed page saves
            // its forward checkpoint so another wake can continue safely.
            for _ in 0..<10 {
                let response = try await api.notificationSync(cursor: cursor, auth: auth.request)
                if response.page.hasMore {
                    guard let next = response.page.nextCursor, seen.insert(next).inserted else {
                        throw APIv2Error.invalidNotificationContinuation
                    }
                }
                let data = try JSONEncoder().encode(ApplePushSyncCheckpoint(auth: auth, cursor: response.syncCursor))
                let defaults = self.defaults
                let key = Self.checkpointKey
                // Account/profile changes cannot publish another scope's cursor.
                try await tokens.withCurrentDurableAuthority(auth) { defaults.set(data, forKey: key) }
                if !response.items.isEmpty {
                    NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
                }
                if !response.page.hasMore { return true }
                cursor = response.page.nextCursor
            }
            return false
        } catch APIv2Error.problem(let problem) where problem.type.hasSuffix("/invalid_cursor") {
            let defaults = self.defaults
            let key = Self.checkpointKey
            try? await tokens.withCurrentDurableAuthority(auth) { defaults.removeObject(forKey: key) }
            // The next wake starts the server's bounded initial snapshot.
            return false
        } catch {
            Self.logger.error("Notification sync failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }
}
#endif
