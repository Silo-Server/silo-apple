#if os(iOS) || os(tvOS)
import Foundation
import XCTest
@testable import Silo

private let capabilitiesPath = "/api/v2/diagnostics/capabilities"

/// Self-hosted diagnostics availability read from
/// `GET /api/v2/diagnostics/capabilities`: the status the coordinator stores,
/// and how failures feed the capture fallback and the settings screen.
final class DiagnosticsCapabilitiesV2Tests: XCTestCase {
    private static let serverID = "server-diagnostics-capabilities"
    /// StubURLProtocol holds handlers weakly; keep each one for the test.
    private var handlers: [StubURLProtocol.Handler] = []

    private func document(
        state: String = "available",
        allowed: Bool = true,
        status: String = "available",
        uploadChunkBytes: Int = 786_432
    ) -> String {
        #"{"revision":"r1","state":"\#(state)","allowed":\#(allowed),"status":"\#(status)","server_instance_id":"srv_123","accepted_schema_versions":[1],"max_bundle_bytes":10485760,"max_manifest_bytes":65536,"retention_days":30,"consent_notice_version":2,"upload_chunk_bytes":\#(uploadChunkBytes)}"#
    }

    private func makeClient(_ response: StubURLProtocol.Response) async throws -> (APIv2Client, StubURLProtocol.Handler) {
        let name = "DiagnosticsCapabilitiesV2Tests.\(UUID().uuidString)"
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
        let tokens = TokenStore(keychain: keychain, defaults: SharedDefaults(suite: suite, standard: suite))
        await tokens.switchActiveServer(serverId: Self.serverID)
        await tokens.setServerUrl("https://silo.example")
        let saved = await tokens.saveTokens(accessToken: "access", refreshToken: "refresh")
        XCTAssertTrue(saved)

        let handler = StubURLProtocol.Handler()
        handlers.append(handler)
        handler.route(StubURLProtocol.method("GET", path: capabilitiesPath)) { _ in response }
        let client = APIv2Client(http: HTTPClient(session: handler.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        return (client, handler)
    }

    private func problem(status: Int, type: String) -> StubURLProtocol.Response {
        .json(#"{"type":"https://silo.example/problems/\#(type)","title":"t","status":\#(status),"detail":"d"}"#,
              status: status, headers: ["Content-Type": "application/problem+json"])
    }

    func testReadsTheV2DocumentWithTheAccountScope() async throws {
        let (client, handler) = try await makeClient(.json(document()))

        let status = try await client.diagnosticsCapabilities()

        XCTAssertEqual(status, DiagnosticsStatusResponse(
            status: .available,
            serverInstanceId: "srv_123",
            acceptedSchemaVersions: [1],
            maxBundleBytes: 10_485_760,
            maxManifestBytes: 65_536,
            retentionDays: 30,
            consentNoticeVersion: 2,
            uploadChunkBytes: 786_432
        ))
        XCTAssertTrue(status.supportsChunkedUpload)
        let request = try XCTUnwrap(handler.requests.first)
        XCTAssertEqual(handler.requests.count, 1)
        XCTAssertEqual(request.header("Authorization"), "Bearer access")
    }

    func testAvailabilityRequiresAllowedAndAvailableState() async throws {
        let cases: [(state: String, allowed: Bool, status: String, expected: DiagnosticsAvailabilityStatus)] = [
            ("available", false, "available", .disabled),
            ("disabled", false, "disabled", .disabled),
            ("not_configured", false, "storage_unavailable", .storageUnavailable),
            ("unsupported", false, "available", .disabled),
        ]
        for testCase in cases {
            let (client, _) = try await makeClient(.json(document(
                state: testCase.state, allowed: testCase.allowed, status: testCase.status
            )))
            let status = try await client.diagnosticsCapabilities()
            XCTAssertEqual(status.status, testCase.expected, "state \(testCase.state)")
            XCTAssertFalse(DiagnosticsCoordinator.canBeginUpload(status: status.status))
        }
    }

    func testZeroChunkBytesMeansNoChunkedUpload() async throws {
        let (client, _) = try await makeClient(.json(document(uploadChunkBytes: 0)))

        let status = try await client.diagnosticsCapabilities()

        XCTAssertFalse(status.supportsChunkedUpload)
    }

    func testServerFailureAllowsTheCaptureFallbackButARefusalDoesNot() async throws {
        let (unavailable, _) = try await makeClient(problem(status: 503, type: "service_unavailable"))
        do {
            _ = try await unavailable.diagnosticsCapabilities()
            XCTFail("expected a problem")
        } catch {
            XCTAssertTrue(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(error), "\(error)")
        }

        let (forbidden, _) = try await makeClient(problem(status: 403, type: "forbidden"))
        do {
            _ = try await forbidden.diagnosticsCapabilities()
            XCTFail("expected a problem")
        } catch {
            XCTAssertFalse(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(error), "\(error)")
        }
    }

    func testLegacyListenerReadsAsServerUpdateRequired() async throws {
        let (client, _) = try await makeClient(.text(APIv2Probe.legacyNotFoundBody + "\n", status: 404))

        do {
            _ = try await client.diagnosticsCapabilities()
            XCTFail("expected serverUpdateRequired")
        } catch APIv2Error.serverUpdateRequired {
            XCTAssertFalse(DiagnosticsCoordinator.isTransientCaptureFallbackFailure(APIv2Error.serverUpdateRequired))
        }
    }
}
#endif
