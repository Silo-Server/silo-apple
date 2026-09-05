import Foundation

/// Wire-only support. This does not activate bootstrap or replace any local progress.
struct APIv2ProgressBootstrapCapabilities: Decodable {
    let revision: String
    let state: String
    let allowed: Bool?
    let mode: String
    let incremental: Bool
    let installationId: String?
    let generation: String?
    let maxPageSize: Int
    let maxSnapshotItems: Int
    let maxSnapshotBytes: Int64
    let snapshotTtlSeconds: Int
    let maxActiveSnapshotsPerAccount: Int

    var supportsFullReplacement: Bool {
        state == "available" && allowed == true && mode == "full_replace" && !incremental
            && installationId?.isEmpty == false && generation?.isEmpty == false
    }
}

/// Created once per admission intent. Replay passes this same value, never a new UUID.
/// Persistence and the documented 24-hour replay horizon belong to the future coordinator.
struct APIv2ProgressSnapshotIntent {
    let requestId: UUID
    let limit: Int
    let identity: HTTPRequestIdentity
    let account: RefreshAccountIdentity
}

struct APIv2ProgressSnapshot: Decodable {
    let snapshotId: String
    let installationId: String
    let accountId: String
    let profileId: String
    let generation: String
    let mode: String
    let capturedAt: Date
    let expiresAt: Date
    let itemCount: Int
    let items: [APIv2ProgressEntry]
    let page: APIv2Page
    let complete: Bool
    let completionToken: String?
}

/// Opaque server receipt; it is neither an upload acknowledgement nor a cursor.
struct APIv2ProgressCompletionReceipt {
    let token: String
}

struct APIv2ProgressSnapshotCursor {
    let token: String
    let snapshot: APIv2ProgressSnapshot
    let intent: APIv2ProgressSnapshotIntent
    let seenCursors: Set<String>
    let seenItems: Set<String>
}

struct APIv2ProgressSnapshotResult {
    let value: APIv2ProgressSnapshot
    let location: String
    let continuation: APIv2ProgressSnapshotCursor?
    let receipt: APIv2ProgressCompletionReceipt?
}

enum APIv2ProgressBootstrapError: LocalizedError {
    case invalidIntent
    case invalidSnapshot
    case response(status: Int, problem: APIv2Problem?, retryAfter: String?)

    var errorDescription: String? {
        switch self {
        case .invalidIntent: return "The progress snapshot request is not valid."
        case .invalidSnapshot: return "The server returned an inconsistent progress snapshot."
        case .response(let status, let problem, _):
            return problem.map { $0.detail.isEmpty ? $0.title : $0.detail } ?? "The server returned HTTP \(status)."
        }
    }
}
