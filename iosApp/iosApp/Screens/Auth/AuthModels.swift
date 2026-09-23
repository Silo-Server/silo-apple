import Foundation

/// Reachability reply from the retained, unauthenticated
/// `GET /api/v1/health` (`ConnectionMonitor.probeServer`).
struct HealthStatus: Codable {
    let status: String
}

/// Public pre-login branding from `GET /api/v2/theme/branding`. Only the
/// server name is read; the white-label fields are not used by the Apple
/// clients. The contract requires `server_name`, but the server sends an
/// empty string when none is configured.
struct ServerBrandingStatus: Decodable {
    let serverName: String
}
