#if os(tvOS)
import Foundation
import Network
import OSLog

/// Advertises `_silopair._tcp` on the LAN and hands the first inbound
/// connection to a `PairingSession`. One connection at a time; later peers
/// are rejected as busy.
///
/// Self-healing (same generation-guarded pattern as `TVControlReceiver`): the
/// first-run screen is the longest-dwelling screen in the app, so a listener
/// the system reclaims or fails must come back on its own — otherwise the TV
/// shows "Looking for a phone or tablet…" while advertising nothing.
@MainActor
final class TVPairingAdvertiser {
    private var listener: NWListener?
    private var busy = false
    private var generation = 0
    private var onConnection: ((PairingSession, AsyncThrowingStream<PairingMessage, Error>) -> Void)?
    private var receiverState: PairingReceiverState = .setup
    private var serverIdentity: String?
    private nonisolated static let logger = Logger(subsystem: "org.siloserver.silo", category: "pairing.advertiser")

    /// - Parameters:
    ///   - state: `setup` on the first-run screen; `login` on the sign-in
    ///     screen of a TV that already has a server.
    ///   - serverIdentity: for `login`, the deployment identity of that
    ///     server, advertised as `srv` so a phone offers only a server it
    ///     holds. A `login` TV without one is not advertised at all.
    ///   - onConnection: called on the main actor with an opened
    ///     session + its inbound stream for the coordinator to drive.
    func start(
        state: PairingReceiverState = .setup,
        serverIdentity: String? = nil,
        onConnection: @escaping (PairingSession, AsyncThrowingStream<PairingMessage, Error>) -> Void
    ) {
        stop()
        let identity = ServerIdentity.usable(serverIdentity)
        guard state == .setup || identity != nil else { return }
        receiverState = state
        self.serverIdentity = state == .login ? identity : nil
        self.onConnection = onConnection
        startListener()
    }

    /// Advertises while the calling task runs, but only while `isCurrent`
    /// holds; it stops when the app leaves the route and starts again when
    /// it comes back.
    ///
    /// Call this from the owning screen's `.task`, with `isCurrent` checking
    /// that the app is on the route the screen was built for (captured in the
    /// view's `init`). View lifecycle alone is not reliable here: a
    /// successful nearby setup changes the active server, which re-keys the
    /// routed subtree while the app is still on the setup route, and the app
    /// moves on to profiles in the next update. The setup screen built by
    /// that re-key appears without ever getting `onDisappear` or a cancelled
    /// task, and SwiftUI shows that same instance again when the user later
    /// picks "Change server". Tying the listener to the view's lifetime left
    /// the TV advertising `st=setup` on the profile and sign-in screens (so
    /// phones offered setup for a TV that already had a server); ending it
    /// for good on the first route change left "Change server" silent.
    func advertise(
        state: PairingReceiverState = .setup,
        serverIdentity: String? = nil,
        while isCurrent: @escaping @MainActor () -> Bool,
        onConnection: @escaping (PairingSession, AsyncThrowingStream<PairingMessage, Error>) -> Void
    ) async {
        var advertising = false
        while !Task.isCancelled {
            let current = isCurrent()
            if current, !advertising {
                start(state: state, serverIdentity: serverIdentity, onConnection: onConnection)
                advertising = true
            } else if !current, advertising {
                stop()
                advertising = false
            }
            try? await Task.sleep(for: .seconds(1))
        }
        if advertising { stop() }
    }

    private func startListener() {
        generation += 1
        let gen = generation
        let device = AppleDeviceIdentity.current
        // `sid` is a fresh nonce minted each time the listener starts — i.e.
        // each time the TV (re)starts advertising (reboot, leaving and
        // re-entering the setup or sign-in screen, or a self-heal restart). It is stable
        // for the life of one listener: `release()` between pairing attempts
        // keeps the same listener and `sid`. The phone keys "Not Now"
        // dismissals on it, so the card re-appears when the TV starts a new
        // setup session (new `sid`) but not on brief Bonjour flaps (same
        // `sid`). Older phones ignore it and fall back to `id`.
        var fields = [
            PairingProtocol.TXTKey.version: String(PairingProtocol.version),
            PairingProtocol.TXTKey.name: device.name,
            PairingProtocol.TXTKey.deviceId: device.id,
            PairingProtocol.TXTKey.sessionNonce: UUID().uuidString,
            PairingProtocol.TXTKey.state: receiverState.rawValue
        ]
        if let serverIdentity { fields[PairingProtocol.TXTKey.serverIdentity] = serverIdentity }
        let txt = NWTXTRecord(fields)
        do {
            let listener = try NWListener(using: PairingTransport.tlsParameters())
            listener.service = NWListener.Service(name: device.name, type: PairingProtocol.serviceType, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.generation == gen, let onConnection = self.onConnection else {
                        connection.cancel()
                        return
                    }
                    if self.busy { connection.cancel(); return }
                    self.busy = true
                    let session = PairingSession(connection: connection)
                    let stream = await session.open()
                    onConnection(session, stream)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    guard let self, self.generation == gen else { return }
                    switch state {
                    case .failed(let error):
                        Self.logger.error("listener failed: \(String(describing: error), privacy: .public)")
                        self.scheduleListenerRestart()
                    case .cancelled:
                        // We bump the generation before cancelling ourselves,
                        // so a current-generation cancel is the system tearing
                        // us down (e.g. after suspension) — recover.
                        self.scheduleListenerRestart()
                    default:
                        break
                    }
                }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            Self.logger.error("failed to start listener: \(String(describing: error), privacy: .public)")
            scheduleListenerRestart()
        }
    }

    private func scheduleListenerRestart() {
        listener = nil
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.listener == nil, self.onConnection != nil else { return }
            self.startListener()
        }
    }

    /// Allow a new connection after the previous session ended.
    func release() { busy = false }

    func stop() {
        generation += 1
        listener?.cancel()
        listener = nil
        busy = false
        onConnection = nil
    }
}
#endif
