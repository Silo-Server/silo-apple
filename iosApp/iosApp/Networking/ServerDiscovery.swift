import Foundation
import Network
import OSLog

/// Finds Silo servers this device can reach without an address
/// (`docs/architecture/server-discovery.md` in silo-server). Two sources:
///
/// - The local network: every API server advertises DNS-SD `_silo._tcp`
///   with its deployment identity in the TXT `id`.
/// - An overlay network (Tailscale): a provider's API node answers plain HTTP
///   on its bare machine name with a redirect to its HTTPS origin, and the
///   overlay's DNS search domain lets this device resolve that bare name.
///
/// Neither source is trusted. A LAN result is kept only when the identity
/// operation at the resolved address reports the advertised `id`, and an
/// overlay result only when the redirect lands on HTTPS and answers identity.
enum ServerDiscoveryProtocol {
    static let serviceType = "_silo._tcp"
    static let txtServerID = "id"
    /// Bare names probed automatically: the Tailscale plugin's default
    /// machine name and the suffixes a second and third server on one
    /// tailnet receive. Any other name is found by typing it.
    static let overlayNames = ["silo", "silo-1", "silo-2"]
    /// Discovery runs while someone looks at the setup screen, so a name that
    /// does not resolve or answer must give up quickly.
    static let probeTimeout: TimeInterval = 4
}

/// One reachable address of a server found by discovery.
struct DiscoveredServer: Identifiable, Hashable, Sendable {
    enum Route: Hashable, Sendable {
        /// Found by its LAN advertisement; `url` is `http://<ipv4>:<port>`.
        case localNetwork
        /// Found by its bare overlay name; `url` is the HTTPS origin.
        case overlay
    }

    let serverId: String
    let name: String
    let url: String
    let route: Route

    var id: String { url }

    /// Short secondary line: where the address lives, never a guess at the
    /// provider (the redirect does not say which overlay it came through).
    var detail: String {
        let host = URL(string: url)?.host ?? url
        switch route {
        case .localNetwork: return "On this network · \(host)"
        case .overlay: return "Private network · \(host)"
        }
    }
}

/// Resolves a bare overlay name through the provider's plain-HTTP redirect.
/// The result is the HTTPS origin the redirect lands on: that origin, not
/// `http://<name>`, is what a client saves, because the redirect answers
/// reads only and refuses sign-in.
struct OverlayNameResolver: Sendable {
    struct Resolution: Equatable, Sendable {
        let origin: String
        let serverId: String
    }

    var timeout: TimeInterval = ServerDiscoveryProtocol.probeTimeout

    /// True for input that can only be a bare machine name: one DNS label,
    /// no scheme, port, or path. `localhost` is excluded.
    static func isBareName(_ input: String) -> Bool {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 63, trimmed.lowercased() != "localhost" else { return false }
        return trimmed.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
            && !trimmed.hasPrefix("-") && !trimmed.hasSuffix("-")
    }

    func resolve(name: String) async -> Resolution? {
        guard Self.isBareName(name),
              let probe = URL(string: "http://\(name.lowercased())\(ServerIdentity.identityPath)") else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        do {
            let policy = HTTPSRedirectOnly()
            let (data, response) = try await session.data(from: probe, delegate: policy)
            guard policy.ranOverOverlay,
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let final = http.url, Self.isExpansion(of: name, host: final.host),
                  let origin = Self.origin(of: final) else { return nil }
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let document = try decoder.decode(ServerIdentityDocument.self, from: data)
            guard let id = ServerIdentity.usable(document.serverId) else { return nil }
            return Resolution(origin: origin, serverId: id)
        } catch {
            return nil
        }
    }

    /// True when `host` is `name` completed with a domain (`silo` ->
    /// `silo.tail1234.ts.net`). The redirect must not name another machine.
    static func isExpansion(of name: String, host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let prefix = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "."
        return host.hasPrefix(prefix) && host.count > prefix.count
    }

    /// True when every connection of a probe ran over the overlay: both its
    /// local and remote addresses are overlay addresses. A remote overlay
    /// address alone is not enough, because a local network can resolve a
    /// bare name to one and route it to itself; only traffic that went through
    /// the overlay's own interface has an overlay address on this end too.
    static func ranOverOverlay(_ connections: [(local: String, remote: String)]) -> Bool {
        !connections.isEmpty && connections.allSatisfy { isOverlayAddress($0.local) && isOverlayAddress($0.remote) }
    }

    /// Overlay networks (Tailscale, NetBird) address peers from the CGNAT
    /// range or Tailscale's ULA prefix.
    static func isOverlayAddress(_ address: String) -> Bool {
        let literal = address.split(separator: "%").first.map(String.init) ?? address
        if let v4 = IPv4Address(literal) {
            let b = [UInt8](v4.rawValue)
            return b[0] == 100 && (b[1] & 0xC0) == 64
        }
        if let v6 = IPv6Address(literal) {
            let b = [UInt8](v6.rawValue)
            return b[0] == 0xfd && b[1] == 0x7a && b[2] == 0x11 && b[3] == 0x5c && b[4] == 0xa1 && b[5] == 0xe0
        }
        return false
    }

    /// `https://host[:port]` of a final redirect target; nil unless HTTPS.
    static func origin(of url: URL) -> String? {
        guard url.scheme?.lowercased() == "https", let host = url.host, !host.isEmpty else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = host
        components.port = url.port.flatMap { $0 == 443 ? nil : $0 }
        return components.url.map { ServerRegistry.normalize(url: $0.absoluteString) }
    }
}

/// Follows exactly one redirect, and only to HTTPS. A plain-HTTP answer or a
/// second hop is returned as-is and fails the status check. Also records
/// whether every connection the probe made ran over the overlay.
private final class HTTPSRedirectOnly: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var followed = false
    private var overlayOnly = false

    var ranOverOverlay: Bool {
        lock.lock()
        defer { lock.unlock() }
        return overlayOnly
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // A transaction with no addresses reused an earlier connection, which
        // is already counted.
        let connections = metrics.transactionMetrics.compactMap { transaction -> (local: String, remote: String)? in
            guard let local = transaction.localAddress, let remote = transaction.remoteAddress else { return nil }
            return (local, remote)
        }
        lock.lock()
        overlayOnly = OverlayNameResolver.ranOverOverlay(connections)
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard !followed, request.url?.scheme?.lowercased() == "https" else {
            completionHandler(nil)
            return
        }
        followed = true
        completionHandler(request)
    }
}

/// Lists the servers discovery finds while the setup screen is visible.
/// Owns the Local Network permission prompt for that screen (first browse).
@MainActor
@Observable
final class ServerDiscovery {
    private(set) var servers: [DiscoveredServer] = []

    private var browser: NWBrowser?
    /// Advances on start and stop; work started for an earlier visit to the
    /// screen checks it and drops its result.
    private var session = 0
    /// Advances whenever a browser is replaced; browse callbacks and LAN
    /// confirmations from an earlier browser are dropped.
    private var browserGeneration = 0
    private var currentKeys: Set<String> = []                 // latest browse snapshot
    private var lanResults: [String: DiscoveredServer] = [:]   // keyed by browse result
    private var overlayResults: [DiscoveredServer] = []
    private var pending: Set<String> = []
    /// Confirmation attempts per browse result. One delayed retry covers a
    /// transient failure; after that a result that does not confirm is left
    /// alone instead of being re-probed on every browse change.
    private var attempts: [String: Int] = [:]
    private static let maxAttempts = 2
    /// Re-runs the overlay probe when the device's network changes, such as
    /// Tailscale connecting while the screen is open.
    private var pathMonitor: NWPathMonitor?
    private var overlayProbe: Task<Void, Never>?
    /// Re-probes on a timer too: a tailnet server can start or recover while
    /// the network itself stays the same.
    private var overlayRefresh: Task<Void, Never>?
    private static let overlayRefreshInterval: Duration = .seconds(30)
    private let identity = ServerIdentityResolver()
    private let overlay = OverlayNameResolver()
    private nonisolated static let logger = Logger(subsystem: "org.siloserver.silo", category: "server.discovery")

    func start() {
        guard browser == nil else { return }
        session += 1
        startBrowser()
        let session = self.session
        // The first path update arrives right away and runs the first probe.
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] _ in
            Task { @MainActor in
                guard let self, self.session == session else { return }
                self.scheduleOverlayProbe(session: session)
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        overlayRefresh = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.overlayRefreshInterval)
                guard let self, !Task.isCancelled, self.session == session else { return }
                self.scheduleOverlayProbe(session: session)
            }
        }
    }

    /// Debounced: a VPN coming up reports several path changes in a row.
    private func scheduleOverlayProbe(session: Int) {
        overlayProbe?.cancel()
        overlayProbe = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            await probeOverlayNames(session: session)
        }
    }

    private func startBrowser() {
        browserGeneration += 1
        // Confirmations in flight belong to the browser being replaced.
        pending = []
        attempts = [:]
        let gen = browserGeneration
        let params = NWParameters()
        params.includePeerToPeer = false
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: ServerDiscoveryProtocol.serviceType, domain: nil), using: params)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            Task { @MainActor in
                guard let self, self.browserGeneration == gen else { return }
                self.update(results: results, generation: gen)
            }
        }
        browser.stateUpdateHandler = { [weak self] state in
            guard case .failed(let error) = state else { return }
            Self.logger.error("browser failed: \(String(describing: error), privacy: .public)")
            // A failed NWBrowser (for example after the network stack resets
            // in the background) never recovers; replace it.
            Task { @MainActor in
                guard let self, self.browserGeneration == gen else { return }
                self.browser?.cancel()
                self.browser = nil
                try? await Task.sleep(for: .seconds(2))
                guard self.browserGeneration == gen, self.browser == nil else { return }
                self.startBrowser()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        session += 1
        browserGeneration += 1
        browser?.cancel()
        browser = nil
        pathMonitor?.cancel()
        pathMonitor = nil
        overlayProbe?.cancel()
        overlayProbe = nil
        overlayRefresh?.cancel()
        overlayRefresh = nil
        currentKeys = []
        lanResults = [:]
        overlayResults = []
        pending = []
        attempts = [:]
        servers = []
    }

    private func update(results: Set<NWBrowser.Result>, generation gen: Int) {
        currentKeys = Set(results.map { "\($0.endpoint)" })
        lanResults = lanResults.filter { currentKeys.contains($0.key) }
        attempts = attempts.filter { currentKeys.contains($0.key) }
        for result in results {
            let key = "\(result.endpoint)"
            guard lanResults[key] == nil, !pending.contains(key), attempts[key, default: 0] < Self.maxAttempts,
                  case let .bonjour(txt) = result.metadata,
                  let advertisedId = ServerIdentity.usable(txt.dictionary[ServerDiscoveryProtocol.txtServerID]) else { continue }
            confirm(key: key, endpoint: result.endpoint, advertisedId: advertisedId, generation: gen)
        }
        publish()
    }

    private func confirm(key: String, endpoint: NWEndpoint, advertisedId: String, generation gen: Int) {
        let instanceName: String? = if case let .service(name, _, _, _) = endpoint { name } else { nil }
        pending.insert(key)
        attempts[key, default: 0] += 1
        Task {
            let found = await self.confirmLAN(endpoint: endpoint, advertisedId: advertisedId, instanceName: instanceName)
            guard self.browserGeneration == gen else { return }
            self.pending.remove(key)
            // The advertisement may have gone while this was confirming.
            guard self.currentKeys.contains(key) else { return }
            if let found {
                self.lanResults[key] = found
                self.publish()
            } else if self.attempts[key, default: 0] < Self.maxAttempts {
                try? await Task.sleep(for: .seconds(3))
                guard self.browserGeneration == gen, self.currentKeys.contains(key), self.lanResults[key] == nil,
                      !self.pending.contains(key) else { return }
                self.confirm(key: key, endpoint: endpoint, advertisedId: advertisedId, generation: gen)
            }
        }
    }

    private func confirmLAN(endpoint: NWEndpoint, advertisedId: String, instanceName: String?) async -> DiscoveredServer? {
        guard let origin = await Self.resolveOrigin(endpoint) else { return nil }
        guard case .identity(let id) = await identity.probeIdentity(serverURL: origin), id == advertisedId else {
            Self.logger.info("ignoring advertisement whose address does not confirm its identity")
            return nil
        }
        let name = await identity.fetchServerName(serverURL: origin, timeout: ServerDiscoveryProtocol.probeTimeout)
            ?? instanceName ?? "Silo"
        return DiscoveredServer(serverId: id, name: name, url: origin, route: .localNetwork)
    }

    /// Resolves each default overlay name, and its display name, concurrently
    /// within the discovery timeout.
    private func probeOverlayNames(session: Int) async {
        let overlay = self.overlay
        let identity = self.identity
        let servers = await withTaskGroup(of: DiscoveredServer?.self) { group in
            for name in ServerDiscoveryProtocol.overlayNames {
                group.addTask {
                    guard let resolution = await overlay.resolve(name: name) else { return nil }
                    let label = await identity.fetchServerName(
                        serverURL: resolution.origin, timeout: ServerDiscoveryProtocol.probeTimeout) ?? "Silo"
                    return DiscoveredServer(serverId: resolution.serverId, name: label, url: resolution.origin, route: .overlay)
                }
            }
            var found: [DiscoveredServer] = []
            for await server in group { if let server { found.append(server) } }
            return found
        }
        // A cancelled probe was replaced by a newer one; its empty result
        // must not clear rows the newer one will report.
        guard self.session == session, !Task.isCancelled else { return }
        overlayResults = servers
        publish()
    }

    /// One row per server and route: replicas of one deployment, or one host
    /// seen on several interfaces, advertise the same `id`.
    private func publish() {
        var seen = Set<String>()
        let candidates = (Array(lanResults.values) + overlayResults).sorted { $0.url < $1.url }
        let all = candidates.filter { seen.insert("\($0.serverId)|\($0.route)").inserted }
        servers = all.sorted {
            if $0.name != $1.name { return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            if $0.route != $1.route { return $0.route == .localNetwork }
            return $0.url < $1.url
        }
    }

    /// The `http://host:port` origin of a browse result: its IPv4 address
    /// when it has one, otherwise a routable IPv6 address. Link-local IPv6 is
    /// skipped because a URL host cannot carry its interface scope.
    private nonisolated static func resolveOrigin(_ endpoint: NWEndpoint) async -> String? {
        if let (address, port) = await resolve(endpoint, version: .v4) {
            return "http://\(address):\(port)"
        }
        if let (address, port) = await resolve(endpoint, version: .v6) {
            return "http://[\(address)]:\(port)"
        }
        return nil
    }

    /// Opens a TCP connection to a browse result over one IP version and
    /// reads the remote address of the resulting path.
    private nonisolated static func resolve(_ endpoint: NWEndpoint, version: NWProtocolIP.Options.Version) async -> (String, UInt16)? {
        let params = NWParameters.tcp
        if let ip = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            ip.version = version
        }
        let connection = NWConnection(to: endpoint, using: params)
        return await withCheckedContinuation { continuation in
            let once = ResumeOnce(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.resume(Self.routableAddress(connection.currentPath?.remoteEndpoint))
                    connection.cancel()
                case .failed, .cancelled:
                    once.resume(nil)
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
            DispatchQueue.global().asyncAfter(deadline: .now() + ServerDiscoveryProtocol.probeTimeout) {
                once.resume(nil)
                connection.cancel()
            }
        }
    }

    private nonisolated static func routableAddress(_ endpoint: NWEndpoint?) -> (String, UInt16)? {
        guard case let .hostPort(host, port)? = endpoint else { return nil }
        switch host {
        case let .ipv4(address):
            return (scopeless("\(address)"), port.rawValue)
        case let .ipv6(address) where !address.isLinkLocal:
            return (scopeless("\(address)"), port.rawValue)
        default:
            return nil
        }
    }

    /// Drops any "%iface" scope suffix; a URL host cannot carry it.
    private nonisolated static func scopeless(_ literal: String) -> String {
        literal.split(separator: "%").first.map(String.init) ?? literal
    }
}

private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<(String, UInt16)?, Never>?

    init(_ continuation: CheckedContinuation<(String, UInt16)?, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: (String, UInt16)?) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
