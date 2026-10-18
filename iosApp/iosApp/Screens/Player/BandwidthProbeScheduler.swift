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

/// A connection speed reading for the network in use: this device's own
/// probe, or the one the server keeps for this device on this connection.
/// Playback starts send it as their estimate, and Settings shows it.
struct BandwidthReading: Equatable, Sendable {
    let kbps: Int
    /// `wifi`, `ethernet`, `cellular` or `other`.
    let transport: String
    let measuredAt: Date
}

/// One probe measurement, as this device reports it to the server.
struct BandwidthMeasurement: Equatable, Sendable {
    let kbps: Int
    let bytes: Int
    let durationMs: Int
    /// `wifi`, `ethernet`, `cellular` or `other`, as reported to the server.
    let transport: String
    let measuredAt: Date

    var reading: BandwidthReading { BandwidthReading(kbps: kbps, transport: transport, measuredAt: measuredAt) }
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
    /// The reading the server keeps for this device on the connection in use
    /// now, from `GET /api/v2/playback/connection`; nil when it has none.
    func storedReading() async throws -> BandwidthReading?
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
    func storedReading() async throws -> BandwidthReading? {
        guard let auth = await TokenStore.shared.captureOrdinaryRequestAuth(),
              let profileId = auth.profileId, !profileId.isEmpty else { return nil }
        let probe = try await SiloAPI.shared.apiV2Client.playbackConnection(auth: auth).probe
        return probe.map { BandwidthReading(kbps: $0.kbps, transport: $0.transport, measuredAt: $0.measuredAt) }
    }

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


/// Keeps a connection speed reading for the active server and network, for
/// playback starts (``freshEstimateKbps()``) and Settings (``reading``,
/// ``runNow()``). One per app. The spec is the server repo's
/// `docs/design/2026-10-17-buffering-quality.md`, "Probe on Android and
/// Apple".
///
/// Tests are rare: a reading stands for ``readingLifetime`` (7 days) on the
/// server and network it was taken on, and the server keeps the latest one
/// for this device and connection.
/// - **Check**: ``startDelay`` after a server is signed in, Silo returns to the
///   foreground, or the network changes. A fresh reading in memory ends it.
///   Otherwise it asks the server for its stored reading and adopts a fresh
///   one. Only then does it test.
/// - **Retry**: only while there is no reading. After `Retry-After` on a 429,
///   ``retryInterval`` after playback held the test off, and on a doubling
///   backoff after a failure. A refusal, a metered network or no network waits
///   for the next check.
/// - **Not**: while media plays or starts (a video player between
///   ``playbackStarting(by:)`` and ``playbackEnded(by:)``, ``isMediaActive``,
///   then ``playbackQuietPeriod``), on a metered or cellular network, or for a
///   server without `connection_speed_v1`. Media starting cancels a running
///   test.
/// - **Test speed** (``runNow()``) tests whatever the reading's age.
/// - **Reporting**: every measurement is POSTed with the transport it was
///   taken on.
@MainActor
@Observable
final class BandwidthProbeScheduler {
    static let shared = BandwidthProbeScheduler(server: LiveBandwidthProbeServer())

    /// Lets the first screen settle before checking.
    nonisolated static let startDelay: TimeInterval = 5
    /// How soon to look again when playback held a test off, and the first
    /// step of the failure backoff.
    nonisolated static let retryInterval: TimeInterval = 5 * 60
    /// The longest wait between attempts after repeated failures.
    nonisolated static let maxRetryInterval: TimeInterval = 6 * 60 * 60
    /// How long after a playback start a test holds off: media is still
    /// loading for a while after the start itself.
    nonisolated static let playbackQuietPeriod: TimeInterval = 60
    /// How long a reading stands for its server and network.
    nonisolated static let defaultReadingLifetime: TimeInterval = 7 * 24 * 60 * 60

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

    /// The reading for the active server and network, from this device's own
    /// test or the server's store, kept past its lifetime so Settings can
    /// show it. Nil once the network or server changes.
    private(set) var reading: BandwidthReading?
    /// The network in use.
    private(set) var network: BandwidthProbeNetwork = .offline
    private(set) var isProbing = false
    /// How long a reading stands before a check tests again.
    @ObservationIgnored var readingLifetime: TimeInterval = BandwidthProbeScheduler.defaultReadingLifetime

    /// Whether other media plays, such as audio. The app sets it; video
    /// players register themselves (``playbackStarting(by:)``).
    @ObservationIgnored var isMediaActive: @MainActor () -> Bool = { false }

    private struct Cached {
        let serverId: String
        let networkKey: String
        let reading: BandwidthReading
    }

    /// One test, and the outcome it ends with when something cancels it.
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
    @ObservationIgnored private var isChecking = false
    /// Failed attempts in a row on this server and network, for the backoff.
    @ObservationIgnored private var consecutiveFailures = 0
    /// Video players between their playback start and their end. Weak, so a
    /// player that goes away without saying so cannot hold tests off.
    @ObservationIgnored private let videoPlayers = NSHashTable<AnyObject>.weakObjects()

    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "BandwidthProbe")

    init(server: BandwidthProbeServer, clock: PlayerPromptClock? = nil) {
        self.server = server
        self.clock = clock ?? LivePlayerPromptClock()
    }

    // MARK: - Playback

    /// The reading's kbps for the active server on the network in use now, or
    /// nil when there is none within its lifetime or the network is metered.
    func freshEstimateKbps() -> Int? {
        guard let cached, isFresh(cached) else { return nil }
        return cached.reading.kbps
    }

    /// Playback is starting: stops a running test and holds off new ones
    /// while the media loads. The reading stays. A video `player` keeps tests
    /// off until ``playbackEnded(by:)``, whichever way it is presented,
    /// including picture in picture.
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

    /// **Test speed**: tests now and reports the result, whatever the
    /// reading's age. Refuses as the automatic test does; joins a test that is
    /// already running.
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

    /// Another network has its own reading, kept by the server: the check
    /// asks for it before anything is tested.
    func networkChanged(_ next: BandwidthProbeNetwork) {
        let changed = next.key != network.key
        network = next
        guard changed else { return }
        forget()
        cancelInFlight(.interrupted)
        if activeServerId != nil { schedule(after: Self.startDelay) }
    }

    // MARK: - Check

    private func forget() {
        cached = nil
        reading = nil
        consecutiveFailures = 0
    }

    private func adopt(_ reading: BandwidthReading, serverId: String, networkKey: String) {
        cached = Cached(serverId: serverId, networkKey: networkKey, reading: reading)
        self.reading = reading
        consecutiveFailures = 0
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
            Task { await self.check() }
        }
    }

    /// Ensures a reading: the one in memory, the server's, or a test.
    private func check() async {
        guard let serverId = activeServerId, !isChecking, inFlight == nil else { return }
        if let cached, isFresh(cached) { return }
        isChecking = true
        defer { isChecking = false }
        let networkKey = network.key
        if let stored = try? await server.storedReading(),
           activeServerId == serverId, network.key == networkKey,
           age(of: stored) <= readingLifetime {
            adopt(stored, serverId: serverId, networkKey: networkKey)
            return
        }
        guard activeServerId == serverId, network.key == networkKey else { return }
        if let refused = gate() {
            if refused == .playbackActive { schedule(after: Self.retryInterval) }
            return
        }
        _ = await probeOnce()
    }

    /// Why a test may not run now, or nil when it may.
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

    private func age(of reading: BandwidthReading) -> TimeInterval {
        clock.now.timeIntervalSince(reading.measuredAt)
    }

    private func isFresh(_ entry: Cached) -> Bool {
        guard network.isConnected, !network.isMetered,
              network.key == entry.networkKey, activeServerId == entry.serverId else { return false }
        return age(of: entry.reading) <= readingLifetime
    }

    // MARK: - Test

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

    /// Schedules the next attempt while there is still no reading.
    private func followUp(_ outcome: Outcome, run: Run) {
        // A cancelled test was replaced by whatever cancelled it, except
        // playback, which leaves the link busy for a while.
        if let reason = run.cancelledFor {
            if reason == .playbackActive, reading == nil { schedule(after: Self.retryInterval) }
            return
        }
        switch outcome {
        case .measured, .notSupported, .unavailable, .metered, .offline, .interrupted:
            // Nothing to retry until the next check.
            break
        case .rateLimited(let seconds):
            schedule(after: max(Self.retryInterval, TimeInterval(seconds)))
        case .playbackActive:
            schedule(after: Self.retryInterval)
        case .tooLittleData, .networkError:
            let backoff = Self.retryInterval * pow(2, Double(consecutiveFailures))
            consecutiveFailures += 1
            schedule(after: min(backoff, Self.maxRetryInterval))
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
        // A change mid-test cancels it; this catches one that raced its end.
        guard network.key == measuredOn.key, activeServerId == target.serverId else { return .interrupted }
        let measurement = BandwidthMeasurement(
            kbps: rate.kbps,
            bytes: rate.bytes,
            durationMs: rate.durationMs,
            transport: measuredOn.transport,
            measuredAt: clock.now
        )
        adopt(measurement.reading, serverId: target.serverId, networkKey: measuredOn.key)
        let reported = await server.report(measurement, to: target)
        Self.logger.info(
            "bandwidth probe: \(measurement.kbps, privacy: .public) kbps over \(measurement.durationMs, privacy: .public) ms on \(measurement.transport, privacy: .public)\(reported ? "" : " (report failed)", privacy: .public)"
        )
        return .measured(measurement)
    }
}
