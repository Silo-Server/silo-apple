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
    let state: DiagnosticsRemoteReportState?

    init(reportId: String, shortId: String, state: DiagnosticsRemoteReportState? = nil) {
        self.reportId = reportId
        self.shortId = shortId
        self.state = state
    }

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
    /// large before it reached Silo: a 413 without a problem document.
    /// Distinct from `.tooLarge` (Silo's own bundle-size verdict): the server
    /// may still accept the same bundle through the chunked upload fallback,
    /// whose requests stay under typical proxy body caps.
    case requestBlockedByProxy
    /// The server refused the request as invalid (400 or 422) without a
    /// problem type that says why. v2 folds unsupported schema, stale consent,
    /// destination and archive mismatches into one 400, so the report is kept
    /// and never retried automatically.
    case serverRejected
    /// A `non_retryable` request (report upload, chunked create or complete)
    /// may have reached the server, but no answer arrived. The report may
    /// already be stored there, so it is never sent again.
    case deliveryUncertain
    case retryable(String)
    case underlying(String)
}

/// Uploads self-hosted diagnostics reports through the v2 routes.
///
/// Failure outcomes, per request:
/// - An HTTP answer is definite and maps through `mapUploadError`.
/// - No answer on a `non_retryable` request (report upload, chunked create,
///   complete) is `.deliveryUncertain`, unless the transport failed before
///   connecting or the owner changed before the request was sent.
/// - A chunk failure is definite for the whole upload: nothing is ingested
///   without `complete`.
actor DiagnosticsAPI {
    static let shared = DiagnosticsAPI()

    static let destinationChanged = "destination_changed"

    private let client: APIv2Client

    init(client: APIv2Client = SiloAPI.shared.apiV2Client) {
        self.client = client
    }

    /// The owner an upload is bound to. Capture it before building the
    /// bundle and pass it to every upload call for that report.
    func captureOwner() async throws -> CapturedOrdinaryRequestAuth {
        try await client.captureRequestOwner()
    }

    func upload(
        manifestData: Data,
        bundleData: Data,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> DiagnosticsUploadResponse {
        try await ensureOwner(auth)
        do {
            return try await client.uploadDiagnosticsReport(
                manifestData: manifestData,
                bundleData: bundleData,
                auth: auth
            )
        } catch {
            throw Self.nonRetryableFailure(error)
        }
    }

    // MARK: - Chunked upload fallback

    /// Uploads via the chunked endpoints: create, sequential chunk PUTs,
    /// complete. Used when the single-shot upload is rejected by an
    /// intermediary body-size cap (`.requestBlockedByProxy`); every request
    /// here stays under the server-advertised chunk size (768 KiB), which
    /// clears nginx's default 1 MiB `client_max_body_size`.
    ///
    /// Every request runs under `auth`, and the owner is re-checked before
    /// each one. A server, account or profile switch mid-sequence stops the
    /// upload with a retryable error and no abort: the DELETE could only go to
    /// the new destination, and the original server's session TTL reclaims
    /// the spool.
    ///
    /// After any other definite failure the session is aborted best-effort so
    /// the server can reclaim its spool immediately. An uncertain `complete`
    /// is left alone: the report may already be ingested.
    func uploadChunked(
        manifestData: Data,
        bundleData: Data,
        auth: CapturedOrdinaryRequestAuth
    ) async throws -> DiagnosticsUploadResponse {
        try await ensureOwner(auth)
        let session: APIv2DiagnosticsUploadSession
        do {
            session = try await client.createDiagnosticsUpload(
                manifestData: manifestData,
                bundleBytes: bundleData.count,
                auth: auth
            )
        } catch {
            throw Self.nonRetryableFailure(error)
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
                try await ensureOwner(auth)
                let end = min(offset + chunkBytes, bundleData.count)
                try await client.putDiagnosticsUploadChunk(
                    uploadID: session.uploadId,
                    index: index,
                    data: bundleData.subdata(in: offset..<end),
                    auth: auth
                )
                offset = end
                index += 1
            }
            try await ensureOwner(auth)
        } catch where Self.isOwnerChange(error) {
            throw DiagnosticsUploadError.retryable(Self.destinationChanged)
        } catch {
            await abort(session, auth: auth)
            throw Self.definiteFailure(error)
        }

        do {
            return try await client.completeDiagnosticsUpload(uploadID: session.uploadId, auth: auth)
        } catch {
            // An owner change skips the abort for the same reason as above.
            let failure = Self.nonRetryableFailure(error)
            if failure != .deliveryUncertain, !Self.isOwnerChange(error) {
                await abort(session, auth: auth)
            }
            throw failure
        }
    }

    /// Frees the server-side spool now rather than at TTL expiry. Errors are
    /// swallowed: the abort is a courtesy and must not mask the upload error
    /// the caller acts on.
    private func abort(_ session: APIv2DiagnosticsUploadSession, auth: CapturedOrdinaryRequestAuth) async {
        try? await client.abortDiagnosticsUpload(uploadID: session.uploadId, auth: auth)
    }

    private func ensureOwner(_ auth: CapturedOrdinaryRequestAuth) async throws {
        guard await client.isCurrentOwner(auth) else {
            throw DiagnosticsUploadError.retryable(Self.destinationChanged)
        }
    }

    // MARK: - Failure classification

    /// The owner changed before a request left, or while a chunk was in
    /// flight. Either way the upload belongs to an owner that is gone.
    private static func isOwnerChange(_ error: Error) -> Bool {
        switch error {
        case DiagnosticsUploadError.retryable(let code):
            return code == destinationChanged
        case is APIv2OwnerChangedBeforeDispatch, HTTPError.authorityChanged, HTTPError.requestIdentityChanged:
            return true
        default:
            return false
        }
    }

    /// A failed `non_retryable` request. An HTTP answer is definite; so is a
    /// refusal before the request was sent, and a transport failure that
    /// happened before a connection existed. Anything else (a lost
    /// connection, a timeout, a response discarded because the owner changed
    /// in flight, an unexpected 2xx) may have been processed.
    static func nonRetryableFailure(_ error: Error) -> DiagnosticsUploadError {
        if let uploadError = error as? DiagnosticsUploadError {
            return uploadError
        }
        if error is APIv2OwnerChangedBeforeDispatch {
            return .retryable(destinationChanged)
        }
        if let apiError = error as? APIv2Error {
            return mapUploadError(apiError)
        }
        if case HTTPError.network(let underlying) = error,
           let urlError = underlying as? URLError,
           APIv2Client.neverConnected.contains(urlError.code) {
            return .retryable(HTTPDiagnosticsErrorCode.classify(transport: urlError))
        }
        return .deliveryUncertain
    }

    /// A failure that cannot have delivered the report (chunk PUTs, and the
    /// owner checks between requests).
    static func definiteFailure(_ error: Error) -> DiagnosticsUploadError {
        if let uploadError = error as? DiagnosticsUploadError {
            return uploadError
        }
        if let apiError = error as? APIv2Error {
            return mapUploadError(apiError)
        }
        if case HTTPError.network(let underlying) = error {
            return .retryable(HTTPDiagnosticsErrorCode.classify(transport: underlying))
        }
        return .underlying(String(describing: error))
    }

    /// Maps a v2 answer. The distinct problem types the server sends today
    /// are `capability_disabled` and `capability_not_configured`; the domain
    /// codes are honored as problem types if a server starts sending them.
    /// Everything else is classified by status alone.
    static func mapUploadError(_ error: APIv2Error) -> DiagnosticsUploadError {
        switch error {
        case .serverUpdateRequired:
            // A v1-only server cannot take v2 reports until it updates.
            return .unsupportedSchema
        case .problem(let problem):
            switch problem.identifier {
            case "capability_disabled":
                return .disabled
            case "capability_not_configured":
                return .storageUnavailable
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
            default:
                return mapStatus(problem.status, isProblem: true)
            }
        case .httpStatus(let status):
            return mapStatus(status, isProblem: false)
        default:
            return .underlying(String(describing: error))
        }
    }

    private static func mapStatus(_ status: Int, isProblem: Bool) -> DiagnosticsUploadError {
        switch status {
        case 413:
            // Silo always answers with a problem document. A 413 without one
            // came from a proxy in front of the server that refused the body
            // before Silo saw it; the chunked upload may still fit.
            return isProblem ? .tooLarge : .requestBlockedByProxy
        case 429:
            return .quotaExceeded
        case 503:
            return .busy
        case 400, 422:
            return .serverRejected
        case 500...599:
            return .retryable("http_\(status)")
        default:
            return .underlying("http_\(status)")
        }
    }
}
#endif
