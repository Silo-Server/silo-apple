import Foundation
import XCTest
@testable import Silo

/// The reachability probe asks the active server for its public health
/// endpoint without credentials, so a dead session cannot make a live server
/// look unreachable or start a token refresh.
final class ConnectionMonitorProbeTests: XCTestCase {
    private static let serverURL = "https://probe.example"

    private func client(_ stub: StubURLProtocol.Handler) async throws -> HTTPClient {
        let name = "ConnectionMonitorProbeTests.\(UUID().uuidString)"
        let suite = try XCTUnwrap(UserDefaults(suiteName: name))
        let tokens = TokenStore(keychain: SharedKeychain(service: name, accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite))
        addTeardownBlock {
            _ = await tokens.clearTokens()
            UserDefaults().removePersistentDomain(forName: name)
            await MainActor.run { ConnectionMonitor.shared.noteServerResponded() }
        }
        await tokens.switchActiveServer(serverId: "server")
        await tokens.setServerUrl(Self.serverURL)
        await tokens.setProfileId("profile")
        await tokens.setProfileToken("profile-token")
        let saved = await tokens.saveTokens(accessToken: "expired", refreshToken: "revoked")
        XCTAssertTrue(saved)
        return HTTPClient(session: stub.makeSession(), tokenStore: tokens)
    }

    @MainActor
    private var status: ConnectionMonitor.ServerStatus { ConnectionMonitor.shared.serverStatus }

    func testProbeSendsNoCredentialsAndMarksTheServerReachable() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.method("GET", path: ConnectionMonitor.healthPath)) { request in
            // A dead session would answer 401 on any authenticated request.
            request.header("Authorization") == nil ? .json(#"{"status":"ok"}"#) : .status(401)
        }
        let http = try await client(stub)
        await MainActor.run { ConnectionMonitor.shared.noteServerUnreachable() }

        let healthy = await ConnectionMonitor.shared.probeServer(using: http)

        XCTAssertTrue(healthy)
        let current = await status
        XCTAssertEqual(current, .reachable)
        XCTAssertEqual(stub.requests.map(\.path), [ConnectionMonitor.healthPath], "no refresh attempt")
        let probe = try XCTUnwrap(stub.requests.first)
        XCTAssertEqual(probe.url?.host, "probe.example")
        XCTAssertNil(probe.header("Authorization"))
        XCTAssertNil(probe.header("X-Profile-Id"))
        XCTAssertNil(probe.header("X-Profile-Token"))
    }

    func testTransportFailureMarksTheServerUnreachable() async throws {
        let stub = StubURLProtocol.Handler()
        stub.route(StubURLProtocol.path(ConnectionMonitor.healthPath)) { _ in
            throw URLError(.cannotConnectToHost)
        }
        let http = try await client(stub)
        await MainActor.run { ConnectionMonitor.shared.noteServerResponded() }

        let healthy = await ConnectionMonitor.shared.probeServer(using: http)

        XCTAssertFalse(healthy)
        let current = await status
        XCTAssertEqual(current, .unreachable)
    }
}
