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

/// Body of a device-login decision (sent by an authenticated client).
struct DeviceApproveRequest: Codable {
    let code: String
}

/// A pairing request as the approving client shows it: the authoritative
/// match code and the requesting device. Pairing builds it from the v2
/// lookup (`APIv2DeviceLookup.presentation`); the SiloRemote handoff still
/// decodes it from its own lookup call.
struct DeviceLookupResponse: Codable {
    let matchCode: String?
    let deviceName: String?
    let devicePlatform: String?
    let status: String?
    var clientPurpose: String? = nil
    var temporary: Bool? = nil
}
