import Foundation

/// Server setup status (from `GET /api/v2/system/setup` via `APIv2Client`).
struct SetupStatus: Codable {
    let needsSetup: Bool
}

/// Liveness + identity probe from GET /api/v1/health.
///
/// The server returns `{"status": "ok"}` always; `serverName` and
/// `serverId` are populated from server config and used by the multi-
/// server picker to show a friendly name for each saved server.
/// Both identity fields are optional to remain compatible with older
/// servers that predate the identity addition.
struct HealthStatus: Codable {
    let status: String
    let serverName: String?
    let serverId: String?
}

/// Public native identity from GET /api/v2/theme/branding (with legacy fallback).
///
/// Native clients consume only the name. Optional v2 asset URLs and web styling
/// fields are ignored, so absent artwork does not affect server identity.
struct ServerBrandingStatus: Codable {
    let serverName: String?
}
