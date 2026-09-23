#if os(iOS)
import Foundation

// Wire models for ordered Apple push registration
// (`registerApplePushDevice`, `getApplePushRegistrationCapabilities`).

/// `POST /api/v2/devices/push/apple` body (`ApplePushRegistrationBody`).
///
/// Also the payload the installation journal retains with its generation, so
/// an uncertain send is replayed with exactly these fields.
struct APIv2ApplePushRegistrationBody: Codable, Equatable, Sendable {
    let deviceId: String
    let apnsToken: String
    let apnsEnvironment: String
    let apnsTopic: String
    let pushMode: String
}

/// `POST /api/v2/devices/push/apple` response (`ApplePushRegistrationReceipt`).
struct APIv2ApplePushRegistrationReceipt: Decodable, Equatable, Sendable {
    /// The generation the server applied, as a decimal string.
    let generation: String
    let id: String
    let serverDeviceId: String
    let pushMode: String
    let enabled: Bool
    /// The retained intent references a deleted registration. An exact
    /// replay never brings it back.
    let removed: Bool
    /// Long-lived, profile-scoped token for the Notification Service
    /// extension's display fetch. Omitted when the server cannot mint one.
    let displayToken: String?
    /// RFC 3339 expiry of `displayToken`. Omitted with it.
    let displayTokenExpiresAt: String?
}

/// `GET /api/v2/devices/push/apple/capabilities`.
struct APIv2ApplePushCapability: Decodable, Equatable, Sendable {
    let allowed: Bool
    /// Ordered storage and login validation are configured. Says nothing
    /// about provider delivery.
    let registrationAvailable: Bool
    /// Opaque; never compared against a literal.
    let revision: String
    let state: String

    var permitsRegistration: Bool {
        allowed && state == "available" && registrationAvailable
    }
}
#endif
