import Foundation

/// Typed download / offline-sync endpoints, grouped as an extension on the
/// existing `SiloAPI` facade. These reuse the facade's injected `http`
/// transport (auth injection, 401 refresh, snake_case JSON coders) rather
/// than the legacy path dispatcher. Contract: server `docs/downloads-api.md`.
extension SiloAPI {

    // MARK: - Manifest and assets

    func fetchManifest(downloadId: String) async throws -> OfflineManifest {
        try await http.get("/api/v1/downloads/\(downloadId)/manifest")
    }

    /// Fetch the raw bytes of an authenticated proxy asset (artwork or
    /// subtitle). `path` is an API-relative path taken from the manifest
    /// (`artwork_urls.*` / `subtitles[].fetch_url`).
    func fetchDownloadAssetData(path: String) async throws -> Data {
        try await http.getData(path)
    }

    /// Build the absolute file-endpoint URL for a download, resolved
    /// against the active server origin. Used by the background downloader.
    func downloadFileURL(downloadId: String) async -> URL? {
        let base = await currentServerUrl()
        guard !base.isEmpty else { return nil }
        let trimmed = base.hasSuffix("/") ? String(base.dropLast()) : base
        return URL(string: "\(trimmed)/api/v1/downloads/\(downloadId)/file")
    }

    // MARK: - Subscriptions

    func createSubscription(_ request: CreateSubscriptionRequest) async throws -> CreateSubscriptionResponse {
        try await http.post("/api/v1/downloads/subscriptions", body: request)
    }

    /// Register newly in-scope episodes across all of this device's
    /// monitors. Returns how many were registered.
    @discardableResult
    func syncSubscriptions() async throws -> Int {
        let response: SubscriptionSyncResponse = try await http.post(
            "/api/v1/downloads/subscriptions/sync"
        )
        return response.registered
    }

    func updateSubscription(
        id: String,
        _ request: UpdateSubscriptionRequest
    ) async throws -> CreateSubscriptionResponse {
        try await http.patch("/api/v1/downloads/subscriptions/\(id)", body: request)
    }

    func deleteSubscription(id: String) async throws {
        try await http.delete("/api/v1/downloads/subscriptions/\(id)")
    }

    // MARK: - Progress reconciliation

    /// Pull watch-state changes made on any device after `cursor`,
    /// server-ordered. Pass `nil` for the initial pull.
    func pullProgressDeltas(since cursor: String?) async throws -> ProgressPullResponse {
        var query: [String: String] = [:]
        if let cursor, !cursor.isEmpty { query["since"] = cursor }
        return try await http.get("/api/v1/progress", query: query)
    }
}
