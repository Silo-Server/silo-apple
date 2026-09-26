#if os(iOS)
import Foundation
import OSLog

@MainActor
final class ApplePushNotificationSyncCoordinator {
    static let shared = ApplePushNotificationSyncCoordinator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePushSync"
    )

    /// One slot for the last `sync_cursor` and the owner it was minted for.
    /// The cursor is a position marker, not a credential. The next owner
    /// overwrites the slot.
    private static let checkpointDefaultsKey = "applePush.notificationSyncCheckpoint.v1"

    private struct PersistedCheckpoint: Codable, Equatable {
        let owner: [String]
        let cursor: String
    }

    private let api: APIv2Client
    private let tokenStore: TokenStore
    private let checkpoints: UserDefaults
    private var inFlight = false

    init(api: APIv2Client = SiloAPI.shared.apiV2Client, tokenStore: TokenStore = .shared,
         checkpoints: UserDefaults = .standard) {
        self.api = api
        self.tokenStore = tokenStore
        self.checkpoints = checkpoints
    }

    /// Stable owner of a persisted sync cursor. `nil` for temporary credentials
    /// and requests without a profile: those read the initial snapshot.
    ///
    /// The server scopes and signs each cursor for one user, profile and page
    /// limit, and answers `invalid_cursor` for any other. So the key only needs
    /// fields that survive a relaunch; a stale match costs one extra request.
    /// It leaves out `credentialGenerationID`, which changes every launch, and
    /// the tokens, which are secrets and rotate.
    static func checkpointOwner(for auth: CapturedOrdinaryRequestAuth) -> [String]? {
        guard auth.credentialOwner == .persistentServer(serverId: auth.account.serverId),
              let profileId = auth.profileId, !profileId.isEmpty else { return nil }
        return [auth.account.serverId, auth.account.serverURL, profileId,
                String(APIv2NotificationSyncPage.defaultLimit)]
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

    /// Reads one page forward from the persisted checkpoint and refreshes Home
    /// when that page has deliveries. Returns `true` when the checkpoint has
    /// reached the server's head; a backlog resumes on the next sync.
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
        // Computed from the auth captured before the request, so the cursor is
        // filed under the owner it was minted for even if the profile changes
        // while the request is in flight.
        let owner = Self.checkpointOwner(for: auth)
        var cursor = owner.flatMap { storedCursor(for: $0) }
        var restarted = false
        var fetched: APIv2NotificationSyncPage?
        // At most two requests: the retry branch runs once, and every other
        // outcome sets `fetched` or returns.
        while fetched == nil {
            do {
                fetched = try await api.notificationSync(cursor: cursor, auth: auth)
            } catch APIv2Error.problem(let problem) where problem.identifier == "invalid_cursor" && cursor != nil && !restarted {
                // The server no longer accepts the checkpoint (for example
                // after its cursor key rotated). Start over from the
                // initial snapshot once.
                Self.logger.info("Notification sync checkpoint was rejected; restarting from the initial snapshot")
                clearStoredCursor()
                cursor = nil
                restarted = true
            } catch {
                Self.logger.error("Notification sync failed: \(String(describing: error), privacy: .public)")
                return false
            }
        }
        guard let page = fetched else { return false }
        // Keep `sync_cursor`, not `page.next_cursor`: the last page has no
        // next cursor but still advances the checkpoint.
        if let owner {
            storeCursor(page.syncCursor, for: owner)
        }
        let caughtUp = !page.page.hasMore
        Self.logger.info("Synced Silo notifications count=\(page.items.count, privacy: .public) unread=\(page.unreadCount, privacy: .public) caught_up=\(caughtUp, privacy: .public)")
        if !page.items.isEmpty {
            NotificationCenter.default.post(name: .homeSectionsShouldRefresh, object: nil)
        }
        return caughtUp
    }

    // MARK: - Checkpoint slot

    /// The stored cursor when it was minted for `owner`. An unreadable slot
    /// counts as empty.
    private func storedCursor(for owner: [String]) -> String? {
        guard let data = checkpoints.data(forKey: Self.checkpointDefaultsKey),
              let stored = try? JSONDecoder().decode(PersistedCheckpoint.self, from: data),
              stored.owner == owner else { return nil }
        return stored.cursor
    }

    private func storeCursor(_ cursor: String, for owner: [String]) {
        guard let data = try? JSONEncoder().encode(PersistedCheckpoint(owner: owner, cursor: cursor)) else { return }
        checkpoints.set(data, forKey: Self.checkpointDefaultsKey)
    }

    private func clearStoredCursor() {
        checkpoints.removeObject(forKey: Self.checkpointDefaultsKey)
    }
}
#endif
