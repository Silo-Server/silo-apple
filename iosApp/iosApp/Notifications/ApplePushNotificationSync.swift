#if os(iOS)
import Foundation
import OSLog

struct ApplePushNotificationSyncResponse: Decodable, Equatable {
    let notifications: [ApplePushNotificationSyncItem]
    let nextCursor: String?
    let unreadCount: Int
}

struct ApplePushNotificationSyncItem: Decodable, Equatable, Identifiable {
    let id: String
    let type: String?
    let profileId: String?
    let createdAt: Date?
    let readAt: Date?
}

enum ApplePushNotificationSyncWire {
    static let endpoint = "/api/v1/notifications/sync"
    static let defaultLimit = 50

    static func query(since: String?) -> [String: String] {
        var query = ["limit": String(defaultLimit)]
        if let since, !since.isEmpty {
            query["since"] = since
        }
        return query
    }
}

@MainActor
final class ApplePushNotificationSyncCoordinator {
    static let shared = ApplePushNotificationSyncCoordinator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePushSync"
    )

    private var inFlight = false
    private var nextCursor: String?
    private var cursorContext: String?

    private init() {}

    @discardableResult
    func refreshFromRemoteNotification() async -> Bool {
        guard AuthService.shared.hasServer, AuthService.shared.hasProfile else {
            return false
        }
        guard !inFlight else {
            return false
        }
        // Claimed before the first await: the retarget below suspends, and a
        // second push/foreground/tap sync re-entering during that window
        // would pass the guard and race the cursor bookkeeping.
        inFlight = true
        defer { inFlight = false }

        // A background remote-notification wake can launch a killed app and
        // land here before ContentView.checkInitialState() has pointed
        // TokenStore at the active registry server — HTTPClient would then
        // send this sync unauthenticated and 401. Retarget first; it's an
        // idempotent no-op on every subsequent call.
        if let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty {
            await TokenStore.shared.retargetActiveServer(serverId: serverId)
        }

        // The cursor is only meaningful for the server+profile that minted
        // it; a cursor from server A sent as ?since= to server B silently
        // skips B's older notifications.
        let context = [
            ServerRegistry.shared.activeServerId ?? "",
            AuthService.shared.profileId ?? ""
        ].joined(separator: "|")
        if context != cursorContext {
            cursorContext = context
            nextCursor = nil
        }

        do {
            let response: ApplePushNotificationSyncResponse = try await HTTPClient.shared.get(
                ApplePushNotificationSyncWire.endpoint,
                query: ApplePushNotificationSyncWire.query(since: nextCursor)
            )
            if let cursor = response.nextCursor, !cursor.isEmpty {
                nextCursor = cursor
            }
            if !response.notifications.isEmpty {
                NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
            }
            Self.logger.info("Synced Silo notifications after APNs wake count=\(response.notifications.count, privacy: .public) unread=\(response.unreadCount, privacy: .public)")
            return true
        } catch HTTPError.http(let statusCode, _) where statusCode == 404 || statusCode == 405 {
            Self.logger.info("Notification sync endpoint is not available on this Silo server yet")
            return false
        } catch {
            Self.logger.error("Notification sync after APNs wake failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
#endif
