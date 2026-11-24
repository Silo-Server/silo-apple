import Foundation
import XCTest
@testable import Silo

/// "Forgot password?" on the login screen: offered only when the server emails
/// reset links (`GET /api/v2/capabilities/password-reset`), and the request
/// (`POST /api/v2/password-resets`) goes out once, with no credentials.
@MainActor
final class ForgotPasswordTests: XCTestCase {
    private static let serverURL = "https://reset.example"
    private let stub = StubURLProtocol.Handler()

    private func makeClients(signedIn: Bool = false) async throws -> (APIv2Client, AuthService) {
        let name = "ForgotPasswordTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
        }
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl(Self.serverURL)
        if signedIn {
            try await tokens.installAccountSession(accessToken: "stale-access", refreshToken: "refresh", accountID: "1")
            await tokens.setProfileId("profile")
        }
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        let api = APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false })
        let auth = AuthService(launchPreferences: ProfileLaunchPreferences(defaults: SharedDefaults(suite: suite, standard: suite)),
            apiV2Client: api, httpClient: http, tokenStore: tokens)
        return (api, auth)
    }

    nonisolated private static func problem(_ identifier: String, status: Int) -> StubURLProtocol.Response {
        .json(#"{"type":"https://siloserver.org/docs/api/v2/problems/\#(identifier)","title":"t","status":\#(status),"detail":"d"}"#,
            status: status, headers: ["Content-Type": "application/problem+json"])
    }

    // MARK: Capability

    /// Only `available` offers the link. A server without the capability (a
    /// 404) never offers it; any other failed read is unknown, so a
    /// background refresh keeps what the screen already showed.
    func testOnlyAnAvailableCapabilityOffersTheLink() async throws {
        let (api, _) = try await makeClients()
        let cases: [(StubURLProtocol.Response, Bool?)] = [
            (.json(#"{"state":"available"}"#), true),
            (.json(#"{"state":"disabled"}"#), false),
            (.json(#"{"state":"not_configured"}"#), false),
            (Self.problem("not_found", status: 404), false),
            (Self.problem("internal_error", status: 500), nil),
        ]
        for (reply, expected) in cases {
            stub.reset()
            stub.route(StubURLProtocol.method("GET", path: APIv2Client.passwordResetCapabilityPath)) { _ in reply }
            let available = await api.passwordResetAvailable(serverURL: Self.serverURL)
            XCTAssertEqual(available, expected, "\(reply)")
        }
    }

    // MARK: Request

    /// A stale session from before sign-out must not ride along: the request
    /// is public, so it carries no bearer or profile header.
    func testRequestSendsTheTrimmedLoginOnceWithNoCredentials() async throws {
        stub.route(StubURLProtocol.method("POST", path: APIv2Client.passwordResetsPath)) { _ in .status(202) }
        let (_, auth) = try await makeClients(signedIn: true)
        let model = ForgotPasswordModel(login: "  alice@example.com ", auth: auth)

        await model.send()

        XCTAssertEqual(model.phase, .sent(login: "alice@example.com"))
        XCTAssertEqual(stub.requests.map(\.path), [APIv2Client.passwordResetsPath])
        let request = try XCTUnwrap(stub.requests.first)
        XCTAssertNil(request.header("Authorization"))
        XCTAssertNil(request.header("X-Profile-Id"))
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.body)) as? [String: String])
        XCTAssertEqual(body, ["login": "alice@example.com"])
    }

    func testEmptyLoginSendsNothing() async throws {
        let (_, auth) = try await makeClients()
        let model = ForgotPasswordModel(login: "   ", auth: auth)

        await model.send()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.error?.message, "Enter your username or email.")
        XCTAssertTrue(stub.requests.isEmpty)
    }

    /// An admin turned self-service reset off, or email stopped working,
    /// after the login screen read the capability.
    func testRefusedCapabilityPointsToTheAdmin() async throws {
        for identifier in ["capability_disabled", "capability_not_configured"] {
            stub.reset()
            stub.route(StubURLProtocol.method("POST", path: APIv2Client.passwordResetsPath)) { _ in
                Self.problem(identifier, status: 409)
            }
            let (_, auth) = try await makeClients()
            let model = ForgotPasswordModel(login: "alice", auth: auth)

            await model.send()

            XCTAssertEqual(model.phase, .unavailable, identifier)
            XCTAssertNil(model.error, identifier)
        }
    }

    func testRateLimitKeepsTheFormOpenToTryAgain() async throws {
        let request = StubURLProtocol.method("POST", path: APIv2Client.passwordResetsPath)
        stub.expect(request) { _ in Self.problem("rate_limited", status: 429) }
        stub.route(request) { _ in .status(202) }
        let (_, auth) = try await makeClients()
        let model = ForgotPasswordModel(login: "alice", auth: auth)

        await model.send()

        XCTAssertEqual(model.phase, .editing)
        XCTAssertEqual(model.error?.message, ForgotPasswordModel.rateLimitedMessage)

        await model.send()

        XCTAssertEqual(model.phase, .sent(login: "alice"))
        XCTAssertNil(model.error)
    }
}
