import Foundation

/// A canonical, validated Silo server origin supplied outside the app.
///
/// Invite links are untrusted input. Converting their `server` value to this
/// type once keeps invalid schemes, credentials, query strings, and fragments
/// out of request routing and gives confirmation UI a stable host to display.
struct ServerEndpoint: Hashable, Sendable {
    let baseURL: String
    let displayHost: String

    init?(rawValue: String) {
        let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = components.host?.lowercased(),
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.percentEncodedQuery == nil,
              components.percentEncodedFragment == nil else {
            return nil
        }

        components.scheme = scheme
        components.host = host
        if (scheme == "https" && components.port == 443)
            || (scheme == "http" && components.port == 80) {
            components.port = nil
        }

        var path = components.percentEncodedPath
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        components.percentEncodedPath = path == "/" ? "" : path

        guard let canonicalURL = components.url else { return nil }
        baseURL = canonicalURL.absoluteString
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        displayHost = components.port.map { "\(displayedHost):\($0)" } ?? displayedHost
    }
}

/// Parsed form of the only custom-scheme invitation route the app accepts.
struct InvitationClaimLink: Hashable, Sendable {
    let endpoint: ServerEndpoint
    let token: String

    init?(url: URL) {
        guard url.scheme?.lowercased() == "silo",
              url.host?.lowercased() == "invite",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return nil
        }

        let serverValues = components.queryItems?.filter { $0.name == "server" }.compactMap(\.value) ?? []
        let tokenValues = components.queryItems?.filter { $0.name == "token" }.compactMap(\.value) ?? []
        guard serverValues.count == 1,
              tokenValues.count == 1,
              let endpoint = ServerEndpoint(rawValue: serverValues[0]) else {
            return nil
        }

        let token = tokenValues[0]
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        guard !token.isEmpty,
              token.count <= 1024,
              token.unicodeScalars.allSatisfy(allowed.contains) else {
            return nil
        }

        self.endpoint = endpoint
        self.token = token
    }
}
