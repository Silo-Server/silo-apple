#if os(iOS) || os(tvOS)
import Foundation

struct HostedDiagnosticsCapabilities: Codable, Equatable, Sendable {
    static let pinnedCollectorID = "silo-public-diagnostics-v1"
    static let conservativeCaptureStatus = DiagnosticsStatusResponse(
        status: .available,
        serverInstanceId: pinnedCollectorID,
        acceptedSchemaVersions: [1],
        maxBundleBytes: 10 * 1024 * 1024,
        maxManifestBytes: 64 * 1024,
        retentionDays: 30,
        consentNoticeVersion: 1,
        uploadChunkBytes: nil
    )

    let status: DiagnosticsAvailabilityStatus
    let collectorId: String
    let acceptedSchemaVersions: [Int]
    let maxBundleBytes: Int
    let maxManifestBytes: Int
    let retentionDays: Int
    let consentNoticeVersion: Int

    enum CodingKeys: String, CodingKey {
        case status
        case collectorId = "collector_id"
        case acceptedSchemaVersions = "accepted_schema_versions"
        case maxBundleBytes = "max_bundle_bytes"
        case maxManifestBytes = "max_manifest_bytes"
        case retentionDays = "retention_days"
        case consentNoticeVersion = "consent_notice_version"
    }

    var statusResponse: DiagnosticsStatusResponse {
        DiagnosticsStatusResponse(
            status: status,
            serverInstanceId: collectorId,
            acceptedSchemaVersions: acceptedSchemaVersions,
            maxBundleBytes: maxBundleBytes,
            maxManifestBytes: maxManifestBytes,
            retentionDays: retentionDays,
            consentNoticeVersion: consentNoticeVersion,
            uploadChunkBytes: nil
        )
    }
}

struct HostedDiagnosticsCredential: Codable, Equatable, Sendable {
    let installationID: String
    let installationToken: String
}

protocol HostedDiagnosticsCredentialStoring: Sendable {
    func load() -> HostedDiagnosticsCredential?
    @discardableResult
    func save(_ credential: HostedDiagnosticsCredential) -> Bool
    func clear()
}

struct HostedDiagnosticsKeychainCredentialStore: HostedDiagnosticsCredentialStoring, @unchecked Sendable {
    private static let installationIDAccount = "com.continuum.diagnostics.hosted.installationID"
    private static let installationTokenAccount = "com.continuum.diagnostics.hosted.installationToken"

    private let keychain: SharedKeychain

    init(keychain: SharedKeychain = SharedKeychain()) {
        self.keychain = keychain
    }

    func load() -> HostedDiagnosticsCredential? {
        guard let installationID = keychain.get(Self.installationIDAccount),
              !installationID.isEmpty,
              let installationToken = keychain.get(Self.installationTokenAccount),
              !installationToken.isEmpty else {
            return nil
        }
        return HostedDiagnosticsCredential(
            installationID: installationID,
            installationToken: installationToken
        )
    }

    @discardableResult
    func save(_ credential: HostedDiagnosticsCredential) -> Bool {
        guard keychain.set(credential.installationID, for: Self.installationIDAccount) else {
            return false
        }
        guard keychain.set(credential.installationToken, for: Self.installationTokenAccount) else {
            keychain.delete(Self.installationIDAccount)
            return false
        }
        return true
    }

    func clear() {
        keychain.delete(Self.installationIDAccount)
        keychain.delete(Self.installationTokenAccount)
    }
}

enum DiagnosticsRemoteReportState: String, Codable, Equatable, Sendable {
    case receiving
    case uploaded
    case processing
    case ready
    case rejected
    case deleting
    case deleted
}

enum HostedDiagnosticsAPIError: Error, Equatable {
    case invalidBaseURL
    case invalidResponse
    case collectorIdentityMismatch
    case credentialPersistenceFailed
    case reportIdentityMismatch
    case remoteReportIdentityMismatch
    case rejected(String?)
    case http(statusCode: Int, code: String?)
    case underlying(String)
}

actor HostedDiagnosticsAPI {
    static let defaultBaseURL: URL = {
        guard let url = URL(string: "https://diagnostics.siloserver.org") else {
            fatalError("The hosted diagnostics URL must be valid.")
        }
        return url
    }()
    static let shared = HostedDiagnosticsAPI()

    private let baseURL: URL
    private let session: URLSession
    private let credentialStore: any HostedDiagnosticsCredentialStoring
    /// A Task, rather than a boolean, makes first-run registration single
    /// flight across actor reentrancy: every concurrent upload awaits and uses
    /// the exact credential that wins persistence.
    private var installationCredentialTask: Task<HostedDiagnosticsCredential, Error>?

    init(
        baseURL: URL = HostedDiagnosticsAPI.defaultBaseURL,
        session: URLSession = HostedDiagnosticsAPI.makeIsolatedSession(),
        credentialStore: any HostedDiagnosticsCredentialStoring = HostedDiagnosticsKeychainCredentialStore()
    ) {
        self.baseURL = baseURL
        self.session = session
        self.credentialStore = credentialStore
    }

    nonisolated static func makeIsolatedSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(
            configuration: configuration,
            delegate: HostedDiagnosticsSessionDelegate(),
            delegateQueue: nil
        )
    }

    func capabilities() async throws -> HostedDiagnosticsCapabilities {
        var request = try request(path: "v1/capabilities", method: "GET")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 10
        let response = try await perform(request, as: HostedDiagnosticsCapabilities.self)
        guard response.collectorId == HostedDiagnosticsCapabilities.pinnedCollectorID,
              response.acceptedSchemaVersions.contains(1),
              response.maxBundleBytes > 0,
              response.maxManifestBytes > 0,
              response.retentionDays == HostedDiagnosticsCapabilities.conservativeCaptureStatus.retentionDays,
              response.consentNoticeVersion > 0 else {
            throw HostedDiagnosticsAPIError.collectorIdentityMismatch
        }
        return response
    }

    /// Read only for exact-match bundle redaction. The token is never logged,
    /// serialized into a manifest, or sent anywhere except the collector's
    /// Authorization header.
    func installationTokenForRedaction() -> String? {
        credentialStore.load()?.installationToken
    }

    func upload(
        reportID: UUID,
        manifest: DiagnosticsManifest,
        bundleData: Data
    ) async throws -> DiagnosticsUploadResponse {
        try await upload(
            reportID: reportID,
            manifest: manifest,
            bundleData: bundleData,
            canRefreshCredential: true
        )
    }

    func reportStatus(reportID: UUID) async throws -> HostedReportStatusResponse {
        guard let credential = credentialStore.load() else {
            throw HostedDiagnosticsAPIError.credentialPersistenceFailed
        }
        let reportIDString = reportID.uuidString.lowercased()
        var request = try self.request(path: "v1/reports/\(reportIDString)", method: "GET")
        request.timeoutInterval = 10
        authorize(&request, token: credential.installationToken)
        let status = try await perform(request, as: HostedReportStatusResponse.self)
        guard status.reportID.caseInsensitiveCompare(reportIDString) == .orderedSame,
              !status.shortID.isEmpty else {
            throw HostedDiagnosticsAPIError.remoteReportIdentityMismatch
        }
        return status
    }

    func deleteReport(reportID: UUID) async throws {
        guard let credential = credentialStore.load() else {
            throw HostedDiagnosticsAPIError.credentialPersistenceFailed
        }
        let reportIDString = reportID.uuidString.lowercased()
        var request = try self.request(path: "v1/reports/\(reportIDString)", method: "DELETE")
        request.timeoutInterval = 10
        authorize(&request, token: credential.installationToken)
        // The collector returns 204 for both an owned report and a valid
        // not-yet-created UUID after durably recording its global tombstone.
        // A 404 therefore means this installation did not prove ownership; it
        // must remain retryable rather than silently clearing local intent.
        try await performNoContent(request)
    }

    private func upload(
        reportID: UUID,
        manifest: DiagnosticsManifest,
        bundleData: Data,
        canRefreshCredential: Bool
    ) async throws -> DiagnosticsUploadResponse {
        guard manifest.report.profileID == nil,
              manifest.playbackSessionIds.isEmpty,
              manifest.destination.serverInstanceID == HostedDiagnosticsCapabilities.pinnedCollectorID else {
            throw HostedDiagnosticsAPIError.reportIdentityMismatch
        }

        let credential = try await installationCredential(platform: manifest.report.platform)
        let reportIDString = reportID.uuidString.lowercased()
        let createBody = HostedCreateReportRequest(
            reportID: reportIDString,
            manifest: manifest,
            bundleBytes: bundleData.count,
            bundleSHA256: DiagnosticsSHA256.hex(data: bundleData)
        )
        var createRequest = try request(path: "v1/reports", method: "POST")
        authorize(&createRequest, token: credential.installationToken)
        createRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        createRequest.httpBody = try DiagnosticsJSONCoding.makeEncoder().encode(createBody)

        let created: HostedCreateReportResponse
        do {
            created = try await perform(createRequest, as: HostedCreateReportResponse.self)
        } catch HostedDiagnosticsAPIError.http(
            statusCode: 401,
            code: "invalid_installation_token"
        ) where canRefreshCredential {
            // Recover only when the initial create proves the stored anonymous
            // credential is invalid. Once a report has been accepted, clearing
            // its owning credential on a later PUT/GET 401 would orphan that
            // remote report and make a replay conflict under the replacement.
            credentialStore.clear()
            return try await upload(
                reportID: reportID,
                manifest: manifest,
                bundleData: bundleData,
                canRefreshCredential: false
            )
        }
        guard created.reportID.caseInsensitiveCompare(reportIDString) == .orderedSame else {
            throw HostedDiagnosticsAPIError.remoteReportIdentityMismatch
        }

        var uploadRequest = try request(
            path: "v1/reports/\(reportIDString)/bundle",
            method: "PUT"
        )
        authorize(&uploadRequest, token: credential.installationToken)
        uploadRequest.setValue(created.uploadToken, forHTTPHeaderField: "X-Upload-Token")
        uploadRequest.setValue("application/gzip", forHTTPHeaderField: "Content-Type")
        uploadRequest.setValue(String(bundleData.count), forHTTPHeaderField: "Content-Length")
        uploadRequest.httpBody = bundleData
        let accepted = try await performAccepted(
            uploadRequest,
            as: HostedReportStatusResponse.self
        )
        guard accepted.reportID.caseInsensitiveCompare(reportIDString) == .orderedSame,
              !created.shortID.isEmpty,
              accepted.shortID == created.shortID else {
            throw HostedDiagnosticsAPIError.remoteReportIdentityMismatch
        }
        guard accepted.state == .processing || accepted.state == .ready else {
            // A 202 is durable only when the collector confirms that the
            // bundle is owned and queued/processed. Treat every other state as
            // a malformed acknowledgement so the pending evidence is kept for
            // an idempotent retry.
            throw HostedDiagnosticsAPIError.invalidResponse
        }

        var statusRequest = try request(path: "v1/reports/\(reportIDString)", method: "GET")
        statusRequest.timeoutInterval = 10
        authorize(&statusRequest, token: credential.installationToken)
        var status = accepted
        do {
            let refreshed = try await perform(statusRequest, as: HostedReportStatusResponse.self)
            guard refreshed.reportID.caseInsensitiveCompare(reportIDString) == .orderedSame,
                  refreshed.shortID == created.shortID else {
                throw HostedDiagnosticsAPIError.remoteReportIdentityMismatch
            }
            status = refreshed
        } catch HostedDiagnosticsAPIError.remoteReportIdentityMismatch {
            throw HostedDiagnosticsAPIError.remoteReportIdentityMismatch
        } catch {
            // The validated 202 response means R2 ownership is durable. Status
            // refresh is informational; the caller keeps the local report and
            // can poll again without rebuilding the accepted envelope.
        }
        switch status.state {
        case .rejected, .deleting, .deleted:
            throw HostedDiagnosticsAPIError.rejected(status.errorCode ?? status.state.rawValue)
        case .receiving, .uploaded:
            // A stale/non-canonical GET must not weaken the validated durable
            // PUT acknowledgement. The public API exposes only processing or
            // ready after acceptance, but retaining the PUT state fails safe
            // if that contract ever regresses.
            status = accepted
        case .processing, .ready:
            break
        }
        return DiagnosticsUploadResponse(
            reportId: status.reportID,
            shortId: status.shortID.isEmpty ? created.shortID : status.shortID,
            state: status.state
        )
    }

    /// Internal so the single-flight boundary can be exercised without
    /// creating unrelated remote report state in tests.
    func installationCredential(platform: Platform) async throws -> HostedDiagnosticsCredential {
        if let existing = credentialStore.load() {
            return existing
        }
        if let installationCredentialTask {
            return try await installationCredentialTask.value
        }

        let task = Task {
            try await registerInstallation(platform: platform)
        }
        installationCredentialTask = task
        defer { installationCredentialTask = nil }
        return try await task.value
    }

    private func registerInstallation(platform: Platform) async throws -> HostedDiagnosticsCredential {
        let body = HostedInstallationRequest(
            platform: platform,
            appID: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
            appVersion: AppleDeviceIdentity.bundleAppVersion,
            appBuild: AppleDeviceIdentity.bundleAppBuild
        )
        var request = try request(path: "v1/installations", method: "POST")
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try DiagnosticsJSONCoding.makeEncoder().encode(body)
        let response = try await perform(request, as: HostedInstallationResponse.self)
        let credential = HostedDiagnosticsCredential(
            installationID: response.installationID,
            installationToken: response.installationToken
        )
        guard credentialStore.save(credential) else {
            throw HostedDiagnosticsAPIError.credentialPersistenceFailed
        }
        return credential
    }

    private func request(path: String, method: String) throws -> URLRequest {
        guard baseURL.scheme?.lowercased() == "https",
              baseURL.host != nil,
              baseURL.path.isEmpty || baseURL.path == "/",
              baseURL.user == nil,
              baseURL.password == nil,
              baseURL.query == nil,
              baseURL.fragment == nil else {
            throw HostedDiagnosticsAPIError.invalidBaseURL
        }
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = method
        request.timeoutInterval = 120
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    private func authorize(_ request: inout URLRequest, token: String) {
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    private func perform<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HostedDiagnosticsAPIError.invalidResponse
            }
            guard (200...299).contains(httpResponse.statusCode) else {
                let envelope = try? DiagnosticsJSONCoding.makeDecoder().decode(
                    HostedErrorEnvelope.self,
                    from: data
                )
                throw HostedDiagnosticsAPIError.http(
                    statusCode: httpResponse.statusCode,
                    code: envelope?.error
                )
            }
            return try DiagnosticsJSONCoding.makeDecoder().decode(type, from: data)
        } catch let error as HostedDiagnosticsAPIError {
            throw error
        } catch {
            throw HostedDiagnosticsAPIError.underlying(String(describing: error))
        }
    }

    private func performAccepted<Response: Decodable>(
        _ request: URLRequest,
        as type: Response.Type
    ) async throws -> Response {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HostedDiagnosticsAPIError.invalidResponse
            }
            guard httpResponse.statusCode == 202 else {
                let envelope = try? DiagnosticsJSONCoding.makeDecoder().decode(
                    HostedErrorEnvelope.self,
                    from: data
                )
                throw HostedDiagnosticsAPIError.http(
                    statusCode: httpResponse.statusCode,
                    code: envelope?.error
                )
            }
            return try DiagnosticsJSONCoding.makeDecoder().decode(type, from: data)
        } catch let error as HostedDiagnosticsAPIError {
            throw error
        } catch {
            throw HostedDiagnosticsAPIError.underlying(String(describing: error))
        }
    }

    private func performNoContent(_ request: URLRequest) async throws {
        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse else {
                throw HostedDiagnosticsAPIError.invalidResponse
            }
            guard httpResponse.statusCode == 204 else {
                let envelope = try? DiagnosticsJSONCoding.makeDecoder().decode(
                    HostedErrorEnvelope.self,
                    from: data
                )
                throw HostedDiagnosticsAPIError.http(
                    statusCode: httpResponse.statusCode,
                    code: envelope?.error
                )
            }
        } catch let error as HostedDiagnosticsAPIError {
            throw error
        } catch {
            throw HostedDiagnosticsAPIError.underlying(String(describing: error))
        }
    }
}

private final class HostedDiagnosticsSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Never carry the anonymous installation bearer or raw bundle across
        // an HTTP redirect. Endpoint changes are shipped explicitly in-app.
        completionHandler(nil)
    }
}

private struct HostedInstallationRequest: Encodable {
    let platform: Platform
    let appID: String
    let appVersion: String
    let appBuild: String

    enum CodingKeys: String, CodingKey {
        case platform
        case appID = "app_id"
        case appVersion = "app_version"
        case appBuild = "app_build"
    }
}

private struct HostedInstallationResponse: Decodable {
    let installationID: String
    let installationToken: String

    enum CodingKeys: String, CodingKey {
        case installationID = "installation_id"
        case installationToken = "installation_token"
    }
}

private struct HostedCreateReportRequest: Encodable {
    let reportID: String
    let manifest: DiagnosticsManifest
    let bundleBytes: Int
    let bundleSHA256: String

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case manifest
        case bundleBytes = "bundle_bytes"
        case bundleSHA256 = "bundle_sha256"
    }
}

private struct HostedCreateReportResponse: Decodable {
    let reportID: String
    let shortID: String
    let uploadToken: String
    let expiresAt: String

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case shortID = "short_id"
        case uploadToken = "upload_token"
        case expiresAt = "expires_at"
    }
}

struct HostedReportStatusResponse: Decodable {
    let reportID: String
    let shortID: String
    let state: DiagnosticsRemoteReportState
    let errorCode: String?

    enum CodingKeys: String, CodingKey {
        case reportID = "report_id"
        case shortID = "short_id"
        case state
        case errorCode = "error_code"
    }
}

private struct HostedErrorEnvelope: Decodable {
    let error: String?
}
#endif
