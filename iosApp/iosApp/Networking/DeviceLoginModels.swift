import Foundation

struct DeviceLoginStartRequest: Codable {
    let deviceName: String?
    let devicePlatform: String?
    var clientPurpose: String? = nil
    var temporary: Bool? = nil
}

/// `deviceCode` is the TV-only secret used for polling; it must never be
/// displayed. `verificationUriComplete` is the URL encoded into the QR —
/// scanning it deep-links into the web app's `/activate?token=…` page.
struct DeviceLoginStartResponse: Codable, Equatable {
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
    var clientPurpose: String? = nil
    var temporary: Bool? = nil
}

struct DeviceLoginPollRequest: Codable {
    let deviceCode: String
}

/// Token fields are only populated on the first `approved` response — the
/// server marks the record consumed atomically, so the TV must capture
/// them immediately on that single reply.
struct DeviceLoginPollResponse: Codable {
    let status: String
    let pollAfter: Int?
    let accessToken: String?
    let refreshToken: String?
    let expiresIn: Int64?
    let user: AuthUser?
    var profileId: String? = nil
    var profileToken: String? = nil
    var temporary: Bool? = nil
    var sessionExpiresAt: String? = nil
}

enum DeviceLoginStatus: String {
    case pending
    case approved
    case denied
    case expired
    case consumed
    case unknown

    init(raw: String) {
        self = DeviceLoginStatus(rawValue: raw) ?? .unknown
    }
}

/// Body for POST /api/v1/auth/device/approve (sent by an authenticated client).
struct DeviceApproveRequest: Codable {
    let code: String
}

/// Response from GET /api/v1/auth/device?code=<userCode>. All optional: we
/// only need the authoritative match code and a display name. Confirm field
/// names against silo-server (see Step 1).
struct DeviceLookupResponse: Codable {
    let matchCode: String?
    let deviceName: String?
    let devicePlatform: String?
    let status: String?
    var clientPurpose: String? = nil
    var temporary: Bool? = nil
}

struct DeviceLoginCapabilityResponse: Codable {
    let remotePlaybackHandoff: Bool
    let protocolVersions: [Int]
}
