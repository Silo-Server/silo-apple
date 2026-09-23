import Foundation
import XCTest
@testable import Silo

/// A v1-only server and a server that refuses this app version must read as
/// "update", on every surface that explains a failed server call, and must
/// never cost the user their saved session.
final class UpdateRequirementTests: XCTestCase {
    static let upgradeProblem = """
    {"type":"https://siloserver.org/docs/api/v2/problems/client_upgrade_required",
     "title":"Client upgrade required","status":410,"detail":"This client version is no longer supported."}
    """
    static let sessionEndedProblem = """
    {"type":"https://siloserver.org/docs/api/v2/problems/playback_session_ended",
     "title":"Playback session ended","status":410,"detail":"Playback session has ended."}
    """
    static let legacyNotFound = "404 page not found\n"
    /// Any route the `HTTPClient` layer requests: its classification depends
    /// only on the reply, never on the path.
    static let httpLayerPath = "/probe"

    private func problem(_ json: String) throws -> APIv2Problem {
        try HTTPClient.makeJSONDecoder().decode(APIv2Problem.self, from: Data(json.utf8))
    }

    // MARK: Classification

    func testClassifiesBothRequestLayers() throws {
        let cases: [(String, Error, UpdateRequirement?)] = [
            ("v2 gate refusal", APIv2Error.serverUpdateRequired, .server),
            ("v2 upgrade problem", APIv2Error.problem(try problem(Self.upgradeProblem)), .app),
            ("v2 other 410 problem", APIv2Error.problem(try problem(Self.sessionEndedProblem)), nil),
            ("v2 bare 404", APIv2Error.httpStatus(404), nil),
            ("v1 upgrade problem", HTTPError.http(statusCode: 410, body: Self.upgradeProblem), .app),
            ("v1 other 410 problem", HTTPError.http(statusCode: 410, body: Self.sessionEndedProblem), nil),
            ("v1 upgrade envelope", HTTPError.http(statusCode: 410,
                body: #"{"error":"client_upgrade_required","message":"Update"}"#), .app),
            ("v1 410 envelope", HTTPError.http(statusCode: 410, body: #"{"error":"expired","message":"gone"}"#), nil),
            ("v1 bare 410", HTTPError.http(statusCode: 410, body: nil), nil),
            ("upgrade problem on another status", HTTPError.http(statusCode: 400, body: Self.upgradeProblem), nil),
            // A v1 path answering Go's 404 does not prove a v1-only Silo server.
            ("v1 legacy 404", HTTPError.http(statusCode: 404, body: Self.legacyNotFound), nil),
            ("transport", HTTPError.network(underlying: URLError(.cannotConnectToHost)), nil),
            ("cancellation", CancellationError(), nil),
        ]
        for (name, error, expected) in cases {
            XCTAssertEqual(UpdateRequirement(error), expected, name)
        }
    }

    // MARK: Wire

    func testV2ClientMapsLegacyNotFoundAndUpgradeProblem() async throws {
        let stub = APIv2TestStub()
        let client = APIv2Client(http: HTTPClient(session: stub.makeSession()), isUpdateRequired: { false })

        stub.reply(.text(404, Self.legacyNotFound, contentType: "text/plain; charset=utf-8"))
        do {
            _ = try await client.setupStatus(serverURL: "https://legacy.example")
            XCTFail("expected the legacy 404 to surface")
        } catch APIv2Error.serverUpdateRequired {}

        stub.reply(410, Self.upgradeProblem)
        do {
            _ = try await client.setupStatus(serverURL: "https://new.example")
            XCTFail("expected the 410 to surface")
        } catch {
            XCTAssertEqual(UpdateRequirement(error), .app)
            XCTAssertEqual(error.localizedDescription, UpdateRequirement.appMessage)
        }

        // Another service's 404 on a v2 path is an ordinary failure.
        stub.reply(.text(404, "<h1>404 page not found</h1>", contentType: "text/html"))
        do {
            _ = try await client.setupStatus(serverURL: "https://proxy.example")
            XCTFail("expected the 404 to surface")
        } catch APIv2Error.httpStatus(404) {}

        XCTAssertEqual(stub.requestedPaths, Array(repeating: "/api/v2/system/setup", count: 3), "no fallback")
    }

    /// The `HTTPClient` layer explains an upgrade 410 in either body shape
    /// the server documents for the v1 tombstone.
    func testHTTPClientUpgradeReplyExplainsItself() async throws {
        let replies: [(String, APIv2TestStub.Reply)] = [
            ("problem document", .json(410, Self.upgradeProblem)),
            ("v1 envelope", .response(.json(#"{"error":"client_upgrade_required","message":"Upgrade required"}"#,
                status: 410))),
        ]
        for (name, reply) in replies {
            let stub = APIv2TestStub(fallback: reply)
            do {
                let _: HealthStatus = try await HTTPClient(session: stub.makeSession())
                    .getUnauthenticated(serverURL: "https://new.example", path: Self.httpLayerPath)
                XCTFail("expected the 410 to surface: \(name)")
            } catch {
                XCTAssertEqual(UpdateRequirement(error), .app, name)
                XCTAssertEqual(error.localizedDescription, UpdateRequirement.appMessage, name)
                XCTAssertEqual(ErrorState(error).message, UpdateRequirement.appMessage, name)
            }
        }
    }

    /// Refresh stays 401-only: a 410 keeps the tokens and triggers no refresh.
    func testUpgradeProblemNeverRefreshesOrDropsTokens() async throws {
        let name = "UpdateRequirementTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { UserDefaults().removePersistentDomain(forName: name) }
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl("https://new.example")
        try await tokens.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "12")

        let stub = APIv2TestStub(fallback: .json(410, Self.upgradeProblem))
        let http = HTTPClient(session: stub.makeSession(), tokenStore: tokens)
        do {
            let _: AuthUser = try await http.get(Self.httpLayerPath)
            XCTFail("expected the HTTPClient 410 to surface")
        } catch {
            XCTAssertEqual(UpdateRequirement(error), .app)
        }
        do {
            _ = try await APIv2Client(http: http, tokenStore: tokens, isUpdateRequired: { false }).currentUser()
            XCTFail("expected the v2 410 to surface")
        } catch {
            XCTAssertEqual(UpdateRequirement(error), .app)
        }

        XCTAssertEqual(stub.requestedPaths, [Self.httpLayerPath, "/api/v2/account/me"], "no refresh attempt")
        let access = await tokens.getAccessToken()
        let refresh = await tokens.getRefreshToken()
        XCTAssertEqual(access, "access")
        XCTAssertEqual(refresh, "refresh")
    }

    // MARK: Error screen

    func testErrorStateShowsUpdateCopyInsteadOfGenericFailure() throws {
        let server = ErrorState(APIv2Error.serverUpdateRequired)
        XCTAssertEqual(server.updateRequirement, .server)
        XCTAssertEqual(server.message, UpdateRequirement.serverMessage)
        XCTAssertFalse(server.isTransient, "an old server is not retried as a blip")

        let app = ErrorState(HTTPError.http(statusCode: 410, body: Self.upgradeProblem))
        XCTAssertEqual(app.updateRequirement, .app)
        XCTAssertEqual(app.statusCode, 410)
        XCTAssertEqual(app.message, UpdateRequirement.appMessage)
        XCTAssertFalse(app.isAuthFailure)
        XCTAssertFalse(app.isNotFound)

        let other = ErrorState(HTTPError.http(statusCode: 410, body: nil))
        XCTAssertNil(other.updateRequirement)
        XCTAssertEqual(other.message, "Something went wrong while talking to the server.")
    }

    // MARK: Server add

    private enum CandidateReply {
        case legacyNotFound, upgradeProblem, htmlNotFound, unreachable
    }

    /// Runs the add-server flow against one stubbed reply per candidate
    /// scheme. The check goes through the real v2 setup read.
    @MainActor
    private func connect(replies: [String: CandidateReply]) async -> String? {
        let handler = StubURLProtocol.Handler()
        handler.route(StubURLProtocol.any) { request in
            let key = "\(request.url?.scheme ?? ""):\(request.url?.port ?? 0)"
            switch replies[key] ?? .unreachable {
            case .legacyNotFound:
                return .text(Self.legacyNotFound, status: 404, contentType: "text/plain; charset=utf-8")
            case .upgradeProblem:
                return .json(Self.upgradeProblem, status: 410, headers: ["Content-Type": "application/problem+json"])
            case .htmlNotFound:
                return .text("<h1>Not Found</h1>", status: 404, contentType: "text/html")
            case .unreachable:
                throw URLError(.cannotConnectToHost)
            }
        }
        let client = APIv2Client(http: HTTPClient(session: handler.makeSession()), isUpdateRequired: { false })
        let viewModel = ServerSetupViewModel(checkServer: { url in
            try await client.setupStatus(serverURL: url)
        })
        viewModel.host = "silo.example"
        await viewModel.connect(router: AppRouter())
        return viewModel.error
    }

    @MainActor
    func testServerAddExplainsVersionMismatchInsteadOfUnreachable() async {
        let unreachable = "Could not reach a Silo server at that address."
        let cases: [(String, [String: CandidateReply], String)] = [
            ("v1-only server", ["https:0": .legacyNotFound, "http:0": .legacyNotFound, "http:8090": .legacyNotFound],
             UpdateRequirement.serverMessage),
            ("v1-only behind one scheme", ["http:0": .legacyNotFound], UpdateRequirement.serverMessage),
            ("app too old", ["https:0": .upgradeProblem], UpdateRequirement.appMessage),
            ("proxy 404", ["https:0": .htmlNotFound], unreachable),
            ("nothing answers", [:], unreachable),
        ]
        for (name, replies, expected) in cases {
            let message = await connect(replies: replies)
            XCTAssertEqual(message, expected, name)
        }
    }
}
