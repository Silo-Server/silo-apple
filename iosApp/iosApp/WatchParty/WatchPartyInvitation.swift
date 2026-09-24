import Foundation

/// Invitations carry a server authority. Never send their proof to whichever
/// server happens to be selected when a link opens.
///
/// Two shapes name the same invitation:
/// - `https://<server>/rooms/join?token=…`, the shareable web link.
/// - `silo://watch-party?server=<server>&token=…`, the app link the server's
///   join page offers, since a self-hosted domain can't be a universal link.
struct WatchPartyInvitation: Equatable, Sendable {
    let serverURL: String
    let joinToken: String

    init?(url: URL) {
        if url.scheme?.lowercased() == SiloURLScheme.current {
            self.init(appURL: url)
        } else {
            self.init(webURL: url)
        }
    }

    private init?(appURL url: URL) {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host?.lowercased() == "watch-party", parts.path.isEmpty || parts.path == "/",
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let items = parts.queryItems,
              let token = Self.single("token", in: items),
              let rawServer = Self.single("server", in: items),
              var server = URLComponents(string: rawServer),
              let scheme = server.scheme?.lowercased(), ["https", "http"].contains(scheme),
              server.host?.isEmpty == false, server.user == nil, server.password == nil,
              server.query == nil, server.fragment == nil else { return nil }
        server.scheme = scheme
        guard let serverURL = server.url else { return nil }
        self.serverURL = serverURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        joinToken = token
    }

    private static func single(_ name: String, in items: [URLQueryItem]) -> String? {
        let matches = items.filter { $0.name == name }
        guard matches.count == 1, let value = matches[0].value, !value.isEmpty else { return nil }
        return value
    }

    private init?(webURL url: URL) {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = parts.scheme?.lowercased(), ["https", "http"].contains(scheme),
              parts.host != nil, parts.user == nil, parts.password == nil,
              parts.fragment == nil, parts.path.hasSuffix("/rooms/join"),
              let tokens = parts.queryItems?.filter({ $0.name == "token" }), tokens.count == 1,
              let token = tokens.first?.value, !token.isEmpty else { return nil }
        parts.path = String(parts.path.dropLast("/rooms/join".count))
        parts.query = nil
        guard let server = parts.url else { return nil }
        serverURL = server.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        joinToken = token
    }
}
