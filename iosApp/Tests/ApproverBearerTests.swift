import Foundation
import XCTest
@testable import Silo

/// `HTTPClient.freshAccessToken(serverId:)` for a saved server that is not
/// the active one: the bearer a phone approves a TV with, from that server's
/// launch account (here its only one). The sign-in renews itself once,
/// writes the rotated pair only when it still holds the session the refresh
/// was sent with, and never hands out an expired or rejected bearer.
final class ApproverBearerTests: XCTestCase {
    private var stub = APIv2TestStub()
    private static let refreshPath = "/api/v2/auth/refresh"

    override func setUp() {
        super.setUp()
        stub = APIv2TestStub()
    }

    /// An account signed in to the active server and, with `access`, one
    /// signed in to the other.
    private func harness(access: String) async throws -> (HTTPClient, TokenStore) {
        let name = "ApproverBearerTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let keys = SharedKeychain(service: name, accessGroup: nil)
        try SavedSignInStore(keychain: keys).saveIndex(SiloAccountIndex())
        let tokens = TokenStore(keychain: keys, defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: Self.active)
        await tokens.setServerUrl("https://active.example")
        try await signIn(account: "1", access: Self.token("active", expiresIn: 3600), refresh: "r",
                         origin: "https://active.example", in: tokens)
        try await install(access: access, refresh: "refresh-1", in: tokens)
        return (HTTPClient(session: stub.makeSession(), tokenStore: tokens), tokens)
    }

    /// Signs the other server's account in, or refreshes its sign-in, then
    /// returns to the active server.
    private func install(access: String, refresh: String, in tokens: TokenStore,
                         origin: String = "https://other.example") async throws {
        await tokens.setServerUrl(origin)
        await tokens.switchActiveServer(serverId: Self.other)
        try await signIn(account: "7", access: access, refresh: refresh, origin: origin, in: tokens)
        await tokens.setServerUrl("https://active.example")
        await tokens.switchActiveServer(serverId: Self.active)
    }

    private func signIn(account: String, access: String, refresh: String, origin: String,
                        in tokens: TokenStore) async throws {
        let identity = await tokens.refreshAccountIdentity()
        let expected = try XCTUnwrap(identity)
        try await tokens.installSignIn(accessToken: access, refreshToken: refresh,
            account: SignInAccount(id: account, username: nil), origin: origin, expected: expected)
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

    /// A slot this path can't renew (a legacy record with only an access
    /// token) hands out its bearer only while it is valid; an expired one
    /// asks for a fresh sign-in.
    func testUnrenewableSlotNeverReleasesAnExpiredBearer() async throws {
        let name = "ApproverBearerTests.legacy.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { UserDefaults().removePersistentDomain(forName: name) }
        let keys = SharedKeychain(service: name, accessGroup: nil)
        let tokens = TokenStore(keychain: keys, defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: Self.active)
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let legacy = keys.withAudience(.userIndependent)

        let valid = Self.token("valid", expiresIn: 3600)
        legacy.set(valid, for: TokenStore.accessTokenKey(for: Self.other))
        var bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .token(valid))

        legacy.set(Self.token("expired", expiresIn: -60), for: TokenStore.accessTokenKey(for: Self.other))
        bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .rejected)
        XCTAssertTrue(refreshes.isEmpty)
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

    /// Two accounts on the active server, the first selected: the second,
    /// expired, renews its own saved sign-in once, at that server's address,
    /// and keeps the rotated pair without touching the selection.
    func testANonCurrentAccountOnTheActiveServerRenewsItsOwnSignIn() async throws {
        let (http, tokens, current, second) = try await twoAccountsOnTheActiveServer()
        let selectedBefore = await tokens.getAccessToken()
        let fresh = Self.token("fresh", expiresIn: 3600)
        stub.reply(path: Self.refreshPath, 200, Self.refreshed(fresh))

        let bearer = await http.freshAccessToken(for: .signIn(second))
        XCTAssertEqual(bearer, .token(fresh))
        XCTAssertEqual(refreshes.count, 1)
        let request = try XCTUnwrap(refreshes.first)
        XCTAssertEqual(request.url?.host, "active.example")
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(body, ["refresh_token": "refresh-1"])
        let stored = await tokens.backgroundSignInSession(for: second)
        XCTAssertEqual(stored?.accessToken, fresh)
        XCTAssertEqual(stored?.refreshToken, "refresh-2")

        let selected = await tokens.currentAccount()
        XCTAssertEqual(selected, .signIn(current))
        let selectedAfter = await tokens.getAccessToken()
        XCTAssertEqual(selectedAfter, selectedBefore)
        let selectedSession = await tokens.backgroundSignInSession(for: current)
        XCTAssertNil(selectedSession, "the selected sign-in rotates through the shared refresh flight")
    }

    /// The second account was signed in again while its renewal was in
    /// flight: the newer session stays, and the rotated pair is dropped.
    func testANonCurrentAccountsRenewalNeverOverwritesASignInThatChanged() async throws {
        let (http, tokens, current, second) = try await twoAccountsOnTheActiveServer()
        stub.reply(path: Self.refreshPath, 200, Self.refreshed(Self.token("rotated", expiresIn: 3600)))
        stub.hold(path: Self.refreshPath)
        let pending = Task { await http.freshAccessToken(for: .signIn(second)) }
        await stub.waitUntilHeld()
        let newer = Self.token("newer", expiresIn: 3600)
        try await signIn(account: "2", access: newer, refresh: "refresh-newer", origin: "https://active.example", in: tokens)
        await tokens.select(serverID: Self.active, credential: .signIn(current))
        stub.release()

        let bearer = await pending.value
        XCTAssertEqual(bearer, .unreachable, "the bearer the refresh was sent for had expired")
        let stored = await tokens.backgroundSignInSession(for: second)
        XCTAssertEqual(stored?.accessToken, newer)
        XCTAssertEqual(stored?.refreshToken, "refresh-newer")
    }

    /// The account was selected while its renewal ran: the server spent the
    /// old refresh token, so the rotated pair is kept, for the stored item
    /// and for the credentials the app now uses.
    func testARenewalThatFinishesAfterTheAccountIsSelectedIsKept() async throws {
        let (http, tokens, _, second) = try await twoAccountsOnTheActiveServer()
        let rotated = Self.token("rotated", expiresIn: 3600)
        stub.reply(path: Self.refreshPath, 200, Self.refreshed(rotated))
        stub.hold(path: Self.refreshPath)
        let pending = Task { await http.freshAccessToken(for: .signIn(second)) }
        await stub.waitUntilHeld()
        await tokens.select(serverID: Self.active, credential: .signIn(second))
        stub.release()

        let bearer = await pending.value
        XCTAssertEqual(bearer, .token(rotated))
        let active = await tokens.getAccessToken(for: Self.active)
        XCTAssertEqual(active, rotated)
    }

    /// The selected account's own refresh doesn't send a token an approver
    /// renewal started before the switch is already spending: it waits for
    /// that renewal and uses its rotated pair.
    func testTheSelectedRefreshJoinsAnApproverRenewalOfTheSameToken() async throws {
        let (_, tokens, _, second) = try await twoAccountsOnTheActiveServer()
        let joins = JoinRecorder()
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens,
                              refreshFlightJoinObserver: { joins.record($0) })
        let rotated = Self.token("rotated", expiresIn: 3600)
        stub.reply(path: Self.refreshPath, 200, Self.refreshed(rotated))
        stub.hold(path: Self.refreshPath)
        let approver = Task { await http.freshAccessToken(for: .signIn(second)) }
        await stub.waitUntilHeld()
        await tokens.select(serverID: Self.active, credential: .signIn(second))
        let selected = Task { await http.freshAccessToken(serverId: Self.active) }
        for _ in 0..<300 where joins.count == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(joins.count, 1, "the selected refresh joined the approver renewal")
        stub.release()

        let approverBearer = await approver.value
        let selectedBearer = await selected.value
        XCTAssertEqual(approverBearer, .token(rotated))
        XCTAssertEqual(selectedBearer, .token(rotated))
        XCTAssertEqual(refreshes.count, 1, "refresh-1 was sent once")
    }

    /// The harness plus a second account on the active server, expired,
    /// with the first account selected again.
    private func twoAccountsOnTheActiveServer() async throws -> (HTTPClient, TokenStore, SignInKey, SignInKey) {
        let (http, tokens) = try await harness(access: Self.token("other", expiresIn: 3600))
        let current = SignInKey.make(Self.active, "1")
        try await signIn(account: "2", access: Self.token("old", expiresIn: -60), refresh: "refresh-1",
                         origin: "https://active.example", in: tokens)
        await tokens.select(serverID: Self.active, credential: .signIn(current))
        return (http, tokens, current, SignInKey.make(Self.active, "2"))
    }

    /// A stored session bound to another origin than the address its slot
    /// is keyed by is never released to approve a device: not from an
    /// inactive slot, and not from the active one.
    func testASessionBoundElsewhereIsNeverReleased() async throws {
        let (http, tokens) = try await harness(access: Self.token("fresh", expiresIn: 3600))
        try await install(access: Self.token("elsewhere", expiresIn: 3600), refresh: "r", in: tokens,
                          origin: "https://elsewhere.example")
        var bearer = await http.freshAccessToken(serverId: Self.other)
        XCTAssertEqual(bearer, .rejected)
        let otherAccess = await tokens.getAccessToken(for: Self.other)
        XCTAssertNil(otherAccess)
        let otherSession = await tokens.inactiveServerSession(for: Self.other)
        XCTAssertNil(otherSession)

        // The active sign-in: its session is bound to the active URL, which
        // is not the address its id names.
        await tokens.setServerUrl("https://elsewhere.example")
        try await signIn(account: "1", access: Self.token("active", expiresIn: 3600), refresh: "r",
                         origin: "https://elsewhere.example", in: tokens)
        bearer = await http.freshAccessToken(serverId: Self.active)
        XCTAssertEqual(bearer, .rejected)
        let activeAccess = await tokens.getAccessToken(for: Self.active)
        XCTAssertNil(activeAccess)
        XCTAssertTrue(refreshes.isEmpty, "nothing was sent anywhere")
    }
}

/// Counts refresh-flight joins (`HTTPClient.refreshFlightJoinObserver`).
private final class JoinRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var joins = 0

    var count: Int { lock.withLock { joins } }

    func record(_ kind: RefreshFlightJoinKind) {
        lock.withLock { joins += 1 }
    }
}
