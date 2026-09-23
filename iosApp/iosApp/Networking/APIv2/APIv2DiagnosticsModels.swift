#if os(iOS) || os(tvOS)
import Foundation

// Wire models for diagnostics (`getDiagnosticsCapabilities`).

/// `GET /api/v2/diagnostics/capabilities` (`DiagnosticsCapabilities`).
struct APIv2DiagnosticsCapabilities: Decodable, Equatable, Sendable {
    let allowed: Bool
    /// Opaque; never compared against a literal.
    let revision: String
    let state: String
    let serverInstanceId: String
    let acceptedSchemaVersions: [Int]
    let maxBundleBytes: Int
    let maxManifestBytes: Int
    let retentionDays: Int
    let consentNoticeVersion: Int
    /// Zero when this server does not offer the chunked upload routes.
    let uploadChunkBytes: Int

    /// Projects the document onto the status the coordinator stores and
    /// persists. Uploads are available only when the principal is allowed
    /// and the state is `available`; the free-form `status` string is not
    /// consulted.
    var statusResponse: DiagnosticsStatusResponse {
        DiagnosticsStatusResponse(
            status: availability,
            serverInstanceId: serverInstanceId,
            acceptedSchemaVersions: acceptedSchemaVersions,
            maxBundleBytes: maxBundleBytes,
            maxManifestBytes: maxManifestBytes,
            retentionDays: retentionDays,
            consentNoticeVersion: consentNoticeVersion,
            uploadChunkBytes: uploadChunkBytes
        )
    }

    private var availability: DiagnosticsAvailabilityStatus {
        switch state {
        case "available":
            return allowed ? .available : .disabled
        case "not_configured":
            return .storageUnavailable
        default:
            return .disabled
        }
    }
}
#endif
