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
}
