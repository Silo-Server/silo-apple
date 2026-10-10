import Foundation

/// Constants for the companion-pairing LAN protocol. Platform-neutral so
/// silo-android can mirror it (Android NSD + sockets).
enum PairingProtocol {
    /// Wire protocol version. Bump on any breaking change to message shapes.
    static let version = 1
    /// Bonjour service type the TV advertises and the phone browses for.
    static let serviceType = "_silopair._tcp"

    /// Rollout gate for sign-in TVs: whether the TV sign-in screen
    /// advertises `st=login`. Both phone apps must accept `login` TVs before
    /// either TV advertises one; a phone that predates them offers a
    /// sign-in TV the setup chooser and pushes servers without an identity.
    /// On in Debug builds for development; turn it on for release once the
    /// iOS and Android phone apps that handle `login` have shipped.
    static let advertisesSignInTVs: Bool = {
        #if DEBUG
        return true
        #else
        return false
        #endif
    }()

    /// TXT keys. `st` is the receiver state; `srv` is the deployment
    /// identity of a `login` TV's server (absent for `setup`).
    enum TXTKey {
        static let version = "v"
        static let name = "name"
        static let deviceId = "id"
        static let sessionNonce = "sid"
        static let state = "st"
        static let serverIdentity = "srv"
    }
}

/// The TV's advertised state, carried in the Bonjour TXT record and in `Hello`.
enum PairingReceiverState: String, Codable, Equatable {
    /// Blank TV with no server configured — needs a URL pushed.
    case setup
    /// TV already has a server and shows its sign-in screen: it only needs
    /// an account signed in. Its TXT record carries `srv`, the deployment
    /// identity (`GET /api/v2/system/identity`) of that server. A phone
    /// offers it only when it holds a saved server with that verified
    /// identity, skips the server chooser, and pushes that server alone.
    /// The TV answers with the code it is already showing.
    case login
}

/// A message on the wire. Encoded as a JSON object with a `type`
/// discriminator and a `v` (version) field; per-type fields are flattened
/// alongside. Tokens NEVER appear in any message — the server delivers
/// those to the TV over HTTPS.
enum PairingMessage: Equatable {
    /// TV → phone, first message after the connection opens.
    case hello(tvName: String, tvDeviceId: String, state: PairingReceiverState, supportedVersions: [Int])
    /// phone → TV, one per chosen server. `serverIdentity` and `endpoints`
    /// are optional additions (protocol still v1): the deployment identity
    /// the phone verified at `serverURL`, and the other addresses the
    /// deployment offers, so a TV that cannot reach the phone's address can
    /// verify and use one it can. Older peers omit and ignore them.
    case pushServer(serverURL: String, serverName: String?, serverIdentity: String? = nil, endpoints: [ServerEndpoint]? = nil)
    /// TV → phone, after the TV called device/start for a pushed server.
    /// `matchCode` is advisory display only; the phone re-fetches the
    /// authoritative match code from the server via lookup before approving.
    case deviceStarted(serverURL: String, userCode: String, matchCode: String)
    /// TV → phone, terminal per-server outcome. `serverURL` always echoes
    /// the pushed URL, even when the TV signed in at another address, so a
    /// phone that keys on it keeps working. `error` is a
    /// ``PairingFailureCode`` raw value on failure.
    case serverResult(serverURL: String, status: PairingServerStatus, error: String?)
    /// phone → TV, no more servers; finish.
    case done
    /// either direction, abort.
    case cancel(reason: String)
}

enum PairingServerStatus: String, Codable, Equatable {
    case signedIn
    case failed
}

/// Why a pushed server failed on the TV. Carried in `serverResult.error`
/// so the phone can say what to fix. Older TVs send only `auth_failed`, and
/// an unknown code from a newer TV reads as that generic failure.
enum PairingFailureCode: String, Codable, Equatable, Sendable {
    /// Device authorization could not be started or completed; the legacy
    /// catch-all.
    case authFailed = "auth_failed"
    /// The phone's user declined the request, or the server refused it.
    case denied
    /// The device code expired before approval, or was already used.
    case expired
    /// The TV could not reach the pushed address, and no offered
    /// alternative worked or was accepted.
    case unreachable
    /// An address answered with a different deployment identity.
    case identityMismatch = "identity_mismatch"
    /// The server is v1-only, or no longer accepts this app version, so one
    /// of them must be updated first. Older phones read it as `auth_failed`.
    case updateRequired = "update_required"
    /// The server approved the sign-in but the TV could not save it (for
    /// example the keychain refused the write). Shown on this TV only:
    /// Android has no `save_failed` yet, so the wire carries `auth_failed`
    /// (see `wireValue`) until both platforms agree on the code.
    case saveFailed = "save_failed"

    init(wire: String?) {
        self = wire.flatMap(PairingFailureCode.init(rawValue:)) ?? .authFailed
    }

    /// What a TV sends in `serverResult.error`: only the codes both
    /// platforms share (auth_failed, denied, expired, unreachable,
    /// identity_mismatch, update_required).
    var wireValue: String {
        switch self {
        case .saveFailed: return PairingFailureCode.authFailed.rawValue
        default: return rawValue
        }
    }
}

extension PairingMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, v
        case tvName, tvDeviceId, state, supportedVersions
        case serverURL, serverName, serverIdentity, endpoints
        case userCode, matchCode
        case status, error
        case reason
    }

    private enum Kind: String, Codable {
        case hello, pushServer, deviceStarted, serverResult, done, cancel
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(PairingProtocol.version, forKey: .v)
        switch self {
        case let .hello(tvName, tvDeviceId, state, supportedVersions):
            try c.encode(Kind.hello, forKey: .type)
            try c.encode(tvName, forKey: .tvName)
            try c.encode(tvDeviceId, forKey: .tvDeviceId)
            try c.encode(state, forKey: .state)
            try c.encode(supportedVersions, forKey: .supportedVersions)
        case let .pushServer(serverURL, serverName, serverIdentity, endpoints):
            try c.encode(Kind.pushServer, forKey: .type)
            try c.encode(serverURL, forKey: .serverURL)
            try c.encodeIfPresent(serverName, forKey: .serverName)
            try c.encodeIfPresent(serverIdentity, forKey: .serverIdentity)
            try c.encodeIfPresent(endpoints, forKey: .endpoints)
        case let .deviceStarted(serverURL, userCode, matchCode):
            try c.encode(Kind.deviceStarted, forKey: .type)
            try c.encode(serverURL, forKey: .serverURL)
            try c.encode(userCode, forKey: .userCode)
            try c.encode(matchCode, forKey: .matchCode)
        case let .serverResult(serverURL, status, error):
            try c.encode(Kind.serverResult, forKey: .type)
            try c.encode(serverURL, forKey: .serverURL)
            try c.encode(status, forKey: .status)
            try c.encodeIfPresent(error, forKey: .error)
        case .done:
            try c.encode(Kind.done, forKey: .type)
        case let .cancel(reason):
            try c.encode(Kind.cancel, forKey: .type)
            try c.encode(reason, forKey: .reason)
        }
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .type)
        switch kind {
        case .hello:
            self = .hello(
                tvName: try c.decode(String.self, forKey: .tvName),
                tvDeviceId: try c.decode(String.self, forKey: .tvDeviceId),
                state: try c.decode(PairingReceiverState.self, forKey: .state),
                supportedVersions: try c.decode([Int].self, forKey: .supportedVersions)
            )
        case .pushServer:
            self = .pushServer(
                serverURL: try c.decode(String.self, forKey: .serverURL),
                serverName: try c.decodeIfPresent(String.self, forKey: .serverName),
                serverIdentity: try c.decodeIfPresent(String.self, forKey: .serverIdentity),
                endpoints: try c.decodeIfPresent([ServerEndpoint].self, forKey: .endpoints)
            )
        case .deviceStarted:
            self = .deviceStarted(
                serverURL: try c.decode(String.self, forKey: .serverURL),
                userCode: try c.decode(String.self, forKey: .userCode),
                matchCode: try c.decode(String.self, forKey: .matchCode)
            )
        case .serverResult:
            self = .serverResult(
                serverURL: try c.decode(String.self, forKey: .serverURL),
                status: try c.decode(PairingServerStatus.self, forKey: .status),
                error: try c.decodeIfPresent(String.self, forKey: .error)
            )
        case .done:
            self = .done
        case .cancel:
            self = .cancel(reason: try c.decode(String.self, forKey: .reason))
        }
    }
}
