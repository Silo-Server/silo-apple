import Foundation

/// Resolves the native display name advertised by a Silo server.
///
/// Branding owns the native product identity. Health remains a compatibility
/// fallback for servers that predate the public branding endpoint.
struct ServerIdentityResolver {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchServerName(serverURL: String) async -> String? {
        if let branding: ServerBrandingStatus = try? await httpClient.getUnauthenticated(
            serverURL: serverURL,
            path: "/api/v1/theme/branding"
        ), let name = Self.usableName(branding.serverName) {
            return name
        }

        if let health: HealthStatus = try? await httpClient.getUnauthenticated(
            serverURL: serverURL,
            path: "/api/v1/health"
        ) {
            return Self.usableName(health.serverName)
        }
        return nil
    }

    private static func usableName(_ value: String?) -> String? {
        guard let name = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            return nil
        }
        return name
    }
}
