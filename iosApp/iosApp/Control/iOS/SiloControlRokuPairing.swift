#if os(iOS)
import Foundation
import Network

/// Pairing keys for Rokus that require pairing (level `sealed`), one per
/// Roku installation ID, in the Keychain. A key arrives only in a scanned
/// pairing link and leaves this store only to key a sealed connection.
/// Nothing logs it.
struct SiloControlPairingKeys {
    var keychain = SharedKeychain(audience: .currentUser)
    private static let accountPrefix = SharedStorage.keychainAccountPrefix + "silocontrol.pairingKey."

    /// The key stored for `target`, only while it is the key the Roku
    /// advertises now (TXT `kid`). A Roku whose pairing code was reset
    /// needs a new scan.
    func key(for target: SiloControlTarget) -> Data? {
        guard let kid = target.keyId, let key = storedKey(forTV: target.id),
              SiloControlSealed.keyId(key) == kid else { return nil }
        return key
    }

    /// `target` as this phone dials it (`pinned(_:key:)`).
    func pinned(_ target: SiloControlTarget) -> SiloControlTarget {
        Self.pinned(target, key: storedKey(forTV: target.id))
    }

    /// `target`, dialed sealed with `key` when it is a Roku that advertises
    /// `plain`. A Roku paired at level `sealed` stays sealed when an
    /// advertisement with its ID says `plain`: anyone on the network can
    /// advertise that, so only a new pairing link drops the key. A Roku that
    /// really went to `plain` refuses the sealed hello, and the user is asked
    /// to scan its new code.
    static func pinned(_ target: SiloControlTarget, key: Data?) -> SiloControlTarget {
        guard target.transport == .plain, let key else { return target }
        var pinned = target
        pinned.transport = .sealed
        pinned.keyId = SiloControlSealed.keyId(key)
        return pinned
    }

    @discardableResult
    func store(_ key: Data, forTV id: String) -> Bool {
        keychain.set(key.base64EncodedString(), for: Self.accountPrefix + id)
    }

    @discardableResult
    func forget(tv id: String) -> Bool {
        keychain.delete(Self.accountPrefix + id)
    }

    private func storedKey(forTV id: String) -> Data? {
        guard let stored = keychain.get(Self.accountPrefix + id), let key = Data(base64Encoded: stored),
              key.count == SiloControlSealed.keyBytes else { return nil }
        return key
    }
}

/// The link a Roku's Connect a Phone screen shows as a QR code, for networks
/// that block multicast DNS (silo-roku `docs/silocontrol.md` section 5.3):
///
/// `silo://cast?v=2&host=<ip>&port=<port>&id=<deviceId>&name=<name>&server=<serverId>&security=plain|sealed[&key=<base32>]`
///
/// The link carries no credential. Unknown parameters are ignored.
struct SiloControlPairingLink: Equatable {
    let host: IPv4Address
    let port: NWEndpoint.Port
    let deviceId: String
    let name: String
    let serverId: String
    let protocolVersion: Int
    let transport: SiloControlTransport
    /// The 16-byte pairing key, present exactly when `transport` is `.sealed`.
    let key: Data?

    init?(url: URL) {
        guard url.scheme?.lowercased() == SiloURLScheme.current, url.host?.lowercased() == "cast",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        func value(_ name: String) -> String? {
            items.first { $0.name == name }?.value.flatMap { $0.isEmpty ? nil : $0 }
        }
        // A Roku listens on its LAN address only; anything else is not a
        // Roku's link.
        guard let hostText = value("host"), let host = IPv4Address(hostText), Self.isLocal(host),
              let portText = value("port"), let portNumber = UInt16(portText), portNumber > 0,
              let port = NWEndpoint.Port(rawValue: portNumber),
              let deviceId = value("id"), let serverId = value("server") else { return nil }
        switch value("security") ?? "plain" {
        case "plain":
            transport = .plain
            key = nil
        case "sealed":
            guard let encoded = value("key"), let decoded = SiloControlSealed.base32Decode(encoded),
                  decoded.count == SiloControlSealed.keyBytes else { return nil }
            transport = .sealed
            key = decoded
        default:
            return nil
        }
        self.host = host
        self.port = port
        self.deviceId = deviceId
        self.name = value("name") ?? "Roku"
        self.serverId = serverId
        self.protocolVersion = value("v").flatMap(Int.init) ?? 2
    }

    /// A target that dials the link's address directly.
    var target: SiloControlTarget {
        SiloControlTarget(
            id: deviceId,
            name: name,
            endpoint: .hostPort(host: .ipv4(host), port: port),
            serverId: serverId,
            serverName: nil,
            protocolVersion: protocolVersion,
            transport: transport,
            keyId: key.map(SiloControlSealed.keyId)
        )
    }

    /// Private (RFC 1918) and link-local IPv4, the peers a Roku accepts.
    static func isLocal(_ address: IPv4Address) -> Bool {
        let bytes = [UInt8](address.rawValue)
        guard bytes.count == 4 else { return false }
        switch (bytes[0], bytes[1]) {
        case (10, _), (192, 168), (169, 254): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
#endif
