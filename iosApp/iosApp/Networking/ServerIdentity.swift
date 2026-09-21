import Foundation

/// The deployment identity contract (`docs/architecture/server-identity.md`
/// in silo-server): `GET /api/v2/system/identity` is public and answers one
/// stable `server_id` at every address of a deployment;
/// `GET /api/v2/system/connections` is authenticated and lists the addresses
/// the deployment offers. The ID is self-asserted, so it only decides which
/// addresses are worth trying and how saved servers are grouped. Device-login
/// approval remains the proof that two addresses share one backend.
enum ServerIdentity {
    static let identityPath = "/api/v2/system/identity"
    static let connectionsPath = "/api/v2/system/connections"

    /// Probe timeout. A TV probing several candidate addresses in sequence
    /// must fail fast on the ones it cannot reach.
    static let probeTimeout: TimeInterval = 8

    static func usable(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// `GET /api/v2/system/identity`.
struct ServerIdentityDocument: Decodable, Hashable, Sendable {
    let serverId: String
}

/// One address a deployment offers. Shared by the connections document, the
/// SiloControl handoff offer, and the companion-pairing push, so the same
/// value crosses every wire unchanged.
struct ServerEndpoint: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Sendable {
        case `public`
        case provider
    }

    let url: String
    let kind: Kind
    /// Provider slug for `kind == .provider`, e.g. `tailscale`.
    let provider: String?
    /// Provider display name from its manifest, used for setup help on the
    /// device that cannot reach the address. Never derived from the hostname.
    let displayName: String?

    init(url: String, kind: Kind, provider: String? = nil, displayName: String? = nil) {
        self.url = ServerRegistry.normalize(url: url)
        self.kind = kind
        self.provider = provider
        self.displayName = displayName
    }

    private enum CodingKeys: String, CodingKey {
        case url, kind, provider, displayName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let rawKind = try c.decode(String.self, forKey: .kind)
        self.init(
            url: try c.decode(String.self, forKey: .url),
            kind: Kind(rawValue: rawKind) ?? .public,
            provider: try c.decodeIfPresent(String.self, forKey: .provider),
            displayName: try c.decodeIfPresent(String.self, forKey: .displayName)
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(url, forKey: .url)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(provider, forKey: .provider)
        try c.encodeIfPresent(displayName, forKey: .displayName)
    }

    /// Help text for a device that cannot reach this address. Provider names
    /// come from the manifest display name; nothing is inferred from the host.
    /// The wording never claims the provider app is missing: a failed request
    /// proves only that this device could not reach the address.
    func unreachableHelp(serverName: String) -> String {
        switch kind {
        case .provider:
            let name = ServerIdentity.usable(displayName) ?? "its network provider"
            return "This device can't reach \(serverName) through \(name). "
                + "Install or open the \(name) app on this device and make sure it has access to the server's network, then try again."
        case .public:
            return "This device can't reach \(serverName) at \(url). Check the network connection and try again."
        }
    }
}

/// `GET /api/v2/system/connections` (account-authenticated).
struct ServerConnectionsDocument: Decodable, Hashable, Sendable {
    struct AccessPath: Decodable, Hashable, Sendable {
        let kind: String
        let provider: String?
    }

    struct Endpoint: Decodable, Hashable, Sendable {
        let kind: String
        let url: String?
        let provider: String?
        let displayName: String?
        let state: String?

        /// Only a connected provider carries a URL; a public endpoint always
        /// does. Anything without one cannot be offered to another device.
        var usable: ServerEndpoint? {
            guard let url = ServerIdentity.usable(url) else { return nil }
            switch kind {
            case "public":
                return ServerEndpoint(url: url, kind: .public)
            case "provider":
                return ServerEndpoint(url: url, kind: .provider, provider: provider, displayName: displayName)
            default:
                return nil
            }
        }
    }

    let revision: String?
    let state: String?
    let allowed: Bool?
    let serverId: String
    let current: AccessPath?
    let endpoints: [Endpoint]

    var isAvailable: Bool { state == "available" && allowed != false }

    /// Addresses another device may try, in the server's order: public first,
    /// then providers in slug order. De-duplicated on the normalized URL.
    var usableEndpoints: [ServerEndpoint] {
        var seen = Set<String>()
        return endpoints.compactMap(\.usable).filter { seen.insert($0.url).inserted }
    }
}

enum ServerIdentityProbeResult: Equatable, Sendable {
    /// The address answered the identity operation.
    case identity(String)
    /// The address answered, but it is a server that predates the identity
    /// contract. Reachable, unknown identity.
    case unsupportedServer
    /// The address could not be reached, or did not answer like a Silo server.
    case unreachable
}

/// Resolves deployment identities by explicit URL, never through the active
/// credential slot, so a probe of a candidate address cannot disturb the
/// device's own session.
struct ServerIdentityResolver {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    /// The display name a server advertises. Branding owns the native
    /// product identity; health remains a compatibility fallback when
    /// branding is blank or the endpoint returns 404. Other failures leave the
    /// previously stored identity unchanged.
    func fetchServerName(serverURL: String) async -> String? {
        do {
            let branding: ServerBrandingStatus = try await httpClient.getUnauthenticated(
                serverURL: serverURL,
                path: "/api/v1/theme/branding",
                quietStatuses: [404]
            )
            if let name = ServerIdentity.usable(branding.serverName) {
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
            return ServerIdentity.usable(health.serverName)
        }
        return nil
    }

    /// The deployment identity at `serverURL`, or nil when the address is
    /// unreachable or the server predates the contract.
    func fetchServerIdentity(serverURL: String) async -> String? {
        if case .identity(let id) = await probeIdentity(serverURL: serverURL) { return id }
        return nil
    }

    /// Classifies one address for candidate selection: which identity it
    /// reports, that it is an older server, or that it cannot be reached.
    func probeIdentity(serverURL: String) async -> ServerIdentityProbeResult {
        do {
            let document: ServerIdentityDocument = try await httpClient.getUnauthenticated(
                serverURL: serverURL,
                path: ServerIdentity.identityPath,
                quietStatuses: [404],
                timeout: ServerIdentity.probeTimeout
            )
            guard let id = ServerIdentity.usable(document.serverId) else { return .unreachable }
            return .identity(id)
        } catch HTTPError.http(let statusCode, let body) where statusCode == 404 {
            return APIv2Probe.isLegacyNotFound(body: body) ? .unsupportedServer : .unreachable
        } catch {
            return .unreachable
        }
    }

    /// The connections document for a saved server, read with that server's
    /// own bearer. Best effort: a nil result means the feature is unavailable
    /// and callers fall back to offering the saved URL alone.
    func fetchConnections(serverURL: String, bearer: String) async -> ServerConnectionsDocument? {
        guard let document: ServerConnectionsDocument = try? await httpClient.getWithBearer(
            serverURL: serverURL,
            path: ServerIdentity.connectionsPath,
            bearer: bearer,
            timeout: ServerIdentity.probeTimeout
        ), document.isAvailable else {
            return nil
        }
        return document
    }
}
