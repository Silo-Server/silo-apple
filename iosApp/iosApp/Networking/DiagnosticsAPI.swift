#if os(iOS) || os(tvOS)
import Foundation

enum DiagnosticsAvailabilityStatus: String, Codable, Equatable {
    case available
    case disabled
    case storageUnavailable = "storage_unavailable"
}

struct DiagnosticsStatusResponse: Codable, Equatable {
    let status: DiagnosticsAvailabilityStatus
    let serverInstanceId: String
    let acceptedSchemaVersions: [Int]
    let maxBundleBytes: Int
    let maxManifestBytes: Int
    let retentionDays: Int
    let consentNoticeVersion: Int
    /// Chunk payload size for the chunked upload fallback. Absent (nil) on
    /// servers that predate chunked uploads; those can only take the
    /// single-shot multipart upload.
    let uploadChunkBytes: Int?

    var serverInstanceID: String {
        serverInstanceId
    }

    var supportsChunkedUpload: Bool {
        (uploadChunkBytes ?? 0) > 0
    }
}

struct DiagnosticsUploadResponse: Codable, Equatable {
    let reportId: String
    let shortId: String

    var reportID: String {
        reportId
    }

    var shortID: String {
        shortId
    }
}

enum DiagnosticsUploadError: Error, Equatable {
    case disabled
    case storageUnavailable
    case quotaExceeded
    case tooLarge
    case busy
    case unsupportedSchema
    case destinationMismatch
    case staleConsent
    case archiveMismatch
    case invalidBundle
    /// An intermediary (reverse proxy/CDN) rejected the request body as too
    /// large before it reached Silo — a 413 with no Silo error envelope.
    /// Distinct from `.tooLarge` (Silo's own bundle-size verdict): the server
    /// may still accept the same bundle through the chunked upload fallback,
    /// whose requests stay under typical proxy body caps.
    case requestBlockedByProxy
    case retryable(String)
    case underlying(String)
}

struct DiagnosticsChunkedUploadSession: Codable, Equatable {
    let uploadId: String
    let chunkBytes: Int
    let totalChunks: Int
}

actor DiagnosticsAPI {
    static let shared = DiagnosticsAPI()

    private let http: HTTPClient

    init(http: HTTPClient = .shared) {
        self.http = http
    }

    func getDiagnosticsStatus() async throws -> DiagnosticsStatusResponse {
        try await http.get("/api/v1/diagnostics/status")
    }

    func upload(manifestData: Data, bundleData: Data) async throws -> DiagnosticsUploadResponse {
        do {
            return try await http.postMultipart(
                "/api/v1/diagnostics/reports",
                parts: [
                    HTTPMultipartPart(
                        name: "manifest",
                        filename: "manifest.json",
                        contentType: "application/json",
                        data: manifestData
                    ),
                    HTTPMultipartPart(
                        name: "bundle",
                        filename: "bundle.tar.gz",
                        contentType: "application/gzip",
                        data: bundleData
                    ),
                ],
                timeout: .extended
            )
        } catch let error as HTTPError {
            throw Self.mapUploadError(error)
        } catch {
            throw DiagnosticsUploadError.underlying(String(describing: error))
        }
    }

    // MARK: - Chunked upload fallback

    /// Uploads via the chunked endpoints: init → sequential chunk PUTs →
    /// complete. Used when the single-shot upload is rejected by an
    /// intermediary body-size cap (`.requestBlockedByProxy`); every request
    /// here stays under the server-advertised `upload_chunk_bytes` (768 KiB),
    /// which clears nginx's default 1 MiB `client_max_body_size`.
    ///
    /// `destinationUnchanged` re-validates the upload's destination identity
    /// before every request after init. HTTPClient resolves the active server
    /// URL and auth per request, so a server/profile switch mid-sequence
    /// would otherwise send the remaining chunk bodies to whatever
    /// destination became active. When the check fails the upload stops with
    /// a retryable error and no abort is attempted — the DELETE would target
    /// the *new* destination; the original server's session TTL reclaims the
    /// spool.
    ///
    /// On failure after init, the session is aborted best-effort so the
    /// server can reclaim its spool immediately instead of waiting out the
    /// session TTL.
    func uploadChunked(
        manifestData: Data,
        bundleData: Data,
        destinationUnchanged: (() async -> Bool)? = nil
    ) async throws -> DiagnosticsUploadResponse {
        let session: DiagnosticsChunkedUploadSession
        do {
            // The manifest bytes are embedded verbatim into the init JSON
            // rather than re-encoded: the server compares the received
            // manifest against the archive's embedded manifest.json, and any
            // re-serialization here could reorder keys and break equality.
            var initBody = Data(#"{"bundle_bytes":\#(bundleData.count),"manifest":"#.utf8)
            initBody.append(manifestData)
            initBody.append(Data("}".utf8))
            session = try await http.postRaw(
                "/api/v1/diagnostics/reports/uploads",
                body: initBody,
                contentType: "application/json"
            )
        } catch let error as HTTPError {
            throw Self.mapUploadError(error)
        } catch {
            throw DiagnosticsUploadError.underlying(String(describing: error))
        }

        func ensureDestinationUnchanged() async throws {
            guard let destinationUnchanged else { return }
            guard await destinationUnchanged() else {
                throw DiagnosticsUploadError.retryable("destination_changed")
            }
        }

        do {
            // Fail fast on a nonsensical chunk size rather than degrade: a
            // zero/negative value coerced to something tiny would turn one
            // bundle into millions of sequential PUTs.
            guard session.chunkBytes > 0 else {
                throw DiagnosticsUploadError.underlying("invalid chunk_bytes \(session.chunkBytes)")
            }
            let chunkBytes = session.chunkBytes
            var index = 0
            var offset = 0
            while offset < bundleData.count {
                try await ensureDestinationUnchanged()
                let end = min(offset + chunkBytes, bundleData.count)
                let _: EmptyDiagnosticsResponse = try await http.putRaw(
                    "/api/v1/diagnostics/reports/uploads/\(session.uploadId)/chunks/\(index)",
                    body: bundleData.subdata(in: offset..<end),
                    contentType: "application/octet-stream"
                )
                offset = end
                index += 1
            }
            try await ensureDestinationUnchanged()
            return try await http.postRaw(
                "/api/v1/diagnostics/reports/uploads/\(session.uploadId)/complete",
                body: Data(),
                contentType: "application/json",
                timeout: .extended
            )
        } catch DiagnosticsUploadError.retryable(let code) where code == "destination_changed" {
            // Deliberately no abort: HTTPClient now points at a different
            // server/account, so the DELETE would go to the wrong place.
            throw DiagnosticsUploadError.retryable(code)
        } catch {
            // Free the server-side spool now rather than at TTL expiry. Errors
            // are swallowed: the abort is a courtesy and must not mask the
            // upload error the caller acts on.
            try? await http.delete("/api/v1/diagnostics/reports/uploads/\(session.uploadId)")
            if let httpError = error as? HTTPError {
                throw Self.mapUploadError(httpError)
            }
            if let uploadError = error as? DiagnosticsUploadError {
                throw uploadError
            }
            throw DiagnosticsUploadError.underlying(String(describing: error))
        }
    }

    static func mapUploadError(_ error: HTTPError) -> DiagnosticsUploadError {
        switch error.serverErrorCode {
        case "disabled":
            return .disabled
        case "storage_unavailable":
            return .storageUnavailable
        case "quota_exceeded":
            return .quotaExceeded
        case "too_large":
            return .tooLarge
        case "busy":
            return .busy
        case "unsupported_schema":
            return .unsupportedSchema
        case "destination_mismatch":
            return .destinationMismatch
        case "stale_consent":
            return .staleConsent
        case "archive_mismatch":
            return .archiveMismatch
        case "invalid_bundle":
            return .invalidBundle
        case let code?:
            // A 413 whose error code is not Silo's own `too_large` (handled
            // above) came from an intermediary — some proxies emit JSON error
            // envelopes rather than nginx's default HTML page. Same fallback
            // as the envelope-less case below.
            if error.statusCode == 413 {
                return .requestBlockedByProxy
            }
            if error.statusCode.map({ $0 >= 500 || $0 == 429 }) == true {
                return .retryable(code)
            }
            return .underlying(code)
        case nil:
            // A 413 with no Silo error envelope means a proxy in front of the
            // server refused the request body before Silo ever saw it (Silo's
            // own too-large answer always carries the `too_large` code).
            // Surfaced distinctly so the coordinator can fall back to the
            // chunked upload instead of retrying a request that can never fit.
            if error.statusCode == 413 {
                return .requestBlockedByProxy
            }
            if error.statusCode.map({ $0 >= 500 || $0 == 429 }) == true {
                return .retryable("http_\(error.statusCode ?? 0)")
            }
            return .underlying(error.localizedDescription)
        }
    }
}

/// Some chunk endpoints reply with small JSON state the client doesn't need;
/// decode into this to accept any object without depending on its shape.
private struct EmptyDiagnosticsResponse: Decodable {}
#endif
