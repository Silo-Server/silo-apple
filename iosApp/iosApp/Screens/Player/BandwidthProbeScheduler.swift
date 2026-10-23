import Foundation
import Network
import os

/// The network in use, as the bandwidth probe sees it.
struct BandwidthProbeNetwork: Equatable, Sendable {
    var isConnected: Bool
    /// `wifi`, `ethernet`, `cellular` or `other`, the contract's names. A VPN
    /// reports the interface it runs over.
    var transport: String
    var usesCellular: Bool
    /// Mobile data, a hotspot the system marks expensive, or Low Data Mode
    /// (``PlaybackNetworkPath/isMetered(usesCellular:isExpensive:isConstrained:)``):
    /// no probe runs, and no cached estimate is sent.
    var isMetered: Bool
    /// Which network a measurement describes: another interface, gateway or
    /// metering is another network.
    var key: String

    static let offline = BandwidthProbeNetwork(
        isConnected: false, transport: "other", usesCellular: false, isMetered: false, key: "none"
    )
}

extension BandwidthProbeNetwork {
    init(_ path: NWPath) {
        guard path.status == .satisfied else {
            self = .offline
            return
        }
        let transport = if path.usesInterfaceType(.wifi) {
            "wifi"
        } else if path.usesInterfaceType(.wiredEthernet) {
            "ethernet"
        } else if path.usesInterfaceType(.cellular) {
            "cellular"
        } else {
            "other"
        }
        let usesCellular = path.usesInterfaceType(.cellular)
        let isMetered = PlaybackNetworkPath.isMetered(path)
        // Cellular coming and going while on another network is the same
        // network, as for the local route.
        let interfaces = path.availableInterfaces
            .filter { transport == "cellular" || $0.type != .cellular }
            .map(\.name).sorted().joined(separator: ",")
        let gateways = path.gateways.map { "\($0)" }.sorted().joined(separator: ",")
        self.init(
            isConnected: true,
            transport: transport,
            usesCellular: usesCellular,
            isMetered: isMetered,
            key: "\(transport)|\(interfaces)|\(gateways)|\(path.isExpensive)|\(path.isConstrained)"
        )
    }
}

/// A connection speed reading for the network in use, from this device's own
/// test or the server's store for this device and connection.
struct BandwidthReading: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        /// A speed test, taken on `transport` (`wifi`, `ethernet`, `cellular`
        /// or `other`).
        case probe(transport: String)
        /// The throughput a plan's media requests received.
        case playbackSample
    }

    let kbps: Int
    /// The link is at least this fast: a quick test that reached its
    /// target, a result over the probe's ceiling, or a playback sample.
    let lowerBound: Bool
    let measuredAt: Date
    let source: Source
}

/// One test's measurement, as this device reports it to the server.
struct BandwidthMeasurement: Equatable, Sendable {
    let kbps: Int
    let lowerBound: Bool
    let bytes: Int
    let durationMs: Int
    /// `wifi`, `ethernet`, `cellular` or `other`, as reported to the server.
    let transport: String
    let measuredAt: Date
    /// The viewer ran it with **Test speed**. A manual result above the
    /// learned limit lifts it on the server.
    var manual = false

    var reading: BandwidthReading {
        BandwidthReading(kbps: kbps, lowerBound: lowerBound, measuredAt: measuredAt, source: .probe(transport: transport))
    }
}

/// The readings the server keeps for this device on the connection in use.
struct BandwidthStoredReadings: Equatable, Sendable {
    var probe: BandwidthReading?
    var playbackSample: BandwidthReading?

    static let none = BandwidthStoredReadings()
}

/// The active server's speed test, from a fresh capability response.
struct BandwidthProbeTarget: Sendable {
    /// `bandwidth_probe_url`, resolved; a test adds its `size`.
    let url: URL
    /// `bandwidth_probe_target_kbps`: the rate a quick test has to prove.
    let targetKbps: Int?
    /// `bandwidth_probe_automatic`: false when the admin turned automatic
    /// tests off.
    let automatic: Bool
    /// `bandwidth_probe_max_age_seconds`: how long a reading stays current.
    let maxAge: TimeInterval
    let auth: CapturedOrdinaryRequestAuth

    var serverId: String { auth.account.serverId }
}

/// The server side of a test: its settings, the stored readings, the
/// download and the report.
protocol BandwidthProbeServer: Sendable {
    /// The active profile's speed test from a fresh capability response; nil
    /// when the server advertises none.
    func target() async throws -> BandwidthProbeTarget?
    /// What `GET /api/v2/playback/connection` keeps for this device on the
    /// connection in use now.
    func storedReadings() async throws -> BandwidthStoredReadings
    func measure(_ target: BandwidthProbeTarget, mode: BandwidthProbeMeter.Mode) async throws -> BandwidthProbeResult
    /// POSTs `measurement`.
    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> BandwidthReportResult
}

/// What became of a reported measurement.
enum BandwidthReportResult: Equatable, Sendable {
    case stored
    /// The server answered and did not store it.
    case refused
    /// The request never got an answer.
    case failed
}

/// ``BandwidthProbeServer`` over `/api/v2`. Tests run only against a server
/// whose capability `features` carry `connection_speed_v1` and that names a
/// `bandwidth_probe_url`.
struct LiveBandwidthProbeServer: BandwidthProbeServer {
    /// Before the redesign a server sent no schedule settings: a reading
    /// lasted 7 days and automatic tests ran.
    static let fallbackMaxAge: TimeInterval = 7 * 24 * 60 * 60

    func target() async throws -> BandwidthProbeTarget? {
        guard let auth = await profileAuth() else { return nil }
        let capabilities: APIv2PlaybackCapabilities
        do {
            // Read afresh: the URL is on the origin the request arrived on,
            // which a local route can change, and the admin can change the
            // schedule.
            capabilities = try await SiloAPI.shared.apiV2Client.playbackCapabilities(auth: auth)
        } catch APIv2Error.serverUpdateRequired {
            return nil
        }
        guard capabilities.features.contains(PlaybackProtocolV3.connectionSpeedFeature),
              let advertised = capabilities.bandwidthProbeUrl, !advertised.isEmpty,
              let serverURL = URL(string: auth.account.serverURL),
              let url = URL(string: advertised, relativeTo: serverURL)?.absoluteURL else {
            return nil
        }
        return BandwidthProbeTarget(
            url: url,
            targetKbps: capabilities.bandwidthProbeTargetKbps,
            automatic: capabilities.bandwidthProbeAutomatic ?? true,
            maxAge: capabilities.bandwidthProbeMaxAgeSeconds.map(TimeInterval.init) ?? Self.fallbackMaxAge,
            auth: auth
        )
    }

    /// No profile is chosen yet, so nothing profile-scoped can be read.
    struct NoProfile: Error {}

    func storedReadings() async throws -> BandwidthStoredReadings {
        guard let auth = await profileAuth() else { throw NoProfile() }
        let connection = try await SiloAPI.shared.apiV2Client.playbackConnection(auth: auth)
        return BandwidthStoredReadings(
            probe: connection.probe.map {
                BandwidthReading(kbps: $0.kbps, lowerBound: $0.lowerBound, measuredAt: $0.measuredAt,
                                 source: .probe(transport: $0.transport))
            },
            playbackSample: connection.playbackSample.map {
                BandwidthReading(kbps: $0.kbps, lowerBound: true, measuredAt: $0.measuredAt, source: .playbackSample)
            }
        )
    }

    func measure(_ target: BandwidthProbeTarget, mode: BandwidthProbeMeter.Mode) async throws -> BandwidthProbeResult {
        let download = BandwidthProbeDownload(mode: mode)
        // An account address that does not parse measures nothing.
        guard let serverURL = URL(string: target.auth.account.serverURL),
              let url = BandwidthProbe.downloadURL(target.url, serverURL: serverURL, bytes: download.requestedBytes) else {
            return .unavailable(status: 0)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        AppleDeviceIdentity.current.applyHeaders(to: &request)
        // The account's own credentials, refreshed when they have expired.
        request.allHTTPHeaderFields = try await SiloAPI.shared.http.mediaRequestHeaders(
            expectedAuth: target.auth,
            baseHeaders: request.allHTTPHeaderFields ?? [:]
        )
        return try await download.measure(request)
    }

    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> BandwidthReportResult {
        do {
            try await SiloAPI.shared.apiV2Client.reportPlaybackBandwidthProbe(
                APIv2PlaybackBandwidthProbeResult(
                    kbps: measurement.kbps,
                    bytes: measurement.bytes,
                    durationMs: measurement.durationMs,
                    transport: measurement.transport,
                    lowerBound: measurement.lowerBound,
                    manual: measurement.manual
                ),
                auth: target.auth
            )
            return .stored
        } catch {
            return Self.reportResult(for: error)
        }
    }

    /// A report the server answered without storing it is refused, so the
    /// result is never kept or sent as an estimate. One that never got an
    /// answer (transport, cancellation, an owner that changed, or the
    /// pre-send v1 verdict) failed.
    static func reportResult(for error: Error) -> BandwidthReportResult {
        switch error {
        case PlaybackSequencedError.invalidResponse, HTTPError.http:
            return .refused
        case let error as APIv2Error:
            switch error {
            case .problem, .httpStatus: return .refused
            default: return .failed
            }
        default:
            return .failed
        }
    }

    /// The report and the connection read are profile-scoped, so both need a
    /// chosen profile.
    private func profileAuth() async -> CapturedOrdinaryRequestAuth? {
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              let profileId = auth.profileId, !profileId.isEmpty else { return nil }
        return auth
    }
}

/// Who a check reads for: a signed-in server, the credentials it signed in
/// with, and the profile. A new sign-in, even to the same server, is another
/// session, and what the scheduler held for the last one is discarded.
struct BandwidthProbeSession: Equatable, Sendable {
    let serverId: String
    var credentialGeneration: UUID? = nil
    var profileId: String? = nil
}

/// Keeps the connection speed readings for the active server and network, for
/// playback starts (``freshEstimateKbps(forServer:overLocalRoute:)``) and
/// Settings (``probeReading``, ``runNow()``). One per app. The spec is the
/// server repo's `docs/design/2026-10-17-buffering-quality.md`, "Connection
/// speed test" > "When to test".
///
/// - **Check**: when a profile signs in, Silo returns to the foreground, or
///   the connection changes: another network, metering, or the local route
///   to this server coming or going. A check reads the server's speed-test
///   settings and its stored readings at once, so a playback start in the
///   first seconds sends one. A failed read changes nothing held and runs no
///   test. Only the test waits: ``startDelay`` later, if automatic tests are
///   on and no current reading proves the link, a look reads again and runs
///   a quick test.
/// - **Current**: a reading younger than the server's
///   `bandwidth_probe_max_age_seconds`; none is current until that is known.
///   A settled rate proves the link; a lower bound proves it only while it
///   reaches the current target.
/// - **Not**: while media plays or starts (a video player loading or
///   playing, ``isMediaActive``, then ``playbackQuietPeriod`` for automatic
///   tests), on a metered or cellular network, or with Silo in the
///   background, hidden or minimized. A test running when one of these begins
///   is cancelled and measured nothing.
/// - **Failures** wait for the next check. A 429 holds automatic tests
///   against the server that sent it until its `Retry-After`, on any network
///   and across sign-ins, while the app runs.
/// - **Test speed** (``runNow()``) runs the accurate test whenever no media
///   plays, even with automatic tests off or a current reading. Its result
///   replaces the playback sample; an automatic test's does not.
/// - **Reporting**: every measurement is POSTed with the transport it was
///   taken on. A result the server refuses is not kept.
@MainActor
@Observable
final class BandwidthProbeScheduler {
    static let shared = BandwidthProbeScheduler(server: LiveBandwidthProbeServer())

    /// Lets the first screen settle before a look that may test.
    nonisolated static let startDelay: TimeInterval = 5
    /// How long after a playback start automatic tests hold off: media is
    /// still loading for a while after the start itself.
    nonisolated static let playbackQuietPeriod: TimeInterval = 60

    /// What a test came to.
    enum Outcome: Equatable {
        case measured(BandwidthMeasurement)
        /// Measured, but the server did not store it: it refused it (the
        /// result is not kept) or the report failed in transport (it is).
        case notSaved(BandwidthMeasurement)
        /// HTTP 429: try again after `retryAfterSeconds`.
        case rateLimited(retryAfterSeconds: Int)
        /// The server refused the download: no media path serves probes.
        case unavailable
        /// The test measured nothing.
        case tooLittleData
        /// The request or the capability read failed, or the first byte never
        /// came.
        case networkError
        /// A metered or cellular network: speed tests are skipped.
        case metered
        case offline
        /// Media is playing or starting; a test would slow it and
        /// under-measure.
        case playbackActive
        /// Signed out, or the server does not advertise `connection_speed_v1`
        /// with a probe URL.
        case notSupported
        /// The network or server changed, or Silo left the foreground, before
        /// the test finished.
        case interrupted
    }

    /// The latest speed test on the active server and connection: this
    /// device's own, or the server's when that is newer. Kept past its
    /// lifetime so Settings can show it; nil once the connection or session
    /// changes.
    private(set) var probeReading: BandwidthReading?
    /// The server's playback sample for this connection.
    private(set) var playbackSample: BandwidthReading?
    /// The network in use.
    private(set) var network: BandwidthProbeNetwork = .offline
    /// Moves on with every change of connection: another network, metering,
    /// or the local route to the server coming or going. Settings reads the
    /// connection again on each.
    private(set) var connectionRevision: UInt64 = 0
    private(set) var isProbing = false

    /// Whether other media plays, such as audio. The app sets it; video
    /// players report themselves (``playbackStarting(by:)``,
    /// ``videoPlayer(_:isActive:)``).
    @ObservationIgnored var isMediaActive: @MainActor () -> Bool = { false }
    /// The server whose local route requests take now, if any.
    @ObservationIgnored var localRouteServerId: @MainActor () -> String? = { LocalRoute.active?.serverID }

    /// One test, and the outcome it ends with when something cancels it.
    private final class Run {
        /// **Test speed**'s accurate test, rather than an automatic one.
        let isTestSpeed: Bool
        var task: Task<Outcome, Never>?
        var cancelledFor: Outcome?

        init(isTestSpeed: Bool) {
            self.isTestSpeed = isTestSpeed
        }
    }

    /// Whose readings these are: a server, over a network and route.
    private struct ReadingsKey: Equatable {
        let serverId: String
        let connection: String
    }

    @ObservationIgnored private let server: BandwidthProbeServer
    @ObservationIgnored private let clock: PlayerPromptClock
    /// Follows the scene: false until it first becomes active, so a launch
    /// into the background reads and tests nothing.
    @ObservationIgnored private var isForeground = false
    @ObservationIgnored private var isHidden = false
    @ObservationIgnored private var session: BandwidthProbeSession?
    /// The connection the scheduler last checked: network and route.
    @ObservationIgnored private var checkedConnection: String?
    @ObservationIgnored private var readingsKey: ReadingsKey?
    /// The speed test settings the server sent for this session.
    @ObservationIgnored private var lastTarget: BandwidthProbeTarget?
    @ObservationIgnored private var lastPlaybackStart: Date?
    /// A 429's `Retry-After` per server: no automatic test against it before
    /// then, on any network.
    @ObservationIgnored private var rateLimits: [String: Date] = [:]
    @ObservationIgnored private var timer: PlayerPromptTimer?
    @ObservationIgnored private var inFlight: Run?
    @ObservationIgnored private var isLooking = false
    /// A look came while an earlier look or test was finishing.
    @ObservationIgnored private var looksAgain = false
    /// Every event that stops a test, counted with the latest reason, even
    /// with no test running: a Test speed waiting for the test it replaced
    /// has no run of its own to cancel yet.
    @ObservationIgnored private var interruption = (count: 0, reason: Outcome.interrupted)
    /// The check's read; the look that follows waits for it.
    @ObservationIgnored private var checkRead: Task<Bool, Never>?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    /// Video players loading or playing. Weak, so a player that goes away
    /// without saying so cannot hold tests off.
    @ObservationIgnored private let videoPlayers = NSHashTable<AnyObject>.weakObjects()

    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "BandwidthProbe")

    init(server: BandwidthProbeServer, clock: PlayerPromptClock? = nil) {
        self.server = server
        self.clock = clock ?? LivePlayerPromptClock()
    }

    // MARK: - Playback

    /// The highest current reading's kbps that a playback start on
    /// `serverId` may send as its estimate: the active session's, taken over
    /// the route the start's media takes (`overLocalRoute`) on the network in
    /// use now. Nil when there is none, for another server, or on a metered
    /// network.
    func freshEstimateKbps(forServer serverId: String?, overLocalRoute: Bool) -> Int? {
        guard network.isConnected, !network.isMetered, let serverId, serverId == session?.serverId,
              readingsKey == ReadingsKey(serverId: serverId, connection: connection(local: overLocalRoute))
        else { return nil }
        return currentReadings.map(\.kbps).max()
    }

    /// ``freshEstimateKbps(forServer:overLocalRoute:)`` for the active
    /// session over the route requests take now.
    func freshEstimateKbps() -> Int? {
        freshEstimateKbps(forServer: session?.serverId, overLocalRoute: routeIsLocal)
    }

    /// Playback is starting: stops a running test and holds off new ones
    /// while the media loads. The readings stay. A video `player` keeps tests
    /// off while it loads or plays (``videoPlayer(_:isActive:)``) and until
    /// ``playbackEnded(by:)``, whichever way it is presented, including
    /// picture in picture.
    func playbackStarting(by player: AnyObject? = nil) {
        if let player { videoPlayers.add(player) }
        lastPlaybackStart = clock.now
        cancelInFlight(.playbackActive)
    }

    /// A video `player` began or stopped loading or playing. A paused player
    /// does not hold tests off; resuming stops a running test.
    func videoPlayer(_ player: AnyObject, isActive: Bool) {
        if isActive {
            videoPlayers.add(player)
            cancelInFlight(.playbackActive)
        } else {
            videoPlayers.remove(player)
        }
    }

    /// The video `player` stopped for good.
    func playbackEnded(by player: AnyObject) {
        videoPlayers.remove(player)
    }

    // MARK: - Settings

    /// **Test speed**: runs the accurate test and reports it. Refuses while
    /// media plays or on a metered network; replaces a running automatic test
    /// and joins a running **Test speed**. A result the server stores replaces
    /// its playback sample, so the connection is read again afterwards.
    func runNow() async -> Outcome {
        if let refused = gate(automatic: false) { return refused }
        let outcome = await probeOnce(testSpeed: true)
        if case .measured = outcome, let session { await read(for: session) }
        return outcome
    }

    // MARK: - App inputs

    /// Begins following the network, on every platform
    /// (``PlaybackNetworkMonitor`` runs only where a cellular quality
    /// applies). Safe to call more than once.
    func followNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let network = BandwidthProbeNetwork(path)
            Task { @MainActor in self?.networkChanged(network) }
        }
        monitor.start(queue: DispatchQueue(label: "org.siloserver.silo.bandwidth-probe-path"))
        pathMonitor = monitor
    }

    /// The scene became active, or left for the background.
    func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else { return }
        isForeground = foreground
        activityChanged()
    }

    /// On a Mac: the app is hidden, or every window it could play in is
    /// minimized.
    func setHidden(_ hidden: Bool) {
        guard hidden != isHidden else { return }
        isHidden = hidden
        Self.logger.notice("app \(hidden ? "hidden" : "visible", privacy: .public)")
        activityChanged()
    }

    /// A profile signed in, or nil once none is. Every sign-in is a check,
    /// and what the last session held is discarded.
    func setActiveSession(_ next: BandwidthProbeSession?) {
        guard next != session else {
            if next != nil { Self.logger.notice("sign-in for the current session ignored") }
            return
        }
        Self.logger.notice("server \(next == nil ? "signed out" : "signed in", privacy: .public)")
        session = next
        forget()
        cancelInFlight(.interrupted)
        if next != nil {
            check()
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    /// ``setActiveSession(_:)`` for a server alone.
    func setActiveServer(_ serverId: String?) {
        setActiveSession(serverId.map { BandwidthProbeSession(serverId: $0) })
    }

    /// Another network has its own readings on the server: a check reads them
    /// before anything is tested.
    func networkChanged(_ next: BandwidthProbeNetwork) {
        let changed = next.key != network.key
        network = next
        guard changed else { return }
        Self.logger.notice("network changed: \(next.isConnected ? next.transport : "offline", privacy: .public)")
        connectionChanged()
    }

    /// The local route to a server came or went: requests, and the readings
    /// they return, now take another path.
    func localRouteChanged() {
        guard let checkedConnection, checkedConnection != currentConnection else { return }
        Self.logger.notice("local route \(self.routeIsLocal ? "up" : "down", privacy: .public)")
        connectionChanged()
    }

    // MARK: - Check

    private var isActive: Bool { isForeground && !isHidden }

    private var routeIsLocal: Bool {
        guard let serverId = session?.serverId else { return false }
        return localRouteServerId() == serverId
    }

    private func connection(local: Bool) -> String {
        "\(network.key)|\(local ? "local" : "remote")"
    }

    /// The network in use and the route requests take now.
    private var currentConnection: String { connection(local: routeIsLocal) }

    private func connectionChanged() {
        connectionRevision &+= 1
        forget()
        cancelInFlight(.interrupted)
        check()
    }

    private func activityChanged() {
        if isActive {
            check()
        } else {
            timer?.cancel()
            timer = nil
            cancelInFlight(.interrupted)
        }
    }

    private func forget() {
        readingsKey = nil
        probeReading = nil
        playbackSample = nil
        lastTarget = nil
        checkRead?.cancel()
        checkRead = nil
    }

    /// The readings that are still current. None is until the server's
    /// lifetime is known.
    private var currentReadings: [BandwidthReading] {
        guard let maxAge = lastTarget?.maxAge else { return [] }
        return [probeReading, playbackSample].compactMap { $0 }.filter {
            // The server dates its readings by its own clock; one ahead of
            // the device's is as fresh as now.
            max(0, clock.now.timeIntervalSince($0.measuredAt)) < maxAge
        }
    }

    /// A current settled reading proves the link; a current lower bound only
    /// while it reaches the target. With no target there is nothing to prove.
    private var linkIsProven: Bool {
        currentReadings.contains { reading in
            guard reading.lowerBound, let target = lastTarget?.targetKbps else { return true }
            return reading.kbps >= target
        }
    }

    /// Keeps the newer probe, the server's or this device's own, and the
    /// server's playback sample.
    private func adopt(_ stored: BandwidthStoredReadings, key: ReadingsKey) {
        if readingsKey != key { probeReading = nil }
        readingsKey = key
        if let probe = stored.probe, probe.measuredAt >= (probeReading?.measuredAt ?? .distantPast) {
            probeReading = probe
        }
        playbackSample = stored.playbackSample
    }

    private func cancelInFlight(_ reason: Outcome) {
        interruption = (interruption.count + 1, reason)
        guard let run = inFlight, run.cancelledFor == nil else { return }
        run.cancelledFor = reason
        run.task?.cancel()
    }

    /// Reads the server's settings and readings now, so a start in the first
    /// seconds sends one, and looks once the first screen has settled.
    private func check() {
        guard let session, isActive else {
            Self.logger.notice("check skipped: \(self.session == nil ? "no server" : "not visible", privacy: .public)")
            return
        }
        checkedConnection = currentConnection
        checkRead?.cancel()
        checkRead = Task { await read(for: session) }
        timer?.cancel()
        timer = clock.schedule(after: Self.startDelay) { [weak self] in
            guard let self else { return }
            self.timer = nil
            Task { await self.look() }
        }
    }

    /// Reads the speed-test settings and, if the server has a speed test,
    /// the stored readings, and adopts them. False when either read failed:
    /// nothing held changes then.
    @discardableResult
    private func read(for session: BandwidthProbeSession) async -> Bool {
        guard self.session == session, isActive, network.isConnected else {
            Self.logger.notice("connection read skipped: \(self.network.isConnected ? "session or visibility changed" : "offline", privacy: .public)")
            return false
        }
        let connection = currentConnection
        let target: BandwidthProbeTarget
        let stored: BandwidthStoredReadings
        do {
            guard let advertised = try await server.target() else {
                if self.session == session {
                    Self.logger.notice("connection read skipped: no speed test on this server")
                }
                return false
            }
            target = advertised
            stored = try await server.storedReadings()
        } catch {
            Self.logger.notice("connection read failed: \(String(describing: type(of: error)), privacy: .public)")
            return false
        }
        guard self.session == session, target.serverId == session.serverId,
              connection == currentConnection, !Task.isCancelled else { return false }
        lastTarget = target
        adopt(stored, key: ReadingsKey(serverId: session.serverId, connection: connection))
        Self.logger.notice("connection read: \(self.currentReadings.count, privacy: .public) current reading(s)")
        return true
    }

    /// After a check's read: tests if automatic tests are on and nothing
    /// current proves the link, reading once more just before.
    private func look() async {
        guard let session, isActive else { return }
        guard !isLooking, inFlight == nil else {
            // One from before a session or connection change; this change's
            // look runs once it finishes rather than being lost.
            looksAgain = true
            return
        }
        isLooking = true
        defer {
            isLooking = false
            lookAgainIfAsked()
        }
        guard await checkRead?.value == true, self.session == session else { return }
        guard testIsDue(for: session) else { return }
        // The stored readings may have changed since the check.
        guard await read(for: session), self.session == session, testIsDue(for: session) else { return }
        _ = await probeOnce(testSpeed: false)
    }

    private func testIsDue(for session: BandwidthProbeSession) -> Bool {
        // Checked after every read too: the app can hide while one waits.
        guard isActive, let target = lastTarget, target.automatic, !linkIsProven else { return false }
        if let until = rateLimits[session.serverId], clock.now < until { return false }
        return gate(automatic: true) == nil
    }

    /// Why a test may not run now, or nil when it may. The quiet period after
    /// a playback start holds only automatic tests.
    private func gate(automatic: Bool) -> Outcome? {
        if session == nil { return .notSupported }
        if !network.isConnected { return .offline }
        if network.isMetered { return .metered }
        if !videoPlayers.allObjects.isEmpty || isMediaActive() { return .playbackActive }
        if automatic, let lastPlaybackStart,
           clock.now.timeIntervalSince(lastPlaybackStart) < Self.playbackQuietPeriod {
            return .playbackActive
        }
        return nil
    }

    // MARK: - Test

    private func lookAgainIfAsked() {
        guard looksAgain, !isLooking, inFlight == nil else { return }
        looksAgain = false
        Task { await look() }
    }

    /// Runs **Test speed**'s accurate test (`testSpeed`) or an automatic quick
    /// one, or joins the test already running. **Test speed** replaces a
    /// running automatic test, so it always measures accurately.
    private func probeOnce(testSpeed: Bool) async -> Outcome {
        while let running = inFlight, let task = running.task {
            guard testSpeed, !running.isTestSpeed else { return await task.value }
            cancelInFlight(.interrupted)
            // The app hiding, the network changing or playback starting while
            // this waits stops it too.
            let waitedFrom = interruption.count
            _ = await task.value
            if interruption.count != waitedFrom { return interruption.reason }
        }
        let run = Run(isTestSpeed: testSpeed)
        inFlight = run
        isProbing = true
        let task = Task { [weak self] () -> Outcome in
            guard let self else { return .interrupted }
            let outcome = await self.measureAndReport(run)
            if self.inFlight === run {
                self.inFlight = nil
                self.isProbing = false
            }
            self.lookAgainIfAsked()
            return outcome
        }
        run.task = task
        return await task.value
    }

    private func measureAndReport(_ run: Run) async -> Outcome {
        let target: BandwidthProbeTarget
        do {
            guard let found = try await server.target() else { return run.cancelledFor ?? .notSupported }
            target = found
        } catch {
            return run.cancelledFor ?? .networkError
        }
        if let reason = run.cancelledFor { return reason }
        if let refused = gate(automatic: !run.isTestSpeed) { return refused }
        guard target.serverId == session?.serverId else { return .interrupted }
        lastTarget = target
        // A quick test proves the target the server sends now.
        let mode: BandwidthProbeMeter.Mode = run.isTestSpeed ? .accurate : .quick(targetKbps: target.targetKbps)
        let measuredOn = network
        let measuredOver = currentConnection
        let measuredFor = session
        let result: BandwidthProbeResult
        do {
            result = try await server.measure(target, mode: mode)
        } catch {
            return run.cancelledFor ?? (error is CancellationError ? .interrupted : .networkError)
        }
        if let reason = run.cancelledFor { return reason }
        let rate: BandwidthProbeMeter.Measurement
        switch result {
        case .measured(let measured): rate = measured
        case .rateLimited(let seconds):
            Self.logger.notice("speed test rate limited: retry after \(seconds, privacy: .public) s")
            // Any test's 429 holds automatic tests against that server.
            rateLimits[target.serverId] = clock.now.addingTimeInterval(TimeInterval(seconds))
            return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let status):
            Self.logger.notice("speed test refused: HTTP \(status, privacy: .public)")
            return .unavailable
        case .tooLittleData:
            Self.logger.notice("speed test measured nothing")
            return .tooLittleData
        case .networkError(let reason):
            Self.logger.notice("speed test failed: \(reason, privacy: .public)")
            return .networkError
        }
        // A result outside the contract's range is never kept or sent.
        guard (BandwidthProbe.minKbps...BandwidthProbe.maxKbps).contains(rate.kbps) else {
            Self.logger.notice("speed test out of range: \(rate.kbps, privacy: .public) kbps")
            return .tooLittleData
        }
        // A change mid-test cancels it; this catches one that raced its end.
        guard network.key == measuredOn.key, session == measuredFor,
              currentConnection == measuredOver else { return .interrupted }
        let measurement = BandwidthMeasurement(
            kbps: rate.kbps,
            lowerBound: rate.lowerBound,
            bytes: rate.bytes,
            durationMs: rate.durationMs,
            transport: measuredOn.transport,
            measuredAt: clock.now,
            manual: run.isTestSpeed
        )
        // A playback start must not cut the report short: the result is
        // already measured.
        let server = server
        let report = await Task { await server.report(measurement, to: target) }.value
        Self.logger.notice(
            "speed test: \(measurement.kbps, privacy: .public) kbps\(measurement.lowerBound ? " or faster" : "", privacy: .public) over \(measurement.durationMs, privacy: .public) ms on \(measurement.transport, privacy: .public), \(String(describing: report), privacy: .public)"
        )
        // A result the server refused is not kept; one it never heard about
        // still describes this connection, while it and the session it was
        // measured for are still the ones in use.
        if report != .refused, session == measuredFor, currentConnection == measuredOver {
            let key = ReadingsKey(serverId: target.serverId, connection: measuredOver)
            // The server clears its playback sample when it stores a Test
            // speed result, so an older, higher sample cannot outvote it.
            if readingsKey != key || (run.isTestSpeed && report == .stored) { playbackSample = nil }
            readingsKey = key
            probeReading = measurement.reading
        }
        return report == .stored ? .measured(measurement) : .notSaved(measurement)
    }
}
