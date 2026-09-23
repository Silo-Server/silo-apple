#if os(iOS)
import Foundation
import OSLog

@MainActor
final class ApplePushNotificationSyncCoordinator {
    static let shared = ApplePushNotificationSyncCoordinator()
    /// Pages one sync may read. A backlog past the cap resumes from the kept
    /// checkpoint on the next wake.
    static let maxPagesPerSync = 100

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePushSync"
    )

    private let api: APIv2Client
    private let tokenStore: TokenStore
    private var inFlight = false
    /// The last `sync_cursor` and the owner it was minted for. A cursor is
    /// only valid for that account and profile; any other owner starts from
    /// the server's initial snapshot.
    private var checkpoint: (owner: CapturedOrdinaryRequestAuth, cursor: String)?

    init(api: APIv2Client = SiloAPI.shared.apiV2Client, tokenStore: TokenStore = .shared) {
        self.api = api
        self.tokenStore = tokenStore
    }

    @discardableResult
    func refreshFromRemoteNotification() async -> Bool {
        // A background remote-notification wake can launch a killed app and
        // land here before ContentView.checkInitialState() has pointed
        // TokenStore at the active registry server — the capture below would
        // then find no credentials. Retarget first; it's an idempotent no-op
        // on every subsequent call.
        if let serverId = ServerRegistry.shared.activeServerId, !serverId.isEmpty {
            await tokenStore.retargetActiveServer(serverId: serverId)
        }
        return await sync()
    }

    /// Reads forward from the saved checkpoint until the server reports no
    /// more pages. Returns `true` only when the inbox is fully caught up.
    @discardableResult
    func sync() async -> Bool {
        guard !inFlight else {
            return false
        }
        // Claimed before the first await so a second push/foreground/tap
        // sync cannot race the checkpoint bookkeeping.
        inFlight = true
        defer { inFlight = false }

        guard let auth = await tokenStore.captureOrdinaryRequestAuth(),
              let profileId = auth.profileId, !profileId.isEmpty else {
            return false
        }
        var cursor = checkpoint.flatMap { $0.owner.sameCredentialIdentity(as: auth) ? $0.cursor : nil }
        var restarted = false
        var caughtUp = false
        var synced = 0
        var pages = 0
        readPages: while !caughtUp, pages < Self.maxPagesPerSync {
            pages += 1
            let page: APIv2NotificationSyncPage
            do {
                page = try await api.notificationSync(cursor: cursor, auth: auth)
            } catch APIv2Error.problem(let problem) where problem.identifier == "invalid_cursor" && cursor != nil && !restarted {
                // The server no longer accepts the checkpoint (for example
                // after its cursor key rotated). Start over from the
                // initial snapshot once.
                Self.logger.info("Notification sync checkpoint was rejected; restarting from the initial snapshot")
                checkpoint = nil
                cursor = nil
                restarted = true
                continue
            } catch {
                Self.logger.error("Notification sync failed: \(String(describing: error), privacy: .public)")
                break readPages
            }
            // Keep `sync_cursor`, not `page.next_cursor`: the last page has no
            // next cursor but still advances the checkpoint.
            checkpoint = (auth, page.syncCursor)
            synced += page.items.count
            caughtUp = !page.page.hasMore
            cursor = page.syncCursor
            if caughtUp {
                Self.logger.info("Synced Silo notifications count=\(synced, privacy: .public) unread=\(page.unreadCount, privacy: .public)")
            }
        }
        if !caughtUp, pages == Self.maxPagesPerSync {
            Self.logger.notice("Notification sync stopped after \(pages, privacy: .public) pages count=\(synced, privacy: .public); the next sync resumes from the checkpoint")
        }
        if synced > 0 {
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        }
        return caughtUp
    }
}
#endif
