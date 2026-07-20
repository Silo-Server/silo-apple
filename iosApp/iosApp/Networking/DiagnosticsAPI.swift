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

    var serverInstanceID: String {
        serverInstanceId
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
    case retryable(String)
    case underlying(String)
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
                        contentType: "application/json",
                        data: manifestData
                    ),
                    HTTPMultipartPart(
                        name: "bundle",
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

    private static func mapUploadError(_ error: HTTPError) -> DiagnosticsUploadError {
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
            if error.statusCode.map({ $0 >= 500 || $0 == 429 }) == true {
                return .retryable(code)
            }
            return .underlying(code)
        case nil:
            if error.statusCode.map({ $0 >= 500 || $0 == 429 }) == true {
                return .retryable("http_\(error.statusCode ?? 0)")
            }
            return .underlying(error.localizedDescription)
        }
    }
}
#endif
