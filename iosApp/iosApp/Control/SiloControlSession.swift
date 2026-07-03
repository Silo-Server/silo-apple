import Foundation
import Network

/// The SiloControl channel is the shared framed-JSON LAN transport specialized
/// to `SiloControlMessage`.
typealias SiloControlSession = FramedJSONSession<SiloControlMessage>

extension FramedJSONSession where Message == SiloControlMessage {
    /// Outbound side (iPhone remote): connect to a discovered receiver.
    init(endpoint: NWEndpoint) {
        self.init(endpoint: endpoint, parameters: Self.tlsParameters())
    }

    static func tlsParameters() -> NWParameters {
        SiloLANTLS.parameters(psk: "silo-cast-v1", identity: "silo-cast")
    }

    /// Send a final `.close` ahead of the FIN. The peer must read `.close`
    /// before EOF to tell a deliberate disconnect from a dropped connection —
    /// otherwise it auto-reconnects.
    func closeGracefully() async {
        await closeGracefully(goodbye: .close)
    }
}
