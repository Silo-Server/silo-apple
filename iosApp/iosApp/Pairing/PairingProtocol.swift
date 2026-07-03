import Foundation

/// Constants for the companion-pairing LAN protocol. Platform-neutral so
/// silo-android can mirror it (Android NSD + sockets).
enum PairingProtocol {
    /// Wire protocol version. Bump on any breaking change to message shapes.
    static let version = 1
    /// Bonjour service type the TV advertises and the phone browses for.
    static let serviceType = "_silopair._tcp"
}

/// The TV's advertised state, carried in the Bonjour TXT record and in `Hello`.
enum PairingReceiverState: String, Codable, Equatable {
    /// Blank TV with no server configured — needs a URL pushed.
    case setup
    /// TV already has a server — only needs a user signed in.
    ///
    /// RESERVED, NOT IMPLEMENTED: nothing advertises or handles `login` yet
    /// (the advertiser hardcodes `setup`, and only the first-run screen
    /// advertises at all). Kept on the wire so a future "sign in to a
    /// configured TV" flow doesn't need a protocol bump.
    case login
}

/// A message on the wire. Encoded as a JSON object with a `type`
/// discriminator and a `v` (version) field; per-type fields are flattened
/// alongside. Tokens NEVER appear in any message — the server delivers
/// those to the TV over HTTPS.
enum PairingMessage: Equatable {
    /// TV → phone, first message after the connection opens.
    case hello(tvName: String, tvDeviceId: String, state: PairingReceiverState, supportedVersions: [Int])
    /// phone → TV, one per chosen server.
    case pushServer(serverURL: String, serverName: String?)
    /// TV → phone, after the TV called device/start for a pushed server.
    /// `matchCode` is advisory display only; the phone re-fetches the
    /// authoritative match code from the server via lookup before approving.
    case deviceStarted(serverURL: String, userCode: String, matchCode: String)
    /// TV → phone, terminal per-server outcome.
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

extension PairingMessage: Codable {
    private enum CodingKeys: String, CodingKey {
        case type, v
        case tvName, tvDeviceId, state, supportedVersions
        case serverURL, serverName
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
        case let .pushServer(serverURL, serverName):
            try c.encode(Kind.pushServer, forKey: .type)
            try c.encode(serverURL, forKey: .serverURL)
            try c.encodeIfPresent(serverName, forKey: .serverName)
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
                serverName: try c.decodeIfPresent(String.self, forKey: .serverName)
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
