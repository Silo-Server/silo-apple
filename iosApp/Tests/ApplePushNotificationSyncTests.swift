#if os(iOS)
import Foundation
import XCTest
@testable import Silo

private let notificationSyncPath = "/api/v2/notifications/sync"

/// Notification inbox catch-up on `GET /api/v2/notifications/sync`: one page
/// per sync, the checkpoint it persists across relaunches and for which owner,
/// and how it recovers from a rejected cursor or a failed page.
@MainActor
final class ApplePushNotificationSyncTests: XCTestCase {
    private static let serverID = "server-sync"

    /// Answers each request from `pages`, keyed by the cursor it was sent
    /// (`""` for the initial snapshot). A missing key answers 500.
    private final class InboxServer: @unchecked Sendable {
        let handler = StubURLProtocol.Handler()
        private let lock = NSLock()
        private var pages: [String: StubURLProtocol.Response] = [:]

        init() {
            handler.route(StubURLProtocol.method("GET", path: notificationSyncPath)) { [self] request in
                lock.withLock { pages[request.query["cursor"] ?? ""] } ?? .status(500)
            }
        }

        func page(for cursor: String?, items: [String], profile: String = "profile-a",
                  syncCursor: String, hasMore: Bool = false) {
            let rows = items.map {
                #"{"id":"\#($0)","type":"new_episode","profile_id":"\#(profile)","reason_flags":{},"created_at":"2026-09-01T12:00:00.000Z","read_at":null}"#
            }
            let page = hasMore ? #"{"has_more":true,"next_cursor":"\#(syncCursor)"}"# : #"{"has_more":false}"#
            let body = #"{"items":[\#(rows.joined(separator: ","))],"page":\#(page),"sync_cursor":"\#(syncCursor)","unread_count":\#(items.count),"initial_snapshot":\#(cursor == nil)}"#
            lock.withLock { pages[cursor ?? ""] = .json(body) }
        }

        func problem(for cursor: String, type: String, status: Int) {
            let body = #"{"type":"https://silo.example/problems/\#(type)","title":"t","status":\#(status),"detail":"d"}"#
            lock.withLock { pages[cursor] = .json(body, status: status, headers: ["Content-Type": "application/problem+json"]) }
        }

        /// The cursor each request sent, `nil` for none.
        var sentCursors: [String?] { handler.requests.map { $0.query["cursor"] } }
    }

    private struct Harness {
        let suite: UserDefaults
        let keychain: SharedKeychain
        let defaults: SharedDefaults
        let tokens: TokenStore
        let server: InboxServer
        let coordinator: ApplePushNotificationSyncCoordinator
    }

    private func makeHarness() async throws -> Harness {
        let name = "ApplePushNotificationSyncTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let keychain = SharedKeychain(service: name, accessGroup: nil)
        addTeardownBlock {
            for key in [
                TokenStore.accessTokenKey(for: Self.serverID),
                TokenStore.refreshTokenKey(for: Self.serverID),
                TokenStore.profileTokenKey(for: Self.serverID),
                TokenStore.accountEpochKey(for: Self.serverID),
                AccountSessionPersistence.recordKey(Self.serverID),
                AccountSessionPersistence.markerKey(Self.serverID),
                SharedStorage.mirroredAccessTokenAccount,
                SharedStorage.mirroredProfileTokenAccount,
            ] {
                keychain.withAudience(.userIndependent).delete(key)
                keychain.withAudience(.currentUser).delete(key)
            }
            UserDefaults().removePersistentDomain(forName: name)
        }
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokens = TokenStore(keychain: keychain, defaults: defaults)
        await tokens.switchActiveServer(serverId: Self.serverID)
        await tokens.setServerUrl("https://silo.example")
        let saved = await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)
        await tokens.setProfileId("profile-a")

        let server = InboxServer()
        let api = APIv2Client(http: HTTPClient(session: server.handler.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        return Harness(suite: suite, keychain: keychain, defaults: defaults, tokens: tokens, server: server,
            coordinator: ApplePushNotificationSyncCoordinator(api: api, tokenStore: tokens, checkpoints: suite))
    }

    /// A coordinator as a relaunched process would build it: a new token store
    /// over the same keychain and defaults, and a client fenced on that store.
    private func relaunch(_ h: Harness) async -> ApplePushNotificationSyncCoordinator {
        let tokens = TokenStore(keychain: h.keychain, defaults: h.defaults)
        await tokens.switchActiveServer(serverId: Self.serverID)
        let api = APIv2Client(http: HTTPClient(session: h.server.handler.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        return ApplePushNotificationSyncCoordinator(api: api, tokenStore: tokens, checkpoints: h.suite)
    }

    func testSyncPagesForwardAndResumesFromTheLastSyncCursor() async throws {
        let h = try await makeHarness()
        h.server.page(for: nil, items: ["n1"], syncCursor: "c1")
        let refreshed = expectation(forNotification: .homeSectionsShouldRefresh, object: nil)

        let first = await h.coordinator.sync()

        XCTAssertTrue(first)
        await fulfillment(of: [refreshed], timeout: 1)
        let request = try XCTUnwrap(h.server.handler.requests.first)
        XCTAssertEqual(request.query, ["limit": "50"])
        XCTAssertEqual(request.header("X-Profile-Id"), "profile-a")

        h.server.page(for: "c1", items: ["n2"], syncCursor: "c2", hasMore: true)
        h.server.page(for: "c2", items: [], syncCursor: "c3")

        let second = await h.coordinator.sync()
        let third = await h.coordinator.sync()

        // One page per sync: the backlog page is not caught up, and the next
        // sync resumes from its sync_cursor.
        XCTAssertFalse(second)
        XCTAssertTrue(third)
        XCTAssertEqual(h.server.sentCursors, [nil, "c1", "c2"])
    }

    func testCheckpointSurvivesRelaunch() async throws {
        let h = try await makeHarness()
        h.server.page(for: nil, items: ["n1"], syncCursor: "c1")
        _ = await h.coordinator.sync()
        h.server.page(for: "c1", items: [], syncCursor: "c1")

        let relaunched = await relaunch(h)
        let synced = await relaunched.sync()

        XCTAssertTrue(synced)
        XCTAssertEqual(h.server.sentCursors, [nil, "c1"])
    }

    func testRelaunchedSyncWithNoNewDeliveriesDoesNotRefreshHome() async throws {
        let h = try await makeHarness()
        h.server.page(for: nil, items: ["n1"], syncCursor: "c1")
        _ = await h.coordinator.sync()
        h.server.page(for: "c1", items: [], syncCursor: "c1")
        let relaunched = await relaunch(h)
        let notRefreshed = expectation(forNotification: .homeSectionsShouldRefresh, object: nil)
        notRefreshed.isInverted = true

        let synced = await relaunched.sync()

        await fulfillment(of: [notRefreshed], timeout: 0.2)
        XCTAssertTrue(synced)
        XCTAssertEqual(h.server.sentCursors, [nil, "c1"])
    }

    func testFailedPageKeepsTheCheckpointOfTheLastCompletedPage() async throws {
        let h = try await makeHarness()
        h.server.page(for: nil, items: ["n1"], syncCursor: "c1")
        let seeded = await h.coordinator.sync()
        // No reply for "c1": the next page fails.
        let failed = await h.coordinator.sync()
        h.server.page(for: "c1", items: [], syncCursor: "c1")

        // A relaunch reads the persisted slot, so this proves the failure left it intact.
        let resumed = await relaunch(h).sync()

        XCTAssertTrue(seeded)
        XCTAssertFalse(failed)
        XCTAssertTrue(resumed)
        XCTAssertEqual(h.server.sentCursors, [nil, "c1", "c1"])
    }

    func testRejectedCursorRestartsFromTheInitialSnapshotOnce() async throws {
        let h = try await makeHarness()
        h.server.page(for: nil, items: ["n1"], syncCursor: "stale")
        _ = await h.coordinator.sync()
        h.server.problem(for: "stale", type: "invalid_cursor", status: 400)
        h.server.page(for: nil, items: ["n1"], syncCursor: "fresh")

        let restarted = await h.coordinator.sync()

        XCTAssertTrue(restarted)
        XCTAssertEqual(h.server.sentCursors, [nil, "stale", nil])

        // The replacement cursor was persisted.
        h.server.page(for: "fresh", items: [], syncCursor: "fresh")
        let resumed = await relaunch(h).sync()
        XCTAssertTrue(resumed)
        XCTAssertEqual(h.server.sentCursors, [nil, "stale", nil, "fresh"])
    }

    func testCheckpointIsNotSentForAnotherProfile() async throws {
        let h = try await makeHarness()
        h.server.page(for: nil, items: ["n1"], syncCursor: "profile-a-cursor")
        _ = await h.coordinator.sync()

        await h.tokens.setProfileId("profile-b")
        h.server.page(for: nil, items: ["n9"], profile: "profile-b", syncCursor: "profile-b-cursor")
        let synced = await h.coordinator.sync()

        XCTAssertTrue(synced)
        XCTAssertEqual(h.server.sentCursors, [nil, nil])
        XCTAssertEqual(h.server.handler.requests.last?.header("X-Profile-Id"), "profile-b")
    }

    func testBacklogSyncReadsOnePageAndResumesOnTheNextSync() async throws {
        let h = try await makeHarness()
        h.server.page(for: nil, items: ["n0"], syncCursor: "c1")
        _ = await h.coordinator.sync()
        h.server.page(for: "c1", items: ["n1"], syncCursor: "c2", hasMore: true)
        h.server.page(for: "c2", items: ["n2"], syncCursor: "c3", hasMore: true)
        // Created after the seeding sync, which posted its own refresh.
        let refreshed = expectation(forNotification: .homeSectionsShouldRefresh, object: nil)

        let backlog = await h.coordinator.sync()

        XCTAssertFalse(backlog)
        XCTAssertEqual(h.server.handler.requests.count, 2)
        await fulfillment(of: [refreshed], timeout: 1)
        _ = await h.coordinator.sync()
        XCTAssertEqual(h.server.sentCursors, [nil, "c1", "c2"])
    }

    func testCheckpointOwnerExcludesTemporaryCredentials() async throws {
        let h = try await makeHarness()
        let captured = await h.tokens.captureOrdinaryRequestAuth()
        let auth = try XCTUnwrap(captured)

        XCTAssertEqual(ApplePushNotificationSyncCoordinator.checkpointOwner(for: auth),
                       [Self.serverID, auth.account.serverURL, "profile-a", "50"])
        let temporary = CapturedOrdinaryRequestAuth(account: auth.account, credentialOwner: .temporary,
            accessToken: auth.accessToken, profileId: auth.profileId, profileToken: auth.profileToken)
        XCTAssertNil(ApplePushNotificationSyncCoordinator.checkpointOwner(for: temporary))
        for profileId in [nil, ""] as [String?] {
            let noProfile = CapturedOrdinaryRequestAuth(account: auth.account, credentialOwner: auth.credentialOwner,
                accessToken: auth.accessToken, profileId: profileId, profileToken: auth.profileToken)
            XCTAssertNil(ApplePushNotificationSyncCoordinator.checkpointOwner(for: noProfile))
        }
    }
}
#endif
