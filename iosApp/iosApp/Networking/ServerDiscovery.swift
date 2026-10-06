import Darwin
import Foundation
import Network
import OSLog
import Synchronization

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
    /// The port stays, so two deployments on one host are told apart.
    var detail: String {
        let host = ServerBranding.hostLabel(url)
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
              let probe = URL(string: "http://\(name.lowercased())\(ServerIdentity.identityPath)"),
              let answer = await Self.probeIdentity(at: probe, timeout: timeout),
              answer.ranOverOverlay, Self.isExpansion(of: name, host: answer.finalURL.host),
              let origin = Self.origin(of: answer.finalURL) else { return nil }
        return Resolution(origin: origin, serverId: answer.serverId)
    }

    /// The HTTPS origin a plain-HTTP server address redirects to, when the
    /// redirect stays on that host, or completes its name (`http://silo` ->
    /// `https://silo.tail1234.ts.net`) over the overlay, and lands on a Silo
    /// server. Such an address answers reads only, so the origin is what
    /// should be saved. A completed name off the overlay is refused: anyone
    /// who can answer plain HTTP for `silo` could otherwise send the app to a
    /// certificate-valid `silo.<their domain>`. Nil for any other address,
    /// answer or failure.
    func secureOrigin(redirectedFrom address: String) async -> String? {
        guard let url = URL(string: address), url.scheme?.lowercased() == "http", let host = url.host,
              url.path.isEmpty || url.path == "/",
              let probe = URL(string: ServerRegistry.normalize(url: address) + ServerIdentity.identityPath),
              let answer = await Self.probeIdentity(at: probe, timeout: timeout) else { return nil }
        let finalHost = answer.finalURL.host?.lowercased()
        guard finalHost == host.lowercased()
            || (answer.ranOverOverlay && Self.isExpansion(of: host, host: finalHost)) else { return nil }
        return Self.origin(of: answer.finalURL)
    }

    private struct IdentityAnswer {
        let finalURL: URL
        let serverId: String
        let ranOverOverlay: Bool
    }

    /// One GET of the identity operation, following at most one redirect and
    /// only to HTTPS. Nil unless it ends in a 200 carrying a server ID.
    private static func probeIdentity(at url: URL, timeout: TimeInterval) async -> IdentityAnswer? {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let policy = HTTPSRedirectOnly()
        guard let (data, response) = try? await session.data(from: url, delegate: policy),
              let http = response as? HTTPURLResponse, http.statusCode == 200, let final = http.url else { return nil }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let document = try? decoder.decode(ServerIdentityDocument.self, from: data),
              let id = ServerIdentity.usable(document.serverId) else { return nil }
        return IdentityAnswer(finalURL: final, serverId: id, ranOverOverlay: await policy.ranOverOverlay())
    }

    /// True when `host` is `name` completed with a domain (`silo` ->
    /// `silo.tail1234.ts.net`). The redirect must not name another machine.
    static func isExpansion(of name: String, host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        let prefix = name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() + "."
        return host.hasPrefix(prefix) && host.count > prefix.count
    }

    /// True when every connection of a probe ran over the overlay: both its
    /// local and remote addresses are overlay addresses, and the local one
    /// belongs to a tunnel interface. A remote overlay address alone is not
    /// enough, because a local network can resolve a bare name to one and
    /// route it to itself; nor is a local one, because a LAN may number its
    /// clients from the same CGNAT range. Only traffic through the overlay's
    /// own point-to-point tunnel (a `utun` interface) passes all three.
    static func ranOverOverlay(
        _ connections: [(local: String, remote: String)],
        isTunnelAddress: (String) -> Bool = isTunnelAddress
    ) -> Bool {
        !connections.isEmpty && connections.allSatisfy {
            isOverlayAddress($0.local) && isOverlayAddress($0.remote) && isTunnelAddress($0.local)
        }
    }

    /// True when `address` is assigned to a point-to-point interface on this
    /// device, as VPN and overlay tunnels are and Wi-Fi and Ethernet are not.
    static func isTunnelAddress(_ address: String) -> Bool {
        let literal = address.split(separator: "%").first.map(String.init) ?? address
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return false }
        defer { freeifaddrs(head) }
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            guard ifa.ifa_flags & UInt32(IFF_POINTOPOINT) != 0, let sockaddr = ifa.ifa_addr else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sockaddr, socklen_t(sockaddr.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let found = String(cString: host)
            if (found.split(separator: "%").first.map(String.init) ?? found) == literal { return true }
        }
        return false
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
        // `URL.host` drops an IPv6 literal's brackets; the origin needs them.
        var origin = "https://" + (host.contains(":") ? "[\(host)]" : host)
        if let port = url.port, port != 443 { origin += ":\(port)" }
        return URL(string: origin).map { ServerRegistry.normalize(url: $0.absoluteString) }
    }
}

/// Follows exactly one redirect, and only to HTTPS. A plain-HTTP answer or a
/// second hop is returned as-is and fails the status check. Also records
/// whether every connection the probe made ran over the overlay.
private final class HTTPSRedirectOnly: NSObject, URLSessionTaskDelegate, Sendable {
    private struct State {
        var followed = false
        var overlayOnly: Bool?
        var waiter: CheckedContinuation<Bool, Never>?
    }

    private let state = Mutex(State())

    /// Waits for the task's metrics: URLSession may deliver them after the
    /// task has returned its data. A bounded wait, in case they never come.
    func ranOverOverlay() async -> Bool {
        await withCheckedContinuation { continuation in
            let known = state.withLock { state -> Bool? in
                if let overlayOnly = state.overlayOnly { return overlayOnly }
                state.waiter = continuation
                return nil
            }
            if let known {
                continuation.resume(returning: known)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(false) }
        }
    }

    private func finish(_ value: Bool) {
        let pending = state.withLock { state -> CheckedContinuation<Bool, Never>? in
            if state.overlayOnly == nil { state.overlayOnly = value }
            defer { state.waiter = nil }
            return state.waiter
        }
        pending?.resume(returning: value)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // A transaction with no addresses reused an earlier connection, which
        // is already counted.
        let connections = metrics.transactionMetrics.compactMap { transaction -> (local: String, remote: String)? in
            guard let local = transaction.localAddress, let remote = transaction.remoteAddress else { return nil }
            return (local, remote)
        }
        finish(OverlayNameResolver.ranOverOverlay(connections))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let follows = request.url?.scheme?.lowercased() == "https" && state.withLock { state -> Bool in
            guard !state.followed else { return false }
            state.followed = true
            return true
        }
        completionHandler(follows ? request : nil)
    }
}

/// Lists the servers discovery finds while the setup screen is visible.
/// Owns the Local Network permission prompt for that screen (first browse).
@MainActor
@Observable
final class ServerDiscovery {
    private(set) var servers: [DiscoveredServer] = []

    /// One current browse result and how far its confirmation got.
    private struct LANEntry {
        enum State {
            /// Not confirmed and not in flight, after `attempts` failures.
            case unconfirmed(attempts: Int)
            /// Attempt number `attempt` is running; `token` tells a stale
            /// attempt's result from the current one. `previous` is a row
            /// being re-checked, which stays visible meanwhile.
            case confirming(attempt: Int, token: UUID, previous: Confirmed?)
            case confirmed(Confirmed)
        }

        /// A confirmed row and the re-checks it has failed in a row.
        struct Confirmed {
            var server: DiscoveredServer
            var misses = 0
        }

        let endpoint: NWEndpoint
        /// The identity the result advertises; a change starts over.
        let serverId: String
        var state: State
    }

    /// An overlay result and the probes it has missed since it last answered.
    private struct OverlayEntry {
        var server: DiscoveredServer
        var misses = 0
    }

    private var isRunning = false
    private var browser: NWBrowser?
    /// Advances on start and stop; work started for an earlier visit to the
    /// screen checks it and drops its result.
    private var session = 0
    /// Advances whenever a browser is replaced; browse callbacks and LAN
    /// confirmations from an earlier browser are dropped.
    private var browserGeneration = 0
    private var lan: [String: LANEntry] = [:]   // keyed by browse result
    private var overlay: [String: OverlayEntry] = [:]   // keyed by origin
    /// One delayed retry covers a transient failure; after that a result that
    /// does not confirm waits for the refresh timer instead of being re-probed
    /// on every browse change.
    private static let maxAttempts = 2
    /// A row survives this many failed re-checks in a row: probes run right
    /// after network changes, while a tunnel may still be re-handshaking.
    private static let maxMisses = 3
    /// Re-runs the overlay probe when the device's network changes, such as
    /// Tailscale connecting while the screen is open.
    private var pathMonitor: NWPathMonitor?
    private var overlayProbe: Task<Void, Never>?
    /// Re-probes on a timer too: a tailnet server can start or recover while
    /// the network itself stays the same, and a LAN result that failed both
    /// confirmations gets another pair.
    private var overlayRefresh: Task<Void, Never>?
    private static let overlayRefreshInterval: Duration = .seconds(30)
    private let identity = ServerIdentityResolver()
    private let resolver = OverlayNameResolver()
    private nonisolated static let logger = Logger(subsystem: "org.siloserver.silo", category: "server.discovery")

    func start() {
        // Not `browser == nil`: the browser is also nil while a failed one
        // waits to be replaced.
        guard !isRunning else { return }
        isRunning = true
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
                self.retryUnconfirmedLAN()
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
        // Results and confirmations belong to the browser being replaced; the
        // new one reports its own, and may find nothing.
        lan = [:]
        publish()
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
                guard self.isRunning, self.browserGeneration == gen, self.browser == nil else { return }
                self.startBrowser()
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    func stop() {
        isRunning = false
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
        lan = [:]
        overlay = [:]
        servers = []
    }

    private func update(results: Set<NWBrowser.Result>, generation gen: Int) {
        var current: [String: LANEntry] = [:]
        for result in results {
            guard case let .bonjour(txt) = result.metadata,
                  let advertisedId = ServerIdentity.usable(txt.dictionary[ServerDiscoveryProtocol.txtServerID]) else { continue }
            let key = "\(result.endpoint)"
            // An entry keeps its progress only while its endpoint advertises
            // the same identity; a changed `id` (a reinstall, or another
            // deployment on the same name and port) is confirmed afresh.
            if let existing = lan[key], existing.serverId == advertisedId {
                current[key] = existing
            } else {
                current[key] = LANEntry(endpoint: result.endpoint, serverId: advertisedId, state: .unconfirmed(attempts: 0))
            }
        }
        lan = current
        confirmUnconfirmed(generation: gen)
        publish()
    }

    /// Starts confirmation for every result that is neither confirmed, in
    /// flight, nor out of attempts.
    private func confirmUnconfirmed(generation gen: Int) {
        for (key, entry) in lan {
            guard case .unconfirmed(let attempts) = entry.state, attempts < Self.maxAttempts else { continue }
            confirm(key: key, attempt: attempts + 1, generation: gen)
        }
    }

    /// Gives results that failed both confirmations another pair, for a
    /// server that was still starting when it was first seen, and re-checks
    /// confirmed rows: an advertisement keeps its name, port and `id` when the
    /// server's address changes (a new DHCP lease), and only resolving it
    /// again finds the new address.
    private func retryUnconfirmedLAN() {
        for (key, entry) in lan {
            switch entry.state {
            case .unconfirmed(let attempts) where attempts >= Self.maxAttempts:
                lan[key]?.state = .unconfirmed(attempts: 0)
            case .confirmed(let confirmed):
                confirm(key: key, attempt: 1, previous: confirmed, generation: browserGeneration)
            default:
                break
            }
        }
        confirmUnconfirmed(generation: browserGeneration)
    }

    private func confirm(key: String, attempt: Int, previous: LANEntry.Confirmed? = nil, generation gen: Int) {
        guard let entry = lan[key] else { return }
        let token = UUID()
        lan[key]?.state = .confirming(attempt: attempt, token: token, previous: previous)
        let instanceName: String? = if case let .service(name, _, _, _) = entry.endpoint { name } else { nil }
        Task {
            let found = await self.confirmLAN(endpoint: entry.endpoint, advertisedId: entry.serverId, instanceName: instanceName)
            // A browse change may have replaced the entry, or a newer browser
            // the whole map, while this was confirming.
            guard self.browserGeneration == gen, case .confirming(_, let current, _)? = self.lan[key]?.state,
                  current == token else { return }
            if let found {
                self.lan[key]?.state = .confirmed(LANEntry.Confirmed(server: found))
                self.publish()
                return
            }
            // A re-checked row stays through a few failures, then is
            // confirmed afresh like a new result.
            if var previous, previous.misses + 1 < Self.maxMisses {
                previous.misses += 1
                self.lan[key]?.state = .confirmed(previous)
                // Another address of this server may now be the better row.
                self.publish()
                return
            }
            self.lan[key]?.state = .unconfirmed(attempts: attempt)
            if previous != nil { self.publish() }
            guard attempt < Self.maxAttempts else { return }
            try? await Task.sleep(for: .seconds(3))
            // Retry only if nothing else touched the entry meanwhile.
            guard self.browserGeneration == gen, case .unconfirmed(let attempts)? = self.lan[key]?.state,
                  attempts == attempt else { return }
            self.confirm(key: key, attempt: attempt + 1, generation: gen)
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
        let resolver = self.resolver
        let identity = self.identity
        let found = await withTaskGroup(of: DiscoveredServer?.self) { group in
            for name in ServerDiscoveryProtocol.overlayNames {
                group.addTask {
                    guard let resolution = await resolver.resolve(name: name) else { return nil }
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
        // must not count as a miss for rows the newer one will report.
        guard self.session == session, !Task.isCancelled else { return }
        mergeOverlay(found)
        publish()
    }

    /// Updates what answered and counts a miss for what did not, dropping a
    /// row only after several misses in a row, so a probe that times out
    /// while a tunnel re-handshakes does not pull a row from under the user.
    private func mergeOverlay(_ found: [DiscoveredServer]) {
        let answered = Dictionary(found.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        let answeredIDs = Set(found.map(\.serverId))
        // A server that answered at a new origin replaces its old one at
        // once; misses only cover a server that did not answer at all.
        overlay = overlay.filter { answered[$0.key] != nil || !answeredIDs.contains($0.value.server.serverId) }
        for key in overlay.keys where answered[key] == nil {
            overlay[key]?.misses += 1
        }
        overlay = overlay.filter { $0.value.misses < Self.maxMisses }
        for (key, server) in answered {
            overlay[key] = OverlayEntry(server: server)
        }
    }

    /// One row per server and route: replicas of one deployment, or one host
    /// seen on several interfaces, advertise the same `id`.
    /// Of several addresses for one server and route, the row shows one that
    /// last answered: a failing address is listed only when no other is.
    private func publish() {
        var rows: [(server: DiscoveredServer, misses: Int)] = []
        for entry in lan.values {
            switch entry.state {
            case .confirmed(let confirmed), .confirming(_, _, let confirmed?):
                rows.append((confirmed.server, confirmed.misses))
            default:
                break
            }
        }
        for entry in overlay.values {
            rows.append((entry.server, entry.misses))
        }
        rows.sort { a, b in
            if a.misses != b.misses { return a.misses < b.misses }
            return a.server.url < b.server.url
        }
        var seen = Set<String>()
        var all: [DiscoveredServer] = []
        for row in rows where seen.insert("\(row.server.serverId)|\(row.server.route)").inserted {
            all.append(row.server)
        }
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

private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<(String, UInt16)?, Never>?>

    init(_ continuation: CheckedContinuation<(String, UInt16)?, Never>) {
        self.continuation = Mutex(continuation)
    }

    func resume(_ value: (String, UInt16)?) {
        let pending = continuation.withLock { slot -> CheckedContinuation<(String, UInt16)?, Never>? in
            defer { slot = nil }
            return slot
        }
        pending?.resume(returning: value)
    }
}
