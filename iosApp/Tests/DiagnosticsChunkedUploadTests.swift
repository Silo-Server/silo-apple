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
          "expires_at": "2099-07-27T12:00:00.000Z"
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
        await tokenStore.switchActiveServer(serverId: "chunk-server")
        await tokenStore.setServerUrl("http://chunk-test.invalid")
        try! await tokenStore.installAccountSession(accessToken: "access", refreshToken: "refresh", accountID: "1")

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ChunkedUploadStubProtocol.self]
        let http = HTTPClient(session: URLSession(configuration: config), tokenStore: tokenStore)
        return DiagnosticsAPI(http: http, tokens: tokenStore)
    }

    func testChunkAuthenticationReplayKeepsExactSessionIndexAndBytes() async throws {
        ChunkedUploadStubProtocol.reset(chunkBytes: 4, failChunkIndex: nil)
        ChunkedUploadStubProtocol.mutate { $0.expireFirstChunk = true }
        let api = await makeStubbedAPI()
        _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8), capturedProfileID: "captured")
        let state = ChunkedUploadStubProtocol.state()
        let chunks = zip(state.requests, state.requestBodies).filter { $0.0.url?.path.hasSuffix("/chunks/0") == true }
        XCTAssertEqual(chunks.count, 2)
        XCTAssertEqual(chunks.map { $0.1 }, [Data("0123".utf8), Data("0123".utf8)])
        XCTAssertTrue(chunks.allSatisfy { $0.0.url?.path == "/api/v2/diagnostics/reports/uploads/stub-session/chunks/0" })
        XCTAssertTrue(chunks.allSatisfy { $0.0.value(forHTTPHeaderField: "X-Profile-Id") == "captured" })
        XCTAssertEqual(state.requests.filter { $0.url?.path == "/api/v2/diagnostics/reports/uploads" }.count, 1)
    }

    func testExpiredReceiptStopsBeforeChunksAndDoesNotReinitialize() async throws {
        ChunkedUploadStubProtocol.reset(chunkBytes: 4, failChunkIndex: nil)
        ChunkedUploadStubProtocol.mutate { $0.expiry = "2020-01-01T00:00:00.000Z" }
        let api = await makeStubbedAPI()
        do { _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8)); XCTFail() } catch {}
        let state = ChunkedUploadStubProtocol.state()
        XCTAssertTrue(state.chunkIndexes.isEmpty)
        XCTAssertFalse(state.completed)
        XCTAssertTrue(state.aborted)
        XCTAssertEqual(state.requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testInit401IsNeverRefreshedOrReplaced() async throws {
        ChunkedUploadStubProtocol.reset(chunkBytes: 4, failChunkIndex: nil)
        ChunkedUploadStubProtocol.mutate { $0.initStatus = 401 }
        let api = await makeStubbedAPI()
        do { _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8)); XCTFail() } catch {}
        XCTAssertEqual(ChunkedUploadStubProtocol.state().requests.count, 1)
    }

    func testUncertainCompletion404And401NeverAbortReplayOrReplace() async throws {
        for status in [404, 401] {
            ChunkedUploadStubProtocol.reset(chunkBytes: 4, failChunkIndex: nil)
            ChunkedUploadStubProtocol.mutate { $0.completeStatus = status }
            let api = await makeStubbedAPI()
            do {
                _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8), capturedProfileID: "captured")
                XCTFail()
            } catch {}
            let state = ChunkedUploadStubProtocol.state()
            XCTAssertEqual(state.requests.count, 5)
            XCTAssertTrue(state.completed)
            XCTAssertFalse(state.aborted)
            XCTAssertEqual(state.requests.filter { $0.url?.path.hasSuffix("/complete") == true }.count, 1)
            XCTAssertTrue(state.requests.allSatisfy { $0.value(forHTTPHeaderField: "X-Profile-Id") == "captured" })
        }
    }

    func testMissingChunkSessionDoesNotCreateReplacement() async throws {
        ChunkedUploadStubProtocol.reset(chunkBytes: 4, failChunkIndex: 1)
        ChunkedUploadStubProtocol.mutate { $0.failChunkStatus = 404 }
        let api = await makeStubbedAPI()
        do { _ = try await api.uploadChunked(manifestData: Data("{}".utf8), bundleData: Data("0123456789".utf8)); XCTFail() } catch {}
        let state = ChunkedUploadStubProtocol.state()
        XCTAssertFalse(state.completed)
        XCTAssertTrue(state.aborted)
        XCTAssertEqual(state.requests.filter { $0.httpMethod == "POST" }.count, 1)
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
        var requests: [URLRequest] = []
        var requestBodies: [Data] = []
        var expireFirstChunk = false
        var initStatus = 201
        var completeStatus = 201
        var failChunkStatus = 500
        var expiry = "2099-01-01T00:00:00.000Z"
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

    static func mutate(_ apply: (inout State) -> Void) {
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
        Self.mutate { $0.requests.append(request) }
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? ""
        let body = Self.requestBody(of: request)
        Self.mutate { $0.requestBodies.append(body ?? Data()) }

        switch (method, path) {
        case ("POST", "/api/v2/auth/refresh"):
            respond(status: 200, json: #"{"access_token":"refreshed","refresh_token":"refreshed-refresh","expires_in":3600}"#)
        case ("POST", "/api/v2/diagnostics/reports/uploads"):
            if Self.state().initStatus != 201 {
                respond(status: Self.state().initStatus, json: #"{"error":"authentication_required"}"#)
                return
            }
            Self.mutate { $0.initBody = body }
            let chunkBytes = Self.state().chunkBytes
            respond(status: 201, json: #"{"upload_id":"stub-session","chunk_bytes":\#(chunkBytes),"total_chunks":3,"expires_at":"\#(Self.state().expiry)"}"#)
        case ("PUT", let chunkPath) where chunkPath.contains("/uploads/stub-session/chunks/"):
            let index = Int(chunkPath.split(separator: "/").last ?? "") ?? -1
            if index == 0, Self.state().expireFirstChunk {
                Self.mutate { $0.expireFirstChunk = false }
                respond(status: 401, json: #"{"error":"authentication_required"}"#)
                return
            }
            if Self.state().failChunkIndex == index {
                respond(status: Self.state().failChunkStatus, json: #"{"error":"internal_error","message":"stub chunk failure"}"#)
                return
            }
            Self.mutate {
                $0.chunkIndexes.append(index)
                $0.chunkBodies.append(body ?? Data())
            }
            respond(status: 200, json: #"{"received_chunks":\#(index + 1),"total_chunks":3}"#)
        case ("POST", "/api/v2/diagnostics/reports/uploads/stub-session/complete"):
            Self.mutate { $0.completed = true }
            if Self.state().completeStatus != 201 {
                respond(status: Self.state().completeStatus, json: #"{"error":"not_found"}"#)
                return
            }
            respond(status: 201, json: #"{"report_id":"11111111-1111-1111-1111-111111111111","short_id":"SILO-TEST12345678"}"#)
        case ("DELETE", "/api/v2/diagnostics/reports/uploads/stub-session"):
            Self.mutate { $0.aborted = true }
            respond(status: 204, json: "")
        default:
            respond(status: 404, json: #"{"error":"not_found"}"#)
        }
    }

    override func stopLoading() {}

    /// URLSession surfaces outgoing bodies to URLProtocol as a stream, not
    /// `httpBody`; drain it.
    private static func requestBody(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }
        stream.open()
        defer { stream.close() }
        var data = Data()
        let bufferSize = 64 * 1024
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: bufferSize)
            guard read > 0 else { break }
            data.append(buffer, count: read)
        }
        return data
    }

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
