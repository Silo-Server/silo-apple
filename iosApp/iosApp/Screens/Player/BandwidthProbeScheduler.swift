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
        let interfaces = path.availableInterfaces.map(\.name).joined(separator: ",")
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

/// Follows the network for ``BandwidthProbeScheduler`` on every platform.
/// (``PlaybackNetworkMonitor`` runs only where a cellular quality applies.)
final class BandwidthProbeNetworkMonitor: @unchecked Sendable {
    static let shared = BandwidthProbeNetworkMonitor()

    private let lock = NSLock()
    private var monitor: NWPathMonitor?

    /// Begin following the network, handing each change to `scheduler`.
    /// Safe to call more than once.
    func start(scheduler: BandwidthProbeScheduler) {
        lock.withLock {
            guard monitor == nil else { return }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                let network = BandwidthProbeNetwork(path)
                Task { @MainActor in scheduler.networkChanged(network) }
            }
            monitor.start(queue: DispatchQueue(label: "org.siloserver.silo.bandwidth-probe-path"))
            self.monitor = monitor
        }
    }
}

/// One probe measurement, as Settings shows it and the server stores it.
struct BandwidthMeasurement: Equatable, Sendable {
    let kbps: Int
    let bytes: Int
    let durationMs: Int
    /// `wifi`, `ethernet`, `cellular` or `other`, as reported to the server.
    let transport: String
    let measuredAt: Date
}

/// The probe endpoint of the active server, for one probe and its report.
struct BandwidthProbeTarget: Sendable {
    /// The download URL, `size` included.
    let url: URL
    let auth: CapturedOrdinaryRequestAuth

    var serverId: String { auth.account.serverId }
}

/// The server side of a probe: discovery, the download and the report.
protocol BandwidthProbeServer: Sendable {
    /// The active profile's probe endpoint, read from a fresh capability
    /// response; nil when the server advertises none.
    func target() async throws -> BandwidthProbeTarget?
    func measure(_ target: BandwidthProbeTarget) async throws -> BandwidthProbeResult
    /// POSTs `measurement`; true once the server stored it.
    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> Bool
}

/// ``BandwidthProbeServer`` over `/api/v2`. The probe runs only for a server
/// whose capability `features` carry `connection_speed_v1` and that names a
/// `bandwidth_probe_url`.
struct LiveBandwidthProbeServer: BandwidthProbeServer {
    func target() async throws -> BandwidthProbeTarget? {
        // The report is profile-scoped, so a probe needs a chosen profile.
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              let profileId = auth.profileId, !profileId.isEmpty else { return nil }
        let capabilities: APIv2PlaybackCapabilities
        do {
            // Read afresh: the URL is on the origin the request arrived on,
            // which a local route can change.
            capabilities = try await SiloAPI.shared.apiV2Client.playbackCapabilities(auth: auth)
        } catch APIv2Error.serverUpdateRequired {
            return nil
        }
        guard capabilities.features.contains(PlaybackProtocolV3.connectionSpeedFeature),
              let advertised = capabilities.bandwidthProbeUrl, !advertised.isEmpty,
              let serverURL = URL(string: auth.account.serverURL),
              let url = BandwidthProbe.downloadURL(serverURL: serverURL, advertised: advertised) else {
            return nil
        }
        return BandwidthProbeTarget(url: url, auth: auth)
    }

    func measure(_ target: BandwidthProbeTarget) async throws -> BandwidthProbeResult {
        var request = URLRequest(url: target.url)
        request.httpMethod = "GET"
        AppleDeviceIdentity.current.applyHeaders(to: &request)
        // The account's own credentials, refreshed when they have expired.
        request.allHTTPHeaderFields = try await SiloAPI.shared.http.mediaRequestHeaders(
            expectedAuth: target.auth,
            baseHeaders: request.allHTTPHeaderFields ?? [:]
        )
        return try await BandwidthProbeDownload().measure(request)
    }

    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> Bool {
        do {
            try await SiloAPI.shared.apiV2Client.reportPlaybackBandwidthProbe(
                APIv2PlaybackBandwidthProbeResult(
                    kbps: measurement.kbps,
                    bytes: measurement.bytes,
                    durationMs: measurement.durationMs,
                    transport: measurement.transport
                ),
                auth: target.auth
            )
            return true
        } catch {
            return false
        }
    }
}

/// Keeps a fresh probe measurement while Silo is in the foreground and signed
/// in, for playback starts (``freshEstimateKbps()``) and Settings
/// (``lastMeasurement``, ``runNow()``). One per app. The spec is the server
/// repo's `docs/design/2026-10-17-buffering-quality.md`, "Probe on Android and
/// Apple"; the rules match Android's `BandwidthProbeScheduler`.
///
/// - **When**: ``startDelay`` after Silo returns to the foreground, a server
///   is signed in, or the network changes; again when the cached result
///   expires; and every ``retryInterval`` while a probe could not run or did
///   not finish. Leaving the foreground stops the schedule and any running
///   probe.
/// - **Not**: while media plays or starts (a video player between
///   ``playbackStarting(by:)`` and ``playbackEnded(by:)``, ``isMediaActive``,
///   then ``playbackQuietPeriod``), on a metered or
///   cellular network, or for a server without `connection_speed_v1`. Media
///   starting cancels a running probe.
/// - **Cache**: ``BandwidthProbe/estimateLifetime``, for the server and network
///   it was measured on. A network or server change discards it.
/// - **Reporting**: every measurement is POSTed with the transport it was
///   taken on.
@MainActor
@Observable
final class BandwidthProbeScheduler {
    static let shared = BandwidthProbeScheduler(server: LiveBandwidthProbeServer())

    /// Lets the first screen settle before spending bandwidth on a probe.
    nonisolated static let startDelay: TimeInterval = 5
    /// How soon to look again when a probe could not run or did not finish.
    nonisolated static let retryInterval: TimeInterval = 5 * 60
    /// How long after a playback start a probe holds off: media is still
    /// loading for a while after the start itself.
    nonisolated static let playbackQuietPeriod: TimeInterval = 60

    /// What a probe request came to.
    enum Outcome: Equatable {
        case measured(BandwidthMeasurement)
        /// HTTP 429: try again after `retryAfterSeconds`.
        case rateLimited(retryAfterSeconds: Int)
        /// The server refused the download: no media path serves probes.
        case unavailable
        /// Too little data arrived to give a rate.
        case tooLittleData
        /// The request or the capability read failed, or the first byte never
        /// came.
        case networkError
        /// A metered or cellular network: speed tests are skipped.
        case metered
        case offline
        /// Media is playing or starting; a probe would slow it and
        /// under-measure.
        case playbackActive
        /// Signed out, or the server does not advertise `connection_speed_v1`
        /// with a probe URL.
        case notSupported
        /// The network or server changed, or Silo left the foreground, before
        /// the probe finished.
        case interrupted
    }

    /// The last measurement on the active server and network, kept past its
    /// playback lifetime so Settings can show it. Nil once the network or
    /// server changes.
    private(set) var lastMeasurement: BandwidthMeasurement?
    /// The network in use.
    private(set) var network: BandwidthProbeNetwork = .offline
    private(set) var isProbing = false

    /// Whether other media plays, such as audio. The app sets it; video
    /// players register themselves (``playbackStarting(by:)``).
    @ObservationIgnored var isMediaActive: @MainActor () -> Bool = { false }

    private struct Cached {
        let serverId: String
        let networkKey: String
        let measurement: BandwidthMeasurement
    }

    /// One probe, and the outcome it ends with when something cancels it.
    private final class Run {
        var task: Task<Outcome, Never>?
        var cancelledFor: Outcome?
    }

    @ObservationIgnored private let server: BandwidthProbeServer
    @ObservationIgnored private let clock: PlayerPromptClock
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var activeServerId: String?
    @ObservationIgnored private var cached: Cached?
    @ObservationIgnored private var lastPlaybackStart: Date?
    @ObservationIgnored private var timer: PlayerPromptTimer?
    @ObservationIgnored private var inFlight: Run?
    /// Video players between their playback start and their end. Weak, so a
    /// player that goes away without saying so cannot hold the probe off.
    @ObservationIgnored private let videoPlayers = NSHashTable<AnyObject>.weakObjects()

    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "BandwidthProbe")

    init(server: BandwidthProbeServer, clock: PlayerPromptClock? = nil) {
        self.server = server
        self.clock = clock ?? LivePlayerPromptClock()
    }

    // MARK: - Playback

    /// The probe's kbps for the active server on the network in use now, or
    /// nil when none is fresh, none was taken, or the network is metered.
    func freshEstimateKbps() -> Int? {
        guard let cached, isFresh(cached) else { return nil }
        return cached.measurement.kbps
    }

    /// Playback is starting: stops a running probe and holds off new ones
    /// while the media loads. The cached estimate stays. A video `player`
    /// keeps the probe off until ``playbackEnded(by:)``, whichever way it is
    /// presented, including picture in picture.
    func playbackStarting(by player: AnyObject? = nil) {
        if let player { videoPlayers.add(player) }
        lastPlaybackStart = clock.now
        cancelInFlight(.playbackActive)
    }

    /// The video `player` stopped for good.
    func playbackEnded(by player: AnyObject) {
        videoPlayers.remove(player)
    }

    // MARK: - Settings

    /// **Test speed**: probes now and reports the result. Refuses as the
    /// schedule does, except that a fresh result does not stand in for a new
    /// one; joins a probe that is already running.
    func runNow() async -> Outcome {
        if let refused = gate() { return refused }
        return await probeOnce()
    }

    // MARK: - App inputs

    func setForeground(_ foreground: Bool) {
        guard foreground != isForeground else { return }
        isForeground = foreground
        if foreground {
            if activeServerId != nil { schedule(after: Self.startDelay) }
        } else {
            timer?.cancel()
            timer = nil
            cancelInFlight(.interrupted)
        }
    }

    /// The server signed in with a profile, or nil when none is.
    func setActiveServer(_ serverId: String?) {
        guard serverId != activeServerId else { return }
        activeServerId = serverId
        if cached?.serverId != serverId { forget() }
        cancelInFlight(.interrupted)
        if serverId != nil {
            schedule(after: Self.startDelay)
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    func networkChanged(_ next: BandwidthProbeNetwork) {
        let changed = next.key != network.key
        network = next
        guard changed else { return }
        forget()
        cancelInFlight(.interrupted)
        if activeServerId != nil { schedule(after: Self.startDelay) }
    }

    // MARK: - Schedule

    private func forget() {
        cached = nil
        lastMeasurement = nil
    }

    private func cancelInFlight(_ reason: Outcome) {
        guard let run = inFlight, run.cancelledFor == nil else { return }
        run.cancelledFor = reason
        run.task?.cancel()
    }

    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        timer = nil
        guard isForeground else { return }
        timer = clock.schedule(after: max(delay, 0)) { [weak self] in
            guard let self else { return }
            self.timer = nil
            Task { await self.runScheduled() }
        }
    }

    private func runScheduled() async {
        guard activeServerId != nil, !awaitExpiry() else { return }
        if let refused = gate() {
            if refused != .notSupported { schedule(after: Self.retryInterval) }
            return
        }
        _ = await probeOnce()
    }

    /// Schedules the next probe for when a fresh cached result expires; false
    /// when none is fresh.
    private func awaitExpiry() -> Bool {
        guard let cached, isFresh(cached) else { return false }
        let expiry = cached.measurement.measuredAt.addingTimeInterval(BandwidthProbe.estimateLifetime)
        schedule(after: expiry.timeIntervalSince(clock.now) + 1)
        return true
    }

    /// Why a probe may not run now, or nil when it may.
    private func gate() -> Outcome? {
        if activeServerId == nil { return .notSupported }
        if !network.isConnected { return .offline }
        if network.isMetered { return .metered }
        if !videoPlayers.allObjects.isEmpty || isMediaActive() { return .playbackActive }
        if let lastPlaybackStart, clock.now.timeIntervalSince(lastPlaybackStart) < Self.playbackQuietPeriod {
            return .playbackActive
        }
        return nil
    }

    private func isFresh(_ entry: Cached) -> Bool {
        guard network.isConnected, !network.isMetered,
              network.key == entry.networkKey, activeServerId == entry.serverId else { return false }
        let age = clock.now.timeIntervalSince(entry.measurement.measuredAt)
        return age >= 0 && age <= BandwidthProbe.estimateLifetime
    }

    private func probeOnce() async -> Outcome {
        if let inFlight, let task = inFlight.task { return await task.value }
        let run = Run()
        inFlight = run
        isProbing = true
        let task = Task { [weak self] () -> Outcome in
            guard let self else { return .interrupted }
            let outcome = await self.measureAndReport(run)
            if self.inFlight === run {
                self.inFlight = nil
                self.isProbing = false
            }
            self.followUp(outcome, run: run)
            return outcome
        }
        run.task = task
        return await task.value
    }

    private func followUp(_ outcome: Outcome, run: Run) {
        // A cancelled probe was replaced by whatever cancelled it, except
        // playback, which leaves the link busy for a while.
        if let reason = run.cancelledFor {
            if reason == .playbackActive { schedule(after: Self.retryInterval) }
            return
        }
        if awaitExpiry() { return }
        switch outcome {
        case .notSupported:
            // Nothing to measure until the next foreground, sign-in or
            // network change.
            break
        case .rateLimited(let seconds):
            schedule(after: max(Self.retryInterval, TimeInterval(seconds)))
        default:
            schedule(after: Self.retryInterval)
        }
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
        if let refused = gate() { return refused }
        guard target.serverId == activeServerId else { return .interrupted }
        let measuredOn = network
        let result: BandwidthProbeResult
        do {
            result = try await server.measure(target)
        } catch {
            return run.cancelledFor ?? (error is CancellationError ? .interrupted : .networkError)
        }
        if let reason = run.cancelledFor { return reason }
        let rate: (kbps: Int, bytes: Int, durationMs: Int)
        switch result {
        case .measured(let kbps, let bytes, let durationMs): rate = (kbps, bytes, durationMs)
        case .rateLimited(let seconds): return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable: return .unavailable
        case .tooLittleData: return .tooLittleData
        case .networkError(let reason):
            Self.logger.info("bandwidth probe failed: \(reason, privacy: .public)")
            return .networkError
        }
        // A change mid-probe cancels it; this catches one that raced its end.
        guard network.key == measuredOn.key, activeServerId == target.serverId else { return .interrupted }
        let measurement = BandwidthMeasurement(
            kbps: rate.kbps,
            bytes: rate.bytes,
            durationMs: rate.durationMs,
            transport: measuredOn.transport,
            measuredAt: clock.now
        )
        cached = Cached(serverId: target.serverId, networkKey: measuredOn.key, measurement: measurement)
        lastMeasurement = measurement
        let reported = await server.report(measurement, to: target)
        Self.logger.info(
            "bandwidth probe: \(measurement.kbps, privacy: .public) kbps over \(measurement.durationMs, privacy: .public) ms on \(measurement.transport, privacy: .public)\(reported ? "" : " (report failed)", privacy: .public)"
        )
        return .measured(measurement)
    }
}
