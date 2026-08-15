import Foundation
import Network
import OSLog

/// App-wide connection state: device connectivity (via `NWPathMonitor`) plus
/// server reachability learned passively from every `HTTPClient` request
/// outcome. Screens read this to distinguish "showing cached data because the
/// server is down" from a healthy session, and playback entry points consult
/// it before opening a streaming player that cannot succeed.
///
/// Server status is optimistic: `.unknown` counts as reachable so the app
/// never blocks a request it hasn't seen fail. Any completed HTTP response —
/// including a 4xx/5xx — proves the server is up; only transport-level
/// failures (connection refused, timeout, DNS) mark it unreachable. While
/// unreachable, a background loop probes `GET /api/v1/health` so the state
/// self-heals as soon as the server comes back.
@MainActor
@Observable
final class ConnectionMonitor {
    static let shared = ConnectionMonitor()

    enum ServerStatus {
        case unknown
        case reachable
        case unreachable
    }

    /// Device has a usable network path (Wi-Fi/cellular/wired).
    private(set) var isDeviceOnline = true
    private(set) var serverStatus: ServerStatus = .unknown

    /// Optimistic gate for starting server-backed work: `.unknown` passes so
    /// the first request after launch is never blocked.
    var isServerReachable: Bool {
        isDeviceOnline && serverStatus != .unreachable
    }

    /// Drive "offline / can't reach server" UI from this: true only once a
    /// failure has actually been observed (or the device itself is offline).
    var isOffline: Bool {
        !isDeviceOnline || serverStatus == .unreachable
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.continuum.app",
        category: "ConnectionMonitor"
    )

    private let pathMonitor = NWPathMonitor()
    private var hasInitialPath = false
    private var reprobeTask: Task<Void, Never>?
    /// Seconds between health probes while the server is unreachable.
    private let reprobeInterval: TimeInterval = 15

    private init() {
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                self?.applyPathUpdate(online: online)
            }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.continuum.connection-monitor"))
    }

    // MARK: - Passive signals (reported by HTTPClient)

    /// Any HTTP response arrived — the server is alive regardless of status
    /// code.
    func noteServerResponded() {
        // Called from every successful request, so the transition check is not
        // an optimization — it is what keeps this out of the diagnostics ring
        // on the hot path. Only the edge is evidence; the steady state is
        // implied by the absence of a later transition.
        if serverStatus != .reachable {
            Self.logger.info("Server marked reachable")
            #if os(iOS) || os(tvOS)
            // Essential: recovery is half the story in an "it won't connect"
            // report. Without it, a bundle shows the failures and gives no way
            // to tell an outage that ended from one that is still happening.
            DiagTrace.log(
                .essential,
                category: .network,
                tag: "Reach",
                message: "server reachable",
                attrs: ["outcome": .string("reachable")]
            )
            #endif
        }
        serverStatus = .reachable
        stopReprobeLoop()
    }

    /// A request failed at the transport layer (no HTTP response). Callers
    /// must not report cancellations here.
    func noteServerUnreachable() {
        guard serverStatus != .unreachable else { return }
        Self.logger.info("Server marked unreachable")
        #if os(iOS) || os(tvOS)
        // Essential, and the single most important line in a connectivity
        // report: it is the moment the app decided the server was down, which
        // is what every "offline" banner and blocked playback entry point
        // downstream is reacting to.
        //
        // The guard above means this fires once per transition, not once per
        // failed request — a server that stays down during a 15s reprobe loop
        // contributes one line, not one every 15 seconds.
        DiagTrace.log(
            .essential,
            level: .warning,
            category: .network,
            tag: "Reach",
            message: "server unreachable",
            attrs: ["outcome": .string("unreachable")]
        )
        #endif
        serverStatus = .unreachable
        startReprobeLoop()
    }

    // MARK: - Active probe

    /// One-shot health check. The request flows through `HTTPClient`, whose
    /// success/failure reporting updates `serverStatus` as a side effect.
    @discardableResult
    func probeServer() async -> Bool {
        do {
            let _: HealthStatus = try await HTTPClient.shared.get("/api/v1/health")
            return true
        } catch {
            return false
        }
    }

    /// Wait (bounded) for `NWPathMonitor` to deliver its first path so early
    /// launch decisions (e.g. landing on Downloads when offline) don't read
    /// the optimistic default.
    func waitForInitialPath(timeout: TimeInterval = 1.0) async {
        let deadline = ContinuousClock.now + .seconds(timeout)
        while !hasInitialPath, ContinuousClock.now < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }

    // MARK: - Internals

    private func applyPathUpdate(online: Bool) {
        hasInitialPath = true
        // `NWPathMonitor` re-delivers a path on interface churn that does not
        // change usability (Wi-Fi roaming, a VPN reconfiguring). The equality
        // guard is what makes this a transition rather than a stream, and it
        // already existed for correctness; diagnostics inherits it.
        guard online != isDeviceOnline else { return }
        isDeviceOnline = online
        Self.logger.info("Device network path: \(online ? "online" : "offline", privacy: .public)")
        #if os(iOS) || os(tvOS)
        // Essential. This is the line that separates the two reports that look
        // identical from the user's side: "the app can't reach my server" and
        // "my phone had no network". Without it every device-side outage reads
        // as a server fault.
        //
        // Only the boolean is recorded — never the interface type, SSID, or
        // any other property of `NWPath`, all of which describe the user's
        // physical location.
        DiagTrace.log(
            .essential,
            level: online ? .info : .warning,
            category: .network,
            tag: "Reach",
            message: "device network path changed",
            attrs: ["outcome": .string(online ? "online" : "offline")]
        )
        #endif
        if online {
            // Regained a network path — find out whether the server is back
            // rather than waiting for the next user-initiated request. The
            // loop was suspended while offline (probes can't succeed without
            // a path), so restart it too in case the server is still down.
            if serverStatus == .unreachable {
                startReprobeLoop()
                Task { await self.probeServer() }
            }
        } else {
            stopReprobeLoop()
        }
    }

    private func startReprobeLoop() {
        guard reprobeTask == nil, isDeviceOnline else { return }
        #if os(iOS) || os(tvOS)
        // The loop's *arming* is a state change and is logged here, once. Its
        // ticks are not: a 15s poll during a long outage would add four lines
        // a minute of "still down", each identical, and the 4000-line ring
        // would be nothing but this by the time the user filed the report.
        //
        // Nothing is lost by staying silent per tick. Each probe is a real
        // request through HTTPClient, so a tick that fails is already covered
        // by the transport-failure line in `perform`, and the tick that
        // finally succeeds is covered by `noteServerResponded`'s transition.
        // The interval is a compile-time constant, so the tick count between
        // this line and the recovery is recoverable from their timestamps.
        DiagTrace.log(
            .essential,
            category: .network,
            tag: "Reach",
            message: "reprobe loop armed",
            attrs: ["outcome": .string("unreachable")]
        )
        #endif
        reprobeTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(nanoseconds: UInt64(self.reprobeInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard self.serverStatus == .unreachable, self.isDeviceOnline else { return }
                await self.probeServer()
            }
        }
    }

    private func stopReprobeLoop() {
        reprobeTask?.cancel()
        reprobeTask = nil
    }
}
