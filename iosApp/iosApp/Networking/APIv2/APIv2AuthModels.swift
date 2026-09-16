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
        guard ["pending", "approved", "denied", "expired", "consumed"].contains(status) else {
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

    var presentation: DeviceLoginCapabilityResponse {
        DeviceLoginCapabilityResponse(remotePlaybackHandoff: state == "available" && remotePlaybackHandoff,
            protocolVersions: protocolVersions)
    }
}

struct APIv2DeviceDecision: Decodable { let status: String }

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
    var presentation: DeviceLookupResponse {
        DeviceLookupResponse(matchCode: matchCode, deviceName: deviceName, devicePlatform: devicePlatform,
            status: status, clientPurpose: clientPurpose, temporary: temporary)
    }
}
