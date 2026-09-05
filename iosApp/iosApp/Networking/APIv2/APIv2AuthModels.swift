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

    func presentation() throws -> DeviceLoginPollResponse {
        guard ["pending", "approved", "denied", "expired", "consumed"].contains(status) else {
            throw APIv2Error.incompleteAuthResponse
        }
        if status == "approved" {
            guard let tokens, !tokens.accessToken.isEmpty, !tokens.refreshToken.isEmpty,
                  !tokens.user.id.isEmpty, !temporary || (sessionExpiresAt != nil && !profileId.isEmpty && !profileToken.isEmpty) else {
                throw APIv2Error.incompleteAuthResponse
            }
        } else if tokens != nil { throw APIv2Error.incompleteAuthResponse }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return DeviceLoginPollResponse(status: status, pollAfter: pollAfter, accessToken: tokens?.accessToken,
            refreshToken: tokens?.refreshToken, expiresIn: tokens?.expiresIn, user: tokens?.user,
            profileId: profileId, profileToken: profileToken, temporary: temporary,
            sessionExpiresAt: sessionExpiresAt.map { formatter.string(from: $0) })
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
