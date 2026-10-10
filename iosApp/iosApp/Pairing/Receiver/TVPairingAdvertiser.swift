#if os(tvOS)
import Foundation
import Network
import OSLog

/// Advertises `_silopair._tcp` on the LAN and hands the first inbound
/// connection to a `PairingSession`. One connection at a time; later peers
/// are rejected as busy.
///
/// Self-healing (generation-guarded restart via `BonjourSelfHeal`): the
/// first-run screen is the longest-dwelling screen in the app, so a listener
/// the system reclaims or fails must come back on its own — otherwise the TV
/// shows "Looking for a phone or tablet…" while advertising nothing.
@MainActor
final class TVPairingAdvertiser {
    private var listener: NWListener?
    private var busy = false
    private let selfHeal = BonjourSelfHeal()
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
    private func start(
        state: PairingReceiverState,
        serverIdentity: String?,
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

    /// Advertises while the calling task runs and `isCurrent` holds, stopping
    /// and restarting as it changes. Call it from the screen's `.task`, with
    /// `isCurrent` comparing the router's route to the one captured in the
    /// view's `init`. SwiftUI can keep or reshow this screen without
    /// `onDisappear` or task cancellation (a nearby setup re-keys the routed
    /// subtree), so view lifetime alone would leave `st=setup` advertised on
    /// later screens.
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
        let gen = selfHeal.activate()
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
            let listener = try NWListener(using: PairingSession.tlsParameters())
            listener.service = NWListener.Service(name: device.name, type: PairingProtocol.serviceType, txtRecord: txt)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in
                    guard let self, self.selfHeal.isCurrent(gen), let onConnection = self.onConnection else {
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
            // Runs on `.main` (see `start(queue:)` below).
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated {
                    guard let self, self.selfHeal.isCurrent(gen) else { return }
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
        selfHeal.scheduleRestart { [weak self] in
            guard let self, self.listener == nil, self.onConnection != nil else { return }
            self.startListener()
        }
    }

    /// Allow a new connection after the previous session ended.
    func release() { busy = false }

    func stop() {
        selfHeal.deactivate()
        listener?.cancel()
        listener = nil
        busy = false
        onConnection = nil
    }
}
#endif
