import Foundation

/// Typed download / offline-sync endpoints, grouped as an extension on the
/// existing `SiloAPI` facade. These reuse the facade's injected `http`
/// transport (auth injection, 401 refresh, snake_case JSON coders) rather
/// than the legacy path dispatcher. Contract: server `docs/downloads-api.md`.
extension SiloAPI {

    // Registry reads, status reports and deletion use DownloadManager ownership.

    /// Register a managed download. Returns one row for a single item, or
    /// every batch member for a series/season request.
    func createDownload(_ request: CreateDownloadRequest) async throws -> [ServerDownloadRow] {
        let response: CreateDownloadResponse = try await http.post(
            "/api/v1/downloads",
            body: request
        )
        return response.downloads
    }

    // Subscription lifecycle uses DownloadManager captured ownership.

    // MARK: - Progress reconciliation

    /// Flush a batch of queued offline progress events. Returns per-item
    /// results so the caller can drop acked items from its queue.
    func syncProgressBatch(items: [SyncProgressItem]) async throws -> [SyncProgressResult] {
        guard !items.isEmpty else { return [] }
        let response: SyncProgressResultsResponse = try await http.post(
            "/api/v1/sync/progress",
            body: SyncProgressRequest(items: items)
        )
        return response.results
    }

    /// Pull watch-state changes made on any device after `cursor`,
    /// server-ordered. Pass `nil` for the initial pull.
    func pullProgressDeltas(since cursor: String?) async throws -> ProgressPullResponse {
        var query: [String: String] = [:]
        if let cursor, !cursor.isEmpty { query["since"] = cursor }
        return try await http.get("/api/v1/progress", query: query)
    }

    /// One page of the active profile's watch progress from
    /// `GET /api/v2/progress` (the pilot's profile-scoped read). The `since`
    /// delta pull above is a different operation and deliberately stays v1.
    func listProgress(
        status: APIv2ProgressStatus? = nil,
        libraryId: String? = nil,
        limit: Int? = nil,
        cursor: String? = nil
    ) async throws -> APIv2ProgressPage {
        try await v2.listProgress(status: status, libraryId: libraryId, limit: limit, cursor: cursor)
    }
}

// MARK: - Request/response helpers

/// `POST /api/v1/downloads` returns either a bare row (single item) or a
/// `{ "downloads": [...] }` batch. This decodes both into a row list.
struct CreateDownloadResponse: Decodable, Sendable {
    let downloads: [ServerDownloadRow]

    private enum CodingKeys: String, CodingKey {
        case downloads
    }

    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: CodingKeys.self),
           let rows = try? keyed.decode([ServerDownloadRow].self, forKey: .downloads) {
            self.downloads = rows
            return
        }
        let single = try ServerDownloadRow(from: decoder)
        self.downloads = [single]
    }
}

/// Per-item result envelope from `POST /api/v1/sync/progress` (§5.1).
struct SyncProgressResultsResponse: Codable, Sendable {
    let results: [SyncProgressResult]
}

struct SyncProgressResult: Codable, Sendable {
    let mediaItemId: String
    let status: String
    let error: String?

    var isOK: Bool { status == "ok" }
}
