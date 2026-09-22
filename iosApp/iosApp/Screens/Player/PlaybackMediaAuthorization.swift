import Foundation
#if canImport(AetherEngine)
import AetherEngine
#endif

/// Binds rotating media credentials to the source a validated playback plan
/// named. A playlist or redirect cannot expand that credential scope.
enum PlaybackMediaAuthorization {
    enum ValidationError: Error, Equatable {
        case invalidSourceURL
        case outsideSessionScope
        case credentialOwnerMismatch
    }

    /// Foundation-only so URL admission can be tested without loading Aether.
    struct Scope: Sendable {
        private let sourceURL: URL
        private let sourcePath: [String]
        private let hlsPrefix: [String]?

        init(sourceURL: URL, serverURL: String, sessionID: String) throws {
            guard Self.isSafeComponent(sessionID),
                  let server = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let serverComponents = Self.checkedComponents(server),
                  serverComponents.query == nil,
                  let basePath = Self.pathComponents(serverComponents.percentEncodedPath, allowsTrailingSlash: true),
                  let sourceComponents = Self.checkedComponents(sourceURL),
                  Self.hasAllowedQuery(sourceComponents),
                  let path = Self.pathComponents(sourceComponents.percentEncodedPath) else {
                throw ValidationError.invalidSourceURL
            }

            let apiHLS = basePath + ["api", "v1", "playback", "transcode", sessionID, "master.m3u8"]
            let apiProgressive = basePath + ["api", "v1", "stream", sessionID]
            let proxyHLS = ["stream", "v3", sessionID, "master.m3u8"]
            let proxyProgressive = ["stream", "v3", sessionID]
            let apiSource = StreamRequest.hasSameOrigin(sourceURL, server)
                && (path == apiHLS || path == apiProgressive)
            // StreamRequest already validated the server-designated proxy.
            // Recheck the route and prevent a cleartext downgrade here too.
            let proxySource = (path == proxyHLS || path == proxyProgressive)
                && (sourceComponents.scheme?.lowercased() == "https"
                    || serverComponents.scheme?.lowercased() == "http")
            guard apiSource || proxySource else { throw ValidationError.invalidSourceURL }

            self.sourceURL = sourceURL
            self.sourcePath = path
            self.hlsPrefix = path.last == "master.m3u8" ? Array(path.dropLast()) : nil
        }

        func allows(_ url: URL) -> Bool {
            guard StreamRequest.hasSameOrigin(url, sourceURL),
                  let components = Self.checkedComponents(url),
                  Self.hasAllowedQuery(components),
                  let path = Self.pathComponents(components.percentEncodedPath) else {
                return false
            }
            if path == sourcePath { return true }
            guard let hlsPrefix,
                  path.count == hlsPrefix.count + 2,
                  Array(path.prefix(hlsPrefix.count)) == hlsPrefix,
                  path[hlsPrefix.count] == "segment" else {
                return false
            }
            return true
        }

        fileprivate static func checkedComponents(_ url: URL) -> URLComponents? {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: true),
                  let scheme = components.scheme?.lowercased(),
                  scheme == "https" || scheme == "http",
                  let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil,
                  components.fragment == nil else {
                return nil
            }
            return components
        }

        fileprivate static func pathComponents(_ path: String, allowsTrailingSlash: Bool = false) -> [String]? {
            if path.isEmpty { return [] }
            guard path.hasPrefix("/") else { return nil }
            let lowercased = path.lowercased()
            // Reject encoded path structure before decoding, including a second
            // encoding layer that an intermediary could decode again.
            guard !["%2e", "%2f", "%5c", "%25"].contains(where: lowercased.contains) else {
                return nil
            }
            var segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if allowsTrailingSlash, segments.last == "" { segments.removeLast() }
            var decoded: [String] = []
            for segment in segments {
                guard let value = segment.removingPercentEncoding, isSafeComponent(value) else { return nil }
                decoded.append(value)
            }
            return decoded
        }

        fileprivate static func isSafeComponent(_ value: String) -> Bool {
            guard !value.isEmpty, value != ".", value != ".." else { return false }
            return value.utf8.allSatisfy { byte in
                (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
                    || byte == 45 || byte == 46 || byte == 95 || byte == 126
            }
        }

        private static func hasAllowedQuery(_ components: URLComponents) -> Bool {
            guard let items = components.queryItems, !items.isEmpty else { return true }
            guard items.count == 1, items[0].name == "seek",
                  let value = items[0].value, let seconds = Double(value),
                  seconds.isFinite, seconds >= 0 else {
                return false
            }
            return true
        }
    }

    /// Subtitle artifacts and fonts remain on the API server even when the
    /// media comes from a proxy. They never inherit the proxy's authority.
    struct SubtitleScope: Sendable {
        private let server: URL
        private let prefix: [String]
        private let sessionID: String

        init(serverURL: String, sessionID: String) throws {
            guard Scope.isSafeComponent(sessionID),
                  let server = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
                  let components = Scope.checkedComponents(server), components.query == nil,
                  let base = Scope.pathComponents(components.percentEncodedPath, allowsTrailingSlash: true) else {
                throw ValidationError.invalidSourceURL
            }
            self.server = server
            self.sessionID = sessionID
            prefix = base + ["api", "v1", "stream", sessionID, "subtitles"]
        }

        func allows(_ url: URL) -> Bool {
            guard StreamRequest.hasSameOrigin(url, server),
                  let components = Scope.checkedComponents(url),
                  let path = Scope.pathComponents(components.percentEncodedPath),
                  Array(path.prefix(prefix.count)) == prefix else { return false }
            let tail = path.dropFirst(prefix.count)
            guard tail.count == 1 || (tail.count == 2 && tail.last == "fonts") else { return false }
            return StreamRequest.hasAllowedHeaderAuthenticatedMediaQuery(
                path: "/stream/\(sessionID)/subtitles/" + tail.joined(separator: "/"),
                items: components.queryItems ?? []
            )
        }
    }

    #if canImport(AetherEngine)
    static func makeSubtitleAuthorization(
        serverURL: String, sessionID: String,
        expectedAuth: CapturedOrdinaryRequestAuth,
        baseHeaders: [String: String], http: HTTPClient
    ) throws -> HTTPRequestAuthorization {
        guard ServerRegistry.normalize(url: expectedAuth.account.serverURL)
                == ServerRegistry.normalize(url: serverURL) else {
            throw ValidationError.credentialOwnerMismatch
        }
        let scope = try SubtitleScope(serverURL: serverURL, sessionID: sessionID)
        return HTTPRequestAuthorization { url, rejectedHeaders in
            guard scope.allows(url) else { throw ValidationError.outsideSessionScope }
            return try await http.mediaRequestHeaders(
                expectedAuth: expectedAuth, baseHeaders: baseHeaders, rejectedHeaders: rejectedHeaders
            )
        }
    }

    static func make(
        sourceURL: URL,
        serverURL: String,
        sessionID: String,
        expectedAuth: CapturedOrdinaryRequestAuth,
        baseHeaders: [String: String],
        http: HTTPClient
    ) throws -> HTTPRequestAuthorization {
        guard ServerRegistry.normalize(url: expectedAuth.account.serverURL)
                == ServerRegistry.normalize(url: serverURL) else {
            throw ValidationError.credentialOwnerMismatch
        }
        let scope = try Scope(sourceURL: sourceURL, serverURL: serverURL, sessionID: sessionID)
        return HTTPRequestAuthorization { url, rejectedHeaders in
            guard scope.allows(url) else { throw ValidationError.outsideSessionScope }
            return try await http.mediaRequestHeaders(
                expectedAuth: expectedAuth,
                baseHeaders: baseHeaders,
                rejectedHeaders: rejectedHeaders
            )
        }
    }
    #endif
}
