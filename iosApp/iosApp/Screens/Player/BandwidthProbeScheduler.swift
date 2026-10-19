import Foundation
import Network
import os
#if os(macOS)
import AppKit
#endif

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
    /// POSTs `measurement`; true once the server stored it.
    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> Bool
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
        guard let serverURL = URL(string: target.auth.account.serverURL),
              let url = BandwidthProbe.downloadURL(
                  serverURL: serverURL, advertised: target.url.absoluteString, bytes: download.requestedBytes
              ) else {
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

    func report(_ measurement: BandwidthMeasurement, to target: BandwidthProbeTarget) async -> Bool {
        do {
            try await SiloAPI.shared.apiV2Client.reportPlaybackBandwidthProbe(
                APIv2PlaybackBandwidthProbeResult(
                    kbps: measurement.kbps,
                    bytes: measurement.bytes,
                    durationMs: measurement.durationMs,
                    transport: measurement.transport,
                    lowerBound: measurement.lowerBound
                ),
                auth: target.auth
            )
            return true
        } catch {
            return false
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

/// Keeps the connection speed readings for the active server and network, for
/// playback starts (``freshEstimateKbps()``) and Settings (``probeReading``,
/// ``runNow()``). One per app. The spec is the server repo's
/// `docs/design/2026-10-17-buffering-quality.md`, "Connection speed test" >
/// "When to test".
///
/// - **Check**: when a server is signed in, Silo returns to the foreground, or
///   the network changes. A check reads the server's stored readings at once,
///   so a playback start in the first seconds sends one. Only the test waits:
///   ``startDelay`` later a look reads them again, then runs a quick test only
///   when automatic tests are on and no current reading proves the link. There
///   is no periodic test.
/// - **Current**: a reading younger than the server's
///   `bandwidth_probe_max_age_seconds`. A settled rate proves the link; a
///   lower bound proves it only while it reaches the current target.
/// - **Not**: while media plays or starts (a video player between
///   ``playbackStarting(by:)`` and ``playbackEnded(by:)``, ``isMediaActive``,
///   then ``playbackQuietPeriod`` for automatic tests), on a metered or
///   cellular network, or with Silo in the background, hidden or minimized. A
///   test running when one of these begins is cancelled and measured nothing.
/// - **Failures** wait for the next look, and after a 429 no earlier than its
///   `Retry-After`.
/// - **Test speed** (``runNow()``) runs the accurate test whenever no media
///   plays, even with automatic tests off or a current reading.
/// - **Reporting**: every measurement is POSTed with the transport it was
///   taken on.
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

    /// The latest speed test on the active server and network: this device's
    /// own, or the server's when that is newer. Kept past its lifetime so
    /// Settings can show it; nil once the network or server changes.
    private(set) var probeReading: BandwidthReading?
    /// The server's playback sample for this network.
    private(set) var playbackSample: BandwidthReading?
    /// The network in use.
    private(set) var network: BandwidthProbeNetwork = .offline
    private(set) var isProbing = false

    /// Whether other media plays, such as audio. The app sets it; video
    /// players register themselves (``playbackStarting(by:)``).
    @ObservationIgnored var isMediaActive: @MainActor () -> Bool = { false }

    /// One test, and the outcome it ends with when something cancels it.
    private final class Run {
        var task: Task<Outcome, Never>?
        var cancelledFor: Outcome?
    }

    @ObservationIgnored private let server: BandwidthProbeServer
    @ObservationIgnored private let clock: PlayerPromptClock
    @ObservationIgnored private var isForeground = true
    @ObservationIgnored private var isHidden = false
    @ObservationIgnored private var activeServerId: String?
    /// The server and network the readings belong to.
    @ObservationIgnored private var readingsKey: (serverId: String, networkKey: String)?
    /// The last speed test settings the server sent.
    @ObservationIgnored private var lastTarget: BandwidthProbeTarget?
    @ObservationIgnored private var lastPlaybackStart: Date?
    /// A 429's `Retry-After`: no automatic test before it.
    @ObservationIgnored private var notBefore: Date?
    @ObservationIgnored private var timer: PlayerPromptTimer?
    @ObservationIgnored private var inFlight: Run?
    @ObservationIgnored private var isLooking = false
    /// Video players between their playback start and their end. Weak, so a
    /// player that goes away without saying so cannot hold tests off.
    @ObservationIgnored private let videoPlayers = NSHashTable<AnyObject>.weakObjects()

    private static let logger = Logger(subsystem: "org.siloserver.silo", category: "BandwidthProbe")

    init(server: BandwidthProbeServer, clock: PlayerPromptClock? = nil) {
        self.server = server
        self.clock = clock ?? LivePlayerPromptClock()
    }

    // MARK: - Playback

    /// The highest current reading's kbps for the active server on the network
    /// in use now, which a playback start sends as its estimate. Nil when
    /// there is none, or on a metered network.
    func freshEstimateKbps() -> Int? {
        guard network.isConnected, !network.isMetered, readingsBelongHere else { return nil }
        return currentReadings.map(\.kbps).max()
    }

    /// Playback is starting: stops a running test and holds off new ones
    /// while the media loads. The readings stay. A video `player` keeps tests
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

    /// **Test speed**: runs the accurate test and reports it. Refuses while
    /// media plays or on a metered network; joins a test already running.
    func runNow() async -> Outcome {
        if let refused = gate(automatic: false) { return refused }
        return await probeOnce(mode: .accurate)
    }

    // MARK: - App inputs

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
        activityChanged()
    }

    /// The server signed in with a profile, or nil when none is.
    func setActiveServer(_ serverId: String?) {
        guard serverId != activeServerId else { return }
        Self.logger.info("server \(serverId == nil ? "signed out" : "signed in", privacy: .public)")
        activeServerId = serverId
        forget()
        cancelInFlight(.interrupted)
        if serverId != nil {
            check()
        } else {
            timer?.cancel()
            timer = nil
        }
    }

    /// Another network has its own readings on the server: a check reads them
    /// before anything is tested.
    func networkChanged(_ next: BandwidthProbeNetwork) {
        let changed = next.key != network.key
        network = next
        guard changed else { return }
        Self.logger.info("network changed: \(next.isConnected ? next.transport : "offline", privacy: .public)")
        forget()
        cancelInFlight(.interrupted)
        check()
    }

    // MARK: - Look

    private var isActive: Bool { isForeground && !isHidden }

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
        notBefore = nil
    }

    private var readingsBelongHere: Bool {
        readingsKey.map { $0.serverId == activeServerId && $0.networkKey == network.key } ?? false
    }

    private var maxAge: TimeInterval {
        lastTarget?.maxAge ?? LiveBandwidthProbeServer.fallbackMaxAge
    }

    private var currentReadings: [BandwidthReading] {
        [probeReading, playbackSample].compactMap { $0 }.filter {
            let age = clock.now.timeIntervalSince($0.measuredAt)
            return age >= 0 && age < maxAge
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
    private func adopt(_ stored: BandwidthStoredReadings, serverId: String, networkKey: String) {
        if !readingsBelongHere { probeReading = nil }
        readingsKey = (serverId, networkKey)
        if let probe = stored.probe, probe.measuredAt >= (probeReading?.measuredAt ?? .distantPast) {
            probeReading = probe
        }
        playbackSample = stored.playbackSample
    }

    private func cancelInFlight(_ reason: Outcome) {
        guard let run = inFlight, run.cancelledFor == nil else { return }
        run.cancelledFor = reason
        run.task?.cancel()
    }

    private func schedule(after delay: TimeInterval) {
        timer?.cancel()
        timer = nil
        guard isActive else { return }
        timer = clock.schedule(after: max(delay, 0)) { [weak self] in
            guard let self else { return }
            self.timer = nil
            Task { await self.look() }
        }
    }

    /// Reads the server's readings now, so a start in the first seconds sends
    /// one, and looks once the first screen has settled.
    private func check() {
        guard let serverId = activeServerId, isActive else {
            Self.logger.info("check skipped: \(self.activeServerId == nil ? "no server" : "not visible", privacy: .public)")
            return
        }
        Task { await readStored(serverId: serverId) }
        schedule(after: Self.startDelay)
    }

    private func readStored(serverId: String) async {
        guard activeServerId == serverId, isActive, network.isConnected else {
            Self.logger.info("connection read skipped: \(self.network.isConnected ? "server or visibility changed" : "offline", privacy: .public)")
            return
        }
        let networkKey = network.key
        let stored: BandwidthStoredReadings
        do {
            stored = try await server.storedReadings()
        } catch {
            Self.logger.info("connection read failed: \(String(describing: type(of: error)), privacy: .public)")
            return
        }
        guard activeServerId == serverId, network.key == networkKey else { return }
        adopt(stored, serverId: serverId, networkKey: networkKey)
        Self.logger.info("connection read: \(self.currentReadings.count, privacy: .public) current reading(s)")
    }

    /// Reads the server's readings and settings, then tests if nothing
    /// current proves the link.
    private func look() async {
        guard let serverId = activeServerId, isActive, !isLooking, inFlight == nil else { return }
        isLooking = true
        defer { isLooking = false }
        let networkKey = network.key
        let stored = try? await server.storedReadings()
        let target = try? await server.target()
        guard activeServerId == serverId, network.key == networkKey, isActive else { return }
        adopt(stored ?? .none, serverId: serverId, networkKey: networkKey)
        guard let target, target.serverId == serverId else { return }
        lastTarget = target
        guard target.automatic, !linkIsProven else { return }
        if let notBefore, clock.now < notBefore { return }
        guard gate(automatic: true) == nil else { return }
        _ = await probeOnce(mode: .quick(targetKbps: target.targetKbps))
    }

    /// Why a test may not run now, or nil when it may. The quiet period after
    /// a playback start holds only automatic tests.
    private func gate(automatic: Bool) -> Outcome? {
        if activeServerId == nil { return .notSupported }
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

    private func probeOnce(mode: BandwidthProbeMeter.Mode) async -> Outcome {
        if let inFlight, let task = inFlight.task { return await task.value }
        let run = Run()
        inFlight = run
        isProbing = true
        let task = Task { [weak self] () -> Outcome in
            guard let self else { return .interrupted }
            let outcome = await self.measureAndReport(run, mode: mode)
            if self.inFlight === run {
                self.inFlight = nil
                self.isProbing = false
            }
            if case .rateLimited(let seconds) = outcome {
                self.notBefore = self.clock.now.addingTimeInterval(TimeInterval(seconds))
            }
            return outcome
        }
        run.task = task
        return await task.value
    }

    private func measureAndReport(_ run: Run, mode: BandwidthProbeMeter.Mode) async -> Outcome {
        let target: BandwidthProbeTarget
        do {
            guard let found = try await server.target() else { return run.cancelledFor ?? .notSupported }
            target = found
        } catch {
            return run.cancelledFor ?? .networkError
        }
        if let reason = run.cancelledFor { return reason }
        if let refused = gate(automatic: mode != .accurate) { return refused }
        guard target.serverId == activeServerId else { return .interrupted }
        lastTarget = target
        // A quick test proves the target the server sends now.
        let mode: BandwidthProbeMeter.Mode = if case .quick = mode { .quick(targetKbps: target.targetKbps) } else { mode }
        let measuredOn = network
        let result: BandwidthProbeResult
        do {
            result = try await server.measure(target, mode: mode)
        } catch {
            return run.cancelledFor ?? (error is CancellationError ? .interrupted : .networkError)
        }
        if let reason = run.cancelledFor { return reason }
        let rate: (kbps: Int, bytes: Int, durationMs: Int, lowerBound: Bool)
        switch result {
        case .measured(let kbps, let bytes, let durationMs, let lowerBound): rate = (kbps, bytes, durationMs, lowerBound)
        case .rateLimited(let seconds):
            Self.logger.info("speed test rate limited: retry after \(seconds, privacy: .public) s")
            return .rateLimited(retryAfterSeconds: seconds)
        case .unavailable(let status):
            Self.logger.info("speed test refused: HTTP \(status, privacy: .public)")
            return .unavailable
        case .tooLittleData:
            Self.logger.info("speed test measured nothing")
            return .tooLittleData
        case .networkError(let reason):
            Self.logger.info("speed test failed: \(reason, privacy: .public)")
            return .networkError
        }
        // A change mid-test cancels it; this catches one that raced its end.
        guard network.key == measuredOn.key, activeServerId == target.serverId else { return .interrupted }
        let measurement = BandwidthMeasurement(
            kbps: rate.kbps,
            lowerBound: rate.lowerBound,
            bytes: rate.bytes,
            durationMs: rate.durationMs,
            transport: measuredOn.transport,
            measuredAt: clock.now
        )
        if !readingsBelongHere { playbackSample = nil }
        readingsKey = (target.serverId, measuredOn.key)
        probeReading = measurement.reading
        let reported = await server.report(measurement, to: target)
        Self.logger.info(
            "speed test: \(measurement.kbps, privacy: .public) kbps\(measurement.lowerBound ? " or faster" : "", privacy: .public) over \(measurement.durationMs, privacy: .public) ms on \(measurement.transport, privacy: .public)\(reported ? "" : " (report failed)", privacy: .public)"
        )
        return .measured(measurement)
    }
}

#if os(macOS)
/// Whether a Mac app can be seen: not while it is hidden, nor while every
/// window it could play in is minimized.
enum MacAppVisibility {
    /// The notifications after which ``isHidden`` can have changed.
    static let changeNotifications = [
        NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification,
    ]

    @MainActor
    static var isHidden: Bool {
        let app = NSApplication.shared
        return app.isHidden || app.windows.filter(\.canBecomeMain).allSatisfy { $0.isMiniaturized || !$0.isVisible }
    }
}

extension BandwidthProbeScheduler {
    /// Treats a hidden or minimized Silo as in the background. Called once at
    /// launch; the scheduler lives as long as the app.
    func followMacVisibility() {
        for name in MacAppVisibility.changeNotifications {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.setHidden(MacAppVisibility.isHidden) }
            }
        }
    }
}
#endif
