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
    /// Positive only when this API namespace supports process-local chunks.
    /// Choose chunking before dispatch; never replace an uncertain upload.
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
    let expiresAt: Date
}

private struct DiagnosticsChunkAcknowledgment: Decodable {
    let receivedChunks: Int
    let totalChunks: Int
}

actor DiagnosticsAPI {
    static let shared = DiagnosticsAPI()

    private let http: HTTPClient
    private let tokens: TokenStore

    init(http: HTTPClient = .shared, tokens: TokenStore = .shared) {
        self.http = http
        self.tokens = tokens
    }

    func getDiagnosticsStatus() async throws -> DiagnosticsStatusResponse {
        guard let auth = await tokens.captureOrdinaryRequestAuth(), auth.accessToken?.isEmpty == false else {
            throw HTTPError.requestIdentityChanged
        }
        let response = try await http.requestData(method: "GET", path: "/api/v2/diagnostics/capabilities",
            headers: ["X-Profile-Id": ""], expectedAccount: auth.account)
        guard let current = await tokens.captureOrdinaryRequestAuth(), current.account == auth.account else {
            throw HTTPError.requestIdentityChanged
        }
        return try HTTPClient.makeJSONDecoder().decode(DiagnosticsStatusResponse.self, from: response.data)
    }

    func upload(manifestData: Data, bundleData: Data, capturedProfileID: String? = nil,
                expectedAccount: RefreshAccountIdentity? = nil) async throws -> DiagnosticsUploadResponse {
        guard let auth = await tokens.captureOrdinaryRequestAuth(), auth.accessToken?.isEmpty == false,
              expectedAccount == nil || expectedAccount == auth.account else {
            throw HTTPError.requestIdentityChanged
        }
        let boundary = "SiloDiagnostics-\(UUID())"
        let body = HTTPClient.multipartBody(parts: [
            HTTPMultipartPart(name: "manifest", filename: "manifest.json", contentType: "application/json", data: manifestData),
            HTTPMultipartPart(name: "bundle", filename: "bundle.tar.gz", contentType: "application/gzip", data: bundleData)
        ], boundary: boundary)
        do {
            let response = try await http.requestData(method: "POST", path: "/api/v2/diagnostics/reports",
                body: body, contentType: "multipart/form-data; boundary=\(boundary)",
                headers: ["X-Profile-Id": capturedProfileID ?? ""], timeout: .extended, expectedAccount: auth.account)
            guard let current = await tokens.captureOrdinaryRequestAuth(), current.account == auth.account else {
                throw HTTPError.requestIdentityChanged
            }
            return try HTTPClient.makeJSONDecoder().decode(DiagnosticsUploadResponse.self, from: response.data)
        } catch let error as HTTPError {
            throw Self.mapUploadError(error)
        }
    }

    // MARK: - Process-local chunk upload

    /// Select before a multipart POST, never as recovery from uncertain delivery.
    /// The same HTTP session/origin is used throughout for deployment affinity.
    /// An expired/restarted/other-replica session is terminal for this attempt.
    func uploadChunked(manifestData: Data, bundleData: Data, capturedProfileID: String? = nil,
                       expectedAccount: RefreshAccountIdentity? = nil, maximumChunkBytes: Int = 786_432,
                       destinationUnchanged: (@Sendable () async -> Bool)? = nil) async throws -> DiagnosticsUploadResponse {
        guard !bundleData.isEmpty, bundleData.count <= 268_435_456, maximumChunkBytes > 0,
              let auth = await tokens.captureOrdinaryRequestAuth(), auth.accessToken?.isEmpty == false,
              expectedAccount == nil || expectedAccount == auth.account else { throw HTTPError.requestIdentityChanged }
        let headers = ["X-Profile-Id": capturedProfileID ?? ""]
        let base = "/api/v2/diagnostics/reports/uploads"
        var initBody = Data(#"{"bundle_bytes":\#(bundleData.count),"manifest":"#.utf8)
        initBody.append(manifestData)
        initBody.append(Data("}".utf8))
        let session: DiagnosticsChunkedUploadSession
        do {
            let response = try await http.requestData(method: "POST", path: base, body: initBody,
                headers: headers, expectedAccount: auth.account)
            session = try HTTPClient.makeJSONDecoder().decode(DiagnosticsChunkedUploadSession.self, from: response.data)
        } catch let error as HTTPError { throw Self.mapUploadError(error) }

        guard !session.uploadId.isEmpty, session.uploadId != ".", session.uploadId != "..",
              let segment = session.uploadId.addingPercentEncoding(withAllowedCharacters:
                CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/?#%"))) else {
            throw DiagnosticsUploadError.underlying("Invalid upload session identity")
        }
        let path = base + "/" + segment
        var completing = false
        func requireDestination() async throws {
            guard let current = await tokens.captureOrdinaryRequestAuth(), current.account == auth.account else {
                throw DiagnosticsUploadError.retryable("destination_changed")
            }
            if let destinationUnchanged, !(await destinationUnchanged()) {
                throw DiagnosticsUploadError.retryable("destination_changed")
            }
        }
        do {
            guard session.chunkBytes > 0, session.chunkBytes <= maximumChunkBytes,
                  session.totalChunks == (bundleData.count - 1) / session.chunkBytes + 1,
                  session.expiresAt > Date() else {
                throw DiagnosticsUploadError.underlying("Invalid or expired upload session")
            }
            for index in 0..<session.totalChunks {
                try await requireDestination()
                let offset = index * session.chunkBytes
                let end = offset + min(session.chunkBytes, bundleData.count - offset)
                let response = try await http.requestData(method: "PUT", path: path + "/chunks/\(index)",
                    body: bundleData.subdata(in: offset..<end), contentType: "application/octet-stream",
                    headers: headers, timeout: .extended, expectedAccount: auth.account)
                let ack = try HTTPClient.makeJSONDecoder().decode(DiagnosticsChunkAcknowledgment.self, from: response.data)
                guard ack.totalChunks == session.totalChunks, ack.receivedChunks == index + 1 else {
                    throw DiagnosticsUploadError.underlying("Invalid chunk acknowledgment")
                }
            }
            try await requireDestination()
            completing = true
            let response = try await http.requestData(method: "POST", path: path + "/complete", body: Data(),
                headers: headers, timeout: .extended, expectedAccount: auth.account)
            guard let current = await tokens.captureOrdinaryRequestAuth(), current.account == auth.account else {
                throw HTTPError.requestIdentityChanged
            }
            return try HTTPClient.makeJSONDecoder().decode(DiagnosticsUploadResponse.self, from: response.data)
        } catch DiagnosticsUploadError.retryable(let code) where code == "destination_changed" {
            throw DiagnosticsUploadError.retryable(code)
        } catch {
            // Never abort/replay/reinitialize after completion may have consumed
            // the session. Its404 is not evidence that no report was created.
            if !completing, let current = await tokens.captureOrdinaryRequestAuth(), current.account == auth.account {
                _ = try? await http.requestData(method: "DELETE", path: path, headers: headers, expectedAccount: auth.account)
            }
            if let error = error as? HTTPError { throw Self.mapUploadError(error) }
            throw error
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
