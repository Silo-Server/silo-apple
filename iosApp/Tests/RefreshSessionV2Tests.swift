import Foundation
import XCTest
@testable import Silo

/// Token refresh runs on `POST /api/v2/auth/refresh` for both the ordinary
/// and the captured-identity (scoped) request paths. Only a rejected
/// credential ends the session; an update-required answer keeps it and
/// surfaces the update instead of the request's 401.
final class RefreshSessionV2Tests: XCTestCase {
    private static let serverId = "server"
    private static let serverURL = "https://refresh.example"
    private static let resourcePath = "/resource"
    private static let rotatedTokens = #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}"#
    private static let upgradeProblem = """
    {"type":"https://siloserver.org/docs/api/v2/problems/client_upgrade_required",
     "title":"Client upgrade required","status":410,"detail":"This client version is no longer supported."}
    """

    private enum Flow: CaseIterable {
        case ordinary
        case scoped
    }

    private struct Harness {
        let tokens: TokenStore
        let http: HTTPClient
        let stub: StubURLProtocol.Handler
        let identity: HTTPRequestIdentity

        func send(_ flow: Flow) async throws -> HTTPRawResponse {
            switch flow {
            case .ordinary:
                try await http.requestData(method: "GET", path: RefreshSessionV2Tests.resourcePath)
            case .scoped:
                try await http.requestData(
                    method: "GET",
                    path: RefreshSessionV2Tests.resourcePath,
                    requestIdentity: identity
                )
            }
        }
    }

    /// The resource answers 401 until it sees the rotated bearer; the refresh
    /// route answers `refresh`.
    private func harness(refresh: StubURLProtocol.Response) async throws -> Harness {
        let name = "RefreshSessionV2Tests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: Self.serverId)
        await tokens.setServerUrl(Self.serverURL)
        await tokens.setProfileId("profile")
        let saved = await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)

        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("POST", path: HTTPClient.refreshPath)) { _ in refresh }
        stub.route(StubURLProtocol.path(Self.resourcePath)) { request in
            request.header("Authorization") == "Bearer new-access" ? .json("{}") : .status(401)
        }
        let identity = HTTPRequestIdentity(serverId: Self.serverId, serverURL: Self.serverURL,
            profileId: "profile", clientFamily: "mobile")
        return Harness(tokens: tokens, http: HTTPClient(session: stub.makeSession(), tokenStore: tokens),
            stub: stub, identity: identity)
    }

    private func observeSessionExpiry() -> (count: ExpiryCounter, token: NSObjectProtocol) {
        let count = ExpiryCounter()
        let token = NotificationCenter.default.addObserver(forName: .siloSessionExpired, object: nil,
            queue: nil) { _ in count.increment() }
        return (count, token)
    }

    // MARK: Success

    func testUnauthorizedRequestRefreshesThroughV2AndRetries() async throws {
        for flow in Flow.allCases {
            let h = try await harness(refresh: .json(Self.rotatedTokens))

            let response = try await h.send(flow)

            XCTAssertEqual(response.statusCode, 200, "\(flow)")
            XCTAssertEqual(h.stub.requests.map(\.path),
                [Self.resourcePath, "/api/v2/auth/refresh", Self.resourcePath], "\(flow)")
            let refresh = h.stub.requests[1]
            XCTAssertEqual(refresh.method, "POST")
            XCTAssertNil(refresh.header("Authorization"), "refreshSession is public")
            XCTAssertNil(refresh.header("X-Profile-Id"), "refreshSession is public")
            let body = try XCTUnwrap(refresh.body)
            XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: String],
                ["refresh_token": "refresh"], "\(flow)")
            let access = await h.tokens.getAccessToken()
            let rotated = await h.tokens.getRefreshToken()
            XCTAssertEqual(access, "new-access", "\(flow)")
            XCTAssertEqual(rotated, "new-refresh", "\(flow)")
        }
    }

    // MARK: Failure classification

    /// 400, 401 and 403 reject the credential and end the session. Everything
    /// else keeps it: 422 (a body the contract refused; the client never
    /// sends a blank token), a 410 that is not an upgrade answer, and
    /// retryable statuses. The request keeps its original 401 either way.
    func testRefreshRejectionEndsTheSessionOnlyForCredentialStatuses() async throws {
        let (expiry, observer) = observeSessionExpiry()
        defer { NotificationCenter.default.removeObserver(observer) }
        let cases: [(Int, String, Bool)] = [
            (400, "malformed_request", true),
            (401, "session_expired", true),
            (401, "invalid_token", true),
            (403, "forbidden", true),
            (422, "validation_failed", false),
            (410, "playback_session_ended", false),
            (429, "rate_limited", false),
            (503, "service_unavailable", false),
        ]
        for flow in Flow.allCases {
            for (status, type, terminal) in cases {
                let name = "\(flow) \(status) \(type)"
                let problem = #"{"type":"https://siloserver.org/docs/api/v2/problems/\#(type)","title":"t","status":\#(status)}"#
                let h = try await harness(refresh: .json(problem, status: status,
                    headers: ["Content-Type": "application/problem+json"]))
                let expiredBefore = expiry.value

                do {
                    _ = try await h.send(flow)
                    XCTFail("expected the original 401: \(name)")
                } catch {
                    XCTAssertEqual((error as? HTTPError)?.statusCode, 401, name)
                }

                XCTAssertEqual(h.stub.requests.map(\.path), [Self.resourcePath, "/api/v2/auth/refresh"], name)
                let access = await h.tokens.getAccessToken()
                let refresh = await h.tokens.getRefreshToken()
                if terminal {
                    XCTAssertNil(access, name)
                    XCTAssertNil(refresh, name)
                    XCTAssertEqual(expiry.value, expiredBefore + 1, name)
                } else {
                    XCTAssertEqual(access, "access", name)
                    XCTAssertEqual(refresh, "refresh", name)
                    XCTAssertEqual(expiry.value, expiredBefore, name)
                }
            }
        }
    }

    // MARK: Update required

    func testUpgradeAnswerKeepsTheSessionAndSurfacesTheUpdate() async throws {
        let (expiry, observer) = observeSessionExpiry()
        defer { NotificationCenter.default.removeObserver(observer) }
        let replies: [(String, StubURLProtocol.Response)] = [
            ("problem document", .json(Self.upgradeProblem, status: 410,
                headers: ["Content-Type": "application/problem+json"])),
            ("v1 envelope", .json(#"{"error":"client_upgrade_required","message":"Upgrade required"}"#, status: 410)),
        ]
        for flow in Flow.allCases {
            for (shape, reply) in replies {
                let name = "\(flow) \(shape)"
                let h = try await harness(refresh: reply)

                do {
                    _ = try await h.send(flow)
                    XCTFail("expected the update to surface: \(name)")
                } catch {
                    XCTAssertEqual(UpdateRequirement(error), .app, name)
                    XCTAssertEqual(error.localizedDescription, UpdateRequirement.appMessage, name)
                }

                XCTAssertEqual(h.stub.requests.map(\.path), [Self.resourcePath, "/api/v2/auth/refresh"], name)
                let access = await h.tokens.getAccessToken()
                let refresh = await h.tokens.getRefreshToken()
                XCTAssertEqual(access, "access", name)
                XCTAssertEqual(refresh, "refresh", name)
            }
        }
        XCTAssertEqual(expiry.value, 0)
    }

    /// A v1-only server answers the v2 refresh route with Go's plain 404. That
    /// proves the server needs an update: the verdict is recorded for the
    /// active server and the saved session stays.
    @MainActor
    func testLegacyNotFoundRecordsServerUpdateAndKeepsTheSession() async throws {
        let monitor = ConnectionMonitor.shared
        let previousProvider = monitor.activeServerIdProvider
        monitor.activeServerIdProvider = { Self.serverId }
        monitor.resetContractStatus()
        defer {
            monitor.resetContractStatus()
            monitor.activeServerIdProvider = previousProvider
        }
        let (expiry, observer) = observeSessionExpiry()
        defer { NotificationCenter.default.removeObserver(observer) }

        for flow in Flow.allCases {
            monitor.resetContractStatus()
            let h = try await harness(refresh: .text("404 page not found\n", status: 404))

            do {
                _ = try await h.send(flow)
                XCTFail("expected the update to surface: \(flow)")
            } catch {
                XCTAssertEqual(UpdateRequirement(error), .server, "\(flow)")
                XCTAssertEqual(ErrorState(error).message, UpdateRequirement.serverMessage, "\(flow)")
            }

            XCTAssertTrue(monitor.isServerUpdateRequired, "\(flow)")
            let access = await h.tokens.getAccessToken()
            let refresh = await h.tokens.getRefreshToken()
            XCTAssertEqual(access, "access", "\(flow)")
            XCTAssertEqual(refresh, "refresh", "\(flow)")
        }
        XCTAssertEqual(expiry.value, 0)
    }

    /// Another service's 404 on the refresh route is not update evidence.
    @MainActor
    func testOtherNotFoundIsNotUpdateEvidence() async throws {
        let monitor = ConnectionMonitor.shared
        let previousProvider = monitor.activeServerIdProvider
        monitor.activeServerIdProvider = { Self.serverId }
        monitor.resetContractStatus()
        defer {
            monitor.resetContractStatus()
            monitor.activeServerIdProvider = previousProvider
        }
        let h = try await harness(refresh: .text("<h1>404 page not found</h1>", status: 404, contentType: "text/html"))

        do {
            _ = try await h.send(.ordinary)
            XCTFail("expected the original 401")
        } catch {
            XCTAssertEqual((error as? HTTPError)?.statusCode, 401)
            XCTAssertNil(UpdateRequirement(error))
        }
        XCTAssertFalse(monitor.isServerUpdateRequired)
        let access = await h.tokens.getAccessToken()
        XCTAssertEqual(access, "access")
    }
}

private final class ExpiryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int { lock.withLock { count } }

    func increment() { lock.withLock { count += 1 } }
}
