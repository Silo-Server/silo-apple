import Foundation

/// The auth paths a server hands the app in discovery (`native_start_path`,
/// `network_sign_in_path`). The app never requests such a path as given: it
/// keeps only the API path the path ends with and puts that on the saved base
/// URL, so a request always stays on the saved origin and path prefix.
enum ServerAuthPath {
    /// A provider's native start: `/api/v2/auth/oauth/<id>/native/start`.
    static let nativeStart = try! NSRegularExpression(pattern: "/api/v2/auth/oauth/[^/?#]+/native/start/?$")

    /// A provider's network sign-in: `/api/v2/auth/network/<id>/sign-in`,
    /// the id in the contract's shape (`^[1-9][0-9]*$`).
    static let networkSignIn = try! NSRegularExpression(pattern: "/api/v2/auth/network/[1-9][0-9]*/sign-in$")

    /// The API path `raw` ends with (matched by `suffix`) and, when
    /// `allowsQuery`, its query items. Nil unless `raw` is a server-relative
    /// path: a leading `/` but not `//`, no scheme, host or fragment, and no
    /// query unless allowed. Anything before the API path (another address's
    /// path prefix) is dropped.
    static func relative(_ raw: String?, suffix: NSRegularExpression,
                         allowsQuery: Bool) -> (apiPath: String, queryItems: [URLQueryItem])? {
        guard let path = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              path.hasPrefix("/"), !path.hasPrefix("//"), let components = URLComponents(string: path),
              components.scheme == nil, components.host == nil, components.fragment == nil,
              allowsQuery || components.query == nil,
              let apiPath = matchedSuffix(of: components.percentEncodedPath, suffix) else { return nil }
        return (apiPath, components.queryItems ?? [])
    }

    /// Whether a request path is a network sign-in, which `HTTPClient` sends
    /// as a public auth path. Matched as a suffix because the request path
    /// carries the saved base's own path prefix. `HTTPClient` asks on every
    /// request, so a plain suffix test rules out almost every path before
    /// the pattern runs.
    static func isNetworkSignIn(_ path: String) -> Bool {
        path.hasSuffix("/sign-in") && matchedSuffix(of: path, networkSignIn) != nil
    }

    private static func matchedSuffix(of path: String, _ pattern: NSRegularExpression) -> String? {
        guard let match = pattern.firstMatch(in: path, range: NSRange(path.startIndex..., in: path)),
              let suffix = Range(match.range, in: path) else { return nil }
        return String(path[suffix])
    }
}
