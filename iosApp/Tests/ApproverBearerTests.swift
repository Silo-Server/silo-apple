import Foundation
import XCTest
@testable import Silo

/// `HTTPClient.freshAccessToken(serverId:)` for a saved server that is not
/// the active one: the bearer a phone approves a TV with. The slot renews
/// itself once, writes the rotated pair only when the slot still holds the
/// session the refresh was sent with, and never hands out an expired or
/// rejected bearer.
final class ApproverBearerTests: XCTestCase {
    private var stub = APIv2TestStub()
    private static let refreshPath = "/api/v2/auth/refresh"

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    private func harness(access: String) async throws -> (HTTPClient, TokenStore) {
        let name = "ApproverBearerTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: Self.active)
        await tokens.setServerUrl("https://active.example")
        try await install(access: access, refresh: "refresh-1", in: tokens)
        return (HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokens)
    }

    private func install(access: String, refresh: String, in tokens: TokenStore) async throws {
        let expected = await tokens.captureAccountInstallationExpectation()
        try await tokens.installAccountSessionForServer(serverID: Self.other, origin: "https://other.example",
            accessToken: access, refreshToken: refresh, accountID: "7", expected: expected)
    }

    /// A JWT-shaped token whose `exp` is `expiresIn` seconds from now,
    /// issued an hour before it expires.
    private static func token(_ label: String, expiresIn: TimeInterval) -> String {
        let exp = Date().timeIntervalSince1970 + expiresIn
        let payload = try! JSONSerialization.data(withJSONObject: ["exp": exp, "iat": exp - 3600, "sub": label])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "h.\(encoded).s"
    }

    private static func refreshed(_ access: String) -> String {
        #"{"access_token":"\#(access)","refresh_token":"refresh-2","expires_in":3600}"#
    }

    /// Registry ids are derived from the server's URL; the bearer reads
    /// check a session against the address its id names.
    private static let active = ServerRegistry.serverId(for: "https://active.example")
    private static let other = ServerRegistry.serverId(for: "https://other.example")

    private var refreshes: [StubURLProtocol.Request] { stub.requests.filter { $0.path == Self.refreshPath } }

    /// An expired bearer is renewed once at that server's own address, with
    /// no credentials but the refresh token, and the rotated pair is kept.
    func testInactiveServerRenewsOnceAndKeepsTheRotatedPair() async throws {
        let (http, tokens) = try await harness(access: Self.token("old", expiresIn: -60))
        let fresh = Self.token("fresh", expiresIn: 3600)
        stub.reply(path: Self.refreshPath, 200, Self.refreshed(fresh))

        let bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .token(fresh))
        XCTAssertEqual(refreshes.count, 1)
        let request = try XCTUnwrap(refreshes.first)
        XCTAssertEqual(request.url?.host, "other.example")
        XCTAssertNil(request.header("authorization"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(body, ["refresh_token": "refresh-1"])
        let stored = await tokens.inactiveServerSession(for: Self.other)
        XCTAssertEqual(stored?.accessToken, fresh)
        XCTAssertEqual(stored?.refreshToken, "refresh-2")
        XCTAssertEqual(stored?.accountID, "7")

        let again = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(again, .token(fresh))
        XCTAssertEqual(refreshes.count, 1, "a fresh bearer is not renewed again")
    }

    /// A failed renewal hands out the stored bearer only while it is still
    /// valid, and never one the server rejected. Once it has expired, the
    /// result says why, and only a refusal asks for a fresh sign-in.
    func testFailedRenewalReturnsOnlyAStillValidBearer() async throws {
        var (http, tokens) = try await harness(access: Self.token("old", expiresIn: -60))
        stub.reply(path: Self.refreshPath, 503, #"{"type":"t","title":"t","status":503,"detail":"d"}"#)
        var bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .unreachable, "an expired bearer is never handed out; a server fault is not a refusal")
        var stored = await tokens.inactiveServerSession(for: Self.other)
        XCTAssertNotNil(stored?.refreshToken, "the session is kept")

        (http, tokens) = try await harness(access: Self.token("old", expiresIn: -60))
        stub.reply(path: Self.refreshPath, 503, Self.providerUnavailable)
        bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .providerUnavailable)
        stored = await tokens.inactiveServerSession(for: Self.other)
        XCTAssertNotNil(stored?.refreshToken, "a provider outage keeps the session")

        // About to expire (inside the renewal margin) but still valid.
        let closing = Self.token("closing", expiresIn: 30)
        (http, _) = try await harness(access: closing)
        stub.reply(path: Self.refreshPath, 503, #"{"type":"t","title":"t","status":503,"detail":"d"}"#)
        bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .token(closing), "a server fault leaves a still-valid bearer usable")

        (http, _) = try await harness(access: closing)
        stub.reply(path: Self.refreshPath, 503, Self.providerUnavailable)
        bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .token(closing), "so does a provider outage")

        (http, _) = try await harness(access: closing)
        stub.reply(path: Self.refreshPath, 401, #"{"type":"t","title":"t","status":401,"detail":"d"}"#)
        bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .rejected, "a rejected session asks for a fresh sign-in")
    }

    /// The active server renews through the shared refresh flight and reports
    /// an outage the same way.
    func testActiveServerOutageIsNotARefusal() async throws {
        let name = "ApproverBearerTests.active.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: Self.active)
        await tokens.setServerUrl("https://active.example")
        try await tokens.installAccountSession(accessToken: Self.token("old", expiresIn: -60), refreshToken: "r",
            accountID: "1")
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)

        stub.reply(path: Self.refreshPath, 503, Self.providerUnavailable)
        var bearer = await http.freshAccessToken(serverId: Self.active)
        XCTAssertEqual(bearer, .providerUnavailable)

        stub.reply(path: Self.refreshPath, 502, "bad gateway")
        bearer = await http.freshAccessToken(serverId: Self.active)
        XCTAssertEqual(bearer, .unreachable)
        let kept = await tokens.getRefreshToken()
        XCTAssertEqual(kept, "r", "neither outage signs out")

        stub.reply(path: Self.refreshPath, 401, #"{"type":"t","title":"t","status":401,"detail":"d"}"#)
        bearer = await http.freshAccessToken(serverId: Self.active)
        XCTAssertEqual(bearer, .rejected)
    }

    private static let providerUnavailable = #"""
    {"type":"https://siloserver.org/docs/api/v2/problems/provider_unavailable","title":"Provider unavailable","status":503,"detail":"d"}
    """#

    /// Two approvals for the same saved server renew its slot once: the
    /// second waits for the first renewal rather than sending the same
    /// refresh token again, and both get the rotated bearer.
    func testConcurrentRenewalsOfOneSlotShareOneRefresh() async throws {
        let (http, tokens) = try await harness(access: Self.token("old", expiresIn: -60))
        let fresh = Self.token("fresh", expiresIn: 3600)
        stub.reply(path: Self.refreshPath, 200, Self.refreshed(fresh))
        stub.hold(path: Self.refreshPath)
        let first = Task { await http.freshAccessToken(serverId: Self.other) }
        await stub.waitUntilHeld()
        let second = Task { await http.freshAccessToken(serverId: Self.other) }
        // Give the second caller time to reach the renewal in flight; an
        // unshared renewal would send its refresh unheld meanwhile.
        try await Task.sleep(for: .milliseconds(200))
        stub.release()

        let bearers = await [first.value, second.value]
        XCTAssertEqual(bearers, [.token(fresh), .token(fresh)])
        XCTAssertEqual(refreshes.count, 1)
        let stored = await tokens.inactiveServerSession(for: Self.other)
        XCTAssertEqual(stored?.refreshToken, "refresh-2")
    }

    /// The slot was signed in again while the refresh was in flight: the
    /// newer session stays, and the rotated pair is dropped unused.
    func testRenewalNeverOverwritesASlotThatChanged() async throws {
        let (http, tokens) = try await harness(access: Self.token("old", expiresIn: -60))
        stub.reply(path: Self.refreshPath, 200, Self.refreshed(Self.token("rotated", expiresIn: 3600)))
        stub.hold(path: Self.refreshPath)
        let pending = Task { await http.freshAccessToken(serverId: Self.other) }
        await stub.waitUntilHeld()
        let newer = Self.token("newer", expiresIn: 3600)
        try await install(access: newer, refresh: "refresh-newer", in: tokens)
        stub.release()

        let bearer = await pending.value
        XCTAssertEqual(bearer, .unreachable, "the bearer the refresh was sent for had expired")
        let stored = await tokens.inactiveServerSession(for: Self.other)
        XCTAssertEqual(stored?.accessToken, newer)
        XCTAssertEqual(stored?.refreshToken, "refresh-newer")
    }

    /// The slot became the active server while the refresh was in flight:
    /// the inactive path writes nothing into it (the active server rotates
    /// through its own refresh flight). The rotated refresh token is lost,
    /// so the slot keeps the one the refresh spent.
    func testRenewalNeverWritesIntoASlotThatBecameActive() async throws {
        let (http, tokens) = try await harness(access: Self.token("old", expiresIn: -60))
        stub.reply(path: Self.refreshPath, 200, Self.refreshed(Self.token("rotated", expiresIn: 3600)))
        stub.hold(path: Self.refreshPath)
        let pending = Task { await http.freshAccessToken(serverId: Self.other) }
        await stub.waitUntilHeld()
        await tokens.switchActiveServer(serverId: Self.other)
        stub.release()

        let bearer = await pending.value
        XCTAssertEqual(bearer, .unreachable)
        await tokens.switchActiveServer(serverId: Self.active)
        let stored = await tokens.inactiveServerSession(for: Self.other)
        XCTAssertEqual(stored?.refreshToken, "refresh-1")
    }

    /// A stored session bound to another origin than the address its slot
    /// is keyed by is never released to approve a device: not from an
    /// inactive slot, and not from the active one.
    func testASessionBoundElsewhereIsNeverReleased() async throws {
        let (http, tokens) = try await harness(access: Self.token("fresh", expiresIn: 3600))
        let expected = await tokens.captureAccountInstallationExpectation()
        try await tokens.installAccountSessionForServer(serverID: Self.other, origin: "https://elsewhere.example",
            accessToken: Self.token("elsewhere", expiresIn: 3600), refreshToken: "r", accountID: "7", expected: expected)
        var bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .rejected)
        let otherAccess = await tokens.getAccessToken(for: Self.other)
        XCTAssertNil(otherAccess)
        let otherSession = await tokens.inactiveServerSession(for: Self.other)
        XCTAssertNil(otherSession)

        // The active slot: its session is bound to the active URL, which is
        // not the address its id names.
        await tokens.setServerUrl("https://elsewhere.example")
        try await tokens.installAccountSession(accessToken: Self.token("active", expiresIn: 3600), refreshToken: "r",
            accountID: "1")
        bearer = await http.freshAccessToken(serverId: Self.active)
        XCTAssertEqual(bearer, .rejected)
        let activeAccess = await tokens.getAccessToken(for: Self.active)
        XCTAssertNil(activeAccess)
        XCTAssertTrue(refreshes.isEmpty, "nothing was sent anywhere")
    }
}
