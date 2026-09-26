import Foundation

/// The server contract's `x-silo-retry-safety` classes
/// (`contracts/api/v2/openapi.json` in silo-server), spelled as the contract
/// spells them. `non_retryable` means a client never repeats the operation
/// automatically after an uncertain answer.
enum APIv2RetrySafety: String, CaseIterable, Sendable {
    case naturalIdempotent = "natural_idempotent"
    case uniqueConstraint = "unique_constraint"
    case domainIdentity = "domain_identity"
    case coalescing
    case durableDispatch = "durable_dispatch"
    case nonRetryable = "non_retryable"
    /// No client operation uses it yet; kept so every contract class decodes.
    case idempotencyKey = "idempotency_key"
}

/// One mutation the client sends, with the contract's retry-safety class.
struct APIv2MutationOperation: Sendable, Equatable {
    /// Uppercase HTTP method.
    let method: String
    /// Path template exactly as the contract spells it, for example
    /// `/api/v2/collections/{id}`.
    let template: String
    let retrySafety: APIv2RetrySafety
    /// The contract would allow a replay, but the client sends the operation
    /// once anyway.
    let clientSingleDispatch: Bool

    init(_ method: String, _ template: String, _ retrySafety: APIv2RetrySafety, clientSingleDispatch: Bool = false) {
        self.method = method
        self.template = template
        self.retrySafety = retrySafety
        self.clientSingleDispatch = clientSingleDispatch
    }

    /// Whether a 401 on this operation may refresh the session and re-send it.
    var replaysAfterRefresh: Bool { retrySafety != .nonRetryable && !clientSingleDispatch }

    /// The number of literal segments when `segments` fits the template, or
    /// nil. A `{...}` segment matches any segment; others must be equal.
    fileprivate func literalSegmentCount(matching segments: [Substring]) -> Int? {
        let parts = template.split(separator: "/")
        guard parts.count == segments.count else { return nil }
        var literals = 0
        for (part, segment) in zip(parts, segments) {
            if part.hasPrefix("{"), part.hasSuffix("}") { continue }
            guard part == segment else { return nil }
            literals += 1
        }
        return literals
    }
}

/// Every mutation the client sends, and whether `HTTPClient` may replay it
/// after a 401 refresh. This is an allowlist: a mutation missing from it is
/// sent once. `APIv2RetrySafetyTests` checks each entry against the vendored
/// contract excerpt (`Tests/Fixtures/APIv2RetrySafety`).
enum APIv2MutationCatalog {
    static let operations: [APIv2MutationOperation] = replayAllowed + nonRetryable + clientSingleDispatch

    /// The catalog entry for a concrete request, or nil. Any query string is
    /// ignored. When several templates match, the one with the most literal
    /// segments wins; on a tie, the first in `candidates`.
    static func operation(
        method: String,
        path: String,
        in candidates: [APIv2MutationOperation] = APIv2MutationCatalog.operations
    ) -> APIv2MutationOperation? {
        let verb = method.uppercased()
        let bare = path.firstIndex(of: "?").map { path[..<$0] } ?? path[...]
        let segments = bare.split(separator: "/")
        var best: (operation: APIv2MutationOperation, literals: Int)?
        for candidate in candidates where candidate.method == verb {
            guard let literals = candidate.literalSegmentCount(matching: segments) else { continue }
            if literals > (best?.literals ?? -1) {
                best = (candidate, literals)
            }
        }
        return best?.operation
    }

    /// Operations the client replays after a refresh, all permitted by the
    /// contract.
    private static let replayAllowed: [APIv2MutationOperation] = [
        // Auth
        .init("POST", "/api/v2/auth/device/approve-handoff", .domainIdentity),
        .init("POST", "/api/v2/auth/device/deny", .domainIdentity),
        .init("POST", "/api/v2/auth/logout", .naturalIdempotent),
        // Profiles and track preferences
        .init("POST", "/api/v2/profiles/{id}/verify-pin", .naturalIdempotent),
        .init("PUT", "/api/v2/audio-prefs/{series_id}", .naturalIdempotent),
        .init("DELETE", "/api/v2/audio-prefs/{series_id}", .naturalIdempotent),
        .init("PUT", "/api/v2/subtitle-prefs/{series_id}", .naturalIdempotent),
        .init("DELETE", "/api/v2/subtitle-prefs/{series_id}", .naturalIdempotent),
        // Settings values
        .init("PUT", "/api/v2/settings/values/{key}", .naturalIdempotent),
        .init("PUT", "/api/v2/settings/values/nav.shortcuts/item", .naturalIdempotent),
        .init("DELETE", "/api/v2/settings/values/{key}", .naturalIdempotent),
        // Catalog and home
        .init("POST", "/api/v2/catalog/query", .naturalIdempotent),
        .init("PUT", "/api/v2/home/dismissals/{surface}/{item_id}", .naturalIdempotent),
        // Playback
        .init("POST", "/api/v2/playback/start", .domainIdentity),
        .init("POST", "/api/v2/playback/{session_id}/progress", .domainIdentity),
        .init("DELETE", "/api/v2/playback/{session_id}", .domainIdentity),
        // Diagnostics uploads
        .init("PUT", "/api/v2/diagnostics/reports/uploads/{upload_id}/chunks/{chunk_index}", .naturalIdempotent),
        .init("DELETE", "/api/v2/diagnostics/reports/uploads/{upload_id}", .naturalIdempotent),
        // Downloads
        .init("PATCH", "/api/v2/downloads/{id}", .domainIdentity),
        .init("DELETE", "/api/v2/downloads/{id}", .naturalIdempotent),
        .init("PATCH", "/api/v2/downloads/subscriptions/{id}", .naturalIdempotent),
        .init("DELETE", "/api/v2/downloads/subscriptions/{id}", .naturalIdempotent),
        .init("POST", "/api/v2/downloads/subscriptions/sync", .naturalIdempotent),
        // Subtitles
        .init("POST", "/api/v2/subtitles/search", .naturalIdempotent),
        .init("POST", "/api/v2/subtitles/ai/jobs/{job_id}/cancel", .naturalIdempotent),
        // Watch together
        .init("POST", "/api/v2/watch-together/rooms", .uniqueConstraint),
        .init("POST", "/api/v2/watch-together/join", .naturalIdempotent),
        .init("PUT", "/api/v2/watch-together/rooms/{room_id}/staged-selection", .naturalIdempotent),
        .init("POST", "/api/v2/watch-together/rooms/{room_id}/playback/stop", .naturalIdempotent),
        .init("PATCH", "/api/v2/watch-together/rooms/{room_id}/selection-mode", .naturalIdempotent),
        .init("PATCH", "/api/v2/watch-together/rooms/{room_id}/policy", .naturalIdempotent),
        .init("DELETE", "/api/v2/watch-together/rooms/{room_id}", .naturalIdempotent),
        .init("POST", "/api/v2/watch-together/rooms/{room_id}/suggestions", .uniqueConstraint),
        .init("DELETE", "/api/v2/watch-together/rooms/{room_id}/suggestions/{suggestion_id}", .naturalIdempotent),
        .init("POST", "/api/v2/watch-together/rooms/{room_id}/suggestions/{suggestion_id}/vote", .uniqueConstraint),
        .init("DELETE", "/api/v2/watch-together/rooms/{room_id}/suggestions/{suggestion_id}/vote", .naturalIdempotent),
        .init("POST", "/api/v2/watch-together/rooms/{room_id}/member-state", .naturalIdempotent),
        .init("POST", "/api/v2/watch-together/rooms/{room_id}/ws-ticket", .naturalIdempotent),
        .init("POST", "/api/v2/watch-together/rooms/{room_id}/source-fallback", .naturalIdempotent),
    ]

    /// `non_retryable` operations the client sends. They would be sent once
    /// without an entry too; listing them lets the contract test cover each
    /// one by name.
    private static let nonRetryable: [APIv2MutationOperation] = [
        .init("POST", "/api/v2/sync/progress", .nonRetryable),
        // Personal collections
        .init("POST", "/api/v2/collections", .nonRetryable),
        .init("POST", "/api/v2/collections/groups", .nonRetryable),
        .init("PATCH", "/api/v2/collections/{id}", .nonRetryable),
        .init("PATCH", "/api/v2/collections/groups/{id}", .nonRetryable),
        .init("DELETE", "/api/v2/collections/{id}", .nonRetryable),
        .init("DELETE", "/api/v2/collections/groups/{id}", .nonRetryable),
        // Media requests
        .init("POST", "/api/v2/requests", .nonRetryable),
        .init("POST", "/api/v2/requests/{id}/cancel", .nonRetryable),
        // Watch together
        .init("POST", "/api/v2/watch-together/rooms/{room_id}/playback/start", .nonRetryable),
        .init("PUT", "/api/v2/watch-together/rooms/{room_id}/selection", .nonRetryable),
        .init("POST", "/api/v2/watch-together/rooms/{room_id}/suggestions/promote", .nonRetryable),
        // Playback
        .init("POST", "/api/v2/playback/route-events", .nonRetryable),
        // Subtitles
        .init("POST", "/api/v2/subtitles/download", .nonRetryable),
        .init("POST", "/api/v2/subtitles/ai/translate", .nonRetryable),
        // Membership
        .init("PUT", "/api/v2/watchlist/{item_id}", .nonRetryable),
        .init("DELETE", "/api/v2/watchlist/{item_id}", .nonRetryable),
        .init("PUT", "/api/v2/favorites/{item_id}", .nonRetryable),
        .init("DELETE", "/api/v2/favorites/{item_id}", .nonRetryable),
        .init("POST", "/api/v2/watched/{id}", .nonRetryable),
        .init("DELETE", "/api/v2/watched/{id}", .nonRetryable),
        // Downloads
        .init("POST", "/api/v2/downloads", .nonRetryable),
        .init("POST", "/api/v2/downloads/subscriptions", .nonRetryable),
        // Onboarding and profiles
        .init("PUT", "/api/v2/onboarding/progress", .nonRetryable),
        .init("POST", "/api/v2/profiles", .nonRetryable),
        .init("PATCH", "/api/v2/profiles/{id}", .nonRetryable),
        // Catalog refreshes
        .init("POST", "/api/v2/catalog/items/{id}/trailers/refresh", .nonRetryable),
        .init("POST", "/api/v2/catalog/people/{id}/refresh", .nonRetryable),
        // Diagnostics
        .init("POST", "/api/v2/diagnostics/reports", .nonRetryable),
        .init("POST", "/api/v2/diagnostics/reports/uploads", .nonRetryable),
        .init("POST", "/api/v2/diagnostics/reports/uploads/{upload_id}/complete", .nonRetryable),
    ]

    /// The contract permits a replay; the client sends these once.
    private static let clientSingleDispatch: [APIv2MutationOperation] = [
        // Kept single-dispatch from the old table; loosening is a separate change.
        .init("POST", "/api/v2/playback/sessions/{session_id}/control/ws-ticket", .naturalIdempotent,
              clientSingleDispatch: true),
        // Kept single-dispatch from the old table; loosening is a separate change.
        .init("POST", "/api/v2/playback/{session_id}/replan", .domainIdentity, clientSingleDispatch: true),
        // Kept single-dispatch from the old table; loosening is a separate change.
        .init("POST", "/api/v2/catalog/items/{id}/translate-description", .coalescing, clientSingleDispatch: true),
        // Kept single-dispatch from the old table; loosening is a separate change.
        .init("POST", "/api/v2/devices/push/apple", .domainIdentity, clientSingleDispatch: true),
    ]
}
