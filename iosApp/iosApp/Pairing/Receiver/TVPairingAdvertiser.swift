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
/// shows "Looking for your iPhone…" while advertising nothing.
@MainActor
final class TVPairingAdvertiser {
    private var listener: NWListener?
    private var busy = false
    private var generation = 0
    private var onConnection: ((PairingSession, AsyncThrowingStream<PairingMessage, Error>) -> Void)?
    private nonisolated static let logger = Logger(subsystem: "com.continuum.app", category: "pairing.advertiser")

    /// - Parameter onConnection: called on the main actor with an opened
    ///   session + its inbound stream for the coordinator to drive.
    func start(onConnection: @escaping (PairingSession, AsyncThrowingStream<PairingMessage, Error>) -> Void) {
        stop()
        self.onConnection = onConnection
        startListener()
    }

    private func startListener() {
        generation += 1
        let gen = generation
        let device = AppleDeviceIdentity.current
        // `sid` is a fresh nonce minted each time the listener starts — i.e.
        // each time the TV (re)starts advertising (reboot, leaving and
        // re-entering the setup screen, or a self-heal restart). It is stable
        // for the life of one listener: `release()` between pairing attempts
        // keeps the same listener and `sid`. The phone keys "Not Now"
        // dismissals on it, so the card re-appears when the TV starts a new
        // setup session (new `sid`) but not on brief Bonjour flaps (same
        // `sid`). Older phones ignore it and fall back to `id`.
        let txt = NWTXTRecord([
            "v": String(PairingProtocol.version),
            "name": device.name,
            "id": device.id,
            "sid": UUID().uuidString,
            "st": PairingReceiverState.setup.rawValue
        ])
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
