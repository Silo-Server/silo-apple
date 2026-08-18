import XCTest
@testable import Silo

final class DiagnosticsChunkedUploadTests: XCTestCase {
    // MARK: - Bare-413 classification (the proxy body-cap bug)

    func testBare413MapsToRequestBlockedByProxy() {
        // An intermediary's 413 carries no Silo JSON envelope (nginx returns
        // an HTML error page) and must be distinguished from Silo's own
        // `too_large` verdict so the client can fall back to chunking.
        let proxyError = HTTPError.http(
            statusCode: 413,
            body: "<html><head><title>413 Request Entity Too Large</title></head></html>"
        )
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(proxyError), .requestBlockedByProxy)
    }

    func testJSON413FromNonSiloProxyStillMapsToRequestBlockedByProxy() {
        // Some proxies emit JSON error envelopes. Any 413 whose code is not
        // Silo's own `too_large` still came from an intermediary and must
        // trigger the chunked fallback rather than mapping to `.underlying`.
        let jsonProxyError = HTTPError.http(
            statusCode: 413,
            body: #"{"error":"request_too_large","message":"body exceeds limit"}"#
        )
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(jsonProxyError), .requestBlockedByProxy)
    }

    func testSilo413StillMapsToTooLarge() {
        let siloError = HTTPError.http(
            statusCode: 413,
            body: #"{"error":"too_large","message":"Diagnostics upload is too large"}"#
        )
        XCTAssertEqual(DiagnosticsAPI.mapUploadError(siloError), .tooLarge)
    }

    func testBodylessProxy413StillMapsToRequestBlockedByProxy() {
        XCTAssertEqual(
            DiagnosticsAPI.mapUploadError(HTTPError.http(statusCode: 413, body: nil)),
            .requestBlockedByProxy
        )
    }

    func testOther4xxWithoutCodeStaysUnderlying() {
        if case .underlying = DiagnosticsAPI.mapUploadError(HTTPError.http(statusCode: 404, body: nil)) {
        } else {
            XCTFail("bare 404 should stay non-retryable underlying")
        }
    }

    // MARK: - Status decoding with and without upload_chunk_bytes

    func testStatusDecodesUploadChunkBytes() throws {
        let status = try HTTPClient.makeJSONDecoder().decode(DiagnosticsStatusResponse.self, from: Data("""
        {
          "status": "available",
          "server_instance_id": "srv_123",
          "accepted_schema_versions": [1],
          "max_bundle_bytes": 10485760,
          "max_manifest_bytes": 65536,
          "retention_days": 30,
          "consent_notice_version": 1,
          "upload_chunk_bytes": 786432
        }
        """.utf8))
        XCTAssertEqual(status.uploadChunkBytes, 786_432)
        XCTAssertTrue(status.supportsChunkedUpload)
    }

    func testStatusFromOlderServerWithoutChunkFieldDecodes() throws {
        // Older servers omit upload_chunk_bytes entirely; decoding must not
        // fail and chunking must read as unsupported.
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

    func testChunkedSessionResponseDecodes() throws {
        let session = try HTTPClient.makeJSONDecoder().decode(DiagnosticsChunkedUploadSession.self, from: Data("""
        {
          "upload_id": "0123456789abcdef",
          "chunk_bytes": 786432,
          "total_chunks": 3,
          "expires_at": "2026-07-27T12:00:00Z"
        }
        """.utf8))
        XCTAssertEqual(session.uploadId, "0123456789abcdef")
        XCTAssertEqual(session.chunkBytes, 786_432)
        XCTAssertEqual(session.totalChunks, 3)
    }

    // MARK: - uploadChunked orchestration (URLProtocol-backed)

    /// Stands up a DiagnosticsAPI whose HTTPClient talks to
    /// ChunkedUploadStubProtocol, with a TokenStore isolated to this test.
    private func makeStubbedAPI() async -> DiagnosticsAPI {
        let suiteName = "diag-chunk-tests-\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        addTeardownBlock {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        let tokenStore = TokenStore(
            keychain: SharedKeychain(service: "DiagnosticsChunkedUploadTests.\(UUID().uuidString)", accessGroup: nil),
            defaults: SharedDefaults(suite: suite, standard: suite)
        )
        await tokenStore.setServerUrl("http://chunk-test.invalid")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedUploadStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokenStore)
        return DiagnosticsAPI(http: http)
    }

    func testUploadChunkedSplitsSequentiallyAndCompletes() async throws {
        ChunkedUploadStubProtocol.reset(chunkBytes: 4, failChunkIndex: nil)
        let api = await makeStubbedAPI()

        let bundle = Data("0123456789".utf8) // 10 bytes → chunks of 4/4/2
        let manifest = Data(#"{"schema_version":1}"#.utf8)
        let response = try await api.uploadChunked(manifestData: manifest, bundleData: bundle)

        XCTAssertEqual(response.shortID, "SILO-TEST12345678")
        let state = ChunkedUploadStubProtocol.state()
        XCTAssertEqual(state.chunkBodies.count, 3)
        XCTAssertEqual(state.chunkBodies.map(\.count), [4, 4, 2])
        XCTAssertEqual(Data(state.chunkBodies.joined()), bundle, "reassembled chunks must equal the bundle")
        XCTAssertEqual(state.chunkIndexes, [0, 1, 2], "chunks must arrive in order")
        XCTAssertTrue(state.completed)
        XCTAssertFalse(state.aborted)
        // Init must embed the manifest bytes verbatim.
        XCTAssertNotNil(state.initBody)
        if let initBody = state.initBody {
            XCTAssertNotNil(initBody.range(of: manifest))
        }
    }

    func testUploadChunkedAbortsSessionWhenAChunkFails() async throws {
        ChunkedUploadStubProtocol.reset(chunkBytes: 4, failChunkIndex: 1)
        let api = await makeStubbedAPI()

        do {
            _ = try await api.uploadChunked(
                manifestData: Data(#"{"schema_version":1}"#.utf8),
                bundleData: Data("0123456789".utf8)
            )
            XCTFail("uploadChunked should rethrow the failed chunk")
        } catch let error as DiagnosticsUploadError {
            guard case .retryable = error else {
                return XCTFail("expected retryable for a 500 chunk, got \(error)")
            }
        }

        let state = ChunkedUploadStubProtocol.state()
        XCTAssertFalse(state.completed)
        XCTAssertTrue(state.aborted, "a failed upload must best-effort abort its session")
    }

    func testUploadChunkedFailsFastOnNonPositiveChunkBytes() async throws {
        // A zero/negative advertised chunk size must fail fast, not degrade
        // to 1-byte chunks (millions of PUTs for a real bundle).
        ChunkedUploadStubProtocol.reset(chunkBytes: 0, failChunkIndex: nil)
        let api = await makeStubbedAPI()

        do {
            _ = try await api.uploadChunked(
                manifestData: Data(#"{"schema_version":1}"#.utf8),
                bundleData: Data("0123456789".utf8)
            )
            XCTFail("uploadChunked should reject chunk_bytes = 0")
        } catch let error as DiagnosticsUploadError {
            guard case .underlying = error else {
                return XCTFail("expected underlying for invalid chunk_bytes, got \(error)")
            }
        }

        let state = ChunkedUploadStubProtocol.state()
        XCTAssertTrue(state.chunkIndexes.isEmpty, "no chunk PUTs may be issued")
        XCTAssertFalse(state.completed)
        XCTAssertTrue(state.aborted, "the opened session should still be reclaimed")
    }

    func testUploadChunkedStopsWithoutAbortWhenDestinationChanges() async throws {
        // Simulate a server/profile switch after the first chunk: the check
        // fires before every post-init request, the remaining bundle bytes
        // must not be sent, and no abort may be issued (it would target the
        // newly active destination).
        ChunkedUploadStubProtocol.reset(chunkBytes: 4, failChunkIndex: nil)
        let api = await makeStubbedAPI()

        let checkCount = ChunkCheckCounter()
        do {
            _ = try await api.uploadChunked(
                manifestData: Data(#"{"schema_version":1}"#.utf8),
                bundleData: Data("0123456789".utf8),
                destinationUnchanged: { await checkCount.next() <= 1 }
            )
            XCTFail("uploadChunked should stop on a destination change")
        } catch let error as DiagnosticsUploadError {
            XCTAssertEqual(error, .retryable("destination_changed"))
        }

        let state = ChunkedUploadStubProtocol.state()
        XCTAssertEqual(state.chunkIndexes, [0], "upload must stop after the destination changed")
        XCTAssertFalse(state.completed)
        XCTAssertFalse(state.aborted, "abort would target the new destination and must be skipped")
    }
}

/// Serializes destination-check counting across the async upload loop.
private actor ChunkCheckCounter {
    private var count = 0
    func next() -> Int {
        count += 1
        return count
    }
}

/// In-process stub for the chunked upload endpoints. State is static because
/// URLSession instantiates the protocol itself; `reset` scopes it per test.
final class ChunkedUploadStubProtocol: URLProtocol {
    struct State {
        var chunkBytes = 4
        var failChunkIndex: Int?
        var initBody: Data?
        var chunkIndexes: [Int] = []
        var chunkBodies: [Data] = []
        var completed = false
        var aborted = false
    }

    private static let lock = NSLock()
    private static var current = State()

    static func reset(chunkBytes: Int, failChunkIndex: Int?) {
        lock.lock()
        current = State(chunkBytes: chunkBytes, failChunkIndex: failChunkIndex)
        lock.unlock()
    }

    static func state() -> State {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    private static func mutate(_ apply: (inout State) -> Void) {
        lock.lock()
        apply(&current)
        lock.unlock()
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "chunk-test.invalid"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""
        let body = request.drainedHTTPBody

        switch (method, path) {
        case ("POST", "/api/v1/diagnostics/reports/uploads"):
            Self.mutate { $0.initBody = body }
            let chunkBytes = Self.state().chunkBytes
            respond(status: 201, json: #"{"upload_id":"stub-session","chunk_bytes":\#(chunkBytes),"total_chunks":3,"expires_at":"2026-01-01T00:00:00Z"}"#)
        case ("PUT", let chunkPath) where chunkPath.contains("/uploads/stub-session/chunks/"):
            let index = Int(chunkPath.split(separator: "/").last ?? "") ?? -1
            if Self.state().failChunkIndex == index {
                respond(status: 500, json: #"{"error":"internal_error","message":"stub chunk failure"}"#)
                return
            }
            Self.mutate {
                $0.chunkIndexes.append(index)
                $0.chunkBodies.append(body)
            }
            respond(status: 200, json: #"{"received_chunks":\#(index + 1),"total_chunks":3}"#)
        case ("POST", "/api/v1/diagnostics/reports/uploads/stub-session/complete"):
            Self.mutate { $0.completed = true }
            respond(status: 201, json: #"{"report_id":"11111111-1111-1111-1111-111111111111","short_id":"SILO-TEST12345678"}"#)
        case ("DELETE", "/api/v1/diagnostics/reports/uploads/stub-session"):
            Self.mutate { $0.aborted = true }
            respond(status: 204, json: "")
        default:
            respond(status: 404, json: #"{"error":"not_found"}"#)
        }
    }

    override func stopLoading() {}

    private func respond(status: Int, json: String) {
        guard let url = request.url, let client else { return }
        let response = HTTPURLResponse(
            url: url,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !json.isEmpty {
            client.urlProtocol(self, didLoad: Data(json.utf8))
        }
        client.urlProtocolDidFinishLoading(self)
    }
}
