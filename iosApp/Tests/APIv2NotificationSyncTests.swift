import Foundation
import XCTest
@testable import Silo

@MainActor
final class APIv2NotificationSyncTests: XCTestCase {
    private func fixture() async throws -> (ApplePushNotificationSyncCoordinator, APIv2Client, TokenStore, SharedDefaults) {
        let name = "APIv2NotificationSyncTests.\(UUID())"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let defaults = SharedDefaults(suite: suite, standard: suite)
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil), defaults: defaults)
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://notifications.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NotificationSyncProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokens)
        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        NotificationSyncProtocol.reset()
        addTeardownBlock {
            suite.removePersistentDomain(forName: name)
            NotificationSyncProtocol.reset()
        }
        return (ApplePushNotificationSyncCoordinator(api: api, tokens: tokens, defaults: defaults), api, tokens, defaults)
    }

    private func page(_ cursor: String, initial: Bool, more: Bool = false, ids: [String] = []) -> Data {
        var pagination: [String: Any] = ["has_more": more]
        if more { pagination["next_cursor"] = cursor }
        return try! JSONSerialization.data(withJSONObject: [
            "items": ids.map { ["id": $0, "profile_id": "profile", "type": "new_episode",
                "created_at": "2026-07-01T12:30:00.123Z"] },
            "page": pagination, "sync_cursor": cursor, "initial_snapshot": initial, "unread_count": ids.count
        ])
    }

    func testPaginationPersistsFinalCheckpointAcrossCoordinatorRestart() async throws {
        let (owner, api, tokens, defaults) = try await fixture()
        NotificationSyncProtocol.enqueue([page("signed-1", initial: true, more: true, ids: ["one"]),
            page("signed-2", initial: false, ids: ["two"])])
        let first = await owner.refresh()
        XCTAssertTrue(first)
        let restarted = ApplePushNotificationSyncCoordinator(api: api, tokens: tokens, defaults: defaults)
        NotificationSyncProtocol.enqueue([page("signed-2", initial: false)])
        let second = await restarted.refresh()
        XCTAssertTrue(second)
        XCTAssertEqual(NotificationSyncProtocol.cursors(), [nil, "signed-1", "signed-2"])
        XCTAssertTrue(NotificationSyncProtocol.requests().allSatisfy {
            $0.url?.path == "/api/v2/notifications/sync" &&
                $0.value(forHTTPHeaderField: "X-Profile-Id") == "profile" &&
                $0.value(forHTTPHeaderField: "Authorization") == "Bearer access"
        })
    }

    func testEmptyInitialSnapshotStillPersistsCheckpoint() async throws {
        let (owner, _, _, _) = try await fixture()
        NotificationSyncProtocol.enqueue([page("empty-checkpoint", initial: true), page("empty-checkpoint", initial: false)])
        let first = await owner.refresh()
        let second = await owner.refresh()
        XCTAssertTrue(first)
        XCTAssertTrue(second)
        XCTAssertEqual(NotificationSyncProtocol.cursors(), [nil, "empty-checkpoint"])
    }

    func testAccountEpochChangeDoesNotReusePreviousCheckpoint() async throws {
        let (owner, _, tokens, _) = try await fixture()
        NotificationSyncProtocol.enqueue([page("old-checkpoint", initial: true), page("new-checkpoint", initial: true)])
        let first = await owner.refresh()
        XCTAssertTrue(first)
        try await tokens.installAccountSession(accessToken: "new-access", refreshToken: "new-refresh", accountID: "1")
        await tokens.setProfileId("profile")
        let second = await owner.refresh()
        XCTAssertTrue(second)
        XCTAssertEqual(NotificationSyncProtocol.cursors(), [nil, nil])
    }

    func testProfileSwitchDuringReplyCannotPublishCheckpoint() async throws {
        let (owner, _, tokens, _) = try await fixture()
        NotificationSyncProtocol.enqueue([page("wrong-scope", initial: true), page("correct-scope", initial: true)])
        NotificationSyncProtocol.beforeNextReply { await tokens.setProfileId("other-profile") }
        let first = await owner.refresh()
        XCTAssertFalse(first)
        await tokens.setProfileId("profile")
        let second = await owner.refresh()
        XCTAssertTrue(second)
        XCTAssertEqual(NotificationSyncProtocol.cursors(), [nil, nil])
    }

    func testRepeatedContinuationDoesNotOverwriteLastGoodCheckpoint() async throws {
        let (owner, _, _, _) = try await fixture()
        NotificationSyncProtocol.enqueue([page("signed-1", initial: true, more: true, ids: ["one"]),
            page("signed-1", initial: false, more: true, ids: ["two"]), page("signed-2", initial: false)])
        let first = await owner.refresh()
        XCTAssertFalse(first)
        let second = await owner.refresh()
        XCTAssertTrue(second)
        XCTAssertEqual(NotificationSyncProtocol.cursors(), [nil, "signed-1", "signed-1"])
    }
}

private final class NotificationSyncProtocol: URLProtocol {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pages: [Data] = []
    nonisolated(unsafe) private static var captured: [URLRequest] = []
    nonisolated(unsafe) private static var hook: (@Sendable () async -> Void)?
    static func reset() { lock.withLock { pages = []; captured = []; hook = nil } }
    static func enqueue(_ values: [Data]) { lock.withLock { pages.append(contentsOf: values) } }
    static func beforeNextReply(_ value: @escaping @Sendable () async -> Void) { lock.withLock { hook = value } }
    static func requests() -> [URLRequest] { lock.withLock { captured } }
    static func cursors() -> [String?] {
        requests().map { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "cursor" }?.value }
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let state = Self.lock.withLock { () -> (Data?, (@Sendable () async -> Void)?) in
            Self.captured.append(request)
            let data = Self.pages.isEmpty ? nil : Self.pages.removeFirst()
            let hook = Self.hook
            Self.hook = nil
            return (data, hook)
        }
        Task {
            await state.1?()
            guard let data = state.0 else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200,
                httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
