import Foundation

// MARK: - Wire models

/// `GET /api/v2/theme/branding`: public white-label fields read before sign-in.
struct ServerBrandingDocument: Decodable, Equatable {
    var serverName: String?
    var loginSubtitle: String?
    var accentColor: String?
    var wordmarkUrl: String?
    var markUrl: String?
}

// MARK: - Presentation

/// A server's branding with its asset paths resolved against the saved base.
struct ServerBranding: Equatable, Codable {
    var serverName: String?
    var loginSubtitle: String?
    var accentColor: String?
    var markURL: URL?
    var wordmarkURL: URL?

    init(document: ServerBrandingDocument, baseURL: String) {
        serverName = ServerIdentity.usable(document.serverName ?? "")
        loginSubtitle = document.loginSubtitle.flatMap { ServerIdentity.usable($0) }
        accentColor = document.accentColor.flatMap { ServerIdentity.usable($0) }
        markURL = Self.resolve(document.markUrl, base: baseURL)
        wordmarkURL = Self.resolve(document.wordmarkUrl, base: baseURL)
    }

    /// Server asset paths are site-relative; only same-origin http(s) URLs
    /// are accepted so branding can't point the app somewhere else.
    static func resolve(_ value: String?, base: String) -> URL? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty,
              let baseURL = URL(string: base.hasSuffix("/") ? base : base + "/") else { return nil }
        let trimmed = value.hasPrefix("/") ? String(value.dropFirst()) : value
        guard let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              let assetOrigin = origin(of: url), assetOrigin == origin(of: baseURL) else { return nil }
        return url
    }

    /// Scheme, host and port, with the default port filled in, so
    /// `https://host` and `https://host:443` count as the same origin.
    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased(), let host = url.host?.lowercased() else { return nil }
        guard let port = url.port ?? ["https": 443, "http": 80][scheme] else { return nil }
        return "\(scheme)://\(host):\(port)"
    }

    /// What first-run screens call a server: its branded name, then the name
    /// saved at connect, then its host.
    @MainActor
    static func displayName(_ branding: ServerBranding?, serverURL: String) -> String {
        branding?.serverName
            ?? ServerRegistry.shared.activeServer?.fetchedName.flatMap { ServerIdentity.usable($0) }
            ?? hostLabel(serverURL)
    }

    static func hostLabel(_ serverURL: String) -> String {
        guard let url = URL(string: serverURL), let host = url.host else { return serverURL }
        if let port = url.port { return "\(host):\(port)" }
        return host
    }
}

// MARK: - Loader

/// Reads `/api/v2/theme/branding` by explicit URL, before sign-in. A failure
/// is no branding: the screens fall back to the plain brand light.
struct ServerBrandingLoader {
    private let httpClient: HTTPClient

    init(httpClient: HTTPClient = .shared) {
        self.httpClient = httpClient
    }

    func branding(serverURL: String) async -> ServerBranding? {
        guard let document: ServerBrandingDocument = try? await httpClient.getUnauthenticated(
            serverURL: serverURL,
            path: ServerIdentity.brandingPath,
            quietStatuses: [404]
        ) else { return nil }
        let branding = ServerBranding(document: document, baseURL: serverURL)
        ServerBrandingCache.store(branding, for: serverURL)
        return branding
    }
}

/// The last branding each server showed, so relaunching into sign-in or
/// recovery shows that server's accent immediately instead of flashing.
enum ServerBrandingCache {
    private static let key = "marquee.serverBranding.v1"

    static func branding(for serverURL: String) -> ServerBranding? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let all = try? JSONDecoder().decode([String: ServerBranding].self, from: data) else { return nil }
        return all[ServerRegistry.normalize(url: serverURL)]
    }

    static func store(_ branding: ServerBranding, for serverURL: String) {
        var all: [String: ServerBranding] = [:]
        if let data = UserDefaults.standard.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: ServerBranding].self, from: data) {
            all = decoded
        }
        all[ServerRegistry.normalize(url: serverURL)] = branding
        if let data = try? JSONEncoder().encode(all) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
