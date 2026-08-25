import Foundation
import Network

/// The pairing channel is the shared framed-JSON LAN transport specialized to
/// `PairingMessage`. TLS provides opportunistic confidentiality only (the PSK
/// is compiled into the app — see the design spec §6); integrity rests on the
/// server-issued match code.
typealias PairingSession = FramedJSONSession<PairingMessage>

enum PairingTransport {
    static func tlsParameters() -> NWParameters {
        SiloLANTLS.parameters(psk: "silo-companion-pairing-v1", identity: "silo-pairing")
    }
}

extension FramedJSONSession where Message == PairingMessage {
    /// Outbound side (Companion): connect to a discovered TV endpoint.
    init(endpoint: NWEndpoint) {
        self.init(endpoint: endpoint, parameters: PairingTransport.tlsParameters())
    }
}

/// Transport seam for the pairing coordinators: everything they need from a
/// live channel, and nothing they don't. `FramedJSONSession` is the production
/// conformer; tests drive the coordinators with a scripted fake instead of a
/// real socket.
protocol PairingChannel: Sendable {
    func send(_ message: PairingMessage) async throws
    /// Queue an ordered best-effort frame without waiting for the transport
    /// write to complete. Used once a sign-in is already committed, where a
    /// stalled socket must not hold teardown open indefinitely.
    func queue(_ message: PairingMessage) async
    func close() async
    /// Best-effort goodbye frame ahead of the FIN, bounded by a watchdog so a
    /// wedged connection can never hang the caller.
    func closeGracefully(goodbye: PairingMessage) async
}

extension FramedJSONSession: PairingChannel where Message == PairingMessage {
    func queue(_ message: PairingMessage) async {
        enqueue(message)
    }
}
