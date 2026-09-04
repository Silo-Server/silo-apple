#if os(iOS)
import Foundation
import OSLog
import UIKit
import UserNotifications

struct ApplePushRegistrationRequest: Encodable, Equatable {
    let deviceId: String
    let apnsToken: String
    let apnsEnvironment: String
    let apnsTopic: String
    let pushMode: String
}

struct ApplePushRegistrationResponse: Decodable {
    let id: String
    let serverDeviceId: String
    let enabled: Bool
    let pushMode: String
    /// Long-lived, profile-scoped token for the Notification Service
    /// extension's display fetch. Absent on older servers.
    let displayToken: String?
    /// RFC 3339 expiry of `displayToken`. Absent with it.
    let displayTokenExpiresAt: String?
}

/// Persists the registration's display token where the Notification Service
/// extension reads it. Kept separate from `TokenStore`'s access/profile
/// mirrors because it is minted per registration, not per sign-in.
struct ApplePushDisplayTokenStore {
    /// Renew this far ahead of expiry so a token never lapses between two
    /// foregrounds; the server's default lifetime is 30 days.
    static let renewalLeadTime: TimeInterval = 7 * 24 * 60 * 60

    var keychain: SharedKeychain = SharedKeychain(audience: TokenStore.profileCredentialAudience)
    var defaults: SharedDefaults = .shared
    var now: () -> Date = Date.init

    /// `true` when a token is stored and is not within `renewalLeadTime` of
    /// its expiry. A token with no recorded expiry, or one that fails to
    /// parse, is treated as needing renewal: the metadata is written only
    /// alongside a successful Keychain write, so its absence means the
    /// token's state is unknown and a fresh registration is the safe move.
    func hasCurrentToken() -> Bool {
        let stored = keychain.get(SharedStorage.applePushDisplayTokenAccount) ?? ""
        guard !stored.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let raw = defaults.string(forKey: SharedStorage.applePushDisplayTokenExpiresAtKey),
              let expiresAt = Self.parseExpiry(raw) else {
            return false
        }
        return expiresAt.timeIntervalSince(now()) > Self.renewalLeadTime
    }

    /// Returns `true` when the token was written, or when there was nothing
    /// to write and any stale token was removed.
    ///
    /// Metadata only follows a Keychain mutation that succeeded. If the write
    /// or delete fails, the previous token and its expiry stay paired, so
    /// `hasCurrentToken()` keeps reporting the old token's real state and
    /// registration retries on the next foreground instead of treating a
    /// stale credential as current.
    @discardableResult
    func store(_ token: String?, expiresAt: String?, serverId: String) -> Bool {
        let trimmed = token?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !trimmed.isEmpty else {
            let removed = keychain.delete(SharedStorage.applePushDisplayTokenAccount)
            if removed {
                defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
                defaults.removeObject(forKey: SharedStorage.applePushDisplayTokenServerIdKey)
            }
            return removed
        }
        let written = keychain.set(trimmed, for: SharedStorage.applePushDisplayTokenAccount)
        if written {
            defaults.set(expiresAt, forKey: SharedStorage.applePushDisplayTokenExpiresAtKey)
            defaults.set(serverId, forKey: SharedStorage.applePushDisplayTokenServerIdKey)
        }
        return written
    }

    static func parseExpiry(_ raw: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }
        return ISO8601DateFormatter().date(from: raw)
    }
}

enum ApplePushRegistrationWire {
    static let endpoint = "/api/v1/devices/push/apple"
    static let defaultTopic = "org.siloserver.silo"
    static let privatePushMode = "private_push"

    /// The APNs environment is a *signing-time* decision (the
    /// `aps-environment` entitlement from the provisioning profile), not a
    /// compile-time one: the repo ships Release IPAs for sideloading that
    /// get re-signed with development profiles, and a `#if DEBUG` guess
    /// would register those sandbox tokens as "production" — every push
    /// would then fail with BadDeviceToken. Read the embedded profile
    /// instead; App Store installs carry no embedded profile and are
    /// production by definition.
    static var currentAPNsEnvironment: String {
        #if targetEnvironment(simulator)
        return "sandbox"
        #else
        if let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url),
           let environment = apnsEnvironment(fromProvisioningProfile: data) {
            return environment
        }
        return "production"
        #endif
    }

    /// Extracts `Entitlements.aps-environment` from a raw
    /// `embedded.mobileprovision` (a CMS blob wrapping an XML plist) and
    /// maps it to the server's wire values. Returns nil when the profile
    /// has no push entitlement or cannot be parsed.
    static func apnsEnvironment(fromProvisioningProfile data: Data) -> String? {
        guard let plistStart = data.range(of: Data("<plist".utf8)),
              let plistEnd = data.range(of: Data("</plist>".utf8), in: plistStart.upperBound..<data.endIndex) else {
            return nil
        }
        let plistData = data.subdata(in: plistStart.lowerBound..<plistEnd.upperBound)
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let value = entitlements["aps-environment"] as? String else {
            return nil
        }
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "development":
            return "sandbox"
        case "production":
            return "production"
        default:
            return nil
        }
    }

    static func tokenHex(from data: Data) -> String {
        data.map { byte in
            let hex = String(byte, radix: 16)
            return hex.count == 1 ? "0" + hex : hex
        }
        .joined()
    }

    static func topic(bundleIdentifier: String?) -> String {
        let trimmed = bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultTopic : trimmed
    }
}

struct ApplePushRegistrationIdentity: Equatable {
    let account: RefreshAccountIdentity
    let profileID: String
}

@MainActor
final class ApplePushRegistrationCoordinator {
    static let shared = ApplePushRegistrationCoordinator()

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "org.siloserver.silo",
        category: "ApplePush"
    )

    private var lastDeviceToken: Data?
    private var inFlightFingerprint: String?
    private var lastSuccessfulFingerprint: String?
    private var endpointUnsupportedForContext: String?
    /// Fingerprint the server last answered without a display token, and
    /// when. Time-bounded rather than process-lifetime so a server upgrade
    /// is noticed by a long-resident app.
    private var displayTokenUnavailable: (fingerprint: String, at: Date)?
    private static let displayTokenUnavailableRetryInterval: TimeInterval = 6 * 60 * 60
    private let displayTokenStore = ApplePushDisplayTokenStore()

    private init() {}

    func prepareForAuthenticatedProfile() async {
        guard AuthService.shared.hasServer, AuthService.shared.hasProfile else {
            return
        }

        let center = UNUserNotificationCenter.current()
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            UIApplication.shared.registerForRemoteNotifications()
        case .notDetermined:
            do {
                let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
                guard granted else {
                    Self.logger.info("User declined Apple push notification authorization")
                    return
                }
                UIApplication.shared.registerForRemoteNotifications()
            } catch {
                Self.logger.error("Apple push authorization request failed: \(String(describing: error), privacy: .public)")
            }
        case .denied:
            Self.logger.info("Apple push notification authorization is denied")
        @unknown default:
            Self.logger.info("Apple push notification authorization is in an unknown state")
        }
    }

    func didRegisterForRemoteNotifications(deviceToken: Data) async {
        lastDeviceToken = deviceToken
        await registerCurrentDeviceTokenIfPossible()
    }

    func didFailToRegisterForRemoteNotifications(error: Error) {
        Self.logger.error("APNs device-token registration failed: \(String(describing: error), privacy: .public)")
    }

    func registerCurrentDeviceTokenIfPossible() async {
        guard AuthService.shared.hasServer, AuthService.shared.hasProfile else {
            return
        }
        guard let lastDeviceToken else {
            return
        }
        // The cached token can outlive the user's permission: if they revoke
        // notification authorization in Settings, a later foreground or
        // profile switch must not re-upload the token for the new context.
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            break
        default:
            return
        }

        let request = makeRegistrationRequest(deviceToken: lastDeviceToken)
        let fingerprint = registrationFingerprint(for: request)
        guard fingerprint != inFlightFingerprint,
              fingerprint != endpointUnsupportedForContext else {
            return
        }
        // Registration is normally deduplicated per fingerprint for the
        // process lifetime. The display token is the exception: a session
        // sign-out clears it (TokenStore) without changing the fingerprint,
        // it expires on its own schedule, and a server upgrade starts
        // returning one for an unchanged registration. Re-register while the
        // slot is empty or near expiry so the extension keeps a live
        // credential without waiting for a token or profile change.
        if fingerprint == lastSuccessfulFingerprint {
            if displayTokenStore.hasCurrentToken() { return }
            if let unavailable = displayTokenUnavailable,
               unavailable.fingerprint == fingerprint,
               Date().timeIntervalSince(unavailable.at) < Self.displayTokenUnavailableRetryInterval {
                return
            }
        }

        inFlightFingerprint = fingerprint
        defer { inFlightFingerprint = nil }

        // Snapshot the identity the registration is for. The response may
        // land after a sign-out, server switch, or profile change has already
        // cleared the display-token slot for the new context; writing the
        // old context's token into it would resurrect a revoked credential.
        let identityBefore = await Self.currentIdentity()

        do {
            let response: ApplePushRegistrationResponse = try await HTTPClient.shared.post(
                ApplePushRegistrationWire.endpoint,
                body: request
            )
            guard await Self.currentIdentity() == identityBefore else {
                Self.logger.info("Discarding Apple push registration response: identity changed while in flight")
                return
            }
            lastSuccessfulFingerprint = fingerprint
            endpointUnsupportedForContext = nil
            // Always store, even when nil: a server downgrade or a profile
            // switch to an older server must not leave a token issued for a
            // different profile in the extension's slot.
            let storedDisplayToken = displayTokenStore.store(
                response.displayToken,
                expiresAt: response.displayTokenExpiresAt,
                serverId: identityBefore?.account.serverId ?? ""
            )
            // Older servers return none; back off for this context for a while.
            displayTokenUnavailable = response.displayToken == nil ? (fingerprint, Date()) : nil
            Self.logger.info("Registered APNs token with Silo server_device_id=\(response.serverDeviceId, privacy: .private) enabled=\(response.enabled, privacy: .public) displayToken=\(response.displayToken != nil, privacy: .public) stored=\(storedDisplayToken, privacy: .public)")
        } catch HTTPError.http(let statusCode, _) where statusCode == 404 || statusCode == 405 {
            endpointUnsupportedForContext = fingerprint
            Self.logger.info("Apple push device endpoint is not available on this Silo server yet")
        } catch {
            Self.logger.error("Apple push device registration failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The account (server + credential generation) and profile a
    /// registration belongs to. Any change, including a sign-out and
    /// sign-in to the same server, produces a different value.
    private static func currentIdentity() async -> ApplePushRegistrationIdentity? {
        guard let account = await TokenStore.shared.refreshAccountIdentity() else { return nil }
        return ApplePushRegistrationIdentity(
            account: account,
            profileID: await TokenStore.shared.getProfileId() ?? ""
        )
    }

    private func makeRegistrationRequest(deviceToken: Data) -> ApplePushRegistrationRequest {
        ApplePushRegistrationRequest(
            deviceId: AppleDeviceIdentity.current.id,
            apnsToken: ApplePushRegistrationWire.tokenHex(from: deviceToken),
            apnsEnvironment: ApplePushRegistrationWire.currentAPNsEnvironment,
            apnsTopic: ApplePushRegistrationWire.topic(bundleIdentifier: Bundle.main.bundleIdentifier),
            pushMode: ApplePushRegistrationWire.privatePushMode
        )
    }

    private func registrationFingerprint(for request: ApplePushRegistrationRequest) -> String {
        [
            ServerRegistry.shared.activeServerId ?? "",
            AuthService.shared.profileId ?? "",
            request.deviceId,
            request.apnsToken,
            request.apnsEnvironment,
            request.apnsTopic,
            request.pushMode
        ]
        .joined(separator: "|")
    }
}
#endif
