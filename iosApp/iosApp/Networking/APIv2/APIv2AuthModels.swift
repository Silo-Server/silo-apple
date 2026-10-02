import Foundation

struct APIv2LoginTokens: Decodable {
    let accessToken: String
    let refreshToken: String
    let expiresIn: Int64
    let user: APIv2Account
}

struct APIv2DevicePoll: Decodable {
    let status: String
    let pollAfter: Int
    /// Whether an approver has looked this pending request up. Absent from
    /// servers without the opened signal, which reads as not opened.
    var opened: Bool? = nil
    /// A pending request's current expiry, which approver lookups extend.
    /// Absent from servers that predate it.
    var expiresAt: Date? = nil
    let tokens: APIv2LoginTokens?
    let profileId: String
    let profileToken: String
    let temporary: Bool
    let sessionExpiresAt: Date?

    /// The poll as the client may act on it: a known status, tokens present
    /// only on `approved`, and a temporary session carrying its expiry and
    /// profile proof. The validated value stays on the wire shape; the login
    /// caller installs it.
    func validated() throws -> APIv2DevicePoll {
        guard ["pending", "approved", "denied", "expired", "consumed", "canceled"].contains(status) else {
            throw APIv2Error.incompleteAuthResponse
        }
        if status == "approved" {
            guard let tokens, !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
                  !tokens.user.id.isEmpty, !temporary || (sessionExpiresAt != nil && !profileId.isEmpty && !profileToken.isEmpty) else {
                throw APIv2Error.incompleteAuthResponse
            }
        } else if tokens != nil { throw APIv2Error.incompleteAuthResponse }
        return self
    }
}

struct APIv2DeviceCapability: Decodable {
    let revision: String
    let state: String
    let remotePlaybackHandoff: Bool
    let protocolVersions: [Int]
    /// Absent for an unauthenticated read.
    let allowed: Bool?
    /// Whether the device can withdraw its own request
    /// (`POST /api/v2/auth/device/cancel`). Absent from older servers.
    var cancel: Bool? = nil
    /// Whether polls report `opened` once an approver looked the request up.
    var openedSignal: Bool? = nil

    /// Whether this server offers device sign-in at all. Older servers
    /// that answer the document always do; `disabled`, `not_configured`
    /// and `unsupported` mean password sign-in only.
    var offersDeviceSignIn: Bool { state == "available" }
    var supportsCancel: Bool { offersDeviceSignIn && cancel == true }
    var supportsOpenedSignal: Bool { offersDeviceSignIn && openedSignal == true }

    /// Whether this server accepts a remote-playback handoff speaking
    /// `protocolVersion`. Only an `available` document counts; a principal the
    /// server explicitly refuses does not.
    func offersRemotePlaybackHandoff(protocolVersion: Int) -> Bool {
        state == "available" && allowed != false && remotePlaybackHandoff
            && protocolVersions.contains(protocolVersion)
    }
}

struct APIv2DeviceDecision: Decodable { let status: String }

/// `POST /api/v2/auth/device/cancel`: `canceled` when the request was still
/// pending (or approved and uncollected), otherwise its unchanged state.
struct APIv2DeviceCancel: Decodable { let status: String }

struct APIv2DeviceStart: Decodable {
    let deviceCode: String
    let userCode: String
    let matchCode: String
    let verificationUri: String
    let verificationUriComplete: String
    let expiresAt: Date
    let expiresIn: Int
    let interval: Int
    let deviceName: String
    let devicePlatform: String
    let clientPurpose: String
    let temporary: Bool
    var presentation: DeviceLoginStartResponse {
        DeviceLoginStartResponse(deviceCode: deviceCode, userCode: userCode, matchCode: matchCode,
            verificationUri: verificationUri, verificationUriComplete: verificationUriComplete,
            expiresAt: expiresAt, expiresIn: expiresIn, interval: interval, deviceName: deviceName,
            devicePlatform: devicePlatform, clientPurpose: clientPurpose, temporary: temporary)
    }
}

struct APIv2DeviceLookup: Decodable {
    let status: String
    let userCode: String
    let matchCode: String
    let deviceName: String
    let devicePlatform: String
    let ipAddressHint: String
    let clientPurpose: String
    let temporary: Bool
    let expiresAt: Date?
    /// When the device started the request. Absent from older servers.
    var requestedAt: Date? = nil
    var serverId: String? = nil
    var serverName: String? = nil
    var presentation: DeviceLookupResponse {
        DeviceLookupResponse(matchCode: matchCode, deviceName: deviceName, devicePlatform: devicePlatform,
            status: status, clientPurpose: clientPurpose, temporary: temporary, userCode: userCode,
            ipAddressHint: ipAddressHint, expiresAt: expiresAt, requestedAt: requestedAt,
            serverId: ServerIdentity.usable(serverId), serverName: ServerIdentity.usable(serverName))
    }
}
