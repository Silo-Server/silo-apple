import Foundation

/// Resolves the native display name advertised by a Silo server.
///
/// Branding owns the native product identity. Health remains a compatibility
/// fallback when branding is blank or the endpoint returns 404, indicating a
/// server that predates the public branding endpoint. Other failures leave the
/// previously stored identity unchanged.
struct ServerIdentityResolver {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func fetchServerName(serverURL: String) async -> String? {
        do {
            let branding: ServerBrandingStatus = try await httpClient.getUnauthenticated(
                serverURL: serverURL,
                path: "/api/v1/theme/branding",
                quietStatuses: [404]
            )
            if let name = Self.usableName(branding.serverName) {
                return name
            }
        } catch HTTPError.http(let statusCode, _) where statusCode == 404 {
            // Older servers do not expose native branding.
        } catch {
            return nil
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
