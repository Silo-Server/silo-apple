import Foundation
import Network
import Synchronization

/// The active server's direct route on the local network
/// (`docs/architecture/server-identity.md` in silo-server, "Local network
/// TLS"). While one is active, requests built against the saved server
/// address go to the server's LAN address instead, over TLS pinned to the
/// deployment's key. Nothing that names the server changes: the saved
/// address stays the credential owner, the base of every stored URL, and what
/// responses report as their origin. `LocalRouteController` decides when a
/// route is active; request paths read it here, once per request.
struct LocalRoute: Sendable, Equatable {
    /// `ServerEntry.id` of the server the route belongs to.
    let serverID: String
    /// Origin of the saved address, which requests are built against.
    let savedOrigin: String
    /// `https://<private IPv4>:<port>` of the server on the local network.
    let localOrigin: String
    /// Advances every time a route is activated, so a failure drops only the
    /// route it was sent on.
    let generation: UInt64

    private static let current = Mutex<LocalRoute?>(nil)

    /// The route requests should use now, if any.
    static var active: LocalRoute? { current.withLock { $0 } }

    /// Set by `LocalRouteController` only.
    static func publish(_ route: LocalRoute?) {
        current.withLock { $0 = route }
    }

    /// Takes `route` out of use at once if it is still the active one, so
    /// requests sent from now on go to the saved address without waiting for
    /// `LocalRouteController` to hear about the failure.
    static func drop(_ route: LocalRoute) {
        current.withLock { if $0?.generation == route.generation { $0 = nil } }
    }

    /// Takes the active route out of use at once if it points at `host` and
    /// `port`, which just presented a key other than the pinned one.
    static func drop(host: String, port: Int) {
        current.withLock { route in
            guard let local = route.flatMap({ URL(string: $0.localOrigin) }),
                  local.host?.lowercased() == host.lowercased(), (local.port ?? 443) == port else { return }
            route = nil
        }
    }

    /// `request` addressed to the local origin, or nil when it is not
    /// addressed to the saved origin.
    func routed(_ request: URLRequest) -> URLRequest? {
        guard let url = request.url, let local = localURL(for: url) else { return nil }
        var routed = request
        routed.url = local
        return routed
    }

    /// `url` on the local origin, keeping its path and query; nil when `url`
    /// is not on the saved origin.
    func localURL(for url: URL) -> URL? {
        Self.replacingOrigin(of: url, from: savedOrigin, to: localOrigin)
    }

    /// The response as the caller expects it: from the saved origin. Artwork
    /// bases, caches and snapshots then never learn the LAN address.
    func relabeled(_ response: URLResponse) -> URLResponse {
        guard let http = response as? HTTPURLResponse,
              let url = http.url,
              let saved = Self.replacingOrigin(of: url, from: localOrigin, to: savedOrigin) else {
            return response
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let key = key as? String, let value = value as? String { headers[key] = value }
        }
        return HTTPURLResponse(url: saved, statusCode: http.statusCode, httpVersion: "HTTP/1.1", headerFields: headers)
            ?? response
    }

    // MARK: - Failures

    /// Whether a failure on the local route says the route stopped working:
    /// the connection could not be made or was lost. A cancellation never
    /// does, whoever cancelled; a presented key that did not match the pin
    /// also surfaces as one, and `LocalRouteTrust` reports that itself.
    static func isRouteFailure(_ error: Error) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        return connectionFailureCodes.contains(code)
    }

    private static let connectionFailureCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
        .networkConnectionLost, .timedOut, .secureConnectionFailed, .cannotLoadFromNetwork,
        .internationalRoamingOff, .callIsActive, .dataNotAllowed,
    ]

    /// Whether a request that failed on the local route may be sent again to
    /// the saved address: always when it cannot have reached a server (the
    /// connection, name lookup or TLS handshake failed), otherwise only when
    /// it is safe to repeat.
    static func mayRetryOnSavedAddress(after error: Error, method: String?) -> Bool {
        guard let code = (error as? URLError)?.code else { return false }
        if neverSentCodes.contains(code) { return true }
        return ["GET", "HEAD"].contains((method ?? "GET").uppercased())
    }

    private static let neverSentCodes: Set<URLError.Code> = [
        .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .notConnectedToInternet,
        .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
        .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot,
        .clientCertificateRejected, .clientCertificateRequired,
        // A challenge the trust check refused surfaces as a cancellation.
        .cancelled,
    ]

    // MARK: - Origins

    /// `scheme://host[:port]`, the form saved servers are compared in
    /// (`NativeSignIn.origin(of:)`). Nil for anything but an http(s) URL.
    static func origin(of url: URL) -> String? {
        NativeSignIn.origin(of: url)
    }

    static func origin(of string: String) -> String? {
        URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap(NativeSignIn.origin(of:))
    }

    /// The local-route origin for a server address on the local network:
    /// `https` on the same host and port, since the API port answers TLS
    /// whatever scheme the address names. Only a private IPv4 literal
    /// qualifies: no public certificate authority issues for one, and App
    /// Transport Security exempts it, so the pin is the only trust that
    /// applies. A missing port is the scheme's default.
    static func localOrigin(forAddress address: String) -> String? {
        guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = url.host, isPrivateIPv4(host) else { return nil }
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return port == 443 ? "https://\(host)" : "https://\(host):\(port)"
    }

    /// RFC 1918 addresses: what a home LAN numbers its hosts from.
    static func isPrivateIPv4(_ literal: String) -> Bool {
        guard let address = IPv4Address(literal) else { return false }
        let b = [UInt8](address.rawValue)
        return b[0] == 10
            || (b[0] == 172 && (16...31).contains(b[1]))
            || (b[0] == 192 && b[1] == 168)
    }

    private static func replacingOrigin(of url: URL, from: String, to: String) -> URL? {
        guard origin(of: url) == from,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let target = URLComponents(string: to) else { return nil }
        components.scheme = target.scheme
        components.percentEncodedHost = target.percentEncodedHost
        components.port = target.port
        return components.url
    }
}

/// A request that failed on the local route and could not go again to the
/// saved address. The caller handles `underlying` as any transport failure,
/// except that it says nothing about the saved address's reachability.
struct LocalRouteFailure: Error {
    let underlying: Error
}
