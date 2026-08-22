import Foundation

/// Resolved media URL plus request headers at the session/Aether boundary.
struct StreamRequest {
    let url: URL
    let headers: [String: String]
    let serverUrl: String

    /// Resolve the server's engine-neutral transport without allowing the
    /// user's API credential to cross an origin boundary. Header-authenticated
    /// V3 deliberately accepts only the two API-local media route families the
    /// server contract promises; an absolute URL is a contract violation even
    /// when it happens to name the same host.
    static func resolve(
        rawURL: String,
        serverURL: String,
        additionalHeaders: [String: String],
        accessToken: String?,
        requiresHeaderAuthenticatedMedia: Bool
    ) -> StreamRequest? {
        let raw = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }

        let normalizedServer = serverURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if raw.hasPrefix("file://") {
            guard !requiresHeaderAuthenticatedMedia, let fileURL = URL(string: raw) else {
                return nil
            }
            return StreamRequest(url: fileURL, headers: [:], serverUrl: normalizedServer)
        }

        guard let baseURL = URL(string: normalizedServer),
              ["http", "https"].contains(baseURL.scheme?.lowercased() ?? ""),
              baseURL.host != nil,
              baseURL.user == nil,
              baseURL.password == nil else {
            return nil
        }

        let resolvedURL: URL
        if requiresHeaderAuthenticatedMedia {
            guard !raw.contains("://"),
                  !raw.hasPrefix("//"),
                  let components = URLComponents(string: raw),
                  components.scheme == nil,
                  components.host == nil,
                  Self.isAllowedHeaderAuthenticatedMediaPath(components.percentEncodedPath),
                  Self.hasAllowedHeaderAuthenticatedMediaQuery(components.queryItems ?? []),
                  components.fragment == nil else {
                return nil
            }
            let path = raw.hasPrefix("/") ? raw : "/\(raw)"
            guard let resolved = URL(string: normalizedServer + "/api/v1" + path) else {
                return nil
            }
            resolvedURL = resolved
        } else if raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard let resolved = URL(string: raw), Self.hasSameOrigin(resolved, baseURL) else {
                return nil
            }
            resolvedURL = resolved
        } else {
            guard !raw.hasPrefix("//") else { return nil }
            let path = raw.hasPrefix("/") ? raw : "/\(raw)"
            let absolute = path.hasPrefix("/api/")
                ? normalizedServer + path
                : normalizedServer + "/api/v1" + path
            guard let resolved = URL(string: absolute) else { return nil }
            resolvedURL = resolved
        }

        guard Self.hasSameOrigin(resolvedURL, baseURL) else { return nil }
        var headers = additionalHeaders.filter {
            $0.key.caseInsensitiveCompare("Authorization") != .orderedSame
        }
        if let accessToken, !accessToken.isEmpty {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        return StreamRequest(url: resolvedURL, headers: headers, serverUrl: normalizedServer)
    }

    static func isAllowedHeaderAuthenticatedMediaPath(_ path: String) -> Bool {
        guard path.hasPrefix("/stream/") || path.hasPrefix("/playback/transcode/") else {
            return false
        }
        let lowered = path.lowercased()
        guard !lowered.contains("%2f"),
              !lowered.contains("%5c"),
              !path.contains("\\") else {
            return false
        }
        return path.split(separator: "/", omittingEmptySubsequences: false).allSatisfy { segment in
            let decoded = String(segment).removingPercentEncoding ?? String(segment)
            return decoded != "." && decoded != ".."
        }
    }

    /// The V3 progressive-remux contract uses one non-secret `seek` value to
    /// anchor the transport. No other query field is accepted in the
    /// header-authenticated mode, so an old or compromised server cannot
    /// smuggle a signed media credential into Aether's source URL.
    private static func hasAllowedHeaderAuthenticatedMediaQuery(
        _ items: [URLQueryItem]
    ) -> Bool {
        guard !items.isEmpty else { return true }
        guard items.count == 1,
              items[0].name == "seek",
              let value = items[0].value,
              let seconds = Double(value),
              seconds.isFinite,
              seconds >= 0 else {
            return false
        }
        return true
    }

    static func hasSameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        guard lhs.scheme?.lowercased() == rhs.scheme?.lowercased(),
              lhs.host?.lowercased() == rhs.host?.lowercased() else {
            return false
        }
        return effectivePort(lhs) == effectivePort(rhs)
    }

    private static func effectivePort(_ url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }
}
