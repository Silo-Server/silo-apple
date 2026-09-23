import Foundation

/// Typed download / offline-sync endpoints, grouped as an extension on the
/// existing `SiloAPI` facade. These reuse the facade's injected `http`
/// transport (auth injection, 401 refresh, snake_case JSON coders) rather
/// than the legacy path dispatcher. Contract: server `docs/downloads-api.md`.
extension SiloAPI {

    // MARK: - Progress reconciliation

    /// Pull watch-state changes made on any device after `cursor`,
    /// server-ordered. Pass `nil` for the initial pull.
    func pullProgressDeltas(since cursor: String?) async throws -> ProgressPullResponse {
        var query: [String: String] = [:]
        if let cursor, !cursor.isEmpty { query["since"] = cursor }
        return try await http.get("/api/v1/progress", query: query)
    }
}
