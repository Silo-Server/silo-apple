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
    ///
    /// `authorized_media_origins_v1` is the one negotiated exception: an
    /// attempt that opted in may receive absolute media URLs on a
    /// server-designated proxy origin. Only the `/stream/v3/{session}` family
    /// is accepted there, only `seek` may qualify it. `authorizedMediaOriginSessionId`
    /// carries both the opt-in and the pin: a non-nil, non-empty value means the
    /// attempt negotiated `authorized_media_origins_v1` and absolute proxy URLs
    /// are allowed, pinned to exactly this session — a plan cannot point the
    /// bearer at some other session's grant. Nil (or empty) means origins are
    /// not allowed at all, identical to behavior before the feature existed.
    /// Everything else — including every relative URL and every non-negotiated
    /// attempt — keeps the API-origin rule byte-for-byte.
    static func resolve(
        rawURL: String,
        serverURL: String,
        additionalHeaders: [String: String],
        accessToken: String?,
        requiresHeaderAuthenticatedMedia: Bool,
        authorizedMediaOriginSessionId: String? = nil
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
        // A validated proxy-origin URL is by definition a different origin than
        // the API server, so it is the only value that may skip the same-origin
        // check below. Its own validation is stricter in exchange.
        var isAuthorizedMediaOrigin = false
        let trimmedSessionId = authorizedMediaOriginSessionId?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if requiresHeaderAuthenticatedMedia,
           let sid = trimmedSessionId,
           !sid.isEmpty,
           raw.hasPrefix("http://") || raw.hasPrefix("https://") {
            guard let proxyURL = Self.authorizedMediaOriginURL(
                raw,
                sessionId: sid,
                serverScheme: baseURL.scheme?.lowercased() ?? ""
            ) else {
                return nil
            }
            resolvedURL = proxyURL
            isAuthorizedMediaOrigin = true
        } else if requiresHeaderAuthenticatedMedia {
            guard !raw.contains("://"),
                  !raw.hasPrefix("//"),
                  let components = URLComponents(string: raw),
                  components.scheme == nil,
                  components.host == nil,
                  Self.isAllowedHeaderAuthenticatedMediaPath(components.percentEncodedPath),
                  Self.hasAllowedHeaderAuthenticatedMediaQuery(
                      path: components.percentEncodedPath,
                      items: components.queryItems ?? []
                  ),
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

        guard isAuthorizedMediaOrigin || Self.hasSameOrigin(resolvedURL, baseURL) else { return nil }
        var headers = additionalHeaders.filter {
            $0.key.caseInsensitiveCompare("Authorization") != .orderedSame
        }
        if let accessToken, !accessToken.isEmpty {
            headers["Authorization"] = "Bearer \(accessToken)"
        }
        return StreamRequest(url: resolvedURL, headers: headers, serverUrl: normalizedServer)
    }

    /// The absolute form `authorized_media_origins_v1` permits. The server may
    /// designate any origin, so nothing about the host is checked beyond it
    /// being a credential-free `http(s)` origin — the path, query and session
    /// identity carry the whole contract, and the bearer only ever travels to a
    /// URL the current plan named for the current session.
    ///
    /// Scheme policy: `https` is always accepted. `http` is accepted only when
    /// the API server itself is `http` — a self-hosted http deployment already
    /// sends the bearer to the http API origin, so an http proxy adds no new
    /// exposure, but an https deployment must never be downgraded to a
    /// cleartext proxy origin.
    private static func authorizedMediaOriginURL(
        _ raw: String,
        sessionId: String,
        serverScheme: String
    ) -> URL? {
        guard let components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              scheme == "https" || (scheme == "http" && serverScheme == "http"),
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.fragment == nil,
              isAllowedAuthorizedMediaOriginPath(
                  components.percentEncodedPath,
                  sessionId: sessionId
              ),
              hasAllowedAuthorizedMediaOriginQuery(components.queryItems ?? []),
              let url = components.url else {
            return nil
        }
        return url
    }

    /// `/stream/v3/{session}`, `/stream/v3/{session}/master.m3u8` and
    /// `/stream/v3/{session}/segment/{name}` — nothing else, and never a
    /// session other than the attempt's own.
    static func isAllowedAuthorizedMediaOriginPath(_ path: String, sessionId: String) -> Bool {
        let lowered = path.lowercased()
        guard !lowered.contains("%2f"),
              !lowered.contains("%5c"),
              !path.contains("\\") else {
            return false
        }
        let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard segments.count >= 4, segments[0].isEmpty else { return false }
        let decoded = segments.map { $0.removingPercentEncoding ?? $0 }
        guard decoded.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            return false
        }
        guard decoded[1] == "stream", decoded[2] == "v3" else { return false }
        guard decoded[3] == sessionId else { return false }
        switch segments.count {
        case 4:
            return true
        case 5:
            return decoded[4] == "master.m3u8"
        case 6:
            return decoded[4] == "segment"
        default:
            return false
        }
    }

    /// Absolute media URLs carry the media family's seek-only query contract.
    /// The subtitle-artifact identifiers allowed on API-origin paths are
    /// deliberately not accepted here: proxies never serve subtitle artifacts.
    private static func hasAllowedAuthorizedMediaOriginQuery(_ items: [URLQueryItem]) -> Bool {
        guard !items.isEmpty else { return true }
        var seenNames = Set<String>()
        for item in items {
            guard seenNames.insert(item.name).inserted,
                  item.name == "seek",
                  let value = item.value,
                  let seconds = Double(value),
                  seconds.isFinite,
                  seconds >= 0 else {
                return false
            }
        }
        return true
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
    /// anchor the media transport. The subtitle artifact family
    /// (`/stream/<session>/subtitles/...`, including its `/fonts` variant)
    /// additionally carries `file_id` and, for imported subtitles,
    /// `downloaded_subtitle_id`: plain non-negative catalog row identifiers
    /// that name a row the caller is already authorized to read, never a
    /// credential or a signed grant. Every other query field is rejected in
    /// header-authenticated mode — and duplicates are rejected too — so an old
    /// or compromised server cannot smuggle a signed media credential into
    /// Aether's source URL. Media (non-subtitle) routes keep the seek-only rule.
    private static func hasAllowedHeaderAuthenticatedMediaQuery(
        path: String,
        items: [URLQueryItem]
    ) -> Bool {
        guard !items.isEmpty else { return true }
        let allowsSubtitleArtifactIdentifiers = isSubtitleArtifactPath(path)
        var seenNames = Set<String>()
        for item in items {
            guard seenNames.insert(item.name).inserted, let value = item.value else {
                return false
            }
            switch item.name {
            case "seek":
                guard let seconds = Double(value), seconds.isFinite, seconds >= 0 else {
                    return false
                }
            case "file_id", "downloaded_subtitle_id":
                guard allowsSubtitleArtifactIdentifiers, isNonNegativeInteger(value) else {
                    return false
                }
            default:
                return false
            }
        }
        return true
    }

    /// Matches the server's subtitle artifact shapes
    /// `/stream/<session>/subtitles/<index><ext>` and
    /// `/stream/<session>/subtitles/<index>/fonts`.
    private static func isSubtitleArtifactPath(_ path: String) -> Bool {
        let segments = path.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count >= 5 else { return false }
        return segments[0].isEmpty
            && segments[1] == "stream"
            && !segments[2].isEmpty
            && segments[3] == "subtitles"
            && !segments[4].isEmpty
    }

    private static func isNonNegativeInteger(_ value: String) -> Bool {
        !value.isEmpty
            && value.allSatisfy { $0.isASCII && $0.isNumber }
            && Int(value) != nil
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
