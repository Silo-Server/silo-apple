import Foundation
import Network
import OSLog

/// What the app remembers about one saved server's local route, keyed by
/// `ServerEntry.id`: the pin learned over the saved address, the admin-set
/// local address, and the local origin that last worked.
struct LocalRouteRecord: Codable, Equatable, Sendable {
    var pin: String
    var localURL: String?
    var lastLocalOrigin: String?
}

/// UserDefaults-backed `LocalRouteRecord`s.
struct LocalRouteStore: Sendable {
    static let defaultsKey = "siloLocalRoute.v1"
    let defaultsKey: String

    init(defaultsKey: String = LocalRouteStore.defaultsKey) {
        self.defaultsKey = defaultsKey
    }

    func record(for serverID: String) -> LocalRouteRecord? {
        all()[serverID]
    }

    func save(_ record: LocalRouteRecord?, for serverID: String) {
        var records = all()
        records[serverID] = record
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    private func all() -> [String: LocalRouteRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let records = try? JSONDecoder().decode([String: LocalRouteRecord].self, from: data) else { return [:] }
        return records
    }
}

/// Decides when the active server's requests use its local route
/// (`LocalRoute`). It needs no location: a route is used exactly when the
/// server answers directly at a private address with the key pinned from its
/// connections document, so a hostile network that copies the server's
/// identity or address gets nothing.
///
/// - The pin and the admin-set local address come from
///   `GET /api/v2/system/connections`, read over the saved address and only
///   when that is HTTPS (a plain-HTTP address cannot vouch for a key).
/// - Candidates: the local origin that last worked, the admin-set local
///   address, and `_silo._tcp` adverts whose TXT `id` is the server's
///   identity. Each is tried as `https` on a private IPv4 address.
/// - It probes while the app is in the foreground on a Wi-Fi, wired or other
///   non-cellular path, again on every path change, and drops the route as
///   soon as the path loses those interfaces or a request on the route fails
///   to connect.
@MainActor
@Observable
final class LocalRouteController {
    static let shared = LocalRouteController()

    /// The active server and what the route needs from it.
    struct Server: Equatable, Sendable {
        let id: String
        let savedURL: String
        let savedOrigin: String
        let identity: String
    }

    /// Effects the controller depends on, replaceable in tests.
    struct Environment: Sendable {
        var fetchConnections: @Sendable (_ server: Server) async -> ServerConnectionsDocument?
        var probe: @Sendable (_ origin: String, _ pin: String, _ identity: String) async -> Bool
        var resolveIPv4: @Sendable (_ host: String) async -> [String]
        var registerSensitiveHost: @Sendable (_ host: String) -> Void
        var store: LocalRouteStore
        /// The path monitor and Bonjour browser; tests drive `pathChanged`
        /// and `advertised` directly instead.
        var startsSystemMonitors: Bool
        var retryDelay: Duration
        var connectionsRefreshInterval: TimeInterval
    }

    /// The local origin requests go to while a route is active; nil
    /// otherwise. Settings show it as "Local network".
    private(set) var activeLocalOrigin: String?

    // Views read only `activeLocalOrigin`; the rest is bookkeeping.
    @ObservationIgnored private var server: Server?
    @ObservationIgnored private var record: LocalRouteRecord?
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var pathAllowsLocal: Bool
    @ObservationIgnored private var pathSignature: String?
    @ObservationIgnored private var advertisedOrigins: [String: String] = [:]
    @ObservationIgnored private var lastConnectionsRefresh: Date?
    @ObservationIgnored private var evaluation: Task<Void, Never>?
    @ObservationIgnored private var retry: Task<Void, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var pathDebounce: Task<Void, Never>?
    @ObservationIgnored private var browser: NWBrowser?
    @ObservationIgnored private var browserGeneration = 0
    @ObservationIgnored private var browseSequence = 0
    @ObservationIgnored private let environment: Environment

    nonisolated static let probeTimeout: TimeInterval = 3
    private nonisolated static let logger = Logger(subsystem: "org.siloserver.silo", category: "local.route")

    init(environment: Environment = .live) {
        self.environment = environment
        // Tests decide the path themselves.
        pathAllowsLocal = !environment.startsSystemMonitors
        if environment.startsSystemMonitors { startPathMonitor() }
    }

    var isOnLocalNetwork: Bool { activeLocalOrigin != nil }

    /// Shown under the active server while its local route is in use.
    nonisolated static let statusText = "Connected on your local network"

    // MARK: - Inputs

    /// The active server, when the app is signed in to it. Called whenever
    /// either changes; a different server starts over.
    func update(activeServer entry: ServerEntry?, isSignedIn: Bool) {
        let next = isSignedIn ? entry.flatMap(Self.server(for:)) : nil
        guard next != server else {
            refresh()
            return
        }
        reset()
        server = next
        record = next.flatMap { environment.store.record(for: $0.id) }
        lastConnectionsRefresh = nil
        restartBrowser()
        refresh()
    }

    func sceneDidBecomeActive() {
        isForeground = true
        restartBrowser()
        refresh()
    }

    func sceneDidEnterBackground() {
        isForeground = false
        evaluation?.cancel()
        evaluation = nil
        stopBrowser()
    }

    /// A request on `route` failed at the connection level. Takes the route
    /// out of use at once if it is still the active one, and checks again
    /// shortly.
    nonisolated static func reportFailure(of route: LocalRoute) {
        LocalRoute.drop(route)
        Task { @MainActor in shared.routeFailed(route) }
    }

    /// A pinned address presented another key: rotated, or not the server.
    /// Requests stop using it at once.
    nonisolated static func reportKeyMismatch(host: String, port: Int) {
        LocalRoute.drop(host: host, port: port)
        Task { @MainActor in shared.keyMismatch(host: host, port: port) }
    }

    func routeFailed(_ route: LocalRoute) {
        guard route.generation == generation, activeLocalOrigin != nil, route.serverID == server?.id else { return }
        Self.logger.info("local route failed; using the saved address")
        demote()
        scheduleRetry()
    }

    func keyMismatch(host: String, port: Int) {
        guard let active = activeLocalOrigin, let url = URL(string: active),
              url.host?.lowercased() == host.lowercased(), (url.port ?? 443) == port else { return }
        Self.logger.error("local route presented an unpinned key; using the saved address")
        demote()
        // The pin may have rotated with SECRET_KEY; the next read of the
        // connections document replaces it.
        lastConnectionsRefresh = nil
        scheduleRetry()
    }

    /// The device's network changed. The route goes at once, since its
    /// address may now lead somewhere else, and so does any check made on the
    /// old network; with a Wi-Fi, wired or other non-cellular interface it
    /// is checked again after `settle` and comes back if the server still
    /// answers there.
    func pathChanged(allowsLocal: Bool, settle: Duration = .zero) {
        pathAllowsLocal = allowsLocal
        demote()
        evaluation?.cancel()
        evaluation = nil
        pathDebounce?.cancel()
        pathDebounce = Task { [weak self] in
            if settle > .zero { try? await Task.sleep(for: settle) }
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// The Bonjour adverts for this server, by browse result.
    func advertised(_ origins: [String: String]) {
        let changed = origins != advertisedOrigins
        advertisedOrigins = origins
        if changed, activeLocalOrigin == nil { refresh() }
    }

    // MARK: - Evaluation

    /// Re-checks the candidates and re-reads the connections document when it
    /// is due. A known key is checked first, so a slow saved address does not
    /// hold up the local one. Runs one evaluation at a time; a newer one
    /// replaces it.
    func refresh() {
        guard let server, isForeground else { return }
        evaluation?.cancel()
        evaluation = Task { [weak self] in
            guard let self else { return }
            let checkedKnownKey = self.record != nil
            if checkedKnownKey { await self.evaluate(for: server) }
            guard !Task.isCancelled else { return }
            let changed = await self.refreshConnectionsIfDue(for: server)
            guard !Task.isCancelled, !checkedKnownKey || changed else { return }
            await self.evaluate(for: server)
        }
    }

    /// Waits for a pending re-check and the evaluation in flight. Tests only.
    func settle() async {
        await pathDebounce?.value
        await evaluation?.value
    }

    /// Whether the record changed.
    private func refreshConnectionsIfDue(for server: Server) async -> Bool {
        if let last = lastConnectionsRefresh,
           Date().timeIntervalSince(last) < environment.connectionsRefreshInterval { return false }
        guard let document = await environment.fetchConnections(server),
              !Task.isCancelled, self.server == server, document.serverId == server.identity else { return false }
        lastConnectionsRefresh = Date()
        guard let local = document.localRoute, !local.spkiSha256.isEmpty else {
            // The server does not offer a local route (an older server).
            guard record != nil else { return false }
            forgetRecord()
            return true
        }
        var next = record ?? LocalRouteRecord(pin: local.spkiSha256)
        if next.pin != local.spkiSha256 {
            // A new key (SECRET_KEY rotation): nothing the old pin trusted
            // stands any more.
            next = LocalRouteRecord(pin: local.spkiSha256)
            LocalRouteTrust.removeAll()
            demote()
        }
        next.localURL = local.url
        if next != record {
            let isFirstPin = record == nil
            record = next
            environment.store.save(next, for: server.id)
            // Adverts are worth browsing for only once there is a key to
            // check them against.
            if isFirstPin { restartBrowser() }
            return true
        }
        return false
    }

    private func evaluate(for server: Server) async {
        guard pathAllowsLocal, let record, self.server == server else {
            demote()
            return
        }
        for origin in await candidates(for: server, record: record) {
            guard !Task.isCancelled, self.server == server else { return }
            LocalRouteTrust.trust(origin, pin: record.pin)
            if await environment.probe(origin, record.pin, server.identity) {
                guard !Task.isCancelled, self.server == server, pathAllowsLocal else { return }
                activate(origin, for: server)
                return
            }
        }
        guard !Task.isCancelled, self.server == server else { return }
        demote()
    }

    /// Candidate local origins, best first: the active one, the one that
    /// worked last, the admin-set address, then Bonjour adverts.
    private func candidates(for server: Server, record: LocalRouteRecord) async -> [String] {
        var ordered: [String] = []
        func add(_ origin: String?) {
            if let origin, !ordered.contains(origin) { ordered.append(origin) }
        }
        add(activeLocalOrigin)
        add(record.lastLocalOrigin)
        if let configured = record.localURL {
            if let origin = LocalRoute.localOrigin(forAddress: configured) {
                add(origin)
            } else if let url = URL(string: configured), let host = url.host {
                // A host name: try each private IPv4 address it resolves to on
                // this network, on the same port.
                let port = url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
                for address in await environment.resolveIPv4(host) {
                    add(LocalRoute.localOrigin(forAddress: "http://\(address):\(port)"))
                }
            }
        }
        for origin in advertisedOrigins.values.sorted() { add(origin) }
        return ordered
    }

    private func activate(_ origin: String, for server: Server) {
        guard activeLocalOrigin != origin else { return }
        if let host = URL(string: origin)?.host { environment.registerSensitiveHost(host) }
        generation += 1
        // It stays installed when the route goes, so a stream already playing
        // over it survives a brief drop; `LocalRouteTrust.removeAll` takes it
        // away with the pins.
        #if canImport(AetherEngine)
        LocalRouteTrust.installEngineEvaluator()
        #endif
        LocalRoute.publish(LocalRoute(
            serverID: server.id, savedOrigin: server.savedOrigin, localOrigin: origin, generation: generation))
        activeLocalOrigin = origin
        if var record, record.lastLocalOrigin != origin {
            record.lastLocalOrigin = origin
            self.record = record
            environment.store.save(record, for: server.id)
        }
        Self.logger.info("local route active")
    }

    private func demote() {
        guard activeLocalOrigin != nil else { return }
        LocalRoute.publish(nil)
        activeLocalOrigin = nil
    }

    private func reset() {
        evaluation?.cancel()
        evaluation = nil
        retry?.cancel()
        retry = nil
        demote()
        LocalRouteTrust.removeAll()
        advertisedOrigins = [:]
        server = nil
        record = nil
    }

    private func forgetRecord() {
        guard let server else { return }
        record = nil
        environment.store.save(nil, for: server.id)
        LocalRouteTrust.removeAll()
        demote()
    }

    private func scheduleRetry() {
        retry?.cancel()
        let delay = environment.retryDelay
        retry = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// The route needs an identity to confirm and an HTTPS saved address
    /// without a path: the LAN listener serves the API at its root.
    static func server(for entry: ServerEntry) -> Server? {
        guard let identity = ServerIdentity.usable(entry.verifiedServerId),
              let url = URL(string: ServerRegistry.normalize(url: entry.url)),
              url.scheme?.lowercased() == "https",
              url.path.isEmpty || url.path == "/",
              let origin = LocalRoute.origin(of: url) else { return nil }
        return Server(id: entry.id, savedURL: ServerRegistry.normalize(url: entry.url), savedOrigin: origin, identity: identity)
    }

    // MARK: - System monitors

    private func startPathMonitor() {
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            // A VPN tunnel reports `.other`; over cellular it is still not the LAN.
            let allows = path.status == .satisfied
                && !path.usesInterfaceType(.cellular)
                && (path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
                    || path.usesInterfaceType(.other))
            // Cellular coming and going does not move the LAN; a new router
            // or subnet on the same interface does.
            let interfaces = path.availableInterfaces.filter { $0.type != .cellular }.map { "\($0.name):\($0.type)" }
            let signature = "\(path.status)|\(interfaces.joined(separator: ","))|\(path.gateways.map { "\($0)" }.sorted().joined(separator: ","))"
            Task { @MainActor [weak self] in self?.pathUpdated(allowsLocal: allows, signature: signature) }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
    }

    /// Updates that leave the network as it was change nothing. Any other
    /// is a network change; its re-check waits for a VPN or an interface
    /// change to finish reporting paths.
    private func pathUpdated(allowsLocal: Bool, signature: String) {
        guard signature != pathSignature else { return }
        pathSignature = signature
        pathChanged(allowsLocal: allowsLocal, settle: .milliseconds(500))
    }

    private func restartBrowser() {
        stopBrowser()
        guard environment.startsSystemMonitors, isForeground, let server, record != nil else { return }
        browserGeneration += 1
        let generation = browserGeneration
        let identity = server.identity
        let parameters = NWParameters()
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjourWithTXTRecord(type: ServerDiscoveryProtocol.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let matching = results.filter { result in
                guard case let .bonjour(txt) = result.metadata else { return false }
                return ServerIdentity.usable(txt.dictionary[ServerDiscoveryProtocol.txtServerID]) == identity
            }
            Task { @MainActor [weak self] in
                guard let self, self.browserGeneration == generation else { return }
                // Only the newest set of results may land: resolving an
                // older one can finish later.
                self.browseSequence += 1
                let sequence = self.browseSequence
                var origins: [String: String] = [:]
                for result in matching {
                    if let resolved = await ServerDiscovery.resolveOrigin(result.endpoint),
                       let origin = LocalRoute.localOrigin(forAddress: resolved) {
                        origins["\(result.endpoint)"] = origin
                    }
                }
                guard self.browserGeneration == generation, self.browseSequence == sequence else { return }
                self.advertised(origins)
            }
        }
        browser.stateUpdateHandler = { state in
            guard case .failed(let error) = state else { return }
            Self.logger.error("local route browser failed: \(String(describing: error), privacy: .public)")
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    private func stopBrowser() {
        browserGeneration += 1
        browser?.cancel()
        browser = nil
    }
}

extension LocalRouteController.Environment {
    static let live = LocalRouteController.Environment(
        fetchConnections: { server in
            // Read over the saved address with its own bearer, never over the
            // local route: this is where the pin is learned.
            guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
                  auth.account.serverId == server.id,
                  ServerRegistry.normalize(url: auth.account.serverURL) == server.savedURL,
                  let bearer = auth.accessToken else { return nil }
            return await LocalRouteProbe.connections(origin: server.savedOrigin, bearer: bearer)
        },
        probe: { origin, pin, identity in
            await LocalRouteProbe.confirms(origin: origin, pin: pin, identity: identity)
        },
        resolveIPv4: { host in await LocalRouteProbe.privateIPv4Addresses(of: host) },
        registerSensitiveHost: { host in
            #if os(iOS) || os(tvOS)
            DiagLog.registerSensitiveHost(host)
            #endif
        },
        store: LocalRouteStore(),
        startsSystemMonitors: true,
        retryDelay: .seconds(5),
        connectionsRefreshInterval: 15 * 60
    )
}

/// One candidate check: TLS that presents the pinned key, no redirects, and
/// the server's identity in `GET /api/v2/system/identity`.
enum LocalRouteProbe {
    /// The connections document from the saved HTTPS address, where the pin
    /// is learned. Follows no redirect: one to another address, or to plain
    /// HTTP, would let whoever answers there hand over their own pin.
    static func connections(
        origin: String,
        bearer: String,
        configuration: URLSessionConfiguration = .ephemeral
    ) async -> ServerConnectionsDocument? {
        guard let url = URL(string: origin + ServerIdentity.connectionsPath) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: ServerIdentity.probeTimeout)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(bearer)", forHTTPHeaderField: "Authorization")
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: RedirectRefusingDelegate(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let document = try? HTTPClient.makeJSONDecoder().decode(ServerConnectionsDocument.self, from: data),
              document.isAvailable
        else { return nil }
        return document
    }

    static func confirms(origin: String, pin: String, identity: String) async -> Bool {
        guard let url = URL(string: origin + ServerIdentity.identityPath) else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = LocalRouteController.probeTimeout
        configuration.timeoutIntervalForResource = LocalRouteController.probeTimeout
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: PinnedProbeDelegate(pin: pin), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        guard let (data, response) = try? await session.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let document = try? HTTPClient.makeJSONDecoder().decode(ServerIdentityDocument.self, from: data)
        else { return false }
        return ServerIdentity.usable(document.serverId) == identity
    }

    /// The private IPv4 addresses `host` resolves to on the current network.
    static func privateIPv4Addresses(of host: String) async -> [String] {
        await Task.detached(priority: .utility) {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_STREAM
            var head: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, nil, &hints, &head) == 0, let first = head else { return [] }
            defer { freeaddrinfo(head) }
            var addresses: [String] = []
            for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
                guard let sockaddr = entry.pointee.ai_addr else { continue }
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                guard getnameinfo(sockaddr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count),
                                  nil, 0, NI_NUMERICHOST) == 0 else { continue }
                let address = String(cString: buffer)
                if LocalRoute.isPrivateIPv4(address), !addresses.contains(address) { addresses.append(address) }
            }
            return addresses
        }.value
    }
}

/// Follows no redirect: the answer has to come from the address asked.
private class RedirectRefusingDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// Trusts exactly the pinned key and follows no redirect: a candidate that
/// sends the probe elsewhere is not the server.
private final class PinnedProbeDelegate: RedirectRefusingDelegate {
    let pin: String

    init(pin: String) {
        self.pin = pin
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        guard let trust = challenge.protectionSpace.serverTrust,
              LocalRouteTrust.spkiPin(of: trust) == pin else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
