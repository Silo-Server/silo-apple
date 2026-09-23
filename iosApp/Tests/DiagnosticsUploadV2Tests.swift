#if os(iOS) || os(tvOS)
import Foundation
import XCTest
@testable import Silo

private let reportsPath = "/api/v2/diagnostics/reports"
private let uploadsPath = "/api/v2/diagnostics/reports/uploads"

/// Self-hosted report uploads through the v2 routes: the wire shape of the
/// single-shot and chunked uploads, how answers map onto upload errors
/// (status-only for the 400s v2 folds together), and which failures count as
/// uncertain for the `non_retryable` requests.
final class DiagnosticsUploadV2Tests: XCTestCase {
    private static let serverID = "server-diagnostics-upload"
    private let stub = DiagnosticsUploadStub()
    private var tokens: TokenStore!

    // MARK: - Answer mapping

    private func problem(_ status: Int, _ type: String) -> APIv2Error {
        .problem(APIv2Problem(type: "https://siloserver.org/docs/api/v2/problems/\(type)", title: "t",
                              status: status, detail: "d", instance: nil, errors: nil))
    }

    func testFoldedBadRequestKeepsTheReportWithoutRetry() {
        // unsupported_schema, stale_consent, destination and archive
        // mismatches all arrive as this one 400 today.
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(400, "malformed_request")), .serverRejected)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(422, "validation_failed")), .serverRejected)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(.httpStatus(400)), .serverRejected)
    }

    func testDistinctProblemTypesAreHonored() {
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(409, "capability_disabled")), .disabled)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(409, "capability_not_configured")), .storageUnavailable)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(400, "unsupported_schema")), .unsupportedSchema)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(400, "stale_consent")), .staleConsent)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(400, "destination_mismatch")), .destinationMismatch)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(400, "archive_mismatch")), .archiveMismatch)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(400, "invalid_bundle")), .invalidBundle)
    }

    func testSizeRateAndCapacityAnswersKeepTheirHandling() {
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(413, "payload_too_large")), .tooLarge)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(429, "rate_limited")), .quotaExceeded)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(503, "dependency_unavailable")), .busy)
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(500, "internal_error")), .retryable("http_500"))
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(problem(403, "permission_denied")), .underlying("http_403"))
    }

    func testA413WithoutAProblemDocumentCameFromAProxy() {
        // nginx answers with an HTML page; Silo always sends problem+json.
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(.httpStatus(413)), .requestBlockedByProxy)
    }

    func testV1OnlyServerNeedsAnUpdate() {
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(.serverUpdateRequired), .unsupportedSchema)
    }

    func testUnansweredNonRetryableRequestIsUncertain() {
        XCTAssertEqual(DiagnosticsAPI.nonRetryableFailure(
            HTTPError.network(underlying: URLError(.networkConnectionLost))), .deliveryUncertain)
        XCTAssertEqual(DiagnosticsAPI.nonRetryableFailure(
            HTTPError.network(underlying: URLError(.timedOut))), .deliveryUncertain)
        XCTAssertEqual(DiagnosticsAPI.nonRetryableFailure(HTTPError.authorityChanged), .deliveryUncertain)
        XCTAssertEqual(DiagnosticsAPI.nonRetryableFailure(
            APIv2DiagnosticsUnexpectedResponse(status: 200)), .deliveryUncertain)
    }

    func testTransportFailureBeforeConnectingIsDefinite() {
        XCTAssertEqual(DiagnosticsAPI.nonRetryableFailure(
            HTTPError.network(underlying: URLError(.cannotConnectToHost))), .retryable("cannot_connect_to_host"))
        XCTAssertEqual(DiagnosticsAPI.nonRetryableFailure(
            HTTPError.network(underlying: URLError(.notConnectedToInternet))), .retryable("not_connected_to_internet"))
    }

    // MARK: - Decoding

    func testStatusDecodesUploadChunkBytes() throws {
        let status = try HTTPClient.makeJSONDecoder().decode(APIv2DiagnosticsCapabilities.self, from: Data("""
        {
          "revision": "r1",
          "state": "available",
          "allowed": true,
          "status": "available",
          "server_instance_id": "srv_123",
          "accepted_schema_versions": [1],
          "max_bundle_bytes": 10485760,
          "max_manifest_bytes": 65536,
          "retention_days": 30,
          "consent_notice_version": 1,
          "upload_chunk_bytes": 786432
        }
        """.utf8)).statusResponse
        XCTAssertEqual(status.uploadChunkBytes, 786_432)
        XCTAssertTrue(status.supportsChunkedUpload)
    }

    func testStatusSnapshotWithoutChunkFieldDecodes() throws {
        // Snapshots persisted from servers that predate chunked uploads omit
        // upload_chunk_bytes; decoding must not fail and chunking must read
        // as unsupported.
        let status = try HTTPClient.makeJSONDecoder().decode(DiagnosticsStatusResponse.self, from: Data("""
        {
          "status": "available",
          "server_instance_id": "srv_123",
          "accepted_schema_versions": [1],
          "max_bundle_bytes": 10485760,
          "max_manifest_bytes": 65536,
          "retention_days": 30,
          "consent_notice_version": 1
        }
        """.utf8))
        XCTAssertNil(status.uploadChunkBytes)
        XCTAssertFalse(status.supportsChunkedUpload)
    }

    // MARK: - Single-shot upload

    private func makeAPI() async throws -> (DiagnosticsAPI, CapturedOrdinaryRequestAuth) {
        let name = "DiagnosticsUploadV2Tests.\(UUID().uuidString)"
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
        await tokens.setProfileId("7")
        self.tokens = tokens
        stub.tokens = tokens
        let client = APIv2Client(http: HTTPClient(session: stub.handler.makeSession(), tokenStore: tokens),
            tokenStore: tokens, isUpdateRequired: { false })
        let api = DiagnosticsAPI(client: client)
        return (api, try await api.captureOwner())
    }

    func testUploadSendsManifestThenBundleAsMultipart() async throws {
        stub.reset(chunkBytes: 4)
        let (api, owner) = try await makeAPI()

        let response = try await api.upload(
            manifestData: Data(#"{"schema_version":1}"#.utf8),
            bundleData: Data("bundle-bytes".utf8),
            auth: owner
        )

        XCTAssertEqual(response, DiagnosticsUploadResponse(reportId: "report-1", shortId: "SILO-SINGLE"))
        let request = try XCTUnwrap(stub.handler.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, reportsPath)
        XCTAssertEqual(request.header("X-Profile-Id"), "7")
        XCTAssertTrue(request.header("Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = try XCTUnwrap(request.bodyString)
        let manifest = try XCTUnwrap(body.range(of: #"name="manifest"; filename="manifest.json""#))
        let bundle = try XCTUnwrap(body.range(of: #"name="bundle"; filename="bundle.tar.gz""#))
        XCTAssertLessThan(manifest.lowerBound, bundle.lowerBound, "the manifest part must come first")
    }

    func testUploadWithAFoldedBadRequestIsServerRejected() async throws {
        stub.reset(chunkBytes: 4, upload: .json(
            #"{"type":"https://siloserver.org/docs/api/v2/problems/malformed_request","title":"Malformed request","status":400,"detail":"stale consent"}"#,
            status: 400, headers: ["Content-Type": "application/problem+json"]))
        let (api, owner) = try await makeAPI()

        do {
            _ = try await api.upload(manifestData: Data("{}".utf8), bundleData: Data("b".utf8), auth: owner)
            XCTFail("a 400 must not succeed")
        } catch let error as DiagnosticsUploadError {
            XCTAssertEqual(error, .serverRejected)
        }
    }

    func testUploadWithALostConnectionIsUncertain() async throws {
        stub.reset(chunkBytes: 4, uploadFailure: URLError(.networkConnectionLost))
        let (api, owner) = try await makeAPI()

        do {
            _ = try await api.upload(manifestData: Data("{}".utf8), bundleData: Data("b".utf8), auth: owner)
            XCTFail("a lost connection must not succeed")
        } catch let error as DiagnosticsUploadError {
            XCTAssertEqual(error, .deliveryUncertain)
        }
        XCTAssertEqual(stub.handler.requests.count, 1, "a non_retryable upload is sent once")
    }

    func testUploadIsRefusedBeforeDispatchAfterAnOwnerChange() async throws {
        stub.reset(chunkBytes: 4)
        let (api, owner) = try await makeAPI()
        await tokens.setProfileId("8")

        do {
            _ = try await api.upload(manifestData: Data("{}".utf8), bundleData: Data("b".utf8), auth: owner)
            XCTFail("a replaced owner must not upload")
        } catch let error as DiagnosticsUploadError {
            XCTAssertEqual(error, .retryable(DiagnosticsAPI.destinationChanged))
        }
        XCTAssertTrue(stub.handler.requests.isEmpty)
    }

    // MARK: - Chunked upload

    func testUploadChunkedSplitsSequentiallyAndCompletes() async throws {
        stub.reset(chunkBytes: 4)
        let (api, owner) = try await makeAPI()

        let bundle = Data("0123456789".utf8) // 10 bytes → chunks of 4/4/2
        let manifest = Data(#"{"schema_version":1,"report":{"b":1,"a":2}}"#.utf8)
        let response = try await api.uploadChunked(manifestData: manifest, bundleData: bundle, auth: owner)

        XCTAssertEqual(response.shortID, "SILO-TEST12345678")
        let state = stub.state()
        XCTAssertEqual(state.chunkBodies.map(\.count), [4, 4, 2])
        XCTAssertEqual(Data(state.chunkBodies.joined()), bundle, "reassembled chunks must equal the bundle")
        XCTAssertEqual(state.chunkIndexes, [0, 1, 2], "chunks must arrive in order")
        XCTAssertTrue(state.completed)
        XCTAssertFalse(state.aborted)
        // The create body embeds the manifest bytes verbatim.
        XCTAssertEqual(state.initBody, Data(#"{"bundle_bytes":10,"manifest":{"schema_version":1,"report":{"b":1,"a":2}}}"#.utf8))
        let chunk = try XCTUnwrap(stub.handler.requests.first { $0.method == "PUT" })
        XCTAssertEqual(chunk.header("Content-Type"), "application/octet-stream")
    }

    func testUploadChunkedAbortsSessionWhenAChunkFails() async throws {
        stub.reset(chunkBytes: 4, failChunkIndex: 1)
        let (api, owner) = try await makeAPI()

        do {
            _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8),
                                            auth: owner)
            XCTFail("uploadChunked should rethrow the failed chunk")
        } catch let error as DiagnosticsUploadError {
            XCTAssertEqual(error, .retryable("http_500"))
        }

        let state = stub.state()
        XCTAssertFalse(state.completed)
        XCTAssertTrue(state.aborted, "a failed upload must best-effort abort its session")
    }

    func testUploadChunkedFailsFastOnNonPositiveChunkBytes() async throws {
        // A zero/negative advertised chunk size must fail fast, not degrade
        // to 1-byte chunks (millions of PUTs for a real bundle).
        stub.reset(chunkBytes: 0)
        let (api, owner) = try await makeAPI()

        do {
            _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8),
                                            auth: owner)
            XCTFail("uploadChunked should reject chunk_bytes = 0")
        } catch let error as DiagnosticsUploadError {
            guard case .underlying = error else {
                return XCTFail("expected underlying for invalid chunk_bytes, got \(error)")
            }
        }

        let state = stub.state()
        XCTAssertTrue(state.chunkIndexes.isEmpty, "no chunk PUTs may be issued")
        XCTAssertFalse(state.completed)
        XCTAssertTrue(state.aborted, "the opened session should still be reclaimed")
    }

    func testUploadChunkedStopsWithoutAbortWhenTheOwnerChanges() async throws {
        // A profile switch after the first chunk: the remaining bundle bytes
        // must not be sent, and no abort may be issued (it would go to the
        // replacement owner).
        stub.reset(chunkBytes: 4, switchProfileAfterChunk: 0)
        let (api, owner) = try await makeAPI()

        do {
            _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8),
                                            auth: owner)
            XCTFail("uploadChunked should stop on an owner change")
        } catch let error as DiagnosticsUploadError {
            XCTAssertEqual(error, .retryable(DiagnosticsAPI.destinationChanged))
        }

        let state = stub.state()
        XCTAssertFalse(state.completed)
        XCTAssertFalse(state.aborted, "abort would target the new owner and must be skipped")
        XCTAssertFalse(stub.handler.requests.contains { $0.path.hasSuffix("/chunks/1") })
    }

    func testUnansweredCompleteIsUncertainAndLeavesTheSessionAlone() async throws {
        stub.reset(chunkBytes: 4, completeFailure: URLError(.timedOut))
        let (api, owner) = try await makeAPI()

        do {
            _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8),
                                            auth: owner)
            XCTFail("a lost complete must not succeed")
        } catch let error as DiagnosticsUploadError {
            XCTAssertEqual(error, .deliveryUncertain)
        }

        XCTAssertFalse(stub.state().aborted, "the report may already be ingested")
        XCTAssertEqual(stub.handler.requests.filter { $0.path.hasSuffix("/complete") }.count, 1)
    }

    func testAnsweredCompleteFailureAbortsTheSession() async throws {
        stub.reset(chunkBytes: 4, complete: .json(
            #"{"type":"https://siloserver.org/docs/api/v2/problems/malformed_request","title":"Malformed request","status":400,"detail":"archive mismatch"}"#,
            status: 400, headers: ["Content-Type": "application/problem+json"]))
        let (api, owner) = try await makeAPI()

        do {
            _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8),
                                            auth: owner)
            XCTFail("a rejected complete must not succeed")
        } catch let error as DiagnosticsUploadError {
            XCTAssertEqual(error, .serverRejected)
        }

        XCTAssertTrue(stub.state().aborted)
    }
}

/// The v2 diagnostics upload routes on the shared stub. `State` is what the
/// tests assert on; `reset` scopes it per test.
private final class DiagnosticsUploadStub: @unchecked Sendable {
    struct State {
        var chunkBytes = 4
        var initBody: Data?
        var chunkIndexes: [Int] = []
        var chunkBodies: [Data] = []
        var completed = false
        var aborted = false
    }

    let handler = StubURLProtocol.Handler()
    var tokens: TokenStore?
    private let lock = NSLock()
    private var current = State()

    func reset(
        chunkBytes: Int,
        failChunkIndex: Int? = nil,
        switchProfileAfterChunk: Int? = nil,
        upload: StubURLProtocol.Response? = nil,
        uploadFailure: URLError? = nil,
        complete: StubURLProtocol.Response? = nil,
        completeFailure: URLError? = nil
    ) {
        lock.withLock { current = State(chunkBytes: chunkBytes) }
        handler.reset()
        handler.route(StubURLProtocol.method("POST", path: reportsPath)) { _ in
            if let uploadFailure { throw uploadFailure }
            return upload ?? .json(#"{"report_id":"report-1","short_id":"SILO-SINGLE"}"#, status: 201)
        }
        handler.route(StubURLProtocol.method("POST", path: uploadsPath)) { [self] request in
            mutate { $0.initBody = request.body }
            return .json(#"{"upload_id":"stub-session","chunk_bytes":\#(chunkBytes),"total_chunks":3,"expires_at":"2026-01-01T00:00:00.000Z"}"#, status: 201)
        }
        handler.route({ $0.method == "PUT" && $0.path.hasPrefix("\(uploadsPath)/stub-session/chunks/") }) { [self] request in
            let index = Int(request.path.split(separator: "/").last ?? "") ?? -1
            if failChunkIndex == index {
                return .json(#"{"type":"https://siloserver.org/docs/api/v2/problems/internal_error","title":"Internal error","status":500,"detail":"stub"}"#,
                             status: 500, headers: ["Content-Type": "application/problem+json"])
            }
            mutate {
                $0.chunkIndexes.append(index)
                $0.chunkBodies.append(request.body ?? Data())
            }
            if switchProfileAfterChunk == index, let tokens {
                await tokens.setProfileId("switched")
            }
            return .json(#"{"received_chunks":\#(index + 1),"total_chunks":3}"#)
        }
        handler.route(StubURLProtocol.method("POST", path: "\(uploadsPath)/stub-session/complete")) { [self] _ in
            if let completeFailure { throw completeFailure }
            if let complete { return complete }
            mutate { $0.completed = true }
            return .json(#"{"report_id":"11111111-1111-1111-1111-111111111111","short_id":"SILO-TEST12345678"}"#, status: 201)
        }
        handler.route(StubURLProtocol.method("DELETE", path: "\(uploadsPath)/stub-session")) { [self] _ in
            mutate { $0.aborted = true }
            return .status(204)
        }
    }

    func state() -> State {
        lock.withLock { current }
    }

    private func mutate(_ apply: (inout State) -> Void) {
        lock.withLock { apply(&current) }
    }
}
#endif
