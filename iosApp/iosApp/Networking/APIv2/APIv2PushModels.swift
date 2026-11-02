#if os(iOS)
import Foundation

// Wire models for ordered Apple push registration
// (`registerApplePushDevice`, `getApplePushRegistrationCapabilities`,
// `retireApplePushInstallation`, `resetApplePushInstallation`).

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
    /// The deployment identity (`GET /api/v2/system/identity`) pushes for
    /// this registration name. Omitted by older servers.
    let serverId: String?
}

/// `POST /api/v2/devices/push/apple/retire` body
/// (`retireApplePushInstallation`).
struct APIv2ApplePushRetirementBody: Encodable, Equatable, Sendable {
    let deviceId: String
}

/// `POST /api/v2/devices/push/apple/retire` response. `removed` is true
/// whether or not the server still held a registration for the device.
struct APIv2ApplePushRetirementReceipt: Decodable, Equatable, Sendable {
    /// The generation the server applied, as a decimal string.
    let generation: String
    let removed: Bool
}

/// `POST /api/v2/devices/push/apple/reset` body
/// (`resetApplePushInstallation`).
struct APIv2ApplePushResetBody: Encodable, Equatable, Sendable {
    let deviceId: String
}

/// `POST /api/v2/devices/push/apple/reset` response. `reset` is false when
/// the server held nothing to clear; the next registration binds either way.
struct APIv2ApplePushResetReceipt: Decodable, Equatable, Sendable {
    let reset: Bool
}

/// `GET /api/v2/auth/sessions` (`LoginSessionCollection`), reduced to what
/// the push registrar's same-backend check reads.
struct APIv2LoginSessionPage: Decodable, Equatable, Sendable {
    struct Session: Decodable, Equatable, Sendable {
        let id: String
        let current: Bool
    }

    struct Page: Decodable, Equatable, Sendable {
        let hasMore: Bool
        let nextCursor: String?
    }

    /// Null for API-key callers.
    let currentSession: Session?
    let items: [Session]
    let page: Page?
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
    /// The server serves `resetApplePushInstallation`. Older servers omit it.
    let installationResetAvailable: Bool?

    var permitsRegistration: Bool {
        allowed && state == "available" && registrationAvailable
    }

    var permitsInstallationReset: Bool {
        permitsRegistration && installationResetAvailable == true
    }
}
#endif
