import Foundation

/// Invitations carry a server authority. Never send their proof to whichever
/// server happens to be selected when a link opens.
struct WatchPartyInvitation: Equatable, Sendable {
    let serverURL: String
    let joinToken: String

    init?(url: URL) {
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
